import CryptoKit
import Foundation

// Antigravity CLI (agy), Google's command-line agent that took over from Gemini CLI, as Binders starts it for a card, and
// what Binders reads back. Everything here comes from Antigravity's documentation and changelog (1.4.7); Binders' own
// self-tests run a stand-in, never agy. The app does the files; these are the decisions.

// MARK: - The launch

/// `agy` in headless mode for one card, in its worktree: the prompt on standard input as one stream-json message (never
/// an argument), stream-json out, its terminal sandbox on, file edits approved in its workspace, slash commands off, and
/// Binders' server for that card in the worktree's `.agents/mcp_config.json`, which takes the place of a user-level server
/// of the same name and which Binders writes before the run and takes out after it. Never Antigravity's Auto mode and
/// never its skip-permissions flag: in a run with no one there, a step its settings don't allow is refused.
public enum AntigravityLaunch {
    /// The folder of a workspace that Antigravity reads its MCP servers, hooks, rules and plugins from.
    public static let workspaceFolder = ".agents"
    /// Binders' server for the run, in the worktree, relative to it.
    public static let mcpConfig = ".agents/mcp_config.json"
    /// The server's name: the one Settings → MCP gives Binders in your own mcp_config.json, which a workspace's entry of
    /// the same name replaces, so a run never has Binders' whole set of tools.
    public static let serverName = "binders"
    /// The rule your Antigravity settings need: headless runs refuse any MCP tool that no rule allows.
    public static let boardRule = "mcp(binders/*)"

    /// Where Binders' server for the run goes.
    public static func mcpConfigPath(worktree: String) -> String {
        CLIAgentLaunches.trimmed(worktree) + "/" + mcpConfig
    }

    /// For the receipt.
    public static let mode = "edits files in its worktree, commands only in its sandbox, no network"

    public static func make(_ run: CLIAgentRun) throws -> CLIAgentLaunch {
        guard run.wake.editsFiles else {
            throw CLIAgentLaunches.Refusal("Antigravity can't be held to reading only, so Binders starts it only to edit files. Set its Permissions to Edits Files in Settings → Agents, or give the card to another agent.")
        }
        let worktree = CLIAgentLaunches.trimmed(run.worktree)
        var arguments = ["--input-format", "stream-json", "--output-format", "stream-json", "--sandbox", "--mode", "accept-edits",
                         "--disable-slash-commands"]
        if let model = run.wake.launchModel { arguments += ["--model", model] }
        if let conversation = run.conversation.flatMap(conversationID) { arguments += ["--conversation", conversation] }
        let extra = ["PWD": worktree, "NO_COLOR": "1"]
        return CLIAgentLaunch(arguments: arguments, directory: worktree, stdin: message(CLIAgentLaunches.prompt(run)),
                              environment: CLIAgentLaunches.environment(base: run.base, home: run.home, path: run.path, temporary: run.temporary,
                                                                        throwawayData: run.throwawayData, extra: extra),
                              files: [mcpConfigPath(worktree: worktree): config(run)], session: nil, lookIn: nil, mode: mode)
    }

    /// The prompt as Antigravity's stream-json input takes it: one user message, on one line.
    public static func message(_ prompt: String) -> String {
        OrderedJSON.object([("event", .string("user")), ("message", .object([("content", .string(prompt))]))]).text() + "\n"
    }

    /// The worktree's mcp_config.json: Binders' server alone, for this card as this agent.
    public static func config(_ run: CLIAgentRun) -> String {
        let environment = CLIAgentLaunches.serverValues(run).map { (key: $0.0, value: OrderedJSON.string($0.1)) }
        let server: OrderedJSON = .object([("command", .string(run.binders)), ("args", .array([.string("--mcp")])), ("env", .object(environment))])
        return OrderedJSON.object([("mcpServers", .object([(serverName, server)]))]).text()
    }

