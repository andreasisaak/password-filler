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

// Write PEM from env, converting literal \n to real newlines (GitHub Secrets quirk)
const rawPem = (process.env.CHROME_PEM || '').replace(/\\n/g, '\n');
if (rawPem.length > 100) {
  fs.writeFileSync(keyPath, rawPem);
  console.log(`PEM written: ${rawPem.length} bytes`);
}

if (!fs.existsSync(keyPath)) {
  console.error('Key file not found:', keyPath);
  process.exit(1);
}

// Validate key is parseable
const { createPrivateKey } = require('crypto');
try {
  const key = createPrivateKey({ key: fs.readFileSync(keyPath), format: 'pem' });
  console.log('Key type:', key.asymmetricKeyType, '— valid');
} catch (e) {
  console.error('Invalid private key:', e.message);
  process.exit(1);
}

crx3([path.resolve('extension')], { keyPath, crxPath, zipPath })
  .then(() => console.log('CRX packed:', crxPath))
  .catch(e => { console.error('Failed:', e.message); process.exit(1); });
