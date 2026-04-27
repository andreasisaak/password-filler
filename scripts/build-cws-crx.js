#!/usr/bin/env node
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

fs.mkdirSync(path.dirname(tmpDir), { recursive: true });
if (fs.existsSync(tmpDir)) fs.rmSync(tmpDir, { recursive: true });
fs.cpSync(srcDir, tmpDir, { recursive: true });

// Remove .DS_Store and .amo-upload-uuid if present
for (const junk of ['.DS_Store', '.amo-upload-uuid']) {
  const p = path.join(tmpDir, junk);
  if (fs.existsSync(p)) fs.rmSync(p);
}

// Strip Chrome-incompatible and CWS-incompatible fields from manifest
const manifestPath = path.join(tmpDir, 'manifest.json');
const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
delete manifest.key;
delete manifest.update_url;
delete manifest.browser_specific_settings;
// Remove Firefox-only 'scripts' from background (CWS MV3 only uses service_worker)
if (manifest.background?.scripts) {
  delete manifest.background.scripts;
}
fs.writeFileSync(manifestPath, JSON.stringify(manifest, null, 2) + '\n');

const { execFileSync } = require('child_process');
const zipPath = path.resolve(`dist/password-filler-cws-v${version}.zip`);

execFileSync('zip', ['-r', zipPath, '.'], { cwd: tmpDir });
console.log('CWS ZIP packed:', zipPath);
