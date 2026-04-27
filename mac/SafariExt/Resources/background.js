// Password Filler Observer — records the current main-frame URL so
// `CredentialProviderViewController.readObservedHost()` can find it in the
// Shared Keychain when Safari's Basic-Auth dialog fires with empty
// `serviceIdentifiers`.
//
// We listen on three signals because no single Safari event covers every
// path that leads to a Basic-Auth dialog reliably:
//
//  - `webNavigation.onBeforeNavigate` (frameId === 0) — the earliest signal
//    for user-initiated navigations (typed URL, clicked link, Reload). Fires
//    before the TCP connection, so the host is in the keychain by the time
//    the 401 response arrives.
//
//  - `webRequest.onBeforeRequest` (type === "main_frame") — redundant with
//    webNavigation for most cases but also fires for programmatic
//    `location.href = …` redirects that can bypass webNavigation in Safari
//    (observed in the spike — webNavigation delivered late or not at all).
//
//  - `webRequest.onAuthRequired` — the authoritative signal: carries the
//    `challenger.host`, i.e. the origin the 401 came from, which may differ
//    from the document URL host when a sub-request to another origin
//    triggers the challenge. This is the entry the CredProvider will
//    ultimately match against.
//
// The Swift handler de-duplicates via SecItemUpdate so multiple writes per
// navigation are cheap.

const NATIVE_APPLICATION_ID = "application.id";

function sendToNative(payload) {
  try {
    browser.runtime
      .sendNativeMessage(NATIVE_APPLICATION_ID, payload)
      .catch((err) => console.error("[PF] native error", String(err)));
  } catch (err) {
    console.error("[PF] sendNativeMessage threw", String(err));
  }
}

browser.webNavigation.onBeforeNavigate.addListener((details) => {
  if (details.frameId !== 0) return;
  sendToNative({
    type: "navObserved",
    source: "webNavigation",
    url: details.url,
    tabId: details.tabId,
  });
});

browser.webRequest.onBeforeRequest.addListener(
  (details) => {
    if (details.type !== "main_frame") return;
    sendToNative({
      type: "navObserved",
      source: "onBeforeRequest",
      url: details.url,
      tabId: details.tabId,
    });
  },
  { urls: ["<all_urls>"] }
);

browser.webRequest.onAuthRequired.addListener(
  (details) => {
    const host = details.challenger ? details.challenger.host : null;
    sendToNative({
      type: "authObserved",
      source: "onAuthRequired",
      url: details.url,
      tabId: details.tabId,
      host,
      realm: details.realm || null,
    });
  },
  { urls: ["<all_urls>"] }
);
