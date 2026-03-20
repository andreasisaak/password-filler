const HOST_NAME = "app.passwordfiller";

// Cache: hostname → { username, password }
let credentialCache = new Map();
let cacheTimestamp = 0;
let refreshInProgress = false;

// Persistent native messaging port
let port = null;
let pendingCallbacks = [];

// Track pending auth requests to prevent infinite loops
const pendingRequests = new Set();

// --- Native Messaging (persistent connection) ---

function ensureConnected() {
  if (port) return true;

  try {
    console.log("[htpasswd] Connecting to native host...");
    port = chrome.runtime.connectNative(HOST_NAME);

    port.onMessage.addListener((response) => {
      console.log("[htpasswd] Native response:", JSON.stringify(response).substring(0, 200));
      const callback = pendingCallbacks.shift();
      if (callback) callback(response);
    });

    port.onDisconnect.addListener(() => {
      const error = chrome.runtime.lastError?.message || "disconnected";
      console.log("[htpasswd] Native host disconnected:", error);
      port = null;
      while (pendingCallbacks.length > 0) {
        pendingCallbacks.shift()({ error });
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
    pendingCallbacks.push(resolve);
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

    pendingRequests.add(details.requestId);

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

// --- Credential Lookup ---

async function lookupCredentials(url) {
  const hostname = new URL(url).hostname;

  if (credentialCache.has(hostname)) {
    console.log("[htpasswd] Cache hit:", hostname);
    return credentialCache.get(hostname);
  }

  // Cache miss — try native host (triggers Touch ID if not connected)
  console.log("[htpasswd] Cache miss, asking host:", hostname);
  const response = await sendNativeMessage({ action: "lookup", hostname });

  if (response?.found) {
    const credentials = { username: response.username, password: response.password };
    credentialCache.set(hostname, credentials);
    return credentials;
  }

  return null;
}

// --- Cache Persistence ---

let cachedItemsSummary = []; // [{title, domains}] for popup display

async function saveCache() {
  const data = {};
  credentialCache.forEach((value, key) => { data[key] = value; });
  await chrome.storage.local.set({ credentials: data, cacheTimestamp, items: cachedItemsSummary });
  console.log("[htpasswd] Cache saved to storage");
}

async function loadCache() {
  const result = await chrome.storage.local.get(["credentials", "cacheTimestamp", "items"]);
  if (result.credentials && result.cacheTimestamp) {
    credentialCache.clear();
    for (const [hostname, creds] of Object.entries(result.credentials)) {
      credentialCache.set(hostname, creds);
    }
    cacheTimestamp = result.cacheTimestamp;
    cachedItemsSummary = result.items || [];
    console.log("[htpasswd] Cache loaded from storage:", credentialCache.size, "hostnames");
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
    refreshing: refreshInProgress
  };
}

// Startup: load from storage only. Never auto-refresh.
loadCache().then((loaded) => {
  if (loaded) {
    console.log("[htpasswd] Cache loaded, ready");
  } else {
    console.log("[htpasswd] No cache yet — use popup to refresh");
  }
});

// No automatic refresh — only manual via popup button
// Cache persists in storage across sessions

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
