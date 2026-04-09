const HOST_NAME = "app.passwordfiller";

// Cache: hostname → { username, password } — NOT persisted to disk
let credentialCache = new Map();
let cacheTimestamp = 0;
let refreshInProgress = false;

// Persistent native messaging port
let port = null;
let pendingCallbacks = [];
let opAccount = "";

// Track pending auth requests to prevent infinite loops
const pendingRequests = new Map(); // requestId → timestamp

// --- Native Messaging (persistent connection) ---

function ensureConnected() {
  if (port) return true;

  try {
    console.log("[htpasswd] Connecting to native host...");
    port = chrome.runtime.connectNative(HOST_NAME);

    port.onMessage.addListener((response) => {
      console.log("[htpasswd] Native response:", JSON.stringify(response).substring(0, 200));
      const pending = pendingCallbacks.shift();
      if (pending) {
        clearTimeout(pending.timer);
        pending.resolve(response);
      }
    });

    port.onDisconnect.addListener(() => {
      const error = chrome.runtime.lastError?.message || "disconnected";
      console.log("[htpasswd] Native host disconnected:", error);
      port = null;
      while (pendingCallbacks.length > 0) {
        const pending = pendingCallbacks.shift();
        clearTimeout(pending.timer);
        pending.resolve({ error });
      }
    });

    return true;
  } catch (error) {
    console.error("[htpasswd] Connect failed:", error);
    return false;
  }
}

function sendNativeMessage(message) {
  return new Promise((resolve) => {
    if (!ensureConnected()) {
      resolve({ error: "Failed to connect to native host" });
      return;
    }
    const timer = setTimeout(() => {
      const idx = pendingCallbacks.findIndex((cb) => cb.timer === timer);
      if (idx !== -1) {
        pendingCallbacks.splice(idx, 1);
        resolve({ error: "Native host timeout after 30s" });
      }
    }, 30000);
    pendingCallbacks.push({ resolve, timer });
    port.postMessage(message);
  });
}

// --- Auth Interception ---

chrome.webRequest.onAuthRequired.addListener(
  (details, callback) => {
    console.log("[htpasswd] onAuthRequired:", details.url);

    if (details.isProxy) {
      callback();
      return;
    }

    if (pendingRequests.has(details.requestId)) {
      console.log("[htpasswd] Already tried, letting browser handle it");
      pendingRequests.delete(details.requestId);
      callback();
      return;
    }

    pendingRequests.set(details.requestId, Date.now());

    lookupCredentials(details.url)
      .then((credentials) => {
        if (credentials) {
          console.log("[htpasswd] Found credentials for", new URL(details.url).hostname);
          callback({ authCredentials: credentials });
        } else {
          console.log("[htpasswd] No match for", new URL(details.url).hostname);
          callback();
        }
      })
      .catch((error) => {
        console.error("[htpasswd] Error:", error);
        callback();
      });
  },
  { urls: ["<all_urls>"] },
  ["asyncBlocking"]
);

chrome.webRequest.onCompleted.addListener(
  (details) => pendingRequests.delete(details.requestId),
  { urls: ["<all_urls>"] }
);

chrome.webRequest.onErrorOccurred.addListener(
  (details) => pendingRequests.delete(details.requestId),
  { urls: ["<all_urls>"] }
);

// Periodic cleanup of stale pending requests (tab closed, network timeout)
setInterval(() => {
  const cutoff = Date.now() - 60000;
  for (const [id, ts] of pendingRequests) {
    if (ts < cutoff) pendingRequests.delete(id);
  }
}, 30000);

// --- Credential Lookup ---

async function lookupCredentials(url) {
  const hostname = new URL(url).hostname;

  if (credentialCache.has(hostname)) {
    console.log("[htpasswd] Cache hit:", hostname);
    return credentialCache.get(hostname);
  }

  console.log("[htpasswd] Cache miss, asking host:", hostname);
  const response = await sendNativeMessage({ action: "lookup", hostname });

  if (response?.found) {
    const credentials = { username: response.username, password: response.password };
    credentialCache.set(hostname, credentials);
    return credentials;
  }

  // Cache negative result to avoid repeated host lookups for unknown domains
  credentialCache.set(hostname, null);
  return null;
}

// --- Cache (summary only — credentials are NOT persisted to disk) ---

let cachedItemsSummary = [];

async function saveCache() {
  // Only save display metadata — never persist credentials to disk
  await chrome.storage.local.set({ cacheTimestamp, items: cachedItemsSummary, opAccount });
  console.log("[htpasswd] Cache metadata saved");
}

async function loadCache() {
  const result = await chrome.storage.local.get(["cacheTimestamp", "items", "opAccount"]);
  if (result.cacheTimestamp) {
    cacheTimestamp = result.cacheTimestamp;
    cachedItemsSummary = result.items || [];
    opAccount = result.opAccount || "";
    // credentialCache is intentionally NOT restored from storage
    console.log("[htpasswd] Cache metadata loaded (credentials will be fetched on demand)");
    return true;
  }
  return false;
}

// --- Cache Refresh ---

async function refreshCache() {
  if (refreshInProgress) {
    console.log("[htpasswd] Refresh already in progress, skipping");
    return;
  }

  refreshInProgress = true;
  console.log("[htpasswd] Refreshing cache from 1Password...");

  try {
    const response = await sendNativeMessage({ action: "refresh" });

    if (response?.items) {
      credentialCache.clear();
      cachedItemsSummary = [];
      for (const item of response.items) {
        for (const hostname of item.hostnames) {
          credentialCache.set(hostname, {
            username: item.username,
            password: item.password
          });
        }
        cachedItemsSummary.push({
          title: item.title,
          domains: item.domains || []
        });
      }
      cacheTimestamp = Date.now();
      console.log("[htpasswd] Cached", credentialCache.size, "hostnames from", response.items.length, "items");

      const configResponse = await sendNativeMessage({ action: "config" });
      if (configResponse?.op_account) {
        opAccount = configResponse.op_account;
      }

      await saveCache();
    } else if (response?.error) {
      console.error("[htpasswd] Refresh error:", response.error);
    }
  } catch (error) {
    console.error("[htpasswd] Refresh failed:", error);
  } finally {
    refreshInProgress = false;
  }
}

function getStatus() {
  return {
    count: credentialCache.size,
    timestamp: cacheTimestamp,
    items: cachedItemsSummary,
    refreshing: refreshInProgress,
    opAccount
  };
}

// Startup: load metadata only. Credentials fetched on demand from native host.
loadCache().then((loaded) => {
  if (loaded) {
    console.log("[htpasswd] Cache metadata loaded, ready");
  } else {
    console.log("[htpasswd] No cache yet — use popup to refresh");
  }
});

// --- Popup Communication ---
// MUST return true from ALL branches to prevent Chrome "Error handling response" bug
// See: https://issues.chromium.org/issues/40826436

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (message.type === "refresh") {
    refreshCache().then(() => sendResponse(getStatus()));
    return true;
  }

  if (message.type === "status") {
    sendResponse(getStatus());
    return true;
  }

  return true;
});
