import Foundation

/// An AI agent that runs in the terminal (a "harness") and keeps a record of what you send it: where that record is,
/// and how to read your prompts out of it. Described, not coded, so a new harness is a few lines in
/// `agent-harnesses.json`, not a new version of Binders.
public struct AgentHarness: Codable, Equatable, Sendable, Identifiable {
    public enum Format: String, Codable, Sendable {
        /// One JSON object per line, added at the end as you go (Claude Code, Codex).
        case jsonl
        /// One JSON file, rewritten as you go: the prompts are an array in it (Gemini CLI, Copilot CLI).
        case json
        /// An SQLite database: `query` returns the prompts (OpenCode).
        case sqlite
    }

    public enum TimeUnit: String, Codable, Sendable { case ms, s, iso }

    public var id: String
    public var name: String
    public var format: Format
    /// The file: "~" is your home folder, and a "*" stands for any one folder ("~/.gemini/tmp/*/logs.json").
    public var path: String
    /// json: the dotted path to the array of prompts in the file; empty when the file is the array.
    public var items: String?
    /// The dotted path to a prompt's words in each item; nil when the item is the words.
    public var text: String?
    public var time: String?
    public var timeUnit: TimeUnit?
    public var project: String?
    /// The dotted path to the harness's name in each item, for a record many tools write to (hooks).
    public var tool: String?
    /// Only items where these dotted paths have these values: {"type": "user"}.
    public var match: [String: String]?
    /// sqlite: rows of (id, text, time in milliseconds, project), newer than `:since` (milliseconds).
    public var query: String?

    public init(id: String, name: String, format: Format, path: String, items: String? = nil, text: String? = nil, time: String? = nil,
                timeUnit: TimeUnit? = nil, project: String? = nil, tool: String? = nil, match: [String: String]? = nil, query: String? = nil) {
        self.id = id
        self.name = name
        self.format = format
        self.path = path
        self.items = items
        self.text = text
        self.time = time
        self.timeUnit = timeUnit
        self.project = project
        self.tool = tool
        self.match = match
        self.query = query
    }

    /// The prompt in one item of the record, if it's one worth keeping.
    public func prompt(from item: Any) -> AgentPrompt? {
        if let match {
            for (path, value) in match where (Self.value(at: path, in: item)).map({ "\($0)" }) != value { return nil }
        }
        let raw: String? = text.map { Self.value(at: $0, in: item) as? String } ?? item as? String
        guard let raw, let words = AgentPrompts.worthKeeping(raw) else { return nil }
        var date = Date()
        if let time, let value = Self.value(at: time, in: item) {
            switch timeUnit ?? .ms {
            case .ms: if let number = (value as? NSNumber)?.doubleValue { date = Date(timeIntervalSince1970: number / 1000) }
            case .s: if let number = (value as? NSNumber)?.doubleValue { date = Date(timeIntervalSince1970: number) }
            case .iso: if let string = value as? String { date = Self.iso(string) ?? date }
            }
        }
        let projectValue = project.flatMap { Self.value(at: $0, in: item) }
        let folder = (projectValue as? String) ?? ((projectValue as? [Any])?.first as? String)
        let named = tool.flatMap { Self.value(at: $0, in: item) as? String }
        return AgentPrompt(text: words, project: folder, date: date, session: nil, tool: named)
    }

    /// The items of a json-format file.
    public func items(in document: Any) -> [Any] {
        let container = (items ?? "").isEmpty ? document : Self.value(at: items ?? "", in: document)
        return container as? [Any] ?? []
    }

    /// "a.b.0.c" in nested dictionaries and arrays.
    public static func value(at path: String, in object: Any) -> Any? {
        var current: Any? = object
        for key in path.split(separator: ".").map(String.init) {
            if let dictionary = current as? [String: Any] {
                current = dictionary[key]
            } else if let array = current as? [Any], let index = Int(key), array.indices.contains(index) {
                current = array[index]
            } else {
                return nil
            }
        }
        return current
    }

    private static func iso(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }

    // MARK: The ones Binders knows

    /// The record `Binders --capture-prompt` writes, for harnesses with hooks: each line names its tool.
    public static let hooksID = "hooks"

    public static let builtIn: [AgentHarness] = [
        AgentHarness(id: "claudeCode", name: "Claude Code", format: .jsonl, path: "~/.claude/history.jsonl",
                     text: "display", time: "timestamp", timeUnit: .ms, project: "project"),
        AgentHarness(id: "codex", name: "Codex", format: .jsonl, path: "~/.codex/history.jsonl", text: "text", time: "ts", timeUnit: .s),
        AgentHarness(id: "geminiCLI", name: "Gemini CLI", format: .json, path: "~/.gemini/tmp/*/logs.json", items: "",
                     text: "message", time: "timestamp", timeUnit: .iso, match: ["type": "user"]),
        AgentHarness(id: "qwenCode", name: "Qwen Code", format: .json, path: "~/.qwen/tmp/*/logs.json", items: "",
                     text: "message", time: "timestamp", timeUnit: .iso, match: ["type": "user"]),
        AgentHarness(id: "copilotCLI", name: "GitHub Copilot CLI", format: .json, path: "~/.copilot/command-history-state.json",
                     items: "commandHistory"),
        AgentHarness(id: "opencode", name: "OpenCode", format: .sqlite, path: "~/.local/share/opencode/opencode.db", query: """
            SELECT p.id, json_extract(p.data, '$.text'), p.time_created, s.directory FROM part p
            JOIN message m ON m.id = p.message_id JOIN session s ON s.id = p.session_id
            WHERE json_extract(m.data, '$.role') = 'user' AND json_extract(p.data, '$.type') = 'text'
              AND coalesce(json_extract(p.data, '$.synthetic'), 0) = 0 AND p.time_created > :since
            ORDER BY p.time_created
            """),
    ]

    /// The built-in harnesses with yours from `agent-harnesses.json`: one with the same id replaces the built-in.
    public static func all(adding custom: [AgentHarness]) -> [AgentHarness] {
        var list = builtIn.filter { harness in !custom.contains { $0.id == harness.id } }
        list += custom
        return list
    }

    /// Reads `agent-harnesses.json`: an array of harnesses. Ones that don't make sense are left out.
    public static func decode(_ data: Data) -> [AgentHarness] {
        ((try? JSONDecoder().decode([AgentHarness].self, from: data)) ?? []).filter { !$0.id.isEmpty && !$0.path.isEmpty && ($0.format != .sqlite || $0.query != nil) }
    }
}

/// What a harness's hook sends `Binders --capture-prompt` on stdin: the prompt, as JSON or as plain words.
public enum HookPayload {
    private static let textKeys = ["prompt", "user_prompt", "text", "message", "display", "input", "query"]
    private static let projectKeys = ["cwd", "project", "workspace", "workspace_roots", "directory"]

    public static func read(_ data: Data) -> (text: String, project: String?)? {
        if let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            let text = textKeys.lazy.compactMap { object[$0] as? String }.first
            let project = projectKeys.lazy.compactMap { key -> String? in
                (object[key] as? String) ?? ((object[key] as? [Any])?.first as? String)
            }.first
            return text.map { ($0, project) }
        }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : (text, nil)
    }
}
