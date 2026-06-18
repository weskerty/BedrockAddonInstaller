#!/usr/bin/env node

const EP = require('path').resolve(__dirname, '..', '.env');
require('dotenv').config({ path: EP });

const blessed    = require('blessed');
const AdmZip     = require('adm-zip');
const fs         = require('fs');
const path       = require('path');
const { spawnSync } = require('child_process');

const SL = path.join(__dirname, 'leveldat.js');

let D_BP  = process.env.CarpetaBP        || '';
let D_RP  = process.env.CarpetaRP        || '';
let D_WO  = process.env.CarpetaMundos    || '';
let D_RES = process.env.CarpetaRecursos  || path.join(__dirname, '..', 'resources');
let D_INS = process.env.CarpetaInstalados|| path.join(__dirname, '..', 'Instalados');
let D_TMP = process.env.TEMP_DIR         || '/tmp/mc_addon_install';

const screen = blessed.screen({ smartCSR: true, title: 'MC Addon Manager' });

let worldName   = null;
let worldBPJson = null;
let worldRPJson = null;

const getDirs = () => ({ BP: D_BP, RP: D_RP, WORLDS: D_WO });

function upsertEnv(k, v) {
  let s = '';
  try { s = fs.readFileSync(EP, 'utf8'); } catch {}
  const re = new RegExp('^' + k + '=.*$', 'm');
  const ln = k + '=' + v;
  s = re.test(s) ? s.replace(re, ln) : s + (s && !s.endsWith('\n') ? '\n' : '') + ln + '\n';
  fs.writeFileSync(EP, s);
  process.env[k] = v;
}

const RV = [
  { key: 'CarpetaBP',       get: () => D_BP,  set: v => { D_BP  = v; }, optional: false,
    title: 'Selecciona CarpetaBP (behavior_packs)',   default: '/opt/minecraft-bedrock-server/behavior_packs' },
  { key: 'CarpetaRP',       get: () => D_RP,  set: v => { D_RP  = v; }, optional: false,
    title: 'Selecciona CarpetaRP (resource_packs)',   default: '/opt/minecraft-bedrock-server/resource_packs' },
  { key: 'CarpetaMundos',   get: () => D_WO,  set: v => { D_WO  = v; }, optional: false,
    title: 'Selecciona CarpetaMundos (worlds)',        default: '/opt/minecraft-bedrock-server/worlds' },
  { key: 'CarpetaRecursos', get: () => D_RES, set: v => { D_RES = v; }, optional: false,
    title: 'Selecciona CarpetaRecursos (fuente)',      default: path.join(__dirname, '..', 'resources') },
  { key: 'CarpetaInstalados',get: () => D_INS,set: v => { D_INS = v; }, optional: false,
    title: 'Selecciona CarpetaInstalados (destino)',   default: path.join(__dirname, '..', 'Instalados') },
];

function needsPicker(e) {
  const v = e.get();
  if (e.optional) return v && !fs.existsSync(v);
  return !v || !fs.existsSync(v);
}

