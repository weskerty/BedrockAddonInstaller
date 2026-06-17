#!/usr/bin/env node

const EP  = require('path').resolve(__dirname, '..', '.env');
require('dotenv').config({ path: EP });

const blessed = require('blessed');
const fs      = require('fs');
const path    = require('path');
const nbt     = require('prismarine-nbt');

const WD = process.argv[2];
if (!WD) { process.stderr.write('Uso: node leveldat.js <ruta/mundo>\n'); process.exit(1); }

const FILE = path.join(WD, 'level.dat');
if (!fs.existsSync(FILE)) { process.stderr.write('No existe: ' + FILE + '\n'); process.exit(1); }

const INFO_PATH = path.join(__dirname, 'info.json');
let INFO = {};
try { INFO = JSON.parse(fs.readFileSync(INFO_PATH, 'utf8')); } catch {}

const raw     = fs.readFileSync(FILE);
const FV      = raw.readInt32LE(0);
const NS      = raw.readInt32LE(4);
const NB      = raw.slice(8);

const screen = blessed.screen({ smartCSR: true, title: 'level.dat — ' + path.basename(WD) });

let parsed, dirty = false, navPath = [];

const TN = {
  byte:'BYTE', short:'SHORT', int:'INT', long:'LONG',
  float:'FLOAT', double:'DOUBLE', string:'STRING',
  byteArray:'BYTE[]', intArray:'INT[]', longArray:'LONG[]',
  list:'LIST', compound:'COMPOUND'
};

const tl  = t => TN[t.type] ?? t.type.toUpperCase();
const dv  = (t, mx=60) => {
  if (t.type==='compound') return '{ '+Object.keys(t.value).length+' keys }';
  if (t.type==='list')     return '[ '+t.value.value.length+' items ]';
  if (/Array$/.test(t.type)) return '[ '+t.value.length+' items ]';
  const s = String(t.value);
  return s.length > mx ? s.slice(0,mx)+'…' : s;
};

const gn = (p) => {
  let n = parsed;
  for (const k of p) {
    if (!n) return null;
    if (n.type==='compound') n = n.value[k];
    else if (n.type==='list') {
      const raw = n.value.value[k];
      const it  = n.value.type;
      n = (raw && typeof raw==='object' && raw.type) ? raw : { type:it, value:raw };
    }
    else return null;
  }
  return n;
};

const lc = (node) => {
  if (node.type==='compound')
    return Object.entries(node.value).map(([k,v]) => ({ key:k, tag:v, label:k+'  ['+tl(v)+']  '+dv(v) }));
  if (node.type==='list') {
    const it = node.value.type;
    return node.value.value.map((v,i) => {
      const tag = (v && typeof v==='object' && v.type) ? v : { type:it, value:v };
      return { key:i, tag, label:'['+i+']  ['+tl(tag)+']  '+dv(tag) };
    });
  }
  return [];
};

const svDat = () => {
  const bk = FILE + '.backup_' + new Date().toISOString().replace(/[:.]/g,'-');
  fs.copyFileSync(FILE, bk);
  const no = nbt.writeUncompressed(parsed, 'little');
  const hd = Buffer.alloc(8);
  hd.writeInt32LE(FV, 0);
  hd.writeInt32LE(no.length, 4);
  fs.writeFileSync(FILE, Buffer.concat([hd, no]));
  dirty = false;
};

const header = blessed.box({
  top:0, left:0, width:'100%', height:3, tags:true,
  content:'',
  style:{ bg:'black', fg:'white' }
});

const listBox = blessed.list({
  top:3, left:0, width:'60%', height:'100%-3',
  keys:true, vi:true, mouse:true, tags:true,
  scrollable:true, scrollbar:{ ch:'|' },
  style:{ selected:{ bg:'blue', fg:'white' }, item:{ fg:'white' } }
});

const detail = blessed.box({
  top:3, left:'60%', width:'40%', height:'100%-3',
  tags:true, scrollable:true, scrollbar:{ ch:'|' },
  border:{ type:'line' },
  style:{ border:{ fg:'cyan' }, fg:'white', bg:'black' }
});

screen.append(header);
screen.append(listBox);
screen.append(detail);

const updHeader = () => {
  const ps = navPath.length ? navPath.join(' > ') : '(raiz)';
  const ds = dirty ? '  {yellow-fg}[*]{/}' : '';
  header.setContent(' level.dat  {gray-fg}'+ps+'{/}'+ds+'  |  {cyan-fg}Enter{/} entrar  {cyan-fg}E{/} editar  {cyan-fg}B{/} atras  {cyan-fg}S{/} guardar  {cyan-fg}Q{/} salir');
  screen.render();
};

let curChildren = [];