    /// Whether a workspace mcp_config.json is the one Binders writes for a run: Binders' server alone, this Binders, for
    /// a run. Any other is left where it is.
    public static func isOurs(_ data: Data, binders: String) -> Bool {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], object.count == 1,
              let servers = object["mcpServers"] as? [String: Any], servers.count == 1,
              let server = servers[serverName] as? [String: Any], server["command"] as? String == binders,
              let env = server["env"] as? [String: String] else { return false }
        return env["BINDERS_RUN"] == "1" && env["BINDERS_TOOLS"] == "board"
    }

    /// A conversation id Binders passes on: a UUID, in lowercase. Nil for anything else.
    public static func conversationID(_ text: String) -> String? {
        UUID(uuidString: text.trimmingCharacters(in: .whitespacesAndNewlines)).map { $0.uuidString.lowercased() }
    }

    /// The command that looks in on a run, with your own Antigravity settings, when its conversation id is a UUID.
    public static func lookIn(conversation: String?, worktree: String, home: String) -> String? {
        guard let conversation, let id = conversationID(conversation) else { return nil }
        return "cd \(CLIAgentLaunches.pastable(worktree, home: home)) && agy --conversation \(id)"
    }
}

// MARK: - Your Antigravity settings

/// Your Antigravity settings, which Binders can't move or override for a run: it reads two things in them before each
/// run, how much the tools may do without asking (toolPermission) and what you allowed (permissions.allow), and won't
/// start Antigravity when they'd let a run act outside its worktree without asking, or when the run couldn't reach the
/// board. It reads nothing else there. The app reads the file; this decides.
public enum AntigravitySettings {
    /// The file, in your home folder.
    public static let path = ".gemini/antigravity-cli/settings.json"
    /// The same, as the card says it.
    public static let shown = "~/.gemini/antigravity-cli/settings.json"
    /// The presets that ask before a step outside the worktree (and so refuse it in a run): the default, the strictest, and
    /// the one that runs commands without asking only inside its sandbox.
    public static let safePresets: Set = ["request-review", "strict", "proceed-in-sandbox"]

    /// One rule of permissions.allow, read as Antigravity writes them: action(target).
    public struct Rule: Equatable, Sendable {
        public var action: String
        public var target: String
        public init(action: String, target: String) {
            self.action = action
            self.target = target
        }

        /// "command(npm test)" → command, "npm test". Nil when it isn't in that shape.
        public static func parse(_ text: String) -> Rule? {
            let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.hasSuffix(")"), let open = text.firstIndex(of: "("), open > text.startIndex else { return nil }
            let action = String(text[..<open])
            guard action.allSatisfy({ $0.isASCII && ($0.isLetter || $0 == "_") }) else { return nil }
            let target = String(text[text.index(after: open)..<text.index(before: text.endIndex)]).trimmingCharacters(in: .whitespaces)
            return Rule(action: action.lowercased(), target: target)
        }

        public var text: String { "\(action)(\(target))" }
    }

    /// Why Binders won't start Antigravity with these settings, for the card; nil when it may. `data` is the file, nil
    /// when there's none; `privatePaths` is the shared list of what no run may read (`CLIAgentLaunches.privatePaths`).
    public static func problem(_ data: Data?, worktree: String, home: String, privatePaths: [String]) -> String? {
        reason(data, worktree: worktree, home: home, privatePaths: privatePaths).map { "Binders didn't start Antigravity: \($0)" }
    }

    /// The same, for Check in Settings.
    public static func found(_ data: Data?, worktree: String?, home: String, privatePaths: [String]) -> String? {
        reason(data, worktree: worktree ?? home + "/.binders/worktrees/x", home: home, privatePaths: privatePaths)
            .map { "Binders won't start Antigravity as your settings are: \($0)" }
    }

