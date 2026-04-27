const HOST_NAME = "app.passwordfiller";

// Persistent native messaging port (no cache — Mac app owns all state).
let port = null;
const pendingCallbacks = [];

// Track pending auth requests to prevent infinite loops.
const pendingRequests = new Map(); // requestId → timestamp

// --- Native Messaging (persistent connection) ---

function ensureConnected() {
  if (port) return true;

  try {
    console.log("[pf] Connecting to native host...");
    port = chrome.runtime.connectNative(HOST_NAME);

    port.onMessage.addListener((response) => {
      const pending = pendingCallbacks.shift();
      if (pending) {
        clearTimeout(pending.timer);
        pending.resolve(response);
      }
    });

    port.onDisconnect.addListener(() => {
      const error = chrome.runtime.lastError?.message || "disconnected";
      console.log("[pf] Native host disconnected:", error);
      port = null;
      while (pendingCallbacks.length > 0) {
        const pending = pendingCallbacks.shift();
        clearTimeout(pending.timer);
        pending.resolve({ error });
      }
      updateStatusBadge(false);
    });

    return true;
  } catch (error) {
    console.error("[pf] Connect failed:", error);
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
    if (details.isProxy) {
      callback();
      return;
    }

    if (pendingRequests.has(details.requestId)) {
      pendingRequests.delete(details.requestId);
      callback();
      return;
    }

    pendingRequests.set(details.requestId, Date.now());

    const hostname = new URL(details.url).hostname;
    sendNativeMessage({ action: "lookup", hostname })
      .then((response) => {
        if (response?.found) {
          callback({
            authCredentials: {
              username: response.username,
              password: response.password
            }
          });
        } else {
          callback();
        }
      })
      .catch((error) => {
        console.error("[pf] Lookup failed:", error);
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

// Periodic cleanup of stale pending requests (tab closed, network timeout).
setInterval(() => {
  const cutoff = Date.now() - 60000;
  for (const [id, ts] of pendingRequests) {
    if (ts < cutoff) pendingRequests.delete(id);
  }
}, 30000);

// --- Toolbar Status Indicator ---
// Chrome's Badge API can't render a transparent round indicator (it always
// draws a solid pill-shaped background around its text). So instead we
// paint a small colored dot directly into the toolbar icon itself via
// OffscreenCanvas and hand the resulting ImageData to `chrome.action.setIcon`.
//   connected    → green dot overlay, green tooltip
//   disconnected → red dot overlay, warning tooltip

const ICON_SIZES = [16, 48, 128];
const iconBitmapCache = new Map(); // size → ImageBitmap of base icon

async function loadBaseIconBitmap(size) {
  if (iconBitmapCache.has(size)) return iconBitmapCache.get(size);
  const url = chrome.runtime.getURL(`icons/icon-${size}.png`);
  const response = await fetch(url);
  const blob = await response.blob();
  const bitmap = await createImageBitmap(blob);
  iconBitmapCache.set(size, bitmap);
  return bitmap;
}

async function renderIconWithDot(color) {
  const imageData = {};
  for (const size of ICON_SIZES) {
    const canvas = new OffscreenCanvas(size, size);
    const ctx = canvas.getContext("2d");
    const bitmap = await loadBaseIconBitmap(size);
    ctx.drawImage(bitmap, 0, 0, size, size);

    // Dot placed bottom-right, ~30% of icon size, with a thin white ring
    // so it reads against both light and dark base icons.
    const r = Math.round(size * 0.30);
    const cx = size - r - Math.round(size * 0.01);
    const cy = size - r - Math.round(size * 0.01);

    ctx.fillStyle = "#ffffff";
    ctx.beginPath();
    ctx.arc(cx, cy, r + Math.max(1, Math.round(size * 0.03)), 0, Math.PI * 2);
    ctx.fill();

    ctx.fillStyle = color;
    ctx.beginPath();
    ctx.arc(cx, cy, r, 0, Math.PI * 2);
    ctx.fill();

    imageData[size] = ctx.getImageData(0, 0, size, size);
  }
  return imageData;
}

async function updateStatusBadge(connected) {
  // Clear any lingering pill badge from older extension versions.
  chrome.action.setBadgeText({ text: "" });

  const color = connected ? "#1a8d3e" : "#d93025";
  const titleKey = connected ? "tooltipConnected" : "tooltipDisconnected";
  try {
    const imageData = await renderIconWithDot(color);
    await chrome.action.setIcon({ imageData });
  } catch (error) {
    console.error("[pf] setIcon failed:", error);
  }
  chrome.action.setTitle({
    title: chrome.i18n.getMessage(titleKey) || "Password Filler"
  });
}

async function refreshStatusBadge() {
  const response = await sendNativeMessage({ action: "ping" });
  updateStatusBadge(!response?.error);
}

chrome.runtime.onInstalled.addListener(refreshStatusBadge);
chrome.runtime.onStartup.addListener(refreshStatusBadge);

// chrome.alarms survives the MV3 service-worker idle termination, unlike
// setInterval — that's the only way to keep a periodic status check alive.
chrome.alarms.create("pfStatusCheck", { periodInMinutes: 0.5 });
chrome.alarms.onAlarm.addListener((alarm) => {
  if (alarm.name === "pfStatusCheck") refreshStatusBadge();
});
