#!/usr/bin/env node

// ============================================================
const MC_ROOT = '/opt/minecraft-bedrock-server';
const DL_DIR  = '/root/Downloads/minecraft';
// ============================================================

const blessed = require('blessed');
const AdmZip  = require('adm-zip');
const fs      = require('fs');
const path    = require('path');

const BP_DIR     = path.join(MC_ROOT, 'behavior_packs');
const RP_DIR     = path.join(MC_ROOT, 'resource_packs');
const WORLDS_DIR = path.join(MC_ROOT, 'worlds');
const TEMP_DIR   = '/tmp/mc_addon_install';

const screen = blessed.screen({ smartCSR: true, title: 'MC Addon Manager' });

let worldName   = null;
let worldBPJson = null;
let worldRPJson = null;
let mainBox     = null;

function readJson(p) {
  try { return JSON.parse(fs.readFileSync(p, 'utf8')); }
  catch { return null; }
}

function writeJson(p, data) {
  fs.writeFileSync(p, JSON.stringify(data, null, '\t'));
}

function parseVer(arr) {
  if (!Array.isArray(arr)) return '0.0.0';
  return arr.join('.');
}

function detectPackType(manifest) {
  const types = (manifest.modules || []).map(m => m.type);
  if (types.includes('resources')) return 'RP';
  return 'BP';
}

function cmpVer(a, b) {
  const pa = a.split('.').map(Number);
  const pb = b.split('.').map(Number);
  for (let i = 0; i < 3; i++) {
    if ((pa[i]||0) > (pb[i]||0)) return 1;
    if ((pa[i]||0) < (pb[i]||0)) return -1;
  }
  return 0;
}

function scanPackDir(dir) {
  const packs = {};
  if (!fs.existsSync(dir)) return packs;
  for (const folder of fs.readdirSync(dir)) {
    const mp = path.join(dir, folder, 'manifest.json');
    if (!fs.existsSync(mp)) continue;
    const m = readJson(mp);
    if (!m?.header?.uuid) continue;
    const uuid = m.header.uuid;
    const ver  = parseVer(m.header.version);
    const name = (m.header.name && !m.header.name.startsWith('pack.')) ? m.header.name : folder;
    if (packs[uuid] && cmpVer(ver, packs[uuid].version) <= 0) continue;
    packs[uuid] = {
      uuid, name, version: ver,
      type:  detectPackType(m),
      deps:  (m.dependencies || []).map(d => d.uuid).filter(Boolean),
      folder, dir,
    };
  }
  return packs;
}

function buildAddonGroups(bpPacks, rpPacks) {
  const groups = {};
  const addToGroup = (key, pack) => {
    if (!groups[key]) groups[key] = { name: pack.name, bp: null, rp: null };
    if (pack.type === 'BP') groups[key].bp = pack;
    else groups[key].rp = pack;
  };

  const linked = new Set();
  for (const [uuid, pack] of Object.entries(bpPacks)) {
    const rpDep = pack.deps.find(d => rpPacks[d]);
    if (rpDep) {
      linked.add(uuid);
      linked.add(rpDep);
      addToGroup(uuid, pack);
      addToGroup(uuid, rpPacks[rpDep]);
    }
  }
  for (const [uuid, pack] of Object.entries(rpPacks)) {
    const bpDep = pack.deps.find(d => bpPacks[d]);
    if (bpDep && !linked.has(uuid)) {
      linked.add(uuid);
      linked.add(bpDep);
      addToGroup(bpDep, bpPacks[bpDep]);
      addToGroup(bpDep, pack);
    }
  }
  for (const [uuid, pack] of Object.entries(bpPacks)) {
    if (!linked.has(uuid)) { addToGroup('bp_' + uuid, pack); }
  }
  for (const [uuid, pack] of Object.entries(rpPacks)) {
    if (!linked.has(uuid)) { addToGroup('rp_' + uuid, pack); }
  }

  return groups;
}