    static func reason(_ data: Data?, worktree: String, home: String, privatePaths: [String]) -> String? {
        var object: [String: Any] = [:]
        if let data, !data.allSatisfy({ [0x20, 0x09, 0x0A, 0x0D].contains($0) }) {
            guard let read = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                return "\(shown) isn't JSON Binders can read (it doesn't read comments), so it can't tell what a run would be allowed. Fix it there, then Wake Now."
            }
            object = read
        }
        // How much may happen without asking.
        if let preset = object["toolPermission"] {
            guard let preset = preset as? String else { return "toolPermission in \(shown) isn't a name Binders knows. \(fix)" }
            let name = preset.trimmingCharacters(in: .whitespaces)
            if name == "always-proceed" {
                return "\(shown) sets toolPermission to always-proceed, which runs commands and tools without asking. \(fix)"
            }
            if !name.isEmpty, !safePresets.contains(name) {
                return "\(shown) sets toolPermission to \(name), which Binders doesn't know, so it can't tell what a run would do without asking. \(fix)"
            }
        }
        // What you allowed. permission.allow too, which an earlier Antigravity's changelog names.
        var rules: [String] = []
        for key in ["permissions", "permission"] {
            guard let permissions = object[key] else { continue }
            guard let table = permissions as? [String: Any] else { return "\(key) in \(shown) isn't in a shape Binders can read. \(fix)" }
            guard let allow = table["allow"] else { continue }
            guard let list = allow as? [Any], list.allSatisfy({ $0 is String }) else {
                return "\(key).allow in \(shown) isn't a list Binders can read. \(fix)"
            }
            rules += list.compactMap { $0 as? String }
        }
        var board = Set<String>()
        for text in rules where !text.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let rule = Rule.parse(text) else {
                return "\(shown) allows “\(text)”, which Binders can't read, so it can't tell what it lets a run do. \(fix)"
            }
            switch outside(rule, worktree: worktree, home: home, privatePaths: privatePaths) {
            case .some(let what):
                return "\(shown) allows \(rule.text), which \(what). \(fix)"
            case .none:
                if rule.action == "mcp" { board.insert(rule.target) }
            }
        }
        guard board.contains(serverAll) || boardTools.allSatisfy({ board.contains(serverName + "/" + $0) }) else {
            return "in a run with no one there to approve a step, Antigravity refuses any MCP tool its settings don't allow, so it couldn't reach the board. Add \"\(AntigravityLaunch.boardRule)\" to permissions.allow in \(shown), then Wake Now. Binders doesn't change that file. The rule lets Antigravity use Binders' tools without asking in your own sessions too."
        }
        return nil
    }

    private static let serverName = AntigravityLaunch.serverName
    private static var serverAll: String { serverName + "/*" }
    /// Binders' board tools for a run, as their own names.
    static let boardTools = OpenCodeLaunch.boardTools.map { String($0.dropFirst("binders_".count)) }

    private static let fix = "Binders can't change your Antigravity settings for a run: change it there, or give the card to another agent, then Wake Now."

    /// What a rule lets a run do outside its worktree without asking, in a few words, or nil when it stays inside: its
    /// commands run in its sandbox (Binders always turns it on), and a path relative to the workspace stays in it.
    static func outside(_ rule: Rule, worktree: String, home: String, privatePaths: [String]) -> String? {
        let target = rule.target
        switch rule.action {
        case "command":
            // In the terminal sandbox, which keeps a command's writes in the workspace and its network off.
            return nil
        case "unsandboxed":
            return "runs commands outside Antigravity's sandbox"
        case "write_file":
            guard let place = place(target, home: home) else { return "lets it change files anywhere" }
            switch place {
            case .relative(let path): return path.split(separator: "/").contains("..") ? "lets it change files outside its worktree" : nil
            case .absolute(let path):
                return AgentWorktree.isInside(path, worktree) ? nil : "lets it change files outside its worktree (\(CLIAgentLaunches.pastable(path, home: home)))"
            }
        case "read_file":
            guard let place = place(target, home: home) else { return "lets it read every file, your keys and Binders' data among them" }
            switch place {
            case .relative(let path): return path.split(separator: "/").contains("..") ? "lets it read files outside its worktree" : nil
            case .absolute(let path):
                let covered = privatePaths.first { AgentWorktree.isInside($0, path) || AgentWorktree.isInside(path, $0) }
                return covered.map { "lets it read \(CLIAgentLaunches.pastable($0, home: home)), which no run may read" }
            }
        case "read_url", "execute_url":
            let site = target.isEmpty || target == "*" ? "any site" : target
            return "lets it reach \(site) without asking, its sandboxed commands too, and Binders' runs reach nothing on the network"
        case "mcp":
            let server = target.split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""
            if server == serverName, target.contains("/") { return nil }
            if server.isEmpty || server.contains("*") { return "lets it use every MCP server's tools without asking, and they act outside its worktree" }
            return "lets it use \(server)'s tools without asking, and they act outside its worktree"
        default:
            return "Binders doesn't know what it allows"
        }
    }

    enum Place: Equatable {
        case relative(String)
        case absolute(String)
    }

    /// Where a path rule points: relative to the workspace, or an absolute path up to its first wildcard. Nil for one that
    /// covers everything ("", "*", "/").
    static func place(_ target: String, home: String) -> Place? {
        var path = target.trimmingCharacters(in: .whitespaces)
        if path == "~" || path.hasPrefix("~/") { path = CLIAgentLaunches.trimmed(home) + path.dropFirst() }
        if let wildcard = path.firstIndex(where: { "*?[".contains($0) }) {
            path = String(path[..<wildcard])
            // "/Users/sam/co*" covers /Users/sam.
            if !path.hasSuffix("/"), let slash = path.lastIndex(of: "/") { path = String(path[...slash]) }
        }
        if path.isEmpty { return nil }
        guard path.hasPrefix("/") else { return .relative(path) }
        let trimmed = CLIAgentLaunches.trimmed(path)
        return trimmed == "/" ? nil : .absolute(trimmed)
    }
}

