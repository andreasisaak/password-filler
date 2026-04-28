const HOST_NAME = "app.passwordfiller";

// Persistent native messaging port (no cache — Mac app owns all state).
let port = null;
const pendingCallbacks = [];

// Track pending auth requests to prevent infinite loops.
const pendingRequests = new Map(); // requestId → timestamp

// Track main-frame Basic-Auth fills so we can show the first-visit banner
// once the page finishes loading. tabId → { origin, hostname, ts }.
const recentFills = new Map();
const SEEN_PREFIX = "pf:seen:";

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
          if (details.type === "main_frame" && details.tabId >= 0) {
            recentFills.set(details.tabId, {
              origin: new URL(details.url).origin,
              hostname,
              ts: Date.now()
            });
          }
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
  for (const [id, fill] of recentFills) {
    if (fill.ts < cutoff) recentFills.delete(id);
  }
}, 30000);

chrome.tabs.onRemoved.addListener((tabId) => {
  recentFills.delete(tabId);
});

// --- First-Visit Banner for Basic-Auth-Protected Pages ---
// Shows a Shadow-DOM card the first time we auto-fill credentials for a
// given origin, so users get visual confirmation that the page they just
// landed on is HTTP-Basic-Auth-protected (otherwise the silent fill makes
// it impossible to tell). Stored seen-state in chrome.storage.local;
// resets if the user clears extension storage.

function injectBanner(hostname, strings) {
  const HOST_ID = "pf-protected-banner";
  if (document.getElementById(HOST_ID)) return;

  const host = document.createElement("div");
  host.id = HOST_ID;
  host.style.cssText =
    "position:fixed!important;top:16px!important;right:16px!important;left:auto!important;bottom:auto!important;z-index:2147483647!important;width:auto!important;height:auto!important;margin:0!important;padding:0!important;display:block!important;";

  const shadow = host.attachShadow({ mode: "closed" });
  shadow.innerHTML = `
    <style>
      :host { all: initial; display: block; }
      .card {
        box-sizing: border-box;
        font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif;
        background: rgb(0, 156, 222);
        color: #ffffff;
        padding: 14px 40px 14px 16px;
        border-radius: 4px;
        box-shadow: 0 10px 30px rgba(0, 0, 0, 0.25);
        display: flex;
        align-items: flex-start;
        gap: 12px;
        font-size: 13px;
        line-height: 1.4;
        min-width: 280px;
        max-width: 380px;
        opacity: 0;
        transform: translateY(-8px);
        transition: opacity 0.25s ease, transform 0.25s ease;
        position: relative;
      }
      .card.visible { opacity: 1; transform: translateY(0); }
      .icon {
        flex: 0 0 auto;
        width: 20px;
        height: 20px;
        color: #ffffff;
        margin-top: 1px;
      }
      .text { display: block; }
      .title { font-weight: 600; color: #ffffff; display: block; font-size: 13px; }
      .why {
        color: rgba(255, 255, 255, 0.88);
        margin-top: 4px;
        display: block;
        font-size: 12px;
      }
      .hostname {
        font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
        font-size: 12px;
        color: #ffffff;
        margin-top: 6px;
        word-break: break-all;
        display: block;
      }
      .close {
        position: absolute;
        top: 6px;
        right: 6px;
        width: 24px;
        height: 24px;
        border: 0;
        background: transparent;
        color: rgba(255, 255, 255, 0.75);
        cursor: pointer;
        font-size: 18px;
        line-height: 1;
        padding: 0;
        border-radius: 4px;
        font-family: inherit;
      }
      .close:hover { color: #ffffff; background: rgba(255, 255, 255, 0.15); }
      .close:focus-visible { outline: 2px solid #ffffff; outline-offset: 1px; }
    </style>
    <div class="card" role="status" aria-live="polite">
      <svg class="icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
        <rect x="3" y="11" width="18" height="11" rx="2"></rect>
        <path d="M7 11V7a5 5 0 0 1 10 0v4"></path>
      </svg>
      <span class="text">
        <span class="title"></span>
        <span class="why"></span>
        <span class="hostname"></span>
      </span>
      <button class="close" type="button">×</button>
    </div>
  `;

  shadow.querySelector(".title").textContent = strings.title;
  shadow.querySelector(".why").textContent = strings.why;
  shadow.querySelector(".hostname").textContent = hostname;
  const closeBtn = shadow.querySelector(".close");
  closeBtn.setAttribute("aria-label", strings.closeLabel);
  document.documentElement.appendChild(host);

  const card = shadow.querySelector(".card");
  requestAnimationFrame(() => card.classList.add("visible"));

  let dismissed = false;
  const dismiss = () => {
    if (dismissed) return;
    dismissed = true;
    card.classList.remove("visible");
    setTimeout(() => host.remove(), 260);
  };

  closeBtn.addEventListener("click", dismiss);
  setTimeout(dismiss, 60000);
}

async function maybeShowBanner(tabId, url) {
  const fill = recentFills.get(tabId);
  if (!fill) return;

  let origin;
  try { origin = new URL(url).origin; } catch { return; }
  if (fill.origin !== origin) return;

  recentFills.delete(tabId);

  const seenKey = SEEN_PREFIX + origin;
  const stored = await chrome.storage.local.get(seenKey);
  if (stored[seenKey]) return;

  await chrome.storage.local.set({ [seenKey]: Date.now() });

  const strings = {
    title: chrome.i18n.getMessage("bannerTitle") || "Login automatically filled",
    why: chrome.i18n.getMessage("bannerWhy") ||
      "This page is password-protected. You'll only see this notice on your first visit.",
    closeLabel: chrome.i18n.getMessage("bannerCloseLabel") || "Close"
  };

  try {
    await chrome.scripting.executeScript({
      target: { tabId },
      func: injectBanner,
      args: [fill.hostname, strings]
    });
  } catch (error) {
    console.warn("[pf] banner injection failed:", error);
  }
}

chrome.tabs.onUpdated.addListener((tabId, changeInfo, tab) => {
  if (changeInfo.status !== "complete") return;
  if (!tab?.url) return;
  maybeShowBanner(tabId, tab.url);
});

// --- Toolbar Status Indicator ---
// Uses Chrome's native badge API on top of the static Manifest icon.
//   connected    → green ✓ pill, "connected" tooltip
//   disconnected → red ! pill, "not available" tooltip

function updateStatusBadge(connected) {
  if (connected) {
    chrome.action.setBadgeBackgroundColor({ color: "#1a8d3e" });
    chrome.action.setBadgeText({ text: "✓" });
  } else {
    chrome.action.setBadgeBackgroundColor({ color: "#d93025" });
    chrome.action.setBadgeText({ text: "!" });
  }
  const titleKey = connected ? "tooltipConnected" : "tooltipDisconnected";
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

