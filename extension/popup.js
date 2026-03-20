var statusEl = document.getElementById("status");
var metaEl = document.getElementById("meta");
var hostsEl = document.getElementById("hosts");
var refreshBtn = document.getElementById("refresh");

function render(data) {
  if (!data || typeof data.count !== "number") {
    statusEl.className = "status error";
    statusEl.textContent = "Extension not responding";
    metaEl.textContent = "";
    hostsEl.innerHTML = "";
    return;
  }

  if (data.refreshing) {
    statusEl.className = "status loading";
    statusEl.textContent = "Loading from 1Password...";
    metaEl.textContent = "";
    return;
  }

  if (data.count === 0) {
    statusEl.className = "status error";
    statusEl.textContent = "No credentials cached";
    metaEl.textContent = "Click Refresh to load from 1Password";
    hostsEl.innerHTML = "";
    return;
  }

  var items = data.items || [];
  var ago = Math.round((Date.now() - data.timestamp) / 1000 / 60);

  statusEl.className = "status ok";
  if (items.length > 0) {
    statusEl.textContent = data.count + " hostnames from " + items.length + " items";
  } else {
    statusEl.textContent = data.count + " hostnames cached — refresh for details";
  }
  metaEl.textContent = "Last refresh: " + new Date(data.timestamp).toLocaleString("de-DE");

  if (items.length === 0) {
    hostsEl.innerHTML = "";
    return;
  }

  items.sort(function (a, b) { return a.title.localeCompare(b.title); });

  var html = "";
  for (var i = 0; i < items.length; i++) {
    var item = items[i];
    var wildcards = item.domains.map(function (d) { return "*." + d; }).join(", ");
    html += "<div class='item'><strong>" + item.title + "</strong><br>" + wildcards + "</div>";
  }
  hostsEl.innerHTML = html;
}

chrome.runtime.sendMessage({ type: "status" }, function (r) { render(r); });

refreshBtn.addEventListener("click", function () {
  refreshBtn.disabled = true;
  refreshBtn.textContent = "Refreshing...";
  statusEl.className = "status loading";
  statusEl.textContent = "Loading from 1Password...";

  chrome.runtime.sendMessage({ type: "refresh" }, function (r) {
    refreshBtn.disabled = false;
    refreshBtn.textContent = "Refresh from 1Password";
    render(r);
  });
});