// MARK: - What's in the worktree's .agents folder

/// What in a worktree's `.agents` folder Antigravity would load and run outside its sandbox: hooks (shell commands), MCP
/// servers and plugins (which bring both). Binders won't start a run in a worktree with any of them, and won't commit a
/// run that adds one. Rules, skills and agents there are words, read as data.
public enum AntigravityWorkspace {
    public static let blocking = ["hooks.json", "mcp_config.json", "plugins"]

    private static func what(_ name: String) -> String {
        switch name {
        case "hooks.json": "which Antigravity would load and run outside its sandbox"
        case "mcp_config.json": "whose servers Antigravity would start outside its sandbox, where Binders puts its own server for the run"
        default: "which can bring hooks and servers of their own"
        }
    }

    /// The first of them in `present` (the names in the folder), as a path in the worktree.
    static func first(_ present: Set<String>) -> String? {
        blocking.first(where: present.contains)
    }

    /// Why a run can't start in this worktree, or nil.
    public static func problem(present: Set<String>) -> String? {
        guard let name = first(present) else { return nil }
        return "Binders didn't start Antigravity: the card's worktree has .agents/\(name), \(what(name)). Take it off the card's branch if the card doesn't need it, or give the card to another agent, then Wake Now."
    }

    /// Why Binders won't commit what a run left, or nil.
    public static func added(present: Set<String>, worktree: String) -> String? {
        guard let name = first(present) else { return nil }
        return "Didn't commit Antigravity's changes: the worktree has .agents/\(name) now, \(what(name)) the next time it opens this repository. They're still in \(worktree)."
    }
}

// MARK: - Steps it wasn't allowed

/// What Antigravity says it refused in a run, with no one there to approve: the stderr notice that names the rule that
/// would allow a step, and `denied_actions` in its JSON. For the card, in plain words.
public enum AntigravityDenials {
    /// Words in a line of stderr that mean a step was refused.
    static let refusing = ["denied", "not permitted", "not allowed", "refused", "requires approval", "needs approval", "blocked", "permission"]

