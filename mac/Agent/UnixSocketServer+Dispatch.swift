import Foundation
import os.log

/// Request dispatch for `UnixSocketServer`: maps one framed JSON request to
/// its JSON response, gated per peer type (D4).
extension UnixSocketServer {

    /// Matches legacy `host/htpasswd-host.js` `handleMessage`:
    ///   - `list`/`refresh` → `{items: [...]}`
    ///   - `lookup` → `{found: true, username, password}` on hit, `{found: false}` on miss
    ///   - `config` → `{op_account: "…"}`
    ///   - `ping` → `{pong: true, cached: N}`
    ///   - unknown → `{error: "Unknown action: X"}` (only reachable ungated;
    ///     a classified peer gets `forbidden` first)
    /// plus, for `password-filler-mcp` only and only while `mcp_enabled`:
    ///   - `hosts` → `{hosts: [...]}` from the cache, no refresh
    ///   - `run_credentials` → same shape as `lookup`
    ///   - switch off → `{error: "mcp_disabled"}`
    ///
    /// D4: each peer type only reaches the actions `SocketPeer.allows` lists.
    /// Internal (not private) so tests can drive the matrix without a signed
    /// peer.
    func dispatch(request: Data, peer: SocketPeer, processID: pid_t?) -> Data {
        guard let json = try? JSONSerialization.jsonObject(with: request) as? [String: Any] else {
            return errorResponse("Invalid JSON")
        }
        let action = (json["action"] as? String) ?? ""

        guard peer.allows(action: action) else {
            log.error("forbidden action \(action, privacy: .public) for peer \(String(describing: peer), privacy: .public)")
            return errorResponse("forbidden")
        }

        switch action {
        case "ping":
            return encode([
                "pong": true,
                "cached": service.itemCount
            ])

        case "config":
            let cfg = service.currentConfig()
            return encode(["op_account": cfg.opAccount])

        case "lookup":
            guard let host = json["hostname"] as? String else {
                return errorResponse("Missing hostname")
            }
            if let match = service.lookup(host: host) {
                return encode([
                    "found": true,
                    "username": match.username,
                    "password": match.password
                ])
            }
            return encode(["found": false])

        case "list", "refresh":
            return handleListOrRefresh()

        case "hosts":
            guard service.currentConfig().mcpEnabled else {
                return errorResponse("mcp_disabled")
            }
            return encode(["hosts": service.hostnames()])

        case "run_credentials":
            return handleRunCredentials(json: json, processID: processID)

        default:
            return errorResponse("Unknown action: \(action)")
        }
    }

    /// Credentials for `password-filler-mcp run`, which hands them to a child
    /// process as environment variables. Logged per call so every hand-out is
    /// traceable; the hostname stays private, the values are never logged.
    private func handleRunCredentials(json: [String: Any], processID: pid_t?) -> Data {
        let pid = processID.map(String.init) ?? "unknown"
        guard service.currentConfig().mcpEnabled else {
            log.info("run_credentials refused, switch off (pid=\(pid, privacy: .public))")
            return errorResponse("mcp_disabled")
        }
        guard let host = json["hostname"] as? String else {
            return errorResponse("Missing hostname")
        }
        guard let match = service.lookup(host: host) else {
            log.info("run_credentials for \(host, privacy: .private): found=false (pid=\(pid, privacy: .public))")
            return encode(["found": false])
        }
        log.info("run_credentials for \(host, privacy: .private): found=true (pid=\(pid, privacy: .public))")
        return encode([
            "found": true,
            "username": match.username,
            "password": match.password
        ])
    }

    /// Synchronously waits on the async refresh via a semaphore — the caller
    /// protocol is request/response and the client expects the items payload
    /// inline. 120 s covers Touch-ID (~user-speed) + parallel itemGet fan-out
    /// across all 31-ish items with comfortable headroom.
    private func handleListOrRefresh() -> Data {
        let semaphore = DispatchSemaphore(value: 0)
        var result: RefreshResult?
        Task { [service] in
            result = await service.performRefresh()
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 120)

        let rows = service.displayRows()
        let items = rows.map { row -> [String: Any] in
            [
                "itemId": row.primaryItemId,
                "title": row.title,
                "hostnames": row.hostnames,
                "domains": row.domains,
                "sourceVaults": row.sourceVaults
            ]
        }
        var payload: [String: Any] = ["items": items]
        if let result, !result.success, let message = result.errorMessage {
            payload["error"] = message
        }
        return encode(payload)
    }

    private func encode(_ dict: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: dict)) ?? Data()
    }

    private func errorResponse(_ message: String) -> Data {
        encode(["error": message])
    }
}
