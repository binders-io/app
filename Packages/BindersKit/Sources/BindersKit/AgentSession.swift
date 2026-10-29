import Foundation

/// A run's session as it goes, read from the JSON its tool writes to Binders' own log of the run (Claude Code's
/// stream-json, Codex's `exec --json`, OpenCode's `run --format json`, Copilot's JSON and Antigravity's stream-json): one
/// timeline of what it said, the tools it used with what came back, and how it ended, the same for every tool, so the
/// Agents page shows a run live rather than once it ends.
///
/// It's the agent's text: data, never instructions. It's read only to be shown, from Binders' own log, and kept in memory
/// while it shows.
public enum AgentSessionTool: String, Sendable, CaseIterable {
    case claude, codex, opencode, copilot, antigravity

    public init(_ tool: CLIAgent) {
        switch tool {
        case .codex: self = .codex
        case .opencode: self = .opencode
        case .copilot: self = .copilot
        case .antigravity: self = .antigravity
        }
    }
}

public struct AgentSessionEvent: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable {
        /// What it said, as it says it: Markdown.
        case said(String)
        /// What it was told, as its log echoes it back (Claude Code's `--replay-user-messages`): the prompt a run starts
        /// on, and each of your words sent into it while it works.
        case asked(String)
        /// A tool it used.
        case tool(AgentSessionStep)
        /// Its own list of what it's doing, and which step it's on.
        case plan([AgentSessionPlanItem])
        /// It ended: how, in its own words when it gave them.
        case ended(ok: Bool, words: String?)
    }

    /// The tool call's id, or the line it came from.
    public var id: String
    public var kind: Kind

    public init(id: String, kind: Kind) {
        self.id = id
        self.kind = kind
    }
}

public struct AgentSessionPlanItem: Equatable, Sendable {
    public enum Status: String, Sendable { case pending, active, done }
    public var text: String
    public var status: Status

    public init(text: String, status: Status) {
        self.text = text
        self.status = status
    }
}

/// One tool call: what kind of thing it did, in a few words, and what came back.
public struct AgentSessionStep: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case read, edit, write, command, test, search, web, board, agent, other

        /// How the timeline says it, done: "Read", "Edited", "Ran".
        public var done: String {
            switch self {
            case .read: "Read"
            case .edit: "Edited"
            case .write: "Wrote"
            case .command: "Ran"
            case .test: "Tests"
            case .search: "Searched"
            case .web: "Looked up"
            case .board: "Board"
            case .agent: "Asked a helper"
            case .other: "Used"
            }
        }

        /// The same, while it's going: "Reading".
        public var going: String {
            switch self {
            case .read: "Reading"
            case .edit: "Editing"
            case .write: "Writing"
            case .command: "Running"
            case .test: "Running tests"
            case .search: "Searching"
            case .web: "Looking up"
            case .board: "Board"
            case .agent: "Asking a helper"
            case .other: "Using"
            }
        }
    }

    public enum Status: String, Sendable { case running, ok, failed }

    public var kind: Kind
    /// The tool's own name: "Edit", "bash", "mcp__binders__report_progress".
    public var name: String
    /// What it was on: a file, a command, a query, the board tool's name.
    public var subject: String
    public var status: Status
    /// The end of what came back, for a command or a failure.
    public var output: String?
    /// For an edit: the lines it took out and put in, with "-" and "+", at most `AgentSessionReader.diffLines`.
    public var diff: [String]
    public var added: Int
    public var removed: Int
    /// How many lines came back in all, before `output` was cut to its end.
    public var outputLines: Int = 0

    public init(kind: Kind, name: String, subject: String, status: Status = .running, output: String? = nil, diff: [String] = [],
                added: Int = 0, removed: Int = 0) {
        self.kind = kind
        self.name = name
        self.subject = subject
        self.status = status
        self.output = output
        self.diff = diff
        self.added = added
        self.removed = removed
    }

    /// "Read UI/Hub/HubView.swift", "Ran swift test", "Tests passed swift test".
    public var line: String {
        switch (kind, status) {
        case (.test, .ok): "Tests passed"
        case (.test, .failed): "Tests failed"
        case (_, .running): kind.going
        default: kind.done
        }
    }
}

/// How a turn ended, when its tool says: how long it took and what it cost.
public struct AgentSessionStats: Equatable, Sendable {
    public var seconds: Double?
    public var cost: Double?
    public var turns: Int?

