#!/usr/bin/env node

require('dotenv').config();

const { execSync, spawn } = require('child_process');
const fs   = require('fs');
const path = require('path');

const BRANCH  = process.env.GIT_BRANCH || 'master';
const SCRIPT  = path.join(__dirname, 'scripts', 'installer.js');
const PKG_RE  = /(^|\/)package(-lock)?\.json$/;

function run(cmd, opts = {}) {
  return execSync(cmd, { encoding: 'utf8', stdio: 'pipe', ...opts }).trim();
}

function launch() {
  const child = spawn(process.execPath, [SCRIPT], { stdio: 'inherit' });
  child.on('exit', code => process.exit(code ?? 0));
}

function needsNpmInstall(local, remote) {
  try {
    const changed = run(`git diff --name-only ${local} ${remote}`);
    return changed.split('\n').some(f => PKG_RE.test(f));
  } catch { return false; }
}

try {
  process.stdout.write('Verificando actualizaciones...\n');
  run(`git fetch origin ${BRANCH}`);

  const local  = run('git rev-parse HEAD');
  const remote = run(`git rev-parse origin/${BRANCH}`);

  if (local !== remote) {
    process.stdout.write('Actualizacion encontrada. Aplicando...\n');
    const doNpm = needsNpmInstall(local, remote);
    run(`git reset --hard origin/${BRANCH}`);
    if (doNpm) {
      process.stdout.write('Instalando dependencias...\n');
      run('npm install', { stdio: 'inherit' });
    }
    process.stdout.write('Listo.\n');
  }
} catch (e) {
  process.stderr.write('Git error: ' + e.message + '\n');
}

launch();