function runValidation(vars, idx, onDone) {
  if (idx >= vars.length) return onDone();
  const e = vars[idx];
  if (!needsPicker(e)) return runValidation(vars, idx + 1, onDone);
  const st = e.get() || e.default || '/';
  showFilePicker(
    e.title,
    fs.existsSync(st) ? st : '/',
    (sel) => { e.set(sel); upsertEnv(e.key, sel); runValidation(vars, idx + 1, onDone); },
    () => {
      if (!e.optional) {
        screen.destroy();
        process.stderr.write('Ruta requerida no configurada: ' + e.key + '\n');
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
  let b = 0;
  const wk = (d) => {
    try {
      for (const f of fs.readdirSync(d)) {
        const fl = path.join(d, f);
        try { const st = fs.statSync(fl); if (st.isDirectory()) wk(fl); else b += st.size; } catch {}
      }
    } catch {}
  };
  wk(dir);
  if (b < 1024)        return b + ' B';
  if (b < 1024 * 1024) return (b / 1024).toFixed(1) + ' KB';
  return (b / (1024 * 1024)).toFixed(1) + ' MB';
}

function parseVer(v) {
  if (Array.isArray(v)) return v.join('.');
  if (typeof v === 'string') return v;
  return '0.0.0';
}

function stripCodes(s) {
  return (s || '').replace(/§./g, '').trim();
}

function parseLang(p) {
  try {
    const out = {};
    for (const ln of fs.readFileSync(p, 'utf8').split('\n')) {
      const eq = ln.indexOf('=');
      if (eq < 0) continue;
      const k = ln.slice(0, eq).trim();
      const v = ln.slice(eq + 1).replace(/#.*$/, '').trim();
      if (k) out[k] = v;
    }
    return out;
  } catch { return null; }
}

function readLangTexts(pd) {
  const td = path.join(pd, 'texts');
  if (!fs.existsSync(td)) return null;
  let files;
  try { files = fs.readdirSync(td).filter(f => f.endsWith('.lang')); } catch { return null; }
  if (!files.length) return null;
  const pk = (fn) => files.find(fn) || null;
  const ch = pk(f => /^es_/i.test(f)) || pk(f => /^en_/i.test(f)) || files[0];
  return parseLang(path.join(td, ch));
}

function sanitizeName(s) {
  return s.replace(/[^a-zA-Z]/g, '').trim();
}

function sanitizePath(s) {
  return s.replace(/[^a-zA-Z0-9._-]/g, '_').trim();
}

function parseManifestInfo(m) {
  const h   = m.header || {};
  const nm  = stripCodes(h.name);
  const dc  = stripCodes(h.description);
  const vr  = parseVer(h.version);
  const me  = parseVer(h.min_engine_version);
  const au  = (m.metadata?.authors || []).join(', ');
  const cp  = (m.capabilities || []).join(', ');
  const sp  = (m.subpacks || []).map(s => s.name ? stripCodes(s.name) : s.folder_name);
  const dp  = [], dm = [];
  for (const d of (m.dependencies || [])) {
    if (d.module_name) dm.push(d.module_name + ' ' + parseVer(d.version));
    else if (d.uuid)   dp.push(d.uuid + ' v' + parseVer(d.version));
  }
  return { name: nm, desc: dc, ver: vr, minEng: me, authors: au, caps: cp,
           subpacks: sp, depPacks: dp, depModules: dm, uuid: h.uuid, formatVersion: m.format_version };
}

function detectPackType(m) {
  const t = (m.modules || []).map(x => x.type);
  if (t.includes('resources')) return 'RP';
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

function isNativePack(pd, m) {
  if (!fs.existsSync(path.join(pd, 'pack_icon.png'))) return true;
  const v = m.header.version || [];
  if (v[0] === 0 && v[1] === 0 && v[2] === 1) return true;
  if ((m.header.name || '').includes('@minecraft')) return true;
  return false;
}

function scanPackDir(dir, hideNative) {
  const packs = {};
  if (!fs.existsSync(dir)) return packs;
  for (const folder of fs.readdirSync(dir)) {
    const pd = path.join(dir, folder);
    const mp = path.join(pd, 'manifest.json');
    if (!fs.existsSync(mp)) continue;
    const m = readJson(mp);
    if (!m?.header?.uuid) continue;
    if (hideNative && isNativePack(pd, m)) continue;
    const uuid = m.header.uuid;
    const info = parseManifestInfo(m);
    const vr   = info.ver;
    const ng   = !info.name || m.header.name?.startsWith('pack.');
    const dg   = !info.desc || m.header.description?.startsWith('pack.');
    let rn = ng ? null : info.name;
    let rd = dg ? null : info.desc;
    if (ng || dg) {
      const lt = readLangTexts(pd);
      if (lt) {
        if (ng && lt['pack.name'])        rn = stripCodes(lt['pack.name']);
        if (dg && lt['pack.description']) rd = stripCodes(lt['pack.description']);
      }
    }
    const nm = rn || folder;
    const dc = rd || info.desc;
    if (packs[uuid] && cmpVer(vr, packs[uuid].version) <= 0) continue;
    packs[uuid] = { uuid, name: nm, desc: dc, version: vr, type: detectPackType(m),
      deps: (m.dependencies || []).map(d => d.uuid).filter(Boolean), folder, dir, manifest: m };
  }
  return packs;
}

function buildAddonGroups(bpPacks, rpPacks) {
  const groups = {};
  const add = (key, pack) => {
    if (!groups[key]) groups[key] = { name: pack.name, desc: pack.desc, bp: null, rp: null };
    if (pack.type === 'BP') groups[key].bp = pack;
    else groups[key].rp = pack;
  };
  const lk = new Set();
  for (const [uuid, pack] of Object.entries(bpPacks)) {
    const rd = pack.deps.find(d => rpPacks[d]);
    if (rd) { lk.add(uuid); lk.add(rd); add(uuid, pack); add(uuid, rpPacks[rd]); }
  }
  for (const [uuid, pack] of Object.entries(rpPacks)) {
    const bd = pack.deps.find(d => bpPacks[d]);
    if (bd && !lk.has(uuid)) { lk.add(uuid); lk.add(bd); add(bd, bpPacks[bd]); add(bd, pack); }
  }
  for (const [uuid, pack] of Object.entries(bpPacks)) if (!lk.has(uuid)) add('bp_' + uuid, pack);
  for (const [uuid, pack] of Object.entries(rpPacks)) if (!lk.has(uuid)) add('rp_' + uuid, pack);
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

function rmrf(p) {
  if (fs.existsSync(p)) spawnSync('rm', ['-rf', p]);
}

function deleteGroup(g) {
  const { BP, RP } = getDirs();
  if (g.bp) rmrf(path.join(BP, g.bp.folder));
  if (g.rp) rmrf(path.join(RP, g.rp.folder));
}

function getOwnerOf(dir) {
  const st = fs.statSync(dir);
  return { uid: st.uid, gid: st.gid };
}

function checkOwnership(installedPaths) {
  const ref = installedPaths.find(p => fs.existsSync(path.dirname(p)));
  if (!ref) return false;
  const { uid, gid } = getOwnerOf(path.dirname(ref));
  return installedPaths.some(p => {
    if (!fs.existsSync(p)) return false;
    const s = fs.statSync(p);
    return s.uid !== uid || s.gid !== gid;
  });
}

function fixOwnership(installedPaths) {
  const ref = installedPaths.find(p => fs.existsSync(path.dirname(p)));
  if (!ref) return;
  const { uid, gid } = getOwnerOf(path.dirname(ref));
  screen.program.disableMouse();
  screen.program.showCursor();
  screen.program.normalBuffer();
  process.stdout.write('\n');
  for (const p of installedPaths) {
    if (!fs.existsSync(p)) continue;
    const r = spawnSync('sudo', ['chown', '-R', `${uid}:${gid}`, p], { stdio: 'inherit' });
    if (r.status !== 0) process.stdout.write('Error chown: ' + p + '\n');
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
  const dest = path.join(D_TMP, base);
  fs.mkdirSync(dest, { recursive: true });
  new AdmZip(file).extractAllTo(dest, true);
  return dest;
}

function findManifests(dir) {
  const r = [];
  const wk = (d, depth) => {
    if (depth > 4) return;
    for (const e of fs.readdirSync(d)) {
      const fl = path.join(d, e);
      if (fs.statSync(fl).isDirectory()) wk(fl, depth + 1);
      else if (e === 'manifest.json') r.push(fl);
    }
  };
  wk(dir, 0);
  return r;
}

function extractNested(dir, onFile) {
  let found = true;
  while (found) {
    found = false;
    const wk = (d) => {
      for (const e of fs.readdirSync(d)) {
        const fl = path.join(d, e);
        if (fs.statSync(fl).isDirectory()) { wk(fl); continue; }
        if (/\.(mcpack|mcaddon|zip)$/.test(e)) {
          found = true;
          if (onFile) onFile(e);
          const dest = path.join(d, sanitizePath(path.basename(e).replace(/\.[^.]+$/, '')));
          fs.mkdirSync(dest, { recursive: true });
          try { new AdmZip(fl).extractAllTo(dest, true); } catch {}
          fs.unlinkSync(fl);
        }
      }
    };
    wk(dir);
  }
}

function scanDownloads() {
  const entries = [];
  if (!fs.existsSync(D_RES)) return entries;
  for (const f of fs.readdirSync(D_RES)) {
    const fl = path.join(D_RES, f);
    if (/\.(mcpack|mcaddon|zip)$/.test(f))
      entries.push({ full: fl, isDir: false });
    else if (fs.statSync(fl).isDirectory())
      entries.push({ full: fl, isDir: true });
  }
  return entries;
}

function buildInstallPreview(bpPacks, rpPacks) {
  const { BP, RP } = getDirs();
  const entries = scanDownloads();
  if (entries.length === 0) return { items: [], files: [] };

  if (fs.existsSync(D_TMP)) fs.rmSync(D_TMP, { recursive: true });
  fs.mkdirSync(D_TMP, { recursive: true });

  const preview = [], srcFiles = [];

  for (const entry of entries) {
    try {
      let sd;
      if (entry.isDir) { sd = entry.full; }
      else { sd = extractToTemp(entry.full); extractNested(sd, () => {}); }

      for (const mp of findManifests(sd)) {
        const m = readJson(mp);
        if (!m?.header?.uuid) continue;
        const tp    = detectPackType(m);
        const uuid  = m.header.uuid;
        const rn    = m.header.name || '';
        const prd   = path.dirname(mp);
        let nm = (!rn || rn.startsWith('pack.')) ? null : stripCodes(rn);
        if (!nm) { const lt = readLangTexts(prd); if (lt?.['pack.name']) nm = stripCodes(lt['pack.name']); }
        const name = sanitizeName(nm || path.basename(prd));
        const nv   = parseVer(m.header.version);
        const ex   = tp === 'BP' ? bpPacks[uuid] : rpPacks[uuid];
        const dg   = ex ? cmpVer(nv, ex.version) < 0 : false;
        preview.push({ file: path.basename(entry.full), name, uuid, type: tp, newVer: nv,
          isDir: entry.isDir, downgrade: dg,
          existing: ex ? { name: ex.name, version: ex.version, folder: ex.folder } : null,
          packRoot: prd });
      }
      srcFiles.push(entry);
      if (!entry.isDir && fs.existsSync(sd)) fs.rmSync(sd, { recursive: true });
    } catch {}
  }

  return { items: preview, files: srcFiles };
}

function doInstall(preview, sourceFiles) {
  const { BP, RP } = getDirs();
  const installed = [];

  const needsTmp = preview.some(p => !p.downgrade && !p.isDir);
  if (needsTmp) {
    if (fs.existsSync(D_TMP)) fs.rmSync(D_TMP, { recursive: true });
    fs.mkdirSync(D_TMP, { recursive: true });
  }

  const reEx = new Map();

  for (const p of preview) {
    if (p.downgrade) continue;
    const dBase = p.type === 'BP' ? BP : RP;
    const ef    = p.existing?.folder;
    let bName   = ef || sanitizeName(p.name);
    if (!bName) {
      let n = 1;
      while (fs.existsSync(path.join(dBase, 'pack' + n))) n++;
      bName = 'pack' + n;
    }
    const dest = path.join(dBase, bName);

    let pr = p.packRoot;

    if (!p.isDir && !fs.existsSync(pr)) {
      const sf = path.join(D_RES, p.file);
      const ck = p.file;
      if (!reEx.has(ck)) {
        if (fs.existsSync(sf)) {
          const td = extractToTemp(sf);
          extractNested(td, () => {});
          reEx.set(ck, td);
        }
      }
      const base = reEx.get(ck);
      if (base) {
        const mfs = findManifests(base);
        const mt  = mfs.find(mp => { const m = readJson(mp); return m?.header?.uuid === p.uuid; });
        if (mt) pr = path.dirname(mt);
      }
    }

    if (!fs.existsSync(pr)) continue;
    if (fs.existsSync(dest)) fs.rmSync(dest, { recursive: true });
    fs.cpSync(pr, dest, { recursive: true });
    installed.push(dest);
  }

  if (fs.existsSync(D_TMP)) fs.rmSync(D_TMP, { recursive: true });

  fs.mkdirSync(D_INS, { recursive: true });
  const moved = new Set();
  for (const entry of sourceFiles) {
    if (moved.has(entry.full)) continue;
    moved.add(entry.full);
    const dst = path.join(D_INS, path.basename(entry.full));
    try {
      if (fs.existsSync(dst)) { entry.isDir ? fs.rmSync(dst, { recursive: true }) : fs.unlinkSync(dst); }
      fs.renameSync(entry.full, dst);
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
  const cl = () => { box.detach(); screen.render(); };
  screen.removeAllListeners('keypress');
  screen.key(['s', 'S'], () => { cl(); onYes(); });
  screen.key(['n', 'N', 'escape'], () => { cl(); onNo(); });
}

function showFilePicker(title, startPath, onSelect, onCancel) {
  screen.children.slice().forEach(c => c.detach());
  screen.removeAllListeners('keypress');

  let cp = startPath;

  const header = blessed.box({
    top: 0, left: 0, width: '100%', height: 3, tags: true,
    content: ' ' + title + '  |  {cyan-fg}k/j{/} arriba/abajo  {cyan-fg}l{/} entrar  {cyan-fg}h{/} atras  {cyan-fg}Enter{/} confirmar aqui  {cyan-fg}Esc{/} cancelar',
    style: { bg: 'black', fg: 'white' },
  });

  const bc = blessed.box({
    top: 3, left: 0, width: '100%', height: 1, tags: true,
    style: { bg: 'blue', fg: 'white' },
  });

  const list = blessed.list({
    top: 4, left: 0, width: '100%', height: '100%-4',
    keys: true, vi: true, mouse: true, tags: true,
    scrollable: true, scrollbar: { ch: '|' },
    style: { selected: { bg: 'blue', fg: 'white' }, item: { fg: 'white' } },
  });

  const rf = () => {
    bc.setContent(' ' + cp);
    let entries = [];
    try {
      entries = fs.readdirSync(cp)
        .map(f => { const fl = path.join(cp, f); const id = fs.statSync(fl).isDirectory(); return { name: f, isDir: id }; })
        .sort((a, b) => { if (a.isDir !== b.isDir) return a.isDir ? -1 : 1; return a.name.localeCompare(b.name); });
    } catch {}
    list.setItems(entries.map(e => e.isDir ? '{cyan-fg}' + e.name + '/{/}' : e.name));
    list._dirEntries = entries;
    screen.render();
  };

  rf();

  screen.key(['l'], () => {
    const idx = list.selected;
    const e = (list._dirEntries || [])[idx];
    if (e?.isDir) { cp = path.join(cp, e.name); rf(); }
  });

  screen.key(['h'], () => { const p = path.dirname(cp); if (p !== cp) { cp = p; rf(); } });
  screen.key('enter', () => onSelect(cp));
  screen.key('escape', () => onCancel());

  screen.append(header);
  screen.append(bc);
  screen.append(list);
  list.focus();
  screen.render();
}

function showDetailModal(group, onClose) {
  const lines = [];
  const addPack = (pack, label) => {
    if (!pack) return;
    const m  = pack.manifest || readJson(path.join(pack.dir, pack.folder, 'manifest.json'));
    if (!m) return;
    const i  = parseManifestInfo(m);
    const pd = path.join(pack.dir, pack.folder);
    const lt = readLangTexts(pd);
    const ng = !i.name || m.header?.name?.startsWith('pack.');
    const dg = !i.desc || m.header?.description?.startsWith('pack.');
    const dn = (ng && lt?.['pack.name'])        ? stripCodes(lt['pack.name'])        : (i.name || pack.folder);
    const dd = (dg && lt?.['pack.description']) ? stripCodes(lt['pack.description']) : (i.desc || '');
    lines.push('{cyan-fg}{bold}── ' + label + ' ──{/}');
    lines.push('{white-fg}Nombre:{/}       ' + dn);
    lines.push('{white-fg}Descripcion:{/}  ' + (dd || 'pack.description'));
    lines.push('{white-fg}Version:{/}      ' + i.ver);
    lines.push('{white-fg}Motor minimo:{/} ' + i.minEng);
    lines.push('{white-fg}UUID:{/}         {gray-fg}' + i.uuid + '{/}');
    lines.push('{white-fg}Formato:{/}      v' + i.formatVersion);
    if (i.authors)           lines.push('{white-fg}Autores:{/}      ' + i.authors);
    if (i.caps)              lines.push('{white-fg}Capacidades:{/} ' + i.caps);
    if (i.depModules.length) lines.push('{white-fg}Modulos:{/}      ' + i.depModules.join('  |  '));
    if (i.depPacks.length)   lines.push('{white-fg}Deps (packs):{/} ' + i.depPacks.join('\n              '));
    if (i.subpacks.length)   lines.push('{white-fg}Subpacks:{/}     ' + i.subpacks.join(', '));
    const td = path.join(pd, 'texts');
    if (fs.existsSync(td))   lines.push('{white-fg}Textos:{/}       {gray-fg}' + td + '{/}');
    lines.push('');
  };

  addPack(group.bp, 'Behavior Pack');
  addPack(group.rp, 'Resource Pack');

  const mh = Math.min(lines.length + 4, screen.height - 4);
  const modal = blessed.box({
    top: 'center', left: 'center', width: '70%', height: mh,
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

  const cl = () => { modal.detach(); onClose(); };
  modal.key(['escape', 'q'], cl);
  modal.key(['C-c'], () => process.exit(0));
}

function showWorldScreen() {
  screen.children.slice().forEach(c => c.detach());
  screen.removeAllListeners('keypress');

  const { BP, RP, WORLDS } = getDirs();
  let showNoIcon = false;

  const rebuild = () => {
    const bp = scanPackDir(BP, !showNoIcon);
    const rp = scanPackDir(RP, !showNoIcon);
    const gr = buildAddonGroups(bp, rp);
    const bpp = path.join(WORLDS, worldName, 'world_behavior_packs.json');
    const rpp = path.join(WORLDS, worldName, 'world_resource_packs.json');
    worldBPJson = readJson(bpp) || [];
    worldRPJson = readJson(rpp) || [];
    return { bpPacks: bp, rpPacks: rp, groups: gr };
  };

  let { bpPacks, rpPacks, groups } = rebuild();
  let entries = Object.entries(groups);

  const header = blessed.box({
    top: 0, left: 0, width: '100%', height: 3, tags: true,
    content: '',
    style: { bg: 'black', fg: 'white' },
  });

  const updateHeader = () => {
    const ol = showNoIcon ? '{yellow-fg}[O] Ocultar sin icono{/}' : '{white-fg}[O] Mostrar sin icono{/}';
    header.setContent(' World: {bold}' + worldName + '{/}  |  {cyan-fg}Enter{/} toggle  {cyan-fg}M{/} detalles  {cyan-fg}D{/} desinstalar  {cyan-fg}I{/} instalar  {cyan-fg}E{/} editar world  {cyan-fg}P{/} rutas  ' + ol + '  {cyan-fg}Q{/} salir');
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
      const ac  = (g.bp && isActive(g.bp.uuid)) || (g.rp && isActive(g.rp.uuid));
      const tg  = [g.bp ? 'BP' : null, g.rp ? 'RP' : null].filter(Boolean).join('+');
      const vr  = g.bp?.version || g.rp?.version || '';
      const st  = ac ? '{green-fg}[ON] {/}' : '{red-fg}[OFF]{/}';
      const sz  = [];
      if (g.bp?.folder) sz.push(dirSize(path.join(BP, g.bp.folder)));
      if (g.rp?.folder) sz.push(dirSize(path.join(RP, g.rp.folder)));
      const szs = sz.length ? ' {gray-fg}[' + sz.join('+') + ']{/}' : '';
      return st + ' [' + tg + '] ' + g.name + ' v' + vr + szs;
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
    const [, grp] = entry;
    const ac = (grp.bp && isActive(grp.bp.uuid)) || (grp.rp && isActive(grp.rp.uuid));
    if (ac) deactivateGroup(grp); else activateGroup(grp);
    renderList();
  });

  listBox.key(['m', 'M'], () => {
    const entry = entries[listBox.selected];
    if (!entry) return;
    showDetailModal(entry[1], () => { listBox.focus(); screen.render(); });
  });

  screen.key(['o', 'O'], () => { showNoIcon = !showNoIcon; updateHeader(); refreshList(); });
  screen.key(['i', 'I'], () => showInstallScreen(bpPacks, rpPacks));

  screen.key(['e', 'E'], () => {
    const { WORLDS } = getDirs();
    const wp = path.join(WORLDS, worldName);
    screen.destroy();
    spawnSync(process.execPath, [SL, wp], { stdio: 'inherit' });
    process.exit(0);
  });

  screen.key(['q', 'Q', 'C-c'], () => process.exit(0));

  screen.key(['d', 'D'], () => {
    const entry = entries[listBox.selected];
    if (!entry) return;
    const [, grp] = entry;
    showConfirmModal('Desinstalar: ' + grp.name + '?', () => {
      showWait('Desinstalando ' + grp.name + '...', () => { deleteGroup(grp); showWorldScreen(); });
    }, () => { listBox.focus(); screen.render(); });
  });

  screen.key(['p', 'P'], () => {
    showFilePicker('Selecciona CarpetaBP', D_BP || '/', (s1) => {
      D_BP = s1; upsertEnv('CarpetaBP', s1);
      showFilePicker('Selecciona CarpetaRP', D_RP || '/', (s2) => {
        D_RP = s2; upsertEnv('CarpetaRP', s2);
        showFilePicker('Selecciona CarpetaMundos', D_WO || '/', (s3) => {
          D_WO = s3; upsertEnv('CarpetaMundos', s3);
          showFilePicker('Selecciona CarpetaRecursos', D_RES || '/', (s4) => {
            D_RES = s4; upsertEnv('CarpetaRecursos', s4);
            showFilePicker('Selecciona CarpetaInstalados', D_INS || '/', (s5) => {
              D_INS = s5; upsertEnv('CarpetaInstalados', s5);
              showWorldScreen();
            }, () => showWorldScreen());
          }, () => showWorldScreen());
        }, () => showWorldScreen());
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
    catch { result = { items: [], files: [] }; }
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
    ? ['{yellow-fg}Sin archivos en ' + D_RES + '{/}']
    : preview.map(p => {
        const ac = p.downgrade
          ? '{red-fg}[DOWNGRADE]{/} v' + p.newVer + ' < v' + p.existing.version + ' (ignorado)'
          : p.existing
            ? '{yellow-fg}[ACTUALIZAR]{/} ' + p.existing.name + ' v' + p.existing.version + ' -> v' + p.newVer
            : '{green-fg}[NUEVO]{/} v' + p.newVer;
        return '[' + p.type + '] ' + p.name + '  ' + ac;
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
    const wi = worlds.map(w => ({ name: w, label: w + ' {gray-fg}(' + dirSize(path.join(WORLDS, w)) + '){/}' }));
    _continueWorldSelect(wi);
  });
}

function _continueWorldSelect(wi) {
  const box = blessed.box({
    top: 0, left: 0, width: '100%', height: 3,
    content: ' MC Addon Manager — Selecciona un mundo',
    style: { bg: 'black', fg: 'white' },
  });

  const list = blessed.list({
    top: 3, left: 'center', width: 60, height: wi.length + 2,
    keys: true, vi: true, mouse: true, tags: true,
    border: { type: 'line' },
    style: { border: { fg: 'cyan' }, selected: { bg: 'blue', fg: 'white' }, item: { fg: 'white' } },
    items: wi.map(w => w.label),
  });

  list.on('select', (_, idx) => { worldName = wi[idx].name; showWorldScreen(); });
  screen.key(['q', 'Q', 'C-c'], () => process.exit(0));
  screen.append(box);
  screen.append(list);
  list.focus();
  screen.render();
}

runValidation(RV, 0, showWorldSelect);
