import Foundation

// MARK: - A session as a terminal shows it

/// A session as the Agents page's terminal draws it, in Claude Code's own idiom: your words after "›", what it says after
/// "⏺", each tool as `⏺ Bash(npm test)` with what came back under "⎿", an edit's lines, and how each turn ended. The same
/// for every tool Binders runs, read from Binders' own logs of its runs (`AgentSessionReader`). The agent's words are data,
/// shown as its.
public struct AgentTerminalBlock: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable {
        /// A run starts: when, and whether it carried on the session before it.
        case run(String)
        /// Your words to it.
        case you(String)
        /// The words Binders started a run with: what woke it, in a line, and all of them.
        case binders(summary: String, text: String)
        /// What it said: Markdown.
        case said(String)
        case tool(AgentTerminalTool)
        case plan([AgentSessionPlanItem])
        /// A turn ended: "Done in 3m 12s · $0.42", or why it stopped.
        case end(ok: Bool, line: String)
        /// Your words that haven't reached it yet, and why.
        case waiting(String, why: String)
    }

    public var id: String
    public var kind: Kind

    public init(id: String, kind: Kind) {
        self.id = id
        self.kind = kind
    }
}

/// One tool call as the terminal shows it: `Name(argument)`, then a line saying what it did, or what came back.
public struct AgentTerminalTool: Equatable, Sendable {
    public var name: String
    public var argument: String
    public var status: AgentSessionStep.Status
    /// The line under it: "Read 120 lines", "Updated Board.swift with 2 additions and 1 removal". With none, `output` is.
    public var summary: String?
    /// What came back, line by line.
    public var output: [String]
    /// An edit's lines, with "-" and "+".
    public var diff: [String]

    public init(name: String, argument: String, status: AgentSessionStep.Status, summary: String? = nil, output: [String] = [], diff: [String] = []) {
        self.name = name
        self.argument = argument
        self.status = status
        self.summary = summary
        self.output = output
        self.diff = diff
    }
}

public enum AgentTerminal {
    /// One run of a session, oldest first: what its log says, and when it started.
    public struct Run: Sendable {
        public var events: [AgentSessionEvent]
        public var stats: [String: AgentSessionStats]
        public var started: Date?
        /// Your words that reached it before it started (the comments a wake carried, a chat's messages), shown before what
        /// its log says: leave out those it echoes (`echoes`).
        public var yours: [String]

        public init(events: [AgentSessionEvent], stats: [String: AgentSessionStats] = [:], started: Date? = nil, yours: [String] = []) {
            self.events = events
            self.stats = stats
            self.started = started
            self.yours = yours
        }
    }

    /// How many lines of what came back show before "… +N lines".
    public static let foldAfter = 20
    /// How much of a tool's output, and how many lines of an edit, the terminal's readers keep.
    public static let outputKept = 48_000
    public static let diffKept = 400

