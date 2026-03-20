#!/usr/bin/env node
const crx3 = require('crx3');
const fs = require('fs');
const path = require('path');

const version = process.argv[2];
if (!version) {
  console.error('Usage: node scripts/build-cws-crx.js <version>');
  process.exit(1);
}

// Copy extension to temp dir and strip CWS-incompatible fields
const srcDir = path.resolve('extension');
const tmpDir = path.resolve('dist/cws-extension');

if (fs.existsSync(tmpDir)) fs.rmSync(tmpDir, { recursive: true });
fs.cpSync(srcDir, tmpDir, { recursive: true });

// Remove .DS_Store and .amo-upload-uuid if present
for (const junk of ['.DS_Store', '.amo-upload-uuid']) {
  const p = path.join(tmpDir, junk);
  if (fs.existsSync(p)) fs.rmSync(p);
}

// Remove key and update_url from manifest
const manifestPath = path.join(tmpDir, 'manifest.json');
const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
delete manifest.key;
delete manifest.update_url;
fs.writeFileSync(manifestPath, JSON.stringify(manifest, null, 2) + '\n');

const keyPath = path.resolve('extension.pem');
const crxPath = path.resolve(`dist/password-filler-cws-v${version}.crx`);

crx3([tmpDir], { keyPath, crxPath })
  .then(() => console.log('CWS CRX packed:', crxPath))
  .catch(e => { console.error('Failed:', e.message); process.exit(1); });
