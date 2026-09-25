import AppKit
import Foundation

/// The tools that can host the MCP server: whether each is on this Mac, whether Binders is already in it, and how to add it.
/// Every change backs the tool's configuration up first and touches only the Binders entry.
enum MCPHost: String, CaseIterable, Identifiable {
    case claudeCode, claudeDesktop, cursor, windsurf, vsCode, geminiCLI, codex

    var id: String { rawValue }

    var name: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .claudeDesktop: "Claude Desktop"
        case .cursor: "Cursor"
        case .windsurf: "Windsurf"
        case .vsCode: "VS Code"
        case .geminiCLI: "Gemini CLI"
        case .codex: "Codex CLI"
        }
    }

    struct Status: Equatable {
        var present: Bool
        var configured: Bool
    }

    enum Failure: LocalizedError {
        case notFound(String)
        case command(String)

        var errorDescription: String? {
            switch self {
            case .notFound(let what): "\(what) wasn't found on this Mac."
            case .command(let detail): detail
            }
        }
    }

    static var executable: String { Bundle.main.executableURL?.path ?? "/Applications/Binders.app/Contents/MacOS/Binders" }

    private static let home = FileManager.default.homeDirectoryForCurrentUser
    private static func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }

    /// Where the tool keeps its servers.
    var configURL: URL {
        switch self {
        case .claudeCode: Self.home.appendingPathComponent(".claude.json")
        case .claudeDesktop: Self.home.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
        case .cursor: Self.home.appendingPathComponent(".cursor/mcp.json")
        case .windsurf: Self.home.appendingPathComponent(".codeium/windsurf/mcp_config.json")
        case .vsCode: Self.home.appendingPathComponent("Library/Application Support/Code/User/mcp.json")
        case .geminiCLI: Self.home.appendingPathComponent(".gemini/settings.json")
        case .codex: Self.home.appendingPathComponent(".codex/config.toml")
        }
    }

    /// Evidence the tool is installed: its app, its folder, or its command.
    var isPresent: Bool {
        let home = Self.home.path
        return switch self {
        case .claudeCode: Self.exists(home + "/.claude") || Self.exists(home + "/.claude.json")
        case .claudeDesktop: Self.exists("/Applications/Claude.app") || Self.exists(home + "/Library/Application Support/Claude")
        case .cursor: Self.exists("/Applications/Cursor.app") || Self.exists(home + "/.cursor")
        case .windsurf: Self.exists("/Applications/Windsurf.app") || Self.exists(home + "/.codeium/windsurf")
        case .vsCode: Self.exists("/Applications/Visual Studio Code.app") || Self.exists(home + "/Library/Application Support/Code/User")
        case .geminiCLI: Self.exists(home + "/.gemini")
        case .codex: Self.exists(home + "/.codex")
        }
    }

    /// Whether the tool's configuration already names Binders, pointing at this copy.
    var isConfigured: Bool {
        guard let data = try? Data(contentsOf: configURL) else { return false }
        if self == .codex {
            let text = String(decoding: data, as: UTF8.self)
            return text.contains("[mcp_servers.binders]") && text.contains(Self.executable)
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = object[serversKey] as? [String: Any], let entry = servers["binders"] as? [String: Any] else { return false }
        return entry["command"] as? String == Self.executable
    }

    var status: Status { Status(present: isPresent, configured: isConfigured) }

    /// What to do after adding, if anything.
    var afterAdding: String {
        switch self {
        case .claudeDesktop: "Quit and reopen Claude Desktop to load it."
        case .cursor, .windsurf: "Reload the window, or restart the app, to load it."
        case .vsCode: "Reload the VS Code window to load it."
        case .claudeCode, .geminiCLI, .codex: "It is there the next time the tool starts."
        }
    }

    private var serversKey: String { self == .vsCode ? "servers" : "mcpServers" }

    private var entry: [String: Any] {
        var entry: [String: Any] = ["command": Self.executable, "args": ["--mcp"]]
        if self == .vsCode { entry["type"] = "stdio" }
        return entry
    }

    /// How to do it by hand, for the tool's own way of taking a server.
    var instructions: String {
        let exe = Self.executable
        switch self {
        case .claudeCode:
            return "In a terminal:\n\nclaude mcp add -s user binders -- \"\(exe)\" --mcp"
        case .codex:
            return "Add to ~/.codex/config.toml:\n\n[mcp_servers.binders]\ncommand = \"\(exe)\"\nargs = [\"--mcp\"]"
        case .vsCode:
            return "Add to \(configURL.path.replacingOccurrences(of: Self.home.path, with: "~")):\n\n{ \"servers\": { \"binders\": { \"type\": \"stdio\", \"command\": \"\(exe)\", \"args\": [\"--mcp\"] } } }"
        default:
            return "Add to \(configURL.path.replacingOccurrences(of: Self.home.path, with: "~")):\n\n{ \"mcpServers\": { \"binders\": { \"command\": \"\(exe)\", \"args\": [\"--mcp\"] } } }"
        }
    }

    /// Adds Binders to the tool's configuration. Returns a line on what happened.
    func add() async throws -> String {
        switch self {
        case .claudeCode:
            // The tool's own command keeps its file in the shape it expects. Removing first makes this repeatable.
            let exe = Self.executable.replacingOccurrences(of: "'", with: "'\\''")
            let script = "command -v claude >/dev/null || exit 127; claude mcp remove -s user binders >/dev/null 2>&1; claude mcp add -s user binders -- '\(exe)' --mcp"
            let result = try await AutomationService.runProcess("/bin/zsh", ["-lc", script], stdin: nil, environment: nil, timeout: 60)
            if result.status == 127 { throw Failure.notFound("The claude command") }
            guard result.status == 0 else { throw Failure.command(result.stderr.trimmed.isEmpty ? "claude mcp add exited with \(result.status)" : result.stderr.trimmed) }
            return "Added to Claude Code. \(afterAdding)"
        case .codex:
            try Self.backup(configURL)
            var text = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
            let block = "[mcp_servers.binders]\ncommand = \"\(Self.executable)\"\nargs = [\"--mcp\"]\n"
            if let range = text.range(of: #"(?ms)^\[mcp_servers\.binders\]\n.*?(?=^\[|\z)"#, options: .regularExpression) {
                text.replaceSubrange(range, with: block)
            } else {
                if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
                text += "\n" + block
            }
            try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: configURL, atomically: true, encoding: .utf8)
            return "Added to \(name). \(afterAdding)"
        default:
            try Self.backup(configURL)
            var object = (try? Data(contentsOf: configURL)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            var servers = object[serversKey] as? [String: Any] ?? [:]
            servers["binders"] = entry
            object[serversKey] = servers
            let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: configURL, options: .atomic)
            return "Added to \(name). \(afterAdding)"
        }
    }

    /// A dated copy beside the file, so nothing a tool wrote is ever lost.
    private static func backup(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let copy = url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".binders-backup-" + formatter.string(from: Date()))
        try FileManager.default.copyItem(at: url, to: copy)
    }
}