function isActive(uuid) {
  const inBP = (worldBPJson || []).some(e => e.pack_id === uuid);
  const inRP = (worldRPJson || []).some(e => e.pack_id === uuid);
  return inBP || inRP;
}

function activateGroup(group) {
  const bpPath = path.join(WORLDS_DIR, worldName, 'world_behavior_packs.json');
  const rpPath = path.join(WORLDS_DIR, worldName, 'world_resource_packs.json');

  if (group.bp) {
    worldBPJson = worldBPJson || [];
    if (!worldBPJson.some(e => e.pack_id === group.bp.uuid)) {
      worldBPJson.push({ pack_id: group.bp.uuid, version: group.bp.version.split('.').map(Number) });
      writeJson(bpPath, worldBPJson);
    }
  }
  if (group.rp) {
    worldRPJson = worldRPJson || [];
    if (!worldRPJson.some(e => e.pack_id === group.rp.uuid)) {
      worldRPJson.push({ pack_id: group.rp.uuid, version: group.rp.version.split('.').map(Number) });
      writeJson(rpPath, worldRPJson);
    }
  }
}

function deactivateGroup(group) {
  const bpPath = path.join(WORLDS_DIR, worldName, 'world_behavior_packs.json');
  const rpPath = path.join(WORLDS_DIR, worldName, 'world_resource_packs.json');

  if (group.bp && worldBPJson) {
    worldBPJson = worldBPJson.filter(e => e.pack_id !== group.bp.uuid);
    writeJson(bpPath, worldBPJson);
  }
  if (group.rp && worldRPJson) {
    worldRPJson = worldRPJson.filter(e => e.pack_id !== group.rp.uuid);
    writeJson(rpPath, worldRPJson);
  }
}

function extractToTemp(file) {
  const base = path.basename(file).replace(/\.[^.]+$/, '');
  const dest = path.join(TEMP_DIR, base);
  fs.mkdirSync(dest, { recursive: true });
  const zip = new AdmZip(file);
  zip.extractAllTo(dest, true);
  return dest;
}

function findManifests(dir) {
  const results = [];
  const walk = (d, depth) => {
    if (depth > 4) return;
    for (const entry of fs.readdirSync(d)) {
      const full = path.join(d, entry);
      const stat = fs.statSync(full);
      if (stat.isDirectory()) walk(full, depth + 1);
      else if (entry === 'manifest.json') results.push(full);
    }
  };
  walk(dir, 0);
  return results;
}

function extractNested(dir) {
  let found = true;
  while (found) {
    found = false;
    const walk = (d) => {
      for (const entry of fs.readdirSync(d)) {
        const full = path.join(d, entry);
        if (fs.statSync(full).isDirectory()) { walk(full); continue; }
        if (/\.(mcpack|mcaddon|zip)$/.test(entry)) {
          found = true;
          const dest = path.join(d, path.basename(entry).replace(/\.[^.]+$/, ''));
          fs.mkdirSync(dest, { recursive: true });
          try { new AdmZip(full).extractAllTo(dest, true); } catch {}
          fs.unlinkSync(full);
        }
      }
    };
    walk(dir);
  }
}

function scanDownloads() {
  if (!fs.existsSync(DL_DIR)) return [];
  return fs.readdirSync(DL_DIR)
    .filter(f => /\.(mcpack|mcaddon|zip)$/.test(f))
    .map(f => path.join(DL_DIR, f));
}