    /// The rules named in the lines of stderr that say a step was refused, once each, in order.
    public static func inErrors(_ text: String) -> [AntigravitySettings.Rule] {
        let plain = text.replacingOccurrences(of: #"\x1B\[[0-9;]*[A-Za-z]"#, with: "", options: .regularExpression)
        var found: [AntigravitySettings.Rule] = []
        for line in plain.split(whereSeparator: \.isNewline) {
            let lowered = line.lowercased()
            guard refusing.contains(where: lowered.contains) else { continue }
            for rule in rules(in: String(line)) where !found.contains(rule) { found.append(rule) }
        }
        return found
    }

    /// The rules written in a line: action(target), the target with at most one level of brackets inside.
    static func rules(in line: String) -> [AntigravitySettings.Rule] {
        let pattern = #"\b(command|write_file|read_file|read_url|execute_url|mcp|unsandboxed)\(((?:[^()\n]|\([^()\n]*\))*)\)"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        return expression.matches(in: line, range: NSRange(line.startIndex..., in: line)).compactMap { match in
            guard let range = Range(match.range, in: line) else { return nil }
            return AntigravitySettings.Rule.parse(String(line[range]))
        }
    }

    /// One entry of `denied_actions`, whatever its shape: a rule, a sentence, or an object naming one.
    public static func read(_ entry: Any) -> String? {
        if let text = entry as? String {
            let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
        guard let object = entry as? [String: Any] else { return nil }
        for key in ["rule", "resource", "permission", "allow_rule", "allowRule"] {
            if let text = object[key] as? String, !text.isEmpty { return text }
        }
        if let action = object["action"] as? String, let target = object["target"] as? String { return "\(action)(\(target))" }
        let tool = (object["tool"] ?? object["tool_name"] ?? object["name"]) as? String
        let detail = (object["command"] ?? object["target"] ?? object["path"]) as? String
        if let tool, let detail { return tool == "run_command" ? "command(\(detail))" : "\(tool) \(detail)" }
        return tool ?? detail
    }

    /// The card's line: "Antigravity wasn't allowed to run `npm test`." and why, or nil when nothing was refused. At most
    /// five steps are named.
    public static func line(_ said: [String]) -> String? {
        var phrases: [String] = []
        for entry in said {
            let phrase: String
            if let rule = AntigravitySettings.Rule.parse(entry) {
                let target = AgentRunReport.trimmed(rule.target, limit: 80)
                switch rule.action {
                case "command", "unsandboxed": phrase = "run `\(target)`"
                case "write_file": phrase = "change `\(target)`"
                case "read_file": phrase = "read `\(target)`"
                case "read_url", "execute_url": phrase = "reach `\(target)`"
                case "mcp": phrase = "use the tool `\(target)`"
                default: phrase = "use `\(AgentRunReport.trimmed(entry, limit: 80))`"
                }
            } else {
                phrase = "use `\(AgentRunReport.trimmed(entry, limit: 80))`"
            }
            if !phrases.contains(phrase) { phrases.append(phrase) }
        }
        guard !phrases.isEmpty else { return nil }
        let shown = Array(phrases.prefix(5))
        var list = shown.count == 1 ? shown[0] : shown.dropLast().joined(separator: ", ") + " or " + shown[shown.count - 1]
        if phrases.count > shown.count { list += ", and \(phrases.count - shown.count) more" }
        return "Antigravity wasn't allowed to \(list). No one is there to approve a step in Binders' runs, so a command outside its sandbox, or one your Antigravity settings don't allow, doesn't run."
    }
}

// MARK: - How it ended

public enum AntigravityOutput {
    /// What a result's status other than SUCCESS says, in words for the card.
    public static func failure(status: String, error: String?) -> String? {
        if let error = error?.trimmingCharacters(in: .whitespacesAndNewlines), !error.isEmpty { return error }
        switch status.uppercased() {
        case "SUCCESS": return nil
        case "CANCELED", "CANCELLED": return "its turn was cancelled"
        case "INTERRUPTED": return "its turn was interrupted"
        case "INVALID": return "Antigravity didn't take the request"
        case "WAITING": return "it stopped at a step a run can't approve"
        case "RUNNING": return "it ended while its turn was still going"
        default: return "its turn ended with \(status.isEmpty ? "no status" : status)"
        }
    }

