#!/usr/bin/env node

const fs = require("fs");
const path = require("path");
const { execFileSync } = require("child_process");
const { getDomain } = require("tldts");

const CONFIG_DIR = path.join(require("os").homedir(), "Library", "Application Support", "passwordfiller");
const CONFIG_PATH = path.join(CONFIG_DIR, "config.json");

let config = {};
if (fs.existsSync(CONFIG_PATH)) {
  config = JSON.parse(fs.readFileSync(CONFIG_PATH, "utf-8"));
}

// Log to ~/Library/Logs/ with restricted permissions — not world-readable /tmp
const LOG_FILE = path.join(require("os").homedir(), "Library", "Logs", "passwordfiller.log");
const OP_ACCOUNT = config.op_account;
const OP_TAG = config.op_tag || ".htaccess";
const SECTION_PATTERN = /(htaccess|basicauth|basic.?auth|htpasswd|webuser)/i;

// Cache TTL: 15 minutes
const CACHE_TTL_MS = 15 * 60 * 1000;
let cachedItems = null;
let cacheLoadedAt = 0;

function log(message) {
  try {
    const entry = new Date().toISOString() + " " + message + "\n";
    fs.appendFileSync(LOG_FILE, entry, { mode: 0o600 });
  } catch {
    // Logging must never crash the host
  }
}

// --- Native Messaging Protocol (length-prefixed JSON over stdio) ---

function sendMessage(response) {
  const json = JSON.stringify(response);
  const buffer = Buffer.from(json, "utf-8");
  const header = Buffer.alloc(4);
  header.writeUInt32LE(buffer.length, 0);
  process.stdout.write(Buffer.concat([header, buffer]));
}

let inputBuffer = Buffer.alloc(0);

process.stdin.on("data", (chunk) => {
  inputBuffer = Buffer.concat([inputBuffer, chunk]);
  processInput();
});

function processInput() {
  while (inputBuffer.length >= 4) {
    const messageLength = inputBuffer.readUInt32LE(0);
    const totalLength = 4 + messageLength;

    if (inputBuffer.length < totalLength) return;

    const messageBody = inputBuffer.subarray(4, totalLength);
    inputBuffer = inputBuffer.subarray(totalLength);

    try {
      const message = JSON.parse(messageBody.toString());
      handleMessage(message);
    } catch (error) {
      log("Parse error: " + error.message);
      sendMessage({ error: "Invalid message: " + error.message });
    }
  }
}

// --- 1Password CLI ---

const OP_PATH = [
  "/opt/homebrew/bin",
  "/usr/local/bin",
  "/opt/local/bin",
  process.env.PATH || ""
].join(":");

function opExec(args) {
  const argv = OP_ACCOUNT
    ? [...args, "--account", OP_ACCOUNT, "--format", "json"]
    : [...args, "--format", "json"];
  log("Executing: op " + args[0] + " " + args[1]);
  const result = execFileSync("op", argv, {
    encoding: "utf-8",
    timeout: 30000,
    env: { ...process.env, PATH: OP_PATH }
  });
  return JSON.parse(result);
}

function extractHostnames(urls) {
  if (!urls) return [];
  return urls.map((entry) => {
    try {
      return new URL(entry.href).hostname;
    } catch {
      return null;
    }
  }).filter(Boolean);
}

function extractHtaccessCredentials(fields) {
  // 1. Try htaccess/basicauth section
  const sectionFields = fields.filter(
    (field) => field.section && SECTION_PATTERN.test(field.section.label)
  );

  if (sectionFields.length > 0) {
    const usernameField = sectionFields.find((field) => field.type === "STRING");
    const passwordField = sectionFields.find((field) => field.type === "CONCEALED");

    if (usernameField && passwordField) {
      return { username: usernameField.value, password: passwordField.value };
    }
  }

  // 2. Fallback: standard login fields (username + password at top level)
  const username = fields.find((field) => field.id === "username" && !field.section);
  const password = fields.find((field) => field.id === "password" && !field.section);

  if (username?.value && password?.value) {
    return { username: username.value, password: password.value };
  }

  return null;
}

function getCachedItems() {
  if (cachedItems && (Date.now() - cacheLoadedAt) > CACHE_TTL_MS) {
    log("Cache TTL expired, clearing");
    cachedItems = null;
    cacheLoadedAt = 0;
  }
  return cachedItems;
}

