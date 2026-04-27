#!/usr/bin/env node
/**
 * Prepend a new <item> to updates/mac-appcast.xml for a Sparkle release.
 *
 * Invocation (all args required):
 *   node scripts/update-appcast.js \
 *     --version 1.0.0 \
 *     --url https://github.com/andreasisaak/password-filler/releases/download/v1.0.0/password-filler-v1.0.0.dmg \
 *     --length 12345678 \
 *     --signature "<base64 ed25519 sig from sign_update>" \
 *     --minimum-system-version 14.0
 *
 * Keeps the most recent 20 items (older releases still downloadable from
 * GitHub, but Sparkle only needs the latest to decide on an update).
 */

'use strict';

const fs = require('fs');
const path = require('path');

const APPCAST_PATH = path.join(__dirname, '..', 'updates', 'mac-appcast.xml');
const MAX_ITEMS = 20;

function parseArgs(argv) {
  const args = {};
  for (let i = 2; i < argv.length; i += 2) {
    const key = argv[i];
    const value = argv[i + 1];
    if (!key || !key.startsWith('--') || value === undefined) {
      throw new Error(`Malformed argument at position ${i}: ${key}`);
    }
    args[key.slice(2)] = value;
  }
  return args;
}

function requireArg(args, name) {
  if (!args[name] || args[name].length === 0) {
    throw new Error(`Missing required argument: --${name}`);
  }
  return args[name];
}

function escapeXml(raw) {
  return String(raw)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

function buildItem(params) {
  const pubDate = new Date().toUTCString();
  const releaseNotesLink = `https://github.com/andreasisaak/password-filler/releases/tag/v${params.version}`;

  return [
    '    <item>',
    `      <title>Version ${escapeXml(params.version)}</title>`,
    `      <link>${escapeXml(releaseNotesLink)}</link>`,
    `      <sparkle:version>${escapeXml(params.version)}</sparkle:version>`,
    `      <sparkle:shortVersionString>${escapeXml(params.version)}</sparkle:shortVersionString>`,
    `      <sparkle:minimumSystemVersion>${escapeXml(params.minimumSystemVersion)}</sparkle:minimumSystemVersion>`,
    `      <pubDate>${escapeXml(pubDate)}</pubDate>`,
    `      <enclosure url="${escapeXml(params.url)}" sparkle:edSignature="${escapeXml(params.signature)}" length="${escapeXml(params.length)}" type="application/octet-stream" />`,
    '    </item>',
  ].join('\n');
}

function prependItem(xml, itemBlock) {
  const channelClose = '</channel>';
  const closeIndex = xml.lastIndexOf(channelClose);
  if (closeIndex === -1) {
    throw new Error('mac-appcast.xml is malformed: no </channel> close tag found');
  }

  const before = xml.slice(0, closeIndex);
  const after = xml.slice(closeIndex);

  const firstItemIndex = before.indexOf('<item>');
  if (firstItemIndex === -1) {
    // First release: insert before </channel>.
    return `${before.trimEnd()}\n${itemBlock}\n  ${after}`;
  }

  // Count existing items to enforce MAX_ITEMS cap.
  const existingItems = [];
  const itemRegex = /<item>[\s\S]*?<\/item>/g;
  let match;
  while ((match = itemRegex.exec(before)) !== null) {
    existingItems.push(match[0]);
  }

  const kept = existingItems.slice(0, MAX_ITEMS - 1);
  const rebuiltChannel = before.slice(0, firstItemIndex).trimEnd();
  const reassembled = [rebuiltChannel, itemBlock, ...kept.map((i) => `    ${i}`)].join('\n');
  return `${reassembled}\n  ${after}`;
}

function main() {
  const args = parseArgs(process.argv);
  const params = {
    version: requireArg(args, 'version'),
    url: requireArg(args, 'url'),
    length: requireArg(args, 'length'),
    signature: requireArg(args, 'signature'),
    minimumSystemVersion: requireArg(args, 'minimum-system-version'),
  };

  if (!/^\d+$/.test(params.length)) {
    throw new Error(`--length must be an integer byte count, got: ${params.length}`);
  }

  const existing = fs.readFileSync(APPCAST_PATH, 'utf8');
  const itemBlock = buildItem(params);
  const updated = prependItem(existing, itemBlock);
  fs.writeFileSync(APPCAST_PATH, updated);

  console.log(`mac-appcast.xml updated for v${params.version} (${params.length} bytes)`);
}

main();