const render = () => {
  const node = gn(navPath);
  if (!node) return;
  curChildren = lc(node);
  if (curChildren.length) {
    listBox.setItems(curChildren.map(c => c.label));
    listBox.select(listBox.selected || 0);
  } else {
    listBox.setItems(['(sin hijos)']);
  }
  const sel = curChildren[listBox.selected];
  if (sel) {
    detail.setContent(mkDetail(sel));
  } else {
    detail.setContent('{white-fg}Tipo:{/}  '+tl(node)+'\n{white-fg}Valor:{/} '+dv(node, 200));
  }
  updHeader();
};

const mkDetail = (sel) => {
  if (!sel) return '';
  const desc = INFO[sel.key];
  let s = '{cyan-fg}'+sel.key+'{/}\n{white-fg}Tipo:{/}  '+tl(sel.tag)+'\n{white-fg}Valor:{/} '+dv(sel.tag, 200);
  if (desc) s += '\n\n{gray-fg}'+desc+'{/}';
  return s;
};

listBox.on('select item', () => {
  const sel = curChildren[listBox.selected];
  if (!sel) return;
  detail.setContent(mkDetail(sel));
  screen.render();
});

const EDITABLE = ['byte','short','int','long','float','double','string'];

const showEditModal = () => {
  const sel = curChildren[listBox.selected];
  if (!sel) return;
  const tag = sel.tag;
  if (!EDITABLE.includes(tag.type)) {
    const w = blessed.box({
      top:'center', left:'center', width:50, height:5,
      border:{ type:'line' }, tags:true,
      content:'\n  {yellow-fg}No editable directamente — entra con Enter{/}',
      style:{ border:{ fg:'yellow' }, bg:'black', fg:'white' }
    });
    screen.append(w); screen.render();
    setTimeout(() => { w.detach(); screen.render(); }, 1500);
    return;
  }

  const box = blessed.box({
    top:'center', left:'center', width:64, height:9,
    border:{ type:'line' }, tags:true,
    label:' {cyan-fg}Editar — Esc cancelar{/} ',
    style:{ border:{ fg:'cyan' }, bg:'black', fg:'white' }
  });
  const info = blessed.box({ top:1, left:1, width:'100%-4', height:2, tags:true, parent:box,
    content:'{white-fg}'+sel.key+'{/}  ['+tl(tag)+']\nActual: '+String(tag.value) });
  const inp = blessed.textbox({ top:4, left:1, width:'100%-4', height:1, parent:box,
    style:{ bg:'blue', fg:'white' }, inputOnFocus:true });

  screen.append(box);
  inp.focus();
  screen.render();

  inp.key('enter', () => {
    const v = inp.getValue().trim();
    if (v) {
      try {
        switch(tag.type) {
          case 'byte':   tag.value = parseInt(v,10) & 0xFF; break;
          case 'short':
          case 'int':    tag.value = parseInt(v,10); break;
          case 'long':   tag.value = BigInt(v); break;
          case 'float':
          case 'double': tag.value = parseFloat(v); break;
          case 'string': tag.value = v; break;
        }
        dirty = true;
      } catch(e) {}
    }
    box.detach(); listBox.focus(); render();
  });
  inp.key('escape', () => { box.detach(); listBox.focus(); render(); });
};

const showSaveModal = (onDone) => {
  const box = blessed.box({
    top:'center', left:'center', width:52, height:7,
    border:{ type:'line' }, tags:true,
    content:'\n  Guardar cambios en level.dat?\n\n  {cyan-fg}[S]{/} Si   {cyan-fg}[N]{/} No',
    style:{ border:{ fg:'yellow' }, fg:'white', bg:'black' }
  });
  screen.append(box); screen.render();
  screen.removeAllListeners('keypress');
  screen.key(['s','S'], () => {
    box.detach();
    try { svDat(); } catch(e) {}
    onDone();
  });
  screen.key(['n','N','escape'], () => { box.detach(); onDone(); });
};

const bindKeys = () => {
  screen.key('enter', () => {
    const sel = curChildren[listBox.selected];
    if (!sel) return;
    if (sel.tag.type==='compound' || sel.tag.type==='list') {
      navPath.push(sel.key);
      render();
    }
  });

  screen.key(['b','B'], () => {
    if (navPath.length) { navPath.pop(); render(); }
  });

  screen.key(['e','E'], () => showEditModal());

  screen.key(['s','S'], () => {
    if (!dirty) return;
    showSaveModal(() => { bindKeys(); render(); });
  });

  screen.key(['q','Q','C-c'], () => {
    if (dirty) {
      showSaveModal(() => { screen.destroy(); process.exit(0); });
    } else {
      screen.destroy(); process.exit(0);
    }
  });
};

nbt.parse(NB, 'little').then(({ parsed: p }) => {
  parsed = p;
  bindKeys();
  render();
  listBox.focus();
  screen.render();
}).catch(e => {
  screen.destroy();
  process.stderr.write('Error NBT: ' + e.message + '\n');
  process.exit(1);
});