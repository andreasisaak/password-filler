#!/usr/bin/env node
const fs = require('fs');
const path = require('path');

const version = process.argv[2];
if (!version) {
  console.error('Usage: node scripts/update-chrome-xml.js <version>');
  process.exit(1);
}

const crxUrl = `https://github.com/andreasisaak/password-filler/releases/download/v${version}/password-filler-chrome-v${version}.crx`;

const xml = `<?xml version='1.0' encoding='UTF-8'?>
<gupdate xmlns='http://www.google.com/update2/response' protocol='2.0'>
  <app appid='hgelgpkdbkoipapbeblddhgfjlebckah'>
    <updatecheck status='ok'
      url='${crxUrl}'
      version='${version}' />
  </app>
</gupdate>
`;

fs.writeFileSync(path.resolve('updates/chrome.xml'), xml);
console.log('chrome.xml updated for version', version);