function buildInstallPreview(bpPacks, rpPacks) {
  const files = scanDownloads();
  if (files.length === 0) return { items: [], files: [] };

  if (fs.existsSync(TEMP_DIR)) fs.rmSync(TEMP_DIR, { recursive: true });
  fs.mkdirSync(TEMP_DIR, { recursive: true });

  const preview = [];
  for (const file of files) {
    try {
      const dest = extractToTemp(file);
      extractNested(dest);
      const manifests = findManifests(dest);
      for (const mp of manifests) {
        const m = readJson(mp);
        if (!m?.header?.uuid) continue;
        const type    = detectPackType(m);
        const uuid    = m.header.uuid;
        const rawName = m.header.name || '';
        const name    = (rawName && !rawName.startsWith('pack.')) ? rawName : path.basename(path.dirname(mp));
        const newVer  = parseVer(m.header.version);
        const existing = type === 'BP' ? bpPacks[uuid] : rpPacks[uuid];
        preview.push({
          file: path.basename(file),
          name, uuid, type, newVer,
          existing: existing ? { name: existing.name, version: existing.version, folder: existing.folder } : null,
          packRoot: path.dirname(mp),
        });
      }
    } catch {}
  }
  return { items: preview, files };
}

function doInstall(preview, sourceFiles) {
  for (const p of preview) {
    const destBase = p.type === 'BP' ? BP_DIR : RP_DIR;
    const existingFolder = p.existing?.folder;
    const isLiteralName = existingFolder && /^pack[._]/.test(existingFolder);
    const folderName = (!existingFolder || isLiteralName)
      ? p.name.replace(/[^a-zA-Z0-9_\- []]/g, '_')
      : existingFolder;
    const dest = path.join(destBase, folderName);
    if (fs.existsSync(dest)) fs.rmSync(dest, { recursive: true });
    fs.cpSync(p.packRoot, dest, { recursive: true });
  }
  if (fs.existsSync(TEMP_DIR)) fs.rmSync(TEMP_DIR, { recursive: true });

  const doneDir = path.join(DL_DIR, 'Instalados');
  fs.mkdirSync(doneDir, { recursive: true });
  for (const f of sourceFiles) {
    const dest = path.join(doneDir, path.basename(f));
    try {
      if (fs.existsSync(dest)) fs.unlinkSync(dest);
      fs.renameSync(f, dest);
    } catch {}
  }
}

function showWorldScreen() {
  screen.children.slice().forEach(c => c.detach());

  const bpPacks = scanPackDir(BP_DIR);
  const rpPacks = scanPackDir(RP_DIR);
  const groups  = buildAddonGroups(bpPacks, rpPacks);

  const bpPath = path.join(WORLDS_DIR, worldName, 'world_behavior_packs.json');
  const rpPath = path.join(WORLDS_DIR, worldName, 'world_resource_packs.json');
  worldBPJson  = readJson(bpPath) || [];
  worldRPJson  = readJson(rpPath) || [];

  const header = blessed.box({
    top: 0, left: 0, width: '100%', height: 3,
    content: ` MC Addon Manager — World: {bold}${worldName}{/bold}  |  {cyan-fg}Enter{/cyan-fg} toggle  {cyan-fg}I{/cyan-fg} install  {cyan-fg}Q{/cyan-fg} quit`,
    tags: true,
    style: { bg: 'black', fg: 'white' },
  });

  const list = blessed.list({
    top: 3, left: 0, width: '100%', height: '100%-3',
    keys: true, vi: true, mouse: true,
    tags: true,
    scrollable: true, scrollbar: { ch: '|' },
    style: {
      selected: { bg: 'blue', fg: 'white' },
      item: { fg: 'white' },
    },
  });

  const entries = Object.entries(groups);

  const buildItems = () => entries.map(([, g]) => {
    const active = (g.bp && isActive(g.bp.uuid)) || (g.rp && isActive(g.rp.uuid));
    const tags   = [g.bp ? 'BP' : null, g.rp ? 'RP' : null].filter(Boolean).join('+');
    const ver    = g.bp?.version || g.rp?.version || '';
    const state  = active ? '{green-fg}[ON] {/}' : '{red-fg}[OFF]{/}';
    return `${state} [${tags}] ${g.name} v${ver}`;
  });

  list.setItems(buildItems());

  list.on('select', (_, idx) => {
    const [, group] = entries[idx];
    const active = (group.bp && isActive(group.bp.uuid)) || (group.rp && isActive(group.rp.uuid));
    if (active) deactivateGroup(group); else activateGroup(group);
    list.setItems(buildItems());
    list.select(idx);
    screen.render();
  });

  screen.key(['i', 'I'], () => showInstallScreen(bpPacks, rpPacks));
  screen.key(['q', 'Q', 'C-c'], () => process.exit(0));

  screen.append(header);
  screen.append(list);
  list.focus();
  screen.render();
}

