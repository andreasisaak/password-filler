#!/usr/bin/env node
const crx3 = require('crx3');
const fs = require('fs');
const path = require('path');

const version = process.argv[2];
if (!version) {
  console.error('Usage: node scripts/pack-crx.js <version>');
  process.exit(1);
}

const keyPath = path.resolve('extension.pem');
const crxPath = path.resolve(`dist/password-filler-chrome-v${version}.crx`);
const zipPath = path.resolve(`dist/password-filler-chrome-v${version}.zip`);

if (!fs.existsSync(keyPath)) {
  console.error('Key file not found:', keyPath);
  process.exit(1);
}

const keySize = fs.statSync(keyPath).size;
console.log(`Key file: ${keyPath} (${keySize} bytes)`);
if (keySize < 100) {
  console.error('Key file is empty or invalid');
  process.exit(1);
}

crx3([path.resolve('extension')], { keyPath, crxPath, zipPath })
  .then(() => console.log('CRX packed:', crxPath))
  .catch(e => { console.error('Failed:', e.message); process.exit(1); });