    /// The session's blocks, run after run, then the words of yours still waiting for it.
    public static func blocks(_ runs: [Run], waiting: [(text: String, why: String)] = []) -> [AgentTerminalBlock] {
        var blocks: [AgentTerminalBlock] = []
        for (number, run) in runs.enumerated() {
            let when = run.started.map { " · " + $0.formatted(.dateTime.weekday(.abbreviated).hour().minute()) } ?? ""
            blocks.append(AgentTerminalBlock(id: "\(number)-run", kind: .run((number == 0 ? "Started" : "Carried on") + when)))
            for (offset, words) in run.yours.enumerated() where !words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                blocks.append(AgentTerminalBlock(id: "\(number)-yours-\(offset)", kind: .you(words)))
            }
            for event in run.events {
                let id = "\(number)-\(event.id)"
                switch event.kind {
                case .asked(let text):
                    if let words = chatWords(text) {
                        blocks.append(AgentTerminalBlock(id: id, kind: .you(words)))
                    } else if let summary = bindersSummary(text) {
                        blocks.append(AgentTerminalBlock(id: id, kind: .binders(summary: summary, text: text)))
                    } else {
                        blocks.append(AgentTerminalBlock(id: id, kind: .you(text)))
                    }
                case .said(let text):
                    blocks.append(AgentTerminalBlock(id: id, kind: .said(text)))
                case .tool(let step):
                    blocks.append(AgentTerminalBlock(id: id, kind: .tool(tool(step))))
                case .plan(let items):
                    blocks.append(AgentTerminalBlock(id: id, kind: .plan(items)))
                case .ended(let ok, let words):
                    blocks.append(AgentTerminalBlock(id: id, kind: .end(ok: ok, line: endLine(ok: ok, words: words, stats: run.stats[event.id]))))
                }
            }
        }
        for (offset, word) in waiting.enumerated() {
            blocks.append(AgentTerminalBlock(id: "waiting-\(offset)", kind: .waiting(word.text, why: word.why)))
        }
        return blocks
    }

    /// What the runs' logs echo of what they were told, your words in a chat's first prompt among them: words of yours
    /// found in one of these needn't show again.
    public static func echoes(_ runs: [[AgentSessionEvent]]) -> [String] {
        runs.flatMap { events in
            events.compactMap { event -> String? in
                guard case .asked(let text) = event.kind else { return nil }
                return chatWords(text) ?? text
            }
        }
    }

    /// Whether `words` are among what the logs echo.
    public static func isEchoed(_ words: String, in echoes: [String]) -> Bool {
        let words = words.trimmingCharacters(in: .whitespacesAndNewlines)
        return !words.isEmpty && echoes.contains { $0.contains(words) }
    }

    /// A tool call in the terminal's words: Claude Code's names for what it did, whichever tool did it.
    public static func tool(_ step: AgentSessionStep) -> AgentTerminalTool {
        let output = lines(step.output)
        let done = step.status == .ok
        func count(_ number: Int, _ noun: String) -> String { "\(number) \(noun)\(number == 1 ? "" : "s")" }
        var made = AgentTerminalTool(name: name(step), argument: step.subject, status: step.status, output: output, diff: step.diff)
        switch step.kind {
        case .read where done:
            made.summary = "Read " + count(max(step.outputLines, output.count), "line")
            made.output = []
        case .edit where !step.diff.isEmpty && step.status != .failed:
            made.summary = "Updated \(step.subject.isEmpty ? "the file" : step.subject) with " + count(step.added, "addition") + " and " + count(step.removed, "removal")
            made.output = []
        case .write where done:
            made.summary = "Wrote " + count(step.added, "line") + " to \(step.subject.isEmpty ? "the file" : step.subject)"
            made.output = []
        case .search where done:
            made.summary = "Found " + count(max(step.outputLines, output.count), "line")
            made.output = []
        default:
            if output.isEmpty, step.status == .ok { made.summary = "Done" }
        }
        return made
    }

    /// Claude Code's name for a tool: Read, Update, Write, Bash, Search, Fetch, Task; Binders' own board tools as "binders".
    public static func name(_ step: AgentSessionStep) -> String {
        switch step.kind {
        case .read: "Read"
        case .edit: "Update"
        case .write: "Write"
        case .command, .test: "Bash"
        case .search: "Search"
        case .web: step.name.lowercased().contains("search") ? "Web Search" : "Fetch"
        case .agent: "Task"
        case .board: "binders"
        case .other: step.name.components(separatedBy: "__").last ?? step.name
        }
    }

    /// "Done in 3m 12s · $0.42", or "Stopped: why".
    public static func endLine(ok: Bool, words: String?, stats: AgentSessionStats?) -> String {
        var line = ok ? "Done" : "Stopped"
        if let seconds = stats?.seconds, seconds >= 1 { line += " in " + duration(seconds) }
        if let cost = stats?.cost, cost >= 0.005 { line += " · " + String(format: "$%.2f", cost) }
        if !ok {
            let why = words?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            line += why.isEmpty ? " before it finished" : ": " + (why.count > 300 ? String(why.prefix(299)) + "…" : why)
        }
        return line
    }

    /// "12s", "3m 12s", "1h 4m".
    public static func duration(_ seconds: Double) -> String {
        let whole = Int(seconds.rounded())
        if whole < 60 { return "\(whole)s" }
        if whole < 3_600 { return "\(whole / 60)m \(whole % 60)s" }
        return "\(whole / 3_600)h \((whole % 3_600) / 60)m"
    }

    /// The first `keep` lines, and how many more there are.
    public static func fold(_ lines: [String], keep: Int = foldAfter) -> (shown: [String], hidden: Int) {
        lines.count > keep + 1 ? (Array(lines.prefix(keep)), lines.count - keep) : (lines, 0)
    }

    /// What came back, as lines, without the blank ones at its ends.
    static func lines(_ output: String?) -> [String] {
        guard var text = output?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return [] }
        if text.hasPrefix("…") { text = "… " + text.dropFirst() }
        return text.components(separatedBy: "\n").map { $0.replacingOccurrences(of: "\t", with: "    ") }
    }

    /// The words of Binders' own prompt for a card's run, in a line: why it was woken.
    static func bindersSummary(_ text: String) -> String? {
        guard text.hasPrefix(AgentWake.promptMarker) else { return nil }
        let lines = text.components(separatedBy: "\n")
        let why = lines.count > 2 ? lines[2].trimmingCharacters(in: .whitespaces) : ""
        return why.isEmpty ? "Binders woke it for the card." : "Binders woke it for the card. " + why
    }

    /// Your words in a chat's first prompt, after Binders' own about the chat.
    static func chatWords(_ text: String) -> String? {
        guard text.hasPrefix(AgentChatPrompt.marker) else { return nil }
        guard let range = text.range(of: "The user says:\n", options: .backwards) else { return "" }
        return String(text[range.upperBound...])
    }
}

// MARK: - Your words while it works