function showInstallScreen(bpPacks, rpPacks) {
  screen.children.slice().forEach(c => c.detach());

  const loading = blessed.box({
    top: 'center', left: 'center', width: 40, height: 3,
    content: ' Escaneando archivos...',
    style: { bg: 'black', fg: 'yellow' },
  });
  screen.append(loading);
  screen.render();

  let result;
  try { result = buildInstallPreview(bpPacks, rpPacks); }
  catch (e) { result = { items: [], files: [] }; }

  const { items: preview, files: srcFiles } = result;

  screen.children.slice().forEach(c => c.detach());

  const header = blessed.box({
    top: 0, left: 0, width: '100%', height: 3,
    content: ` Instalar Addons  |  {cyan-fg}Enter{/cyan-fg} confirmar  {cyan-fg}B{/cyan-fg} volver  {cyan-fg}Q{/cyan-fg} salir`,
    tags: true,
    style: { bg: 'black', fg: 'white' },
  });

  const lines = preview.length === 0
    ? ['{yellow-fg}Sin archivos en ' + DL_DIR + '{/}']
    : preview.map(p => {
        const action = p.existing
          ? `{yellow-fg}[ACTUALIZAR]{/} ${p.existing.name} v${p.existing.version} -> v${p.newVer}`
          : `{green-fg}[NUEVO]{/} v${p.newVer}`;
        return `[${p.type}] ${p.name}  ${action}`;
      });

  const list = blessed.box({
    top: 3, left: 0, width: '100%', height: '100%-3',
    content: lines.join('\n'),
    tags: true, scrollable: true, scrollbar: { ch: '|' },
    keys: true, vi: true, mouse: true,
    style: { fg: 'white', bg: 'black' },
  });

  screen.removeAllListeners('keypress');
  screen.key(['b', 'B'], () => showWorldScreen());
  screen.key(['q', 'Q', 'C-c'], () => process.exit(0));

  if (preview.length > 0) {
    screen.key('enter', () => {
      try {
        doInstall(preview, srcFiles);
        list.setContent('{green-fg}Instalacion completada. B para volver.{/}');
      } catch (e) {
        list.setContent(`{red-fg}Error: ${e.message}{/}`);
      }
      screen.render();
    });
  }

  screen.append(header);
  screen.append(list);
  list.focus();
  screen.render();
}

function showWorldSelect() {
  if (!fs.existsSync(WORLDS_DIR)) {
    console.error('No existe: ' + WORLDS_DIR);
    process.exit(1);
  }

  const worlds = fs.readdirSync(WORLDS_DIR)
    .filter(f => fs.statSync(path.join(WORLDS_DIR, f)).isDirectory());

  if (worlds.length === 0) {
    console.error('Sin mundos en ' + WORLDS_DIR);
    process.exit(1);
  }

  const box = blessed.box({
    top: 0, left: 0, width: '100%', height: 3,
    content: ' MC Addon Manager — Selecciona un mundo',
    style: { bg: 'black', fg: 'white' },
  });

  const list = blessed.list({
    top: 3, left: 'center', width: 60, height: worlds.length + 2,
    keys: true, vi: true, mouse: true,
    border: { type: 'line' },
    style: {
      border: { fg: 'cyan' },
      selected: { bg: 'blue', fg: 'white' },
      item: { fg: 'white' },
    },
    items: worlds,
  });

  list.on('select', (item) => {
    worldName = item.getText();
    showWorldScreen();
  });

  screen.key(['q', 'Q', 'C-c'], () => process.exit(0));
  screen.append(box);
  screen.append(list);
  list.focus();
  screen.render();
}

showWorldSelect();