    public init(seconds: Double? = nil, cost: Double? = nil, turns: Int? = nil) {
        self.seconds = seconds
        self.cost = cost
        self.turns = turns
    }
}

/// Fed one line of a run's log at a time; `events` is the session so far. Lines that aren't a JSON object are skipped.
public struct AgentSessionReader: Sendable {
    public let tool: AgentSessionTool
    public private(set) var events: [AgentSessionEvent] = []
    /// The run's session id, as its tool names it.
    public private(set) var session: String?
    /// How each end went, by its event's id, when the tool said.
    public private(set) var stats: [String: AgentSessionStats] = [:]
    /// The most of a tool's output this reader keeps, from its end: `outputLimit` unless a terminal asks for more.
    public let keepsOutput: Int
    /// The most lines of an edit's diff this reader keeps.
    public let keepsDiff: Int

    /// The most events kept: the oldest go first.
    public static let eventLimit = 400
    /// The most a thing it said keeps, in characters.
    public static let textLimit = 6_000
    /// The most lines of a diff kept.
    public static let diffLines = 40
    /// The most of a tool's output kept, from its end.
    public static let outputLimit = 600

    private var index: [String: Int] = [:]
    private var lines = 0
    /// How many times it has ended: a run you send words into ends each turn.
    private var ends = 0
    /// Antigravity: what each response step has said so far.
    private var responses: [Int: String] = [:]

    /// `output` and `diff`: how much of a tool's output and an edit's lines to keep; a terminal keeps far more than a card.
    public init(tool: AgentSessionTool, output: Int = AgentSessionReader.outputLimit, diff: Int = AgentSessionReader.diffLines) {
        self.tool = tool
        keepsOutput = max(1, output)
        keepsDiff = max(1, diff)
    }

    public mutating func feed(_ line: Substring) {
        lines += 1
        let line = line.drop { $0 == " " || $0 == "\t" }
        guard line.first == "{", let data = String(line).data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        switch tool {
        case .claude: claude(object)
        case .codex: codex(object)
        case .opencode: opencode(object)
        case .copilot: copilot(object)
        case .antigravity: antigravity(object)
        }
    }

