#!/usr/bin/env node

const ENV_PATH = require('path').resolve(__dirname, '..', '.env');
require('dotenv').config({ path: ENV_PATH });

const blessed = require('blessed');
const AdmZip  = require('adm-zip');
const fs      = require('fs');
const path    = require('path');
const { spawnSync } = require('child_process');

let MC_ROOT  = process.env.MC_ROOT  || '/opt/minecraft-bedrock-server';
let DL_DIR   = process.env.DL_DIR   || path.join(__dirname, '..', 'resources');
let TEMP_DIR = process.env.TEMP_DIR || '/tmp/mc_addon_install';

const screen = blessed.screen({ smartCSR: true, title: 'MC Addon Manager' });

let worldName   = null;
let worldBPJson = null;
let worldRPJson = null;

const getDirs = () => {
  const wBase = process.env.WORLDS_DIR ||
    ['worlds', 'minecraftWorlds'].map(d => path.join(MC_ROOT, d)).find(fs.existsSync) ||
    path.join(MC_ROOT, 'worlds');
  return {
    BP:     process.env.BP_DIR || path.join(MC_ROOT, 'behavior_packs'),
    RP:     process.env.RP_DIR || path.join(MC_ROOT, 'resource_packs'),
    WORLDS: wBase,
  };
};

function upsertEnv(key, value) {
  let src = '';
  try { src = fs.readFileSync(ENV_PATH, 'utf8'); } catch {}
  const re = new RegExp('^' + key + '=.*$', 'm');
  const line = key + '=' + value;
  src = re.test(src) ? src.replace(re, line) : src + (src && !src.endsWith('\n') ? '\n' : '') + line + '\n';
  fs.writeFileSync(ENV_PATH, src);
  process.env[key] = value;
}

const ROUTE_VARS = [
  { key: 'MC_ROOT',    get: () => MC_ROOT,               set: v => { MC_ROOT  = v; }, optional: false,
    title: 'Selecciona MC_ROOT (servidor Minecraft)',     default: '/opt/minecraft-bedrock-server' },
  { key: 'BP_DIR',     get: () => process.env.BP_DIR,    set: () => {}, optional: true,
    title: 'Selecciona BP_DIR (behavior_packs)',          default: null },
  { key: 'RP_DIR',     get: () => process.env.RP_DIR,    set: () => {}, optional: true,
    title: 'Selecciona RP_DIR (resource_packs)',          default: null },
  { key: 'WORLDS_DIR', get: () => process.env.WORLDS_DIR,set: () => {}, optional: true,
    title: 'Selecciona WORLDS_DIR (mundos)',              default: null },
];

function needsPicker(entry) {
  const val = entry.get();
  if (entry.optional) return val && !fs.existsSync(val);
  return !val || !fs.existsSync(val);
}

function runValidation(vars, idx, onDone) {
  if (idx >= vars.length) return onDone();
  const entry = vars[idx];
  if (!needsPicker(entry)) return runValidation(vars, idx + 1, onDone);
  const start = entry.get() || entry.default || '/';
  showFilePicker(
    entry.title,
    fs.existsSync(start) ? start : '/',
    (selected) => {
      entry.set(selected);
      upsertEnv(entry.key, selected);
      runValidation(vars, idx + 1, onDone);
    },
    () => {
      if (!entry.optional) {
        screen.destroy();
        process.stderr.write('Ruta requerida no configurada: ' + entry.key + '\n');
        process.exit(1);
      }
      runValidation(vars, idx + 1, onDone);
    }
  );
}

function readJson(p) {
  try { return JSON.parse(fs.readFileSync(p, 'utf8')); }
  catch { return null; }
}

function writeJson(p, data) {
  fs.writeFileSync(p, JSON.stringify(data, null, '\t'));
}

function dirSize(dir) {
  let bytes = 0;
  const walk = (d) => {
    try {
      for (const f of fs.readdirSync(d)) {
        const full = path.join(d, f);
        try {
          const st = fs.statSync(full);
          if (st.isDirectory()) walk(full);
          else bytes += st.size;
        } catch {}
      }
    } catch {}
  };
  walk(dir);
  if (bytes < 1024)        return bytes + ' B';
  if (bytes < 1024 * 1024) return (bytes / 1024).toFixed(1) + ' KB';
  return (bytes / (1024 * 1024)).toFixed(1) + ' MB';
}