/// Claude Code taking your words while it works: started with stream-json input, it reads its prompt as the first message
/// on standard input and each of yours after it, each answered by its own `result`, and it stays until its input closes.
/// Binders closes it once every message has its answer, so the run then ends as a run always has. Its log echoes each
/// message back (`--replay-user-messages`), which is how the terminal shows what it was told.
public enum ClaudeCodeLiveInput {
    public static let arguments = ["--input-format", "stream-json", "--replay-user-messages"]

    /// The launch, taking its input as messages: the arguments after `--verbose`. The prompt is sent as the first message.
    public static func taking(_ launch: ClaudeCodeLaunch) -> ClaudeCodeLaunch {
        var launch = launch
        guard !launch.arguments.contains("--input-format") else { return launch }
        let at = (launch.arguments.firstIndex(of: "--verbose").map { $0 + 1 }) ?? launch.arguments.count
        launch.arguments.insert(contentsOf: arguments, at: at)
        return launch
    }

    /// One message, as a line of stream-json.
    public static func message(_ text: String) -> String {
        let object: [String: Any] = ["type": "user", "message": ["role": "user", "content": text]]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else { return "" }
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    /// A turn's answer: its words, and whether it ended in an error.
    public struct Answer: Equatable, Sendable {
        public var text: String?
        public var error: Bool

        public init(text: String?, error: Bool) {
            self.text = text
            self.error = error
        }
    }

    /// The answer a line of the run's log is, when it's a `result`.
    public static func answer(in line: Substring) -> Answer? {
        guard line.contains("\"result\""), let data = String(line).data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], object["type"] as? String == "result" else { return nil }
        let text = (object["result"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return Answer(text: text?.isEmpty == true ? nil : text, error: object["is_error"] as? Bool == true)
    }

    /// Whether to close its input: every message sent has its answer.
    public static func closes(sent: Int, answered: Int) -> Bool { sent > 0 && answered >= sent }
}

// MARK: - Looking in from Terminal

/// What Terminal runs to look in on a session with your own settings: the command the card's own lines give, rebuilt from
/// their parts or matched exactly to the shape Binders writes, so nothing an agent wrote can become a command.
public enum AgentLookIn {
    /// Where a Claude Code run's session is, from its wake receipt: "Started Claude Code in <folder> (" or
    /// "<folder>, the folder itself (".
    public static func claudeFolder(inReceipt text: String) -> String? {
        guard let start = text.range(of: "Started Claude Code in ") else { return nil }
        let rest = text[start.upperBound...]
        guard let end = rest.range(of: ", the folder itself (") ?? rest.range(of: " (") else { return nil }
        let folder = String(rest[..<end.lowerBound])
        return folder.hasPrefix("/") || folder.hasPrefix("~/") ? folder : nil
    }

    /// `claude --resume <session>`, with the agent's own program when it has one.
    public static func claude(executable: String?, session: String) -> String? {
        guard let id = UUID(uuidString: session) else { return nil }
        let program = executable.map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 } ?? "claude"
        return "\(word(program)) --resume \(id.uuidString.lowercased())"
    }

    /// A CLI tool's look-in, from one of Binders' own lines ("To look in, with your own Codex settings: codex resume …"),
    /// only when it has exactly the shape Binders writes for that tool.
    public static func cli(_ tool: CLIAgent, inLine text: String) -> String? {
        guard let marker = text.range(of: "To look in", options: .backwards),
              let colon = text[marker.upperBound...].range(of: ": ") else { return nil }
        var command = String(text[colon.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        if command.hasSuffix(".") { command.removeLast() }
        let path = #"(?:~/)?(?:[A-Za-z0-9._/+@%:,-]+|'(?:[^']|'\\'')*')"#
        let id = "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
        let shape = switch tool {
        case .codex: "codex resume \(id) -C \(path)"
        case .opencode: "opencode \(path) --session ses_[A-Za-z0-9]{1,64}"
        case .antigravity: "cd \(path) && agy --conversation \(id)"
        case .copilot: "cd \(path) && COPILOT_HOME=\(path) copilot --resume=[A-Za-z0-9-]{1,80}"
        }
        guard command.range(of: "^" + shape + "$", options: .regularExpression) != nil else { return nil }
        return command
    }

    /// The script Terminal opens: a login shell, so your PATH finds the tool, in the session's folder.
    public static func script(folder: String?, command: String, title: String) -> String {
        var lines = ["#!/bin/zsh -l", "# \(title.replacingOccurrences(of: "\n", with: " ")): opened from Binders' Agents page."]
        if let folder, !folder.isEmpty {
            let home = folder.hasPrefix("~/")
            lines.append("cd " + (home ? "~/" + word(String(folder.dropFirst(2))) : word(folder)) + " || exit 1")
        }
        lines.append(command)
        return lines.joined(separator: "\n") + "\n"
    }

    /// A word for the shell: as it is when it's plain, else in single quotes.
    static func word(_ text: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._/+-@%:,")
        return !text.isEmpty && text.unicodeScalars.allSatisfy(safe.contains) ? text : AgentMCPEntry.quoted(text)
    }
}