    /// What it's doing, from a tool step: its tool and the part of its arguments that says what.
    public static func plan(tool: String, arguments: [String: Any]) -> String? {
        func file(_ keys: [String]) -> String? {
            keys.lazy.compactMap { arguments[$0] as? String }.first.map { ($0 as NSString).lastPathComponent }
        }
        switch tool {
        case "run_command": return (arguments["CommandLine"] as? String).map { "Running " + AgentRunReport.trimmed($0, limit: 80) }
        case "write_to_file", "replace_file_content", "multi_replace_file_content": return file(["TargetFile"]).map { "Editing \($0)" }
        case "view_file": return file(["AbsolutePath"]).map { "Reading \($0)" }
        case "grep_search", "find_by_name", "codesearch": return "Searching the code"
        default: return nil
        }
    }

    /// Whether a tool step was one of Binders' board tools: by its name as Antigravity gives an MCP tool (the server's and
    /// the tool's names in it) or by the server it names.
    public static func isBoardTool(name: String, server: String?) -> Bool {
        let tools = AntigravitySettings.boardTools
        if let server, server == AntigravityLaunch.serverName { return true }
        let lowered = name.lowercased()
        return lowered.contains(AntigravityLaunch.serverName) && tools.contains { lowered.hasSuffix($0) }
    }

    /// The reason in what agy printed on stderr when it stopped: its last "error:" line, or the message of its AGY_ERROR
    /// line, or its last other line. Nil when there's none.
    public static func reason(inErrors text: String) -> String? {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        if let error = lines.last(where: { $0.lowercased().hasPrefix("error:") }) { return error }
        if let structured = lines.last(where: { $0.hasPrefix("AGY_ERROR:") }) {
            let json = structured.dropFirst("AGY_ERROR:".count).trimmingCharacters(in: .whitespaces)
            if let object = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] {
                if let message = (object["message"] ?? object["error"]) as? String, !message.isEmpty { return message }
                if let status = (object["status"] ?? object["code"]) as? String { return "Antigravity said \(status)" }
            }
        }
        return CLIAgentOutput.reason(inErrors: text.split(whereSeparator: \.isNewline).filter { !$0.hasPrefix("AGY_ERROR:") }.joined(separator: "\n"))
    }
}

// MARK: - MCP configuration files

/// A tool's MCP configuration file in JSON, with one server added or taken out and everything else in it as it was. A
/// file that isn't plain JSON (comments, trailing commas: Antigravity reads both) is never rewritten: it's refused, so
/// nothing in it is lost.
public enum MCPConfigFile {
    public struct Unreadable: Error, Equatable {}

    private static func object(_ data: Data?) throws -> [String: Any] {
        guard let data, !data.allSatisfy({ [0x20, 0x09, 0x0A, 0x0D].contains($0) }) else { return [:] }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw Unreadable() }
        return object
    }

    /// The file with `entry` as the server `name`, in place of any there was.
    public static func adding(_ entry: [String: Any], named name: String, serversKey: String = "mcpServers", to data: Data?) throws -> Data {
        var object = try object(data)
        if let existing = object[serversKey], !(existing is [String: Any]) { throw Unreadable() }
        var servers = object[serversKey] as? [String: Any] ?? [:]
        servers[name] = entry
        object[serversKey] = servers
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    /// The file without the server `name`; nil when it has none, so there's nothing to write.
    public static func removing(named name: String, serversKey: String = "mcpServers", from data: Data?) throws -> Data? {
        var object = try object(data)
        guard var servers = object[serversKey] as? [String: Any], servers[name] != nil else { return nil }
        servers[name] = nil
        object[serversKey] = servers
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }
}

// MARK: - A hook's prompt, once

extension HookPayload {
    /// The conversation a hook's prompt belongs to, when the tool says (Antigravity's conversationId).
    public static func conversation(_ data: Data) -> String? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return ["conversationId", "conversation_id", "session_id", "sessionId"].lazy.compactMap { object[$0] as? String }.first { !$0.isEmpty }
    }

    /// What tells one prompt from the same prompt handed over again: Antigravity's hook runs before each model call, with
    /// the last thing you sent each time. A digest, so the words aren't kept twice.
    public static func repeatKey(tool: String, conversation: String, text: String) -> String {
        let digest = SHA256.hash(data: Data((tool + "\u{0}" + conversation + "\u{0}" + text).utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