function loadAllItems() {
  log("Loading all tagged items from 1Password...");
  const items = opExec(["item", "list", "--tags", OP_TAG]);
  log("Found " + items.length + " tagged items");

  const results = [];

  for (const item of items) {
    const hostnames = extractHostnames(item.urls);
    if (hostnames.length === 0) continue;

    try {
      const fullItem = opExec(["item", "get", item.id]);
      const credentials = extractHtaccessCredentials(fullItem.fields || []);

      if (credentials) {
        const domains = [...new Set(hostnames.map((h) => getDomain(h)).filter(Boolean))];
        results.push({
          itemId: item.id,
          title: item.title,
          hostnames: hostnames,
          domains: domains,
          username: credentials.username,
          password: credentials.password
        });
        log("  item loaded for: " + domains.map((d) => "*." + d).join(", "));
      } else {
        log("  item skipped (no htaccess section)");
      }
    } catch (error) {
      log("  item error: " + error.message);
    }
  }

  cachedItems = results;
  cacheLoadedAt = Date.now();
  return results;
}

// --- Message Handlers ---

function handleMessage(message) {
  log("Received: " + message.action);

  try {
    switch (message.action) {
      case "list":
      case "refresh":
        cachedItems = null;
        cacheLoadedAt = 0;
        const items = loadAllItems();
        sendMessage({ items });
        break;

      case "lookup":
        handleLookup(message);
        break;

      case "ping":
        sendMessage({ pong: true, cached: getCachedItems()?.length ?? 0 });
        break;

      default:
        sendMessage({ error: "Unknown action: " + message.action });
    }
  } catch (error) {
    log("ERROR: " + error.message);
    sendMessage({ error: error.message });
  }
}

function sharedSuffixLength(a, b) {
  const partsA = a.split(".").reverse();
  const partsB = b.split(".").reverse();
  let shared = 0;
  for (let i = 0; i < Math.min(partsA.length, partsB.length); i++) {
    if (partsA[i] === partsB[i]) shared++;
    else break;
  }
  return shared;
}

function handleLookup(message) {
  const hostname = message.hostname;

  if (!getCachedItems()) loadAllItems();

  const cached = getCachedItems();

  // 1. Exact hostname match
  const exactMatch = cached.find((item) => item.hostnames.includes(hostname));
  if (exactMatch) {
    log("Exact match for: " + hostname);
    sendMessage({ found: true, title: exactMatch.title, username: exactMatch.username, password: exactMatch.password });
    return;
  }

  // 2. Domain-suffix match with longest-suffix wins
  const requestDomain = getDomain(hostname);
  if (requestDomain) {
    const candidates = cached.filter((item) =>
      item.hostnames.some((h) => getDomain(h) === requestDomain)
    );

    if (candidates.length === 1) {
      const match = candidates[0];
      log("Domain match (unique) for: " + hostname);
      sendMessage({ found: true, title: match.title, username: match.username, password: match.password });
      return;
    }

    if (candidates.length > 1) {
      const baseDomainParts = requestDomain.split(".").length;
      const requestDepth = hostname.split(".").length - baseDomainParts;
      let bestMatch = null;
      let bestScore = 0;

      for (const item of candidates) {
        for (const stored of item.hostnames) {
          const score = sharedSuffixLength(hostname, stored);
          if (score > bestScore) {
            bestScore = score;
            bestMatch = item;
          }
        }
      }

      // Clear winner: shares more than just the base domain
      if (bestMatch && bestScore > baseDomainParts) {
        log("Domain match (best of " + candidates.length + ") for: " + hostname);
        sendMessage({ found: true, title: bestMatch.title, username: bestMatch.username, password: bestMatch.password });
        return;
      }

      // Tiebreaker: prefer item with hostnames at same subdomain depth
      let depthMatch = null;
      for (const item of candidates) {
        const hasMatchingDepth = item.hostnames.some((h) => {
          if (getDomain(h) !== requestDomain) return false;
          const storedDepth = h.split(".").length - baseDomainParts;
          return storedDepth === requestDepth;
        });
        if (hasMatchingDepth) {
          if (depthMatch) {
            depthMatch = null;
            break;
          }
          depthMatch = item;
        }
      }

      if (depthMatch) {
        log("Domain match (depth tiebreak) for: " + hostname);
        sendMessage({ found: true, title: depthMatch.title, username: depthMatch.username, password: depthMatch.password });
        return;
      }

      log("Ambiguous: " + hostname + " has " + candidates.length + " candidates");
    }
  }

  log("No match: " + hostname);
  sendMessage({ found: false });
}

// --- Startup ---

log("Host started (persistent), PID=" + process.pid);

process.stdin.on("end", () => {
  log("stdin closed, exiting");
  process.exit(0);
});