    public mutating func feed(text: String) {
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) { feed(line) }
    }

    /// The step it's on now: the last tool still running, else its plan's active item.
    public var current: String? {
        for event in events.reversed() {
            switch event.kind {
            case .tool(let step) where step.status == .running:
                return step.subject.isEmpty ? step.kind.going : "\(step.kind.going) \(step.subject)"
            case .plan(let items):
                return items.first { $0.status == .active }?.text
            case .ended:
                return nil
            default:
                continue
            }
        }
        return nil
    }

    /// Its plan as it last said it.
    public var plan: [AgentSessionPlanItem] {
        for event in events.reversed() { if case .plan(let items) = event.kind { return items } }
        return []
    }

    /// It has ended, and nothing has come since: a run you send words into goes on after a turn's end.
    public var ended: Bool {
        guard let last = events.last else { return false }
        if case .ended = last.kind { return true }
        return false
    }

    // MARK: Keeping the timeline

    private mutating func add(_ id: String?, _ kind: AgentSessionEvent.Kind) {
        let id = id ?? "line-\(lines)-\(events.count)"
        if let at = index[id], at < events.count, events[at].id == id {
            events[at].kind = kind
            return
        }
        events.append(AgentSessionEvent(id: id, kind: kind))
        index[id] = events.count - 1
        if events.count > Self.eventLimit {
            events.removeFirst(events.count - Self.eventLimit)
            index = Dictionary(uniqueKeysWithValues: events.enumerated().map { ($1.id, $0) })
        }
    }

    private mutating func say(_ text: String?, id: String? = nil) {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return }
        add(id, .said(String(text.prefix(Self.textLimit))))
    }

    private mutating func ask(_ text: String?, id: String? = nil) {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return }
        add(id, .asked(String(text.prefix(Self.textLimit))))
    }

    private mutating func plan(_ items: [AgentSessionPlanItem]) {
        guard !items.isEmpty else { return }
        add("plan", .plan(items))
        // The plan shows where it was last said: moved to the end.
        if let at = index["plan"], at != events.count - 1 {
            let event = events.remove(at: at)
            events.append(event)
            index = Dictionary(uniqueKeysWithValues: events.enumerated().map { ($1.id, $0) })
        }
    }

    private mutating func start(_ id: String, _ step: AgentSessionStep) {
        add(id, .tool(step))
    }

    /// What came back for a tool call.
    private mutating func finish(_ id: String, ok: Bool, output: String?) {
        guard let at = index[id], at < events.count, case .tool(var step) = events[at].kind else { return }
        step.status = ok ? .ok : .failed
        if let output = output?.trimmingCharacters(in: .whitespacesAndNewlines), !output.isEmpty {
            step.output = Self.tail(output, keeping: keepsOutput)
            step.outputLines = output.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
        }
        events[at].kind = .tool(step)
    }

    /// The first end is "end"; a run that carries on after it ends again as "end-2", "end-3", each where it came.
    private mutating func end(ok: Bool, words: String?, stats: AgentSessionStats? = nil) {
        // Ended twice with nothing between (a turn's failure, then its result): one end, the last word.
        let id: String
        if let last = events.last, case .ended = last.kind {
            id = last.id
        } else {
            ends += 1
            id = ends == 1 ? "end" : "end-\(ends)"
        }
        add(id, .ended(ok: ok, words: words.map { String($0.prefix(Self.textLimit)) }))
        if let stats { self.stats[id] = stats }
    }

    // MARK: Claude Code (stream-json)

    private mutating func claude(_ object: [String: Any]) {
        switch object["type"] as? String {
        case "system":
            if object["subtype"] as? String == "init", let id = object["session_id"] as? String { session = id }
        case "assistant":
            let message = object["message"] as? [String: Any] ?? [:]
            let id = message["id"] as? String
            for (offset, part) in ((message["content"] as? [[String: Any]]) ?? []).enumerated() {
                switch part["type"] as? String {
                case "text":
                    say(part["text"] as? String, id: id.map { "\($0)-\(offset)" })
                case "tool_use":
                    guard let call = part["id"] as? String else { continue }
                    let name = part["name"] as? String ?? ""
                    let input = part["input"] as? [String: Any] ?? [:]
                    if name == "TodoWrite" {
                        plan(((input["todos"] as? [[String: Any]]) ?? []).compactMap { todo in
                            guard let text = (todo["activeForm"] as? String).flatMap({ todo["status"] as? String == "in_progress" ? $0 : nil })
                                    ?? todo["content"] as? String else { return nil }
                            return AgentSessionPlanItem(text: text, status: Self.planStatus(todo["status"] as? String))
                        })
                        continue
                    }
                    start(call, Self.step(name: name, input: input, diffLimit: keepsDiff))
                default:
                    continue
                }
            }
        case "user":
            let message = object["message"] as? [String: Any] ?? [:]
            // What it was told, echoed back: never Claude Code's own notes to itself.
            let own = object["isSynthetic"] as? Bool == true || object["isMeta"] as? Bool == true
            if let text = message["content"] as? String {
                if !own { ask(text, id: object["uuid"] as? String) }
                return
            }
            let parts = (message["content"] as? [[String: Any]]) ?? []
            let results = parts.filter { $0["type"] as? String == "tool_result" }
            for part in results {
                guard let call = part["tool_use_id"] as? String else { continue }
                finish(call, ok: part["is_error"] as? Bool != true, output: Self.text(part["content"]))
            }
            if results.isEmpty, !own {
                ask(parts.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n"), id: object["uuid"] as? String)
            }
        case "result":
            let failed = object["is_error"] as? Bool == true || (object["subtype"] as? String).map { $0 != "success" } == true
            let stats = AgentSessionStats(seconds: (object["duration_ms"] as? NSNumber).map { $0.doubleValue / 1_000 },
                                          cost: (object["total_cost_usd"] as? NSNumber)?.doubleValue, turns: (object["num_turns"] as? NSNumber)?.intValue)
            end(ok: !failed, words: failed ? (object["result"] as? String ?? object["subtype"] as? String) : nil, stats: stats)
        default:
            break
        }
    }

    // MARK: Codex (`codex exec --json`)

    private mutating func codex(_ object: [String: Any]) {
        switch object["type"] as? String {
        case "thread.started":
            session = object["thread_id"] as? String
        case "turn.completed":
            end(ok: true, words: nil)
        case "turn.failed":
            end(ok: false, words: (object["error"] as? [String: Any])?["message"] as? String)
        case "item.started", "item.updated", "item.completed":
            guard let item = object["item"] as? [String: Any] else { return }
            let id = item["id"] as? String ?? "item-\(lines)"
            let completed = object["type"] as? String == "item.completed"
            switch item["type"] as? String {
            case "agent_message":
                if completed { say(item["text"] as? String, id: id) }
            case "command_execution":
                let command = item["command"] as? String ?? ""
                if index[id] == nil { start(id, AgentSessionStep(kind: Self.isTest(command) ? .test : .command, name: "shell", subject: Self.short(command))) }
                if completed || item["status"] as? String == "failed" {
                    let code = (item["exit_code"] as? NSNumber)?.intValue
                    finish(id, ok: item["status"] as? String != "failed" && (code ?? 0) == 0, output: item["aggregated_output"] as? String)
                }
            case "file_change":
                let changes = (item["changes"] as? [[String: Any]]) ?? []
                let paths = changes.compactMap { $0["path"] as? String }
                let kind: AgentSessionStep.Kind = changes.allSatisfy { $0["kind"] as? String == "add" } && !changes.isEmpty ? .write : .edit
                start(id, AgentSessionStep(kind: kind, name: "apply_patch", subject: Self.files(paths)))
                if completed { finish(id, ok: item["status"] as? String != "failed", output: nil) }
            case "mcp_tool_call":
                let server = item["server"] as? String ?? ""
                let tool = item["tool"] as? String ?? ""
                if index[id] == nil {
                    start(id, AgentSessionStep(kind: server.hasPrefix("binders") ? .board : .other, name: "\(server).\(tool)", subject: Self.humane(tool)))
                }
                if completed { finish(id, ok: item["status"] as? String != "failed", output: nil) }
            case "web_search":
                start(id, AgentSessionStep(kind: .web, name: "web_search", subject: item["query"] as? String ?? "", status: completed ? .ok : .running))
            case "todo_list":
                plan(((item["items"] as? [[String: Any]]) ?? []).enumerated().compactMap { offset, todo in
                    guard let text = todo["text"] as? String else { return nil }
                    let done = todo["completed"] as? Bool == true
                    return AgentSessionPlanItem(text: text, status: done ? .done : .pending)
                }.markingFirstPendingActive())
            default:
                break
            }
        default:
            break
        }
    }

    // MARK: OpenCode (`opencode run --format json`)

    private mutating func opencode(_ object: [String: Any]) {
        if session == nil, let id = object["sessionID"] as? String { session = id }
        let part = object["part"] as? [String: Any] ?? [:]
        switch object["type"] as? String {
        case "text":
            say(part["text"] as? String, id: part["id"] as? String)
        case "tool_use":
            let id = (part["callID"] ?? part["id"]) as? String ?? "tool-\(lines)"
            let name = part["tool"] as? String ?? ""
            let state = part["state"] as? [String: Any] ?? [:]
            let input = state["input"] as? [String: Any] ?? [:]
            if name == "todowrite" {
                let todos = (input["todos"] as? [[String: Any]]) ?? ((state["metadata"] as? [String: Any])?["todos"] as? [[String: Any]]) ?? []
                plan(todos.compactMap { todo in
                    (todo["content"] as? String).map { AgentSessionPlanItem(text: $0, status: Self.planStatus(todo["status"] as? String)) }
                })
                return
            }
            start(id, Self.step(name: name, input: input, diffLimit: keepsDiff))
            switch state["status"] as? String {
            case "completed": finish(id, ok: true, output: state["output"] as? String)
            case "error": finish(id, ok: false, output: state["error"] as? String)
            default: break
            }
        case "error":
            let error = object["error"] as? [String: Any] ?? [:]
            end(ok: false, words: ((error["data"] as? [String: Any])?["message"] as? String) ?? (error["name"] as? String))
        case "step_finish":
            if part["reason"] as? String == "stop" { end(ok: true, words: nil) }
        default:
            break
        }
    }

    // MARK: GitHub Copilot CLI

    private mutating func copilot(_ object: [String: Any]) {
        let data = object["data"] as? [String: Any] ?? [:]
        switch object["type"] as? String {
        case "assistant.message":
            if data["parentToolCallId"] == nil || data["parentToolCallId"] is NSNull {
                say(data["content"] as? String, id: data["messageId"] as? String)
            }
        case "tool.execution_start":
            let id = data["toolCallId"] as? String ?? "tool-\(lines)"
            let name = data["toolName"] as? String ?? ""
            let arguments = data["arguments"] as? [String: Any] ?? [:]
            if name == "report_intent" || name == "update_todo" { return }
            var step = Self.step(name: name, input: arguments, diffLimit: keepsDiff)
            if let server = data["mcpServerName"] as? String, server.hasPrefix("binders") { step.kind = .board }
            start(id, step)
        case "tool.execution_complete":
            let id = data["toolCallId"] as? String ?? ""
            let result = data["result"] as? [String: Any]
            finish(id, ok: data["success"] as? Bool != false, output: Self.text(result?["content"]) ?? Self.text(data["error"]))
        case "session.error":
            end(ok: false, words: data["message"] as? String)
        case "result":
            if session == nil { session = object["sessionId"] as? String }
            let ok = (object["exitCode"] as? NSNumber)?.intValue == 0
            end(ok: ok, words: nil)
        default:
            break
        }
    }

    // MARK: Antigravity (stream-json)

    private mutating func antigravity(_ object: [String: Any]) {
        let event = (object["event"] ?? object["type"]) as? String ?? ""
        let body = object[event] as? [String: Any] ?? object
        if let id = (body["conversation_id"] ?? object["conversation_id"]) as? String, !id.isEmpty { session = id }
        switch event {
        case "step_update":
            let step = (body["step_index"] as? NSNumber)?.intValue ?? -1
            let done = body["state"] as? String == "DONE"
            switch body["step_type"] as? String {
            case "agent_response":
                guard let delta = body["text_delta"] as? String, !delta.isEmpty else { return }
                let sofar = responses[step] ?? ""
                responses[step] = done && delta.hasPrefix(sofar) && !sofar.isEmpty ? delta : sofar + delta
                say(responses[step], id: "response-\(step)")
            case "tool":
                let info = body["tool_info"] as? [String: Any] ?? [:]
                let name = ((body["tool_name"] ?? info["name"] ?? info["tool_name"]) as? String) ?? ""
                let server = (info["server"] ?? info["server_name"] ?? info["mcp_server"]) as? String
                let arguments = (info["parameters"] ?? info["args"] ?? info["arguments"] ?? info["input"]) as? [String: Any] ?? [:]
                let id = "step-\(step)"
                if index[id] == nil {
                    var made = Self.step(name: name, input: arguments, diffLimit: keepsDiff)
                    if AntigravityOutput.isBoardTool(name: name, server: server) { made.kind = .board }
                    start(id, made)
                }
                if done { finish(id, ok: body["error"] == nil, output: body["error"] as? String) }
            default:
                break
            }
        case "result":
            let status = (body["status"] as? String ?? "").uppercased()
            if let response = body["response"] as? String, !response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !events.contains(where: { if case .said(let said) = $0.kind { said == response.trimmingCharacters(in: .whitespacesAndNewlines) } else { false } }) {
                say(response, id: "response-final")
            }
            end(ok: status == "SUCCESS", words: status == "SUCCESS" ? nil : AntigravityOutput.failure(status: status, error: body["error"] as? String))
        default:
            break
        }
    }

    // MARK: Words

    /// A tool call from its name and arguments, as the tools name them (Claude Code's Read, OpenCode's read, Copilot's view).
    static func step(name: String, input: [String: Any], diffLimit: Int = diffLines) -> AgentSessionStep {
        let lowered = name.lowercased()
        func value(_ keys: String...) -> String? {
            for key in keys { if let text = input[key] as? String, !text.isEmpty { return text } }
            return nil
        }
        let path = value("file_path", "filePath", "path", "absolute_path", "notebook_path", "target_file", "file")
        if lowered.hasPrefix("mcp__") || lowered.hasPrefix("binders") {
            let tool = name.components(separatedBy: "__").last ?? name
            return AgentSessionStep(kind: lowered.contains("binders") ? .board : .other, name: name, subject: humane(tool))
        }
        switch lowered {
        case "read", "view", "read_file", "cat", "notebookread":
            return AgentSessionStep(kind: .read, name: name, subject: shortPath(path ?? ""))
        case "edit", "multiedit", "str_replace", "str_replace_editor", "replace", "edit_file", "apply_patch", "patch", "notebookedit":
            var step = AgentSessionStep(kind: .edit, name: name, subject: shortPath(path ?? ""))
            var old = value("old_string", "oldString", "old_str") ?? ""
            var new = value("new_string", "newString", "new_str") ?? ""
            if let edits = input["edits"] as? [[String: Any]] {
                old = edits.compactMap { ($0["old_string"] ?? $0["oldString"]) as? String }.joined(separator: "\n")
                new = edits.compactMap { ($0["new_string"] ?? $0["newString"]) as? String }.joined(separator: "\n")
            }
            (step.diff, step.removed, step.added) = diff(old: old, new: new, limit: diffLimit)
            return step
        case "write", "create", "write_file", "create_file":
            let content = value("content", "file_text", "text") ?? ""
            let lines = content.isEmpty ? 0 : content.split(separator: "\n", omittingEmptySubsequences: false).count
            return AgentSessionStep(kind: .write, name: name, subject: shortPath(path ?? ""), added: lines)
        case "bash", "shell", "run_command", "run_shell_command", "terminal", "exec", "command":
            let command = value("command", "cmd", "CommandLine") ?? (input["command"] as? [String])?.joined(separator: " ") ?? ""
            return AgentSessionStep(kind: isTest(command) ? .test : .command, name: name, subject: short(command))
        case "grep", "glob", "search", "find", "list", "ls", "codebase_search", "grep_search", "find_by_name", "list_dir":
            return AgentSessionStep(kind: .search, name: name, subject: short(value("pattern", "query", "glob", "path", "Query") ?? ""))
        case "webfetch", "websearch", "web_fetch", "web_search", "fetch", "read_url_content", "search_web":
            return AgentSessionStep(kind: .web, name: name, subject: short(value("url", "query", "Url") ?? ""))
        case "task", "agent", "subagent":
            return AgentSessionStep(kind: .agent, name: name, subject: short(value("description", "prompt") ?? ""))
        default:
            return AgentSessionStep(kind: .other, name: name, subject: humane(name))
        }
    }

    /// The lines an edit took out and put in, without those it kept at either end; and how many of each.
    static func diff(old: String, new: String, limit: Int = diffLines) -> ([String], Int, Int) {
        var before = old.isEmpty ? [] : old.components(separatedBy: "\n")
        var after = new.isEmpty ? [] : new.components(separatedBy: "\n")
        while let a = before.first, let b = after.first, a == b { before.removeFirst(); after.removeFirst() }
        while let a = before.last, let b = after.last, a == b { before.removeLast(); after.removeLast() }
        let lines = (before.map { "- " + $0 } + after.map { "+ " + $0 }).prefix(limit).map { String($0.prefix(200)) }
        return (Array(lines), before.count, after.count)
    }

    static func isTest(_ command: String) -> Bool {
        let lowered = command.lowercased()
        return ["swift test", "xcodebuild test", "npm test", "npm run test", "pnpm test", "yarn test", "pytest", "go test", "cargo test",
                "jest", "vitest", "rspec", "mvn test", "gradle test", "make test", "--selftest"].contains { lowered.contains($0) }
    }

    static func shortPath(_ path: String) -> String {
        let parts = path.split(separator: "/")
        return parts.count > 3 ? parts.suffix(3).joined(separator: "/") : path
    }

    static func files(_ paths: [String]) -> String {
        guard let first = paths.first else { return "" }
        return shortPath(first) + (paths.count > 1 ? " and \(paths.count - 1) more" : "")
    }

    static func short(_ text: String) -> String {
        let line = text.split(separator: "\n").first.map(String.init) ?? text
        return line.count > 120 ? String(line.prefix(119)) + "…" : line
    }

    /// "report_progress" → "report progress".
    static func humane(_ name: String) -> String {
        name.replacingOccurrences(of: "_", with: " ")
    }

    static func tail(_ text: String, keeping limit: Int = outputLimit) -> String {
        text.count > limit ? "…" + String(text.suffix(limit)) : text
    }

    static func planStatus(_ status: String?) -> AgentSessionPlanItem.Status {
        switch status {
        case "in_progress": .active
        case "completed": .done
        default: .pending
        }
    }

    /// A tool result's words: a string, or the text parts of a list.
    static func text(_ value: Any?) -> String? {
        if let text = value as? String { return text }
        if let parts = value as? [[String: Any]] { return parts.compactMap { $0["text"] as? String }.joined(separator: "\n") }
        if let object = value as? [String: Any] { return (object["message"] ?? object["text"]) as? String }
        return nil
    }
}

extension Array where Element == AgentSessionPlanItem {
    /// The first item not done is the one being worked on.
    func markingFirstPendingActive() -> [AgentSessionPlanItem] {
        var items = self
        if let first = items.firstIndex(where: { $0.status == .pending }) { items[first].status = .active }
        return items
    }
}
