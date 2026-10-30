import Foundation

// An agent on this Mac working on a hub's cards: a binder linked to a hub keeps its notes and cards there, so the agent
// reaches them through the hub's own MCP server (`/mcp`), as an agent of the hub's with a `bnd_` token of its own, not
// through Binders' server on this Mac. Setting one up asks the hub for the agent (POST /api/agents, as the person signed
// in), which gives its token once, and puts the hub's server in the tool's configuration with that token. Here: what can
// be checked without the hub, the tool or the store.

public enum HubAgents {
    /// The hub's MCP server.
    public static func mcpURL(hub: URL) -> URL {
        hub.appendingPathComponent("mcp")
    }

    /// The server's name in a tool's configuration, beside Binders' own ("binders"): one per Binder on the hub, as its
    /// tokens are, named from it ("binders-team"), so an agent's tools say which.
    public static func serverName(spaceName: String) -> String {
        let slug = spaceName.lowercased().unicodeScalars.map { CharacterSet.alphanumerics.contains($0) && $0.isASCII ? String($0) : "-" }.joined()
            .split(separator: "-").joined(separator: "-")
        return slug.isEmpty || slug == "binders" ? "binders-hub" : "binders-\(String(slug.prefix(40)))"
    }

    /// The hub's word for the tool an agent is (its `provider`).
    public static func provider(forTool tool: String) -> String {
        switch tool.lowercased() {
        case let name where name.contains("claude"): "claude"
        case let name where name.contains("codex") || name.contains("openai"): "openai"
        case let name where name.contains("cursor"): "cursor"
        case let name where name.contains("vs code") || name.contains("copilot"): "copilot"
        case let name where name.contains("gemini") || name.contains("antigravity"): "gemini"
        default: "other"
        }
    }

    /// The agent's name on the hub's boards: the tool and the Mac it's on, "Claude Code · Robin's MacBook".
    public static func agentName(tool: String, mac: String) -> String {
        let mac = mac.trimmingCharacters(in: .whitespacesAndNewlines)
        return String((mac.isEmpty ? tool : "\(tool) · \(mac)").prefix(80))
    }

    /// POST /api/agents's body: the agent, the projects (the hub's `binders`) it may take work from, and where it runs.
    public static func newAgent(name: String, provider: String, binders: [String], runsOn: String) -> Data {
        let body: [String: Any] = ["name": name, "provider": provider, "binders": binders.sorted(), "repos": [String](), "skills": [String](),
                                   "runsOn": runsOn]
        return (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data()
    }

    /// PATCH /api/agents/:id's body, when the projects it may take work from change.
    public static func agentBinders(_ binders: [String]) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["binders": binders.sorted()], options: [.sortedKeys])) ?? Data()
    }

    /// What the hub gives for a new agent: its id and its token, shown this once. Nil for anything else, or a token that
    /// isn't an agent's.
    public static func issued(from data: Data) -> (agent: String, token: String)? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let agent = (object["agent"] as? [String: Any])?["id"] as? String, !agent.isEmpty,
              let token = object["token"] as? String, token.hasPrefix("bnd_") else { return nil }
        return (agent, token)
    }

    /// How a tool's JSON configuration names a server it reaches over HTTP.
    public enum EntryShape: Sendable {
        /// `type: http`, `url` and `headers`: Claude Code, VS Code.
        case typed
        /// `url` and `headers`: Cursor.
        case url
        /// `serverUrl` and `headers`: Windsurf.
        case serverURL
    }

    /// The hub's server as a tool's configuration has it, with the agent's token.
    public static func entry(_ shape: EntryShape, url: URL, token: String) -> [String: Any] {
        let headers = ["Authorization": "Bearer \(token)"]
        switch shape {
        case .typed: return ["type": "http", "url": url.absoluteString, "headers": headers]
        case .url: return ["url": url.absoluteString, "headers": headers]
        case .serverURL: return ["serverUrl": url.absoluteString, "headers": headers]
        }
    }

    /// Whether a configuration's entry is the hub's server at `url`: Binders' own, to change or take out.
    public static func isEntry(_ entry: [String: Any]?, for url: URL) -> Bool {
        guard let entry else { return false }
        return (entry["url"] as? String ?? entry["serverUrl"] as? String) == url.absoluteString
    }
}
