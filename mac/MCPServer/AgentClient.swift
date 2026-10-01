import Foundation

/// Why the Agent could not answer a `password-filler-mcp` request.
enum AgentClientError: Error, Equatable {
    /// The Agent socket does not accept connections — PasswordFiller.app is
    /// not running.
    case unreachable
    /// The "For AI Agents" switch is off (`{"error":"mcp_disabled"}`).
    case disabled
    /// The Agent did not accept this binary as `password-filler-mcp`
    /// (`{"error":"forbidden"}`, or the connection was closed at the gate).
    case forbidden
    /// Any other reply — names what arrived.
    case unexpectedResponse(String)
}

struct RunCredentials {
    let username: String
    let password: String
}

/// Typed wrapper around the Agent's `hosts` and `run_credentials` socket
/// actions. One connection per call; the Agent closes unauthorized peers
/// right after `accept`, which surfaces here as a broken connection.
struct AgentClient {

    let socketURL: URL

    func hosts() throws -> [String] {
        let reply = try send(["action": "hosts"])
        guard let hosts = reply["hosts"] as? [String] else {
            throw AgentClientError.unexpectedResponse(describe(reply))
        }
        return hosts
    }

    /// `nil` when no unique cached item matches `hostname`.
    func runCredentials(hostname: String) throws -> RunCredentials? {
        let reply = try send(["action": "run_credentials", "hostname": hostname])
        guard let found = reply["found"] as? Bool else {
            throw AgentClientError.unexpectedResponse(describe(reply))
        }
        guard found else { return nil }
        guard let username = reply["username"] as? String, let password = reply["password"] as? String else {
            throw AgentClientError.unexpectedResponse("found=true without username/password")
        }
        return RunCredentials(username: username, password: password)
    }

    private func send(_ request: [String: Any]) throws -> [String: Any] {
        let body = try JSONSerialization.data(withJSONObject: request)
        let response: Data
        do {
            response = try SocketFraming.exchange(body, at: socketURL)
        } catch SocketFramingError.unreachable {
            throw AgentClientError.unreachable
        } catch SocketFramingError.connectionBroken {
            throw AgentClientError.forbidden
        }
        guard let reply = try JSONSerialization.jsonObject(with: response) as? [String: Any] else {
            throw AgentClientError.unexpectedResponse("reply is not a JSON object")
        }
        switch reply["error"] as? String {
        case "mcp_disabled": throw AgentClientError.disabled
        case "forbidden": throw AgentClientError.forbidden
        case let other?: throw AgentClientError.unexpectedResponse("error \(other)")
        case nil: return reply
        }
    }

    /// Key names only — a reply may carry credentials.
    private func describe(_ reply: [String: Any]) -> String {
        "reply with keys \(reply.keys.sorted())"
    }
}