function parseVer(v) {
  if (Array.isArray(v)) return v.join('.');
  if (typeof v === 'string') return v;
  return '0.0.0';
}

function stripCodes(s) {
  return (s || '').replace(/§./g, '').trim();
}

function sanitizeName(s) {
  return s.replace(/[^a-zA-Z]/g, '').trim();
}

function sanitizePath(s) {
  return s.replace(/[^a-zA-Z0-9._-]/g, '_').trim();
}

function parseManifestInfo(m) {
  const h   = m.header || {};
  const name = stripCodes(h.name);
  const desc = stripCodes(h.description);
  const ver  = parseVer(h.version);
  const minEng = parseVer(h.min_engine_version);
  const authors = (m.metadata?.authors || []).join(', ');
  const caps = (m.capabilities || []).join(', ');
  const subpacks = (m.subpacks || []).map(s => s.name ? stripCodes(s.name) : s.folder_name);

  const depPacks   = [];
  const depModules = [];
  for (const d of (m.dependencies || [])) {
    if (d.module_name) depModules.push(d.module_name + ' ' + parseVer(d.version));
    else if (d.uuid)   depPacks.push(d.uuid + ' v' + parseVer(d.version));
  }

  return { name, desc, ver, minEng, authors, caps, subpacks, depPacks, depModules,
           uuid: h.uuid, formatVersion: m.format_version };
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

function isNativePack(packDir, m) {
  if (!fs.existsSync(path.join(packDir, 'pack_icon.png'))) return true;
  const ver = m.header.version || [];
  if (ver[0] === 0 && ver[1] === 0 && ver[2] === 1) return true;
  if ((m.header.name || '').includes('@minecraft')) return true;
  return false;
}

function scanPackDir(dir, hideNative) {
  const packs = {};
  if (!fs.existsSync(dir)) return packs;
  for (const folder of fs.readdirSync(dir)) {
    const packDir = path.join(dir, folder);
    const mp = path.join(packDir, 'manifest.json');
    if (!fs.existsSync(mp)) continue;
    const m = readJson(mp);
    if (!m?.header?.uuid) continue;
    if (hideNative && isNativePack(packDir, m)) continue;
    const uuid = m.header.uuid;
    const info = parseManifestInfo(m);
    const ver  = info.ver;
    const name = (info.name && !m.header.name?.startsWith('pack.')) ? info.name : folder;
    if (packs[uuid] && cmpVer(ver, packs[uuid].version) <= 0) continue;
    packs[uuid] = { uuid, name, desc: info.desc, version: ver, type: detectPackType(m),
      deps: (m.dependencies || []).map(d => d.uuid).filter(Boolean), folder, dir, manifest: m };
  }
  return packs;
}

function buildAddonGroups(bpPacks, rpPacks) {
  const groups = {};
  const addToGroup = (key, pack) => {
    if (!groups[key]) groups[key] = { name: pack.name, desc: pack.desc, bp: null, rp: null };
    if (pack.type === 'BP') groups[key].bp = pack;
    else groups[key].rp = pack;
  };
  const linked = new Set();
  for (const [uuid, pack] of Object.entries(bpPacks)) {
    const rpDep = pack.deps.find(d => rpPacks[d]);
    if (rpDep) {
      linked.add(uuid); linked.add(rpDep);
      addToGroup(uuid, pack); addToGroup(uuid, rpPacks[rpDep]);
    }
  }
  for (const [uuid, pack] of Object.entries(rpPacks)) {
    const bpDep = pack.deps.find(d => bpPacks[d]);
    if (bpDep && !linked.has(uuid)) {
      linked.add(uuid); linked.add(bpDep);
      addToGroup(bpDep, bpPacks[bpDep]); addToGroup(bpDep, pack);
    }
  }
  for (const [uuid, pack] of Object.entries(bpPacks))
    if (!linked.has(uuid)) addToGroup('bp_' + uuid, pack);
  for (const [uuid, pack] of Object.entries(rpPacks))
    if (!linked.has(uuid)) addToGroup('rp_' + uuid, pack);
  return groups;
}

function isActive(uuid) {
  return (worldBPJson || []).some(e => e.pack_id === uuid) ||
         (worldRPJson || []).some(e => e.pack_id === uuid);
}

function activateGroup(group) {
  const { WORLDS } = getDirs();
  const bpPath = path.join(WORLDS, worldName, 'world_behavior_packs.json');
  const rpPath = path.join(WORLDS, worldName, 'world_resource_packs.json');
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
  const { WORLDS } = getDirs();
  const bpPath = path.join(WORLDS, worldName, 'world_behavior_packs.json');
  const rpPath = path.join(WORLDS, worldName, 'world_resource_packs.json');
  if (group.bp && worldBPJson) {
    worldBPJson = worldBPJson.filter(e => e.pack_id !== group.bp.uuid);
    writeJson(bpPath, worldBPJson);
  }
  if (group.rp && worldRPJson) {
    worldRPJson = worldRPJson.filter(e => e.pack_id !== group.rp.uuid);
    writeJson(rpPath, worldRPJson);
  }
}

function deleteGroup(group) {
  const { BP, RP } = getDirs();
  if (group.bp) { const p = path.join(BP, group.bp.folder); if (fs.existsSync(p)) fs.rmSync(p, { recursive: true }); }
  if (group.rp) { const p = path.join(RP, group.rp.folder); if (fs.existsSync(p)) fs.rmSync(p, { recursive: true }); }
}

function getMCOwner() {
  const stat = fs.statSync(MC_ROOT);
  return { uid: stat.uid, gid: stat.gid };
}

function checkOwnership(installedPaths) {
  const { uid, gid } = getMCOwner();
  return installedPaths.some(p => {
    if (!fs.existsSync(p)) return false;
    const s = fs.statSync(p);
    return s.uid !== uid || s.gid !== gid;
  });
}

function fixOwnership(installedPaths) {
  const { uid, gid } = getMCOwner();
  screen.program.disableMouse();
  screen.program.showCursor();
  screen.program.normalBuffer();
  process.stdout.write('\n');
  for (const p of installedPaths) {
    if (!fs.existsSync(p)) continue;
    const result = spawnSync('sudo', ['chown', '-R', `${uid}:${gid}`, p], { stdio: 'inherit' });
    if (result.status !== 0) process.stdout.write('Error chown: ' + p + '\n');
  }
  screen.program.enableMouse();
  screen.program.hideCursor();
  screen.program.alternateBuffer();
  screen.alloc();
  screen.render();
}

function showWait(label, fn) {
  const b = blessed.box({
    top: 'center', left: 'center', width: 50, height: 5,
    border: { type: 'line' }, tags: true,
    content: '\n  ⏳ ' + label,
    style: { border: { fg: 'yellow' }, bg: 'black', fg: 'yellow' },
  });
  screen.append(b);
  screen.render();
  setImmediate(() => { fn(); b.detach(); screen.render(); });
}

function extractToTemp(file) {
  const base = sanitizePath(path.basename(file).replace(/\.[^.]+$/, ''));
  const dest = path.join(TEMP_DIR, base);
  fs.mkdirSync(dest, { recursive: true });
  new AdmZip(file).extractAllTo(dest, true);
  return dest;
}

function findManifests(dir) {
  const results = [];
  const walk = (d, depth) => {
    if (depth > 4) return;
    for (const entry of fs.readdirSync(d)) {
      const full = path.join(d, entry);
      if (fs.statSync(full).isDirectory()) walk(full, depth + 1);
      else if (entry === 'manifest.json') results.push(full);
    }
  };
  walk(dir, 0);
  return results;
}

function extractNested(dir, onFile) {
  let found = true;
  while (found) {
    found = false;
    const walk = (d) => {
      for (const entry of fs.readdirSync(d)) {
        const full = path.join(d, entry);
        if (fs.statSync(full).isDirectory()) { walk(full); continue; }
        if (/\.(mcpack|mcaddon|zip)$/.test(entry)) {
          found = true;
          if (onFile) onFile(entry);
          const dest = path.join(d, sanitizePath(path.basename(entry).replace(/\.[^.]+$/, '')));
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
  const entries = [];
  if (!fs.existsSync(DL_DIR)) return entries;
  for (const f of fs.readdirSync(DL_DIR)) {
    const full = path.join(DL_DIR, f);
    if (/\.(mcpack|mcaddon|zip)$/.test(f))
      entries.push({ full, isDir: false });
    else if (fs.statSync(full).isDirectory())
      entries.push({ full, isDir: true });
  }
  return entries;
}

function buildInstallPreview(bpPacks, rpPacks) {
  const { BP, RP } = getDirs();
  const entries = scanDownloads();
  if (entries.length === 0) return { items: [], files: [] };

  if (fs.existsSync(TEMP_DIR)) fs.rmSync(TEMP_DIR, { recursive: true });
  fs.mkdirSync(TEMP_DIR, { recursive: true });

  const preview = [];
  const sourceFiles = [];

  for (const entry of entries) {
    try {
      let scanDir;
      if (entry.isDir) {
        scanDir = entry.full;
      } else {
        scanDir = extractToTemp(entry.full);
        extractNested(scanDir, () => {});
      }

      for (const mp of findManifests(scanDir)) {
        const m = readJson(mp);
        if (!m?.header?.uuid) continue;
        const type    = detectPackType(m);
        const uuid    = m.header.uuid;
        const rawName = m.header.name || '';
        const name    = sanitizeName(stripCodes((rawName && !rawName.startsWith('pack.')) ? rawName : path.basename(path.dirname(mp))));
        const newVer  = parseVer(m.header.version);
        const existing = type === 'BP' ? bpPacks[uuid] : rpPacks[uuid];
        const downgrade = existing ? cmpVer(newVer, existing.version) < 0 : false;
        preview.push({ file: path.basename(entry.full), name, uuid, type, newVer, isDir: entry.isDir, downgrade,
          existing: existing ? { name: existing.name, version: existing.version, folder: existing.folder } : null,
          packRoot: path.dirname(mp) });
      }
      sourceFiles.push(entry);

      if (!entry.isDir) {
        if (fs.existsSync(scanDir)) fs.rmSync(scanDir, { recursive: true });
      }

    } catch {}
  }

  return { items: preview, files: sourceFiles };
}

function doInstall(preview, sourceFiles) {
  const { BP, RP } = getDirs();
  const installed = [];

  const needsTmp = preview.some(p => !p.downgrade && !p.isDir);
  if (needsTmp) {
    if (fs.existsSync(TEMP_DIR)) fs.rmSync(TEMP_DIR, { recursive: true });
    fs.mkdirSync(TEMP_DIR, { recursive: true });
  }

  const reExtracted = new Map();

  for (const p of preview) {
    if (p.downgrade) continue;

    const destBase = p.type === 'BP' ? BP : RP;
    const existingFolder = p.existing?.folder;
    let baseName = existingFolder || sanitizeName(p.name);
    if (!baseName) {
      let n = 1;
      while (fs.existsSync(path.join(destBase, 'pack' + n))) n++;
      baseName = 'pack' + n;
    }
    const dest = path.join(destBase, baseName);


    let packRoot = p.packRoot;

    if (!p.isDir && !fs.existsSync(packRoot)) {
      const srcFile = path.join(DL_DIR, p.file);
      const cacheKey = p.file;
      if (!reExtracted.has(cacheKey)) {
        if (fs.existsSync(srcFile)) {
          const tmpDest = extractToTemp(srcFile);
          extractNested(tmpDest, () => {});
          reExtracted.set(cacheKey, tmpDest);
        }
      }
      const base = reExtracted.get(cacheKey);
      if (base) {
        const manifests = findManifests(base);
        const match = manifests.find(mp => {
          const m = readJson(mp);
          return m?.header?.uuid === p.uuid;
        });
        if (match) packRoot = path.dirname(match);
      }
    }

    if (!fs.existsSync(packRoot)) continue;

    if (fs.existsSync(dest)) fs.rmSync(dest, { recursive: true });
    fs.cpSync(packRoot, dest, { recursive: true });
    installed.push(dest);
  }

  if (fs.existsSync(TEMP_DIR)) fs.rmSync(TEMP_DIR, { recursive: true });

  const doneDir = path.join('Instalados');
  fs.mkdirSync(doneDir, { recursive: true });
  const moved = new Set();
  for (const entry of sourceFiles) {
    if (moved.has(entry.full)) continue;
    moved.add(entry.full);
    const dest = path.join(doneDir, path.basename(entry.full));
    try {
      if (fs.existsSync(dest)) { entry.isDir ? fs.rmSync(dest, { recursive: true }) : fs.unlinkSync(dest); }
      fs.renameSync(entry.full, dest);
    } catch {}
  }

  return installed;
}

function showConfirmModal(msg, onYes, onNo) {
  const box = blessed.box({
    top: 'center', left: 'center', width: 64, height: 7,
    border: { type: 'line' }, tags: true,
    content: '\n ' + msg + '\n\n {cyan-fg}[S]{/} Si   {cyan-fg}[N]{/} No',
    style: { border: { fg: 'yellow' }, fg: 'white', bg: 'black' },
  });
  screen.append(box);
  screen.render();
  const cleanup = () => { box.detach(); screen.render(); };
  screen.removeAllListeners('keypress');
  screen.key(['s', 'S'], () => { cleanup(); onYes(); });
  screen.key(['n', 'N', 'escape'], () => { cleanup(); onNo(); });
}

function showFilePicker(title, startPath, onSelect, onCancel) {
  screen.children.slice().forEach(c => c.detach());
  screen.removeAllListeners('keypress');

  let currentPath = startPath;

  const header = blessed.box({
    top: 0, left: 0, width: '100%', height: 3, tags: true,
    content: ' ' + title + '  |  {cyan-fg}k/j{/} arriba/abajo  {cyan-fg}l{/} entrar  {cyan-fg}h{/} atras  {cyan-fg}Enter{/} confirmar aqui  {cyan-fg}Esc{/} cancelar',
    style: { bg: 'black', fg: 'white' },
  });

  const breadcrumb = blessed.box({
    top: 3, left: 0, width: '100%', height: 1,
    tags: true,
    style: { bg: 'blue', fg: 'white' },
  });

  const list = blessed.list({
    top: 4, left: 0, width: '100%', height: '100%-4',
    keys: true, vi: true, mouse: true, tags: true,
    scrollable: true, scrollbar: { ch: '|' },
    style: { selected: { bg: 'blue', fg: 'white' }, item: { fg: 'white' } },
  });

  const refresh = () => {
    breadcrumb.setContent(' ' + currentPath);
    let entries = [];
    try {
      entries = fs.readdirSync(currentPath)
        .map(f => {
          const full = path.join(currentPath, f);
          const isDir = fs.statSync(full).isDirectory();
          return { name: f, isDir };
        })
        .sort((a, b) => {
          if (a.isDir !== b.isDir) return a.isDir ? -1 : 1;
          return a.name.localeCompare(b.name);
        });
    } catch {}
    list.setItems(entries.map(e => e.isDir ? '{cyan-fg}' + e.name + '/{/}' : e.name));
    list._dirEntries = entries;
    screen.render();
  };

  refresh();

  screen.key(['l'], () => {
    const idx = list.selected;
    const entries = list._dirEntries || [];
    if (!entries[idx]) return;
    const entry = entries[idx];
    if (entry.isDir) { currentPath = path.join(currentPath, entry.name); refresh(); }
  });

  screen.key(['h'], () => {
    const parent = path.dirname(currentPath);
    if (parent !== currentPath) { currentPath = parent; refresh(); }
  });

  screen.key('enter', () => onSelect(currentPath));
  screen.key('escape', () => onCancel());

  screen.append(header);
  screen.append(breadcrumb);
  screen.append(list);
  list.focus();
  screen.render();
}

function showDetailModal(group, onClose) {
  const lines = [];
  const addPack = (pack, label) => {
    if (!pack) return;
    const m = pack.manifest || readJson(path.join(pack.dir, pack.folder, 'manifest.json'));
    if (!m) return;
    const i = parseManifestInfo(m);
    lines.push('{cyan-fg}{bold}── ' + label + ' ──{/}');
    lines.push('{white-fg}Nombre:{/}       ' + (i.name || pack.folder));
    lines.push('{white-fg}Descripcion:{/}  ' + (i.desc || 'pack.description'));
    lines.push('{white-fg}Version:{/}      ' + i.ver);
    lines.push('{white-fg}Motor minimo:{/} ' + i.minEng);
    lines.push('{white-fg}UUID:{/}         {gray-fg}' + i.uuid + '{/}');
    lines.push('{white-fg}Formato:{/}      v' + i.formatVersion);
    if (i.authors)              lines.push('{white-fg}Autores:{/}      ' + i.authors);
    if (i.caps)                 lines.push('{white-fg}Capacidades:{/} ' + i.caps);
    if (i.depModules.length)    lines.push('{white-fg}Modulos:{/}      ' + i.depModules.join('  |  '));
    if (i.depPacks.length)      lines.push('{white-fg}Deps (packs):{/} ' + i.depPacks.join('\n              '));
    if (i.subpacks.length)      lines.push('{white-fg}Subpacks:{/}     ' + i.subpacks.join(', '));
    lines.push('');
  };

  addPack(group.bp, 'Behavior Pack');
  addPack(group.rp, 'Resource Pack');

  const modalH = Math.min(lines.length + 4, screen.height - 4);
  const modal = blessed.box({
    top: 'center', left: 'center',
    width: '70%', height: modalH,
    border: { type: 'line' },
    label: ' {cyan-fg}Detalles — Esc para cerrar{/} ',
    tags: true, scrollable: true, scrollbar: { ch: '|' },
    keys: true, vi: true,
    content: lines.join('\n'),
    style: { border: { fg: 'cyan' }, fg: 'white', bg: 'black' },
  });

  screen.append(modal);
  modal.focus();
  screen.render();

  const close = () => { modal.detach(); onClose(); };
  modal.key(['escape', 'q'], close);
  modal.key(['C-c'], () => process.exit(0));
}

function showWorldScreen() {
  screen.children.slice().forEach(c => c.detach());
  screen.removeAllListeners('keypress');

  const { BP, RP, WORLDS } = getDirs();
  let showNoIcon = false;

  const rebuild = () => {
    const bpPacks = scanPackDir(BP, !showNoIcon);
    const rpPacks = scanPackDir(RP, !showNoIcon);
    const groups  = buildAddonGroups(bpPacks, rpPacks);
    const bpPath  = path.join(WORLDS, worldName, 'world_behavior_packs.json');
    const rpPath  = path.join(WORLDS, worldName, 'world_resource_packs.json');
    worldBPJson   = readJson(bpPath) || [];
    worldRPJson   = readJson(rpPath) || [];
    return { bpPacks, rpPacks, groups };
  };

  let { bpPacks, rpPacks, groups } = rebuild();

  let entries = Object.entries(groups);

  const header = blessed.box({
    top: 0, left: 0, width: '100%', height: 3, tags: true,
    content: '',
    style: { bg: 'black', fg: 'white' },
  });

  const updateHeader = () => {
    const oLabel = showNoIcon ? '{yellow-fg}[O] Ocultar sin icono{/}' : '{white-fg}[O] Mostrar sin icono{/}';
    header.setContent(' World: {bold}' + worldName + '{/}  |  {cyan-fg}Enter{/} toggle  {cyan-fg}M{/} detalles  {cyan-fg}D{/} desinstalar  {cyan-fg}I{/} instalar  {cyan-fg}P{/} rutas  ' + oLabel + '  {cyan-fg}Q{/} salir');
    screen.render();
  };

  const listBox = blessed.list({
    top: 3, left: 0, width: '100%', height: '100%-3',
    keys: true, vi: true, mouse: true, tags: true,
    scrollable: true, scrollbar: { ch: '|' },
    style: { selected: { bg: 'blue', fg: 'white' }, item: { fg: 'white' } },
  });

  const buildItems = () => {
    const { BP, RP } = getDirs();
    return entries.map(([, g]) => {
      const active  = (g.bp && isActive(g.bp.uuid)) || (g.rp && isActive(g.rp.uuid));
      const tags    = [g.bp ? 'BP' : null, g.rp ? 'RP' : null].filter(Boolean).join('+');
      const ver     = g.bp?.version || g.rp?.version || '';
      const state   = active ? '{green-fg}[ON] {/}' : '{red-fg}[OFF]{/}';
      const szParts = [];
      if (g.bp?.folder) szParts.push(dirSize(path.join(BP, g.bp.folder)));
      if (g.rp?.folder) szParts.push(dirSize(path.join(RP, g.rp.folder)));
      const sizeStr = szParts.length ? ' {gray-fg}[' + szParts.join('+') + ']{/}' : '';
      return state + ' [' + tags + '] ' + g.name + ' v' + ver + sizeStr;
    });
  };

  const renderList = () => {
    const idx = listBox.selected || 0;
    listBox.setItems(buildItems());
    listBox.select(idx);
    screen.render();
  };

  const refreshList = () => {
    showWait('Actualizando...', () => {
      const r = rebuild();
      bpPacks = r.bpPacks; rpPacks = r.rpPacks; groups = r.groups;
      entries = Object.entries(groups);
      renderList();
    });
  };

  screen.append(header);
  screen.append(listBox);
  listBox.focus();

  updateHeader();
  renderList();

  listBox.key('enter', () => {
    const entry = entries[listBox.selected];
    if (!entry) return;
    const [, group] = entry;
    const active = (group.bp && isActive(group.bp.uuid)) || (group.rp && isActive(group.rp.uuid));
    if (active) deactivateGroup(group); else activateGroup(group);
    renderList();
  });

  listBox.key(['m', 'M'], () => {
    const entry = entries[listBox.selected];
    if (!entry) return;
    showDetailModal(entry[1], () => {
      listBox.focus();
      screen.render();
    });
  });

  screen.key(['o', 'O'], () => {
    showNoIcon = !showNoIcon;
    updateHeader();
    refreshList();
  });

  screen.key(['i', 'I'], () => showInstallScreen(bpPacks, rpPacks));
  screen.key(['q', 'Q', 'C-c'], () => process.exit(0));

  screen.key(['d', 'D'], () => {
    const entry = entries[listBox.selected];
    if (!entry) return;
    const [, group] = entry;
    showConfirmModal('Desinstalar: ' + group.name + '?', () => {
      showWait('Desinstalando ' + group.name + '...', () => {
        deleteGroup(group);
        showWorldScreen();
      });
    }, () => showWorldScreen());
  });

  screen.key(['p', 'P'], () => {
    showFilePicker('Selecciona MC_ROOT', MC_ROOT, (selected) => {
      MC_ROOT = selected;
      showFilePicker('Selecciona DL_DIR', DL_DIR, (sel2) => {
        DL_DIR = sel2;
        showWorldScreen();
      }, () => showWorldScreen());
    }, () => showWorldScreen());
  });

  screen.render();
}

function showInstallScreen(bpPacks, rpPacks) {
  screen.children.slice().forEach(c => c.detach());
  screen.removeAllListeners('keypress');

  showWait('Escaneando archivos...', () => {
    let result;
    try { result = buildInstallPreview(bpPacks, rpPacks); }
    catch (e) { result = { items: [], files: [] }; }
    _continueInstallScreen(result, bpPacks, rpPacks);
  });
}

function _continueInstallScreen(result, bpPacks, rpPacks) {
  screen.children.slice().forEach(c => c.detach());

  const header = blessed.box({
    top: 0, left: 0, width: '100%', height: 3, tags: true,
    content: ' Instalar  |  {cyan-fg}Enter{/cyan-fg} confirmar  {cyan-fg}B{/cyan-fg} volver  {cyan-fg}Q{/cyan-fg} salir',
    style: { bg: 'black', fg: 'white' },
  });

  const { items: preview, files: srcFiles } = result;

  const lines = preview.length === 0
    ? ['{yellow-fg}Sin archivos en ' + DL_DIR + '{/}']
    : preview.map(p => {
        const action = p.downgrade
          ? '{red-fg}[DOWNGRADE]{/} v' + p.newVer + ' < v' + p.existing.version + ' (ignorado)'
          : p.existing
            ? '{yellow-fg}[ACTUALIZAR]{/} ' + p.existing.name + ' v' + p.existing.version + ' -> v' + p.newVer
            : '{green-fg}[NUEVO]{/} v' + p.newVer;
        return '[' + p.type + '] ' + p.name + '  ' + action;
      });

  const content = blessed.box({
    top: 3, left: 0, width: '100%', height: '100%-3',
    content: lines.join('\n'),
    tags: true, scrollable: true, scrollbar: { ch: '|' },
    keys: true, vi: true, mouse: true,
    style: { fg: 'white', bg: 'black' },
  });

  screen.key(['b', 'B'], () => showWorldScreen());
  screen.key(['q', 'Q', 'C-c'], () => process.exit(0));

  if (preview.length > 0) {
    screen.key('enter', () => {
      screen.removeAllListeners('keypress');

      showWait('Instalando...', () => {
        let installed = [], err = null;
        try { installed = doInstall(preview, srcFiles); } catch (e) { err = e; }

        if (err) {
          content.setContent('{red-fg}Error: ' + err.message + '{/}');
          screen.render();
          screen.key(['b', 'B'], () => showWorldScreen());
          screen.key(['q', 'Q', 'C-c'], () => process.exit(0));
          return;
        }

        if (checkOwnership(installed)) {
          content.setContent('{green-fg}Instalacion completada.{/}');
          screen.render();
          showConfirmModal('Permisos incorrectos. Corregir con sudo?', () => {
            fixOwnership(installed);
            showWorldScreen();
          }, () => showWorldScreen());
        } else {
          content.setContent('{green-fg}Instalacion completada. B para volver.{/}');
          screen.render();
          screen.key(['b', 'B'], () => showWorldScreen());
          screen.key(['q', 'Q', 'C-c'], () => process.exit(0));
        }
      });
    });
  }

  screen.append(header);
  screen.append(content);
  content.focus();
  screen.render();
}

function showWorldSelect() {
  const { WORLDS } = getDirs();
  if (!fs.existsSync(WORLDS)) { console.error('No existe: ' + WORLDS); process.exit(1); }
  const worlds = fs.readdirSync(WORLDS).filter(f => fs.statSync(path.join(WORLDS, f)).isDirectory());
  if (worlds.length === 0) { console.error('Sin mundos en ' + WORLDS); process.exit(1); }

  showWait('Cargando mundos...', () => {
    const worldItems = worlds.map(w => {
      const sz = dirSize(path.join(WORLDS, w));
      return { name: w, label: w + ' {gray-fg}(' + sz + '){/}' };
    });
    _continueWorldSelect(worldItems);
  });
}

function _continueWorldSelect(worldItems) {

  const box = blessed.box({
    top: 0, left: 0, width: '100%', height: 3,
    content: ' MC Addon Manager — Selecciona un mundo',
    style: { bg: 'black', fg: 'white' },
  });

  const list = blessed.list({
    top: 3, left: 'center', width: 60, height: worldItems.length + 2,
    keys: true, vi: true, mouse: true, tags: true,
    border: { type: 'line' },
    style: { border: { fg: 'cyan' }, selected: { bg: 'blue', fg: 'white' }, item: { fg: 'white' } },
    items: worldItems.map(w => w.label),
  });

  list.on('select', (_, idx) => { worldName = worldItems[idx].name; showWorldScreen(); });
  screen.key(['q', 'Q', 'C-c'], () => process.exit(0));
  screen.append(box);
  screen.append(list);
  list.focus();
  screen.render();
}

runValidation(ROUTE_VARS, 0, showWorldSelect);