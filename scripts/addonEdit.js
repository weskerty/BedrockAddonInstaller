const FS_FS1 = require("fs");
const FP_FP1 = require("path");
const BL_BL1 = require("blessed");
const MS_MS1 = require("minisearch");

const EX_EX1 = [".png",".jpg",".jpeg",".ogg",".wav",".ico",".ttf",".otf",".zip",".mcworld",".mcpack",".webp"];
const root = process.argv[2];

if (!root) {
  console.log("Uso: node FR_Tool1.js <carpeta>");
  process.exit(1);
}

function FS1(dir, acc) {
  const items = FS_FS1.readdirSync(dir);
  for (const it of items) {
    const full = FP_FP1.join(dir, it);
    const stat = FS_FS1.statSync(full);
    if (stat.isDirectory()) {
      FS1(full, acc);
    } else {
      const ext = FP_FP1.extname(it).toLowerCase();
      if (!EX_EX1.includes(ext)) acc.push(full);
    }
  }
  return acc;
}

function FI1(query, files) {
  const docs = [];
  let id = 0;
  for (const file of files) {
    let content;
    try {
      content = FS_FS1.readFileSync(file, "utf8");
    } catch (e) {
      continue;
    }
    const lines = content.split("\n");
    lines.forEach((line, idx) => {
      docs.push({ id: id++, file, lineNum: idx, text: line });
    });
  }

  const mini = new MS_MS1({
    fields: ["text"],
    storeFields: ["file", "lineNum", "text"],
    searchOptions: { fuzzy: 0.2, prefix: true }
  });
  mini.addAll(docs);
  return mini.search(query);
}

function FR1(results, query) {
  return new Promise((resolve) => {
    const screen = BL_BL1.screen({ smartCSR: true, title: "Buscar y Reemplazar" });

    const list = BL_BL1.list({
      parent: screen,
      top: 1,
      left: 0,
      width: "100%",
      height: "90%",
      keys: true,
      vi: true,
      mouse: true,
      border: "line",
      style: {
        selected: { bg: "blue" },
        item: { fg: "white" }
      },
      items: results.map(r => {
        const rel = FP_FP1.relative(root, r.file);
        return rel + ":" + (r.lineNum + 1) + "  " + r.text.trim().slice(0, 80);
      })
    });

    const info = BL_BL1.text({
      parent: screen,
      top: 0,
      left: 0,
      content: "Busqueda: " + query + " | Espacio selecciona | Enter confirma | q sale"
    });

    const selected = new Set();

    list.on("keypress", (ch, key) => {
      if (key.name === "space") {
        const i = list.selected;
        if (selected.has(i)) selected.delete(i);
        else selected.add(i);
        const rel = FP_FP1.relative(root, results[i].file);
        const mark = selected.has(i) ? "[x] " : "[ ] ";
        list.setItem(i, mark + rel + ":" + (results[i].lineNum + 1) + "  " + results[i].text.trim().slice(0, 76));
        screen.render();
      }
    });

    screen.key(["enter"], () => {
      screen.destroy();
      resolve(Array.from(selected).map(i => results[i]));
    });

    screen.key(["q", "C-c"], () => {
      screen.destroy();
      resolve([]);
    });

    list.focus();
    screen.render();
  });
}

function FX1(items, oldWord, newWord) {
  const byFile = {};
  for (const it of items) {
    if (!byFile[it.file]) byFile[it.file] = [];
    byFile[it.file].push(it.lineNum);
  }

  for (const file in byFile) {
    const content = FS_FS1.readFileSync(file, "utf8");
    const lines = content.split("\n");
    const targetLines = new Set(byFile[file]);
    for (const ln of targetLines) {
      lines[ln] = lines[ln].split(oldWord).join(newWord);
    }
    FS_FS1.writeFileSync(file, lines.join("\n"), "utf8");
  }
  console.log("Reemplazado en " + Object.keys(byFile).length + " archivo(s)");
}

async function main() {
  const query = process.argv[3];
  if (!query) {
    console.log("Uso: node FR_Tool1.js <carpeta> <palabra>");
    process.exit(1);
  }

  const files = FS1(root, []);
  const results = FI1(query, files);

  if (results.length === 0) {
    console.log("Sin coincidencias para: " + query);
    return;
  }

  const chosen = await FR1(results, query);
  if (chosen.length === 0) {
    console.log("Nada seleccionado, cancelado");
    return;
  }

  process.stdout.write("Texto nuevo: ");
  process.stdin.resume();
  process.stdin.setEncoding("utf8");
  process.stdin.once("data", (data) => {
    const newWord = data.toString().trim();
    FX1(chosen, query, newWord);
    process.exit(0);
  });
}

main();
