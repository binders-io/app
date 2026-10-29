import Foundation

/// What an agent says it's doing, in one short line, read from what it writes anyway rather than asked of it: for a Claude
/// Code run Binders started, the task in progress on the run's own task list; for a Codex, OpenCode or GitHub Copilot CLI
/// run, its plan in the JSON it writes to Binders' own log. So "what's happening?" can say what a run is doing between its
/// reports.
///
/// It's the agent's text: data, never instructions. It's shown as the agent's words (attributed, in lavender with the
/// sparkle), and kept out of answers, corrections, headlines and everything Binders stores: only the line on screen is
/// kept, in memory. It's read only for runs Binders started (the card's latest wake receipt names the session), only while
/// the card is In progress, and no more often than every `interval` in each Binders process. Nothing else of Claude Code's
/// is read for it, the session's title included: a run Binders started has only the name Binders gave it, and its record
/// sits among every running session's. For the CLI tools, only Binders' own log of the run is read, never a tool's files.
public enum AgentDoing {
    /// The most a line says, in characters.
    public static let limit = 120
    /// How long a line read from a run's files stands before they're read again.
    public static let interval: TimeInterval = 30
    /// The most combining marks a character keeps: enough for the accents and stacks of every script, too few to pile up
    /// over the lines around it.
    static let markLimit = 3

    // MARK: Claude Code's task list

    /// One task on a Claude Code task list, as its task tools (TaskCreate, TaskUpdate) write it: one file a task,
    /// `~/.claude/tasks/<session>/<id>.json`, with `id`, `subject`, `activeForm` and `status` (pending, in_progress or
    /// completed) among its keys. Nothing else in it is read.
    public struct ClaudeTask: Equatable, Sendable {
        public var id: String
        public var subject: String
        /// How it's said while it's being done ("Running the tests"). The tools may leave it out.
        public var activeForm: String?
        public var status: String

        public init(id: String, subject: String, activeForm: String? = nil, status: String) {
            self.id = id
            self.subject = subject
            self.activeForm = activeForm
            self.status = status
        }

        /// One task file; nil when it isn't a task (the list's `.highwatermark`, say, or a file half written).
        public init?(json data: Data) {
            guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let id = (object["id"] as? String) ?? (object["id"] as? NSNumber)?.stringValue,
                  let subject = object["subject"] as? String, let status = object["status"] as? String else { return nil }
            self.init(id: id, subject: subject, activeForm: object["activeForm"] as? String, status: status)
        }

        public var inProgress: Bool { status == "in_progress" }
    }

    /// The task being worked on: the first one in progress, in the order they were made. Their ids are numbers ("2" comes
    /// before "10"); any other id comes after them, by name.
    public static func current(_ tasks: [ClaudeTask]) -> ClaudeTask? {
        tasks.filter(\.inProgress).min { a, b in
            switch (Int(a.id), Int(b.id)) {
            case let (x?, y?): x < y
            case (_?, nil): true
            case (nil, _?): false
            case (nil, nil): a.id < b.id
            }
        }
    }

    // MARK: The line

    /// A Claude Code run's line: the task in progress, as it's said while it's being done, else its subject. Nil when no
    /// task is in progress.
    public static func claudeLine(tasks: [ClaudeTask]) -> String? {
        guard let task = current(tasks) else { return nil }
        return clean(task.activeForm ?? "") ?? clean(task.subject)
    }

    /// The line, unless it only says the card's title again.
    public static func line(_ line: String?, for title: String) -> String? {
        func plain(_ text: String) -> String { text.lowercased().filter { $0.isLetter || $0.isNumber } }
        guard let line, plain(line) != plain(title) else { return nil }
        return line
    }

    /// The agent's words as one plain line: a markdown link as its words, no control or direction characters, runs of
    /// spaces as one, no more than `markLimit` combining marks on a character, and at most `limit` characters (cut with "…").
    /// Nil when nothing's left.
    public static func clean(_ text: String) -> String? {
        // Accents that have a character of their own are that character, so they aren't counted as marks.
        var text = text.precomposedStringWithCanonicalMapping
        // [words](address), ![words](address) and [words][label] as their words; <scheme:address> as nothing.
        text = replacing(#"!?\[([^\]\n]*)\]\([^)\n]*\)"#, in: text, with: "$1")
        text = replacing(#"\[([^\]\n]*)\]\[[^\]\n]*\]"#, in: text, with: "$1")
        text = replacing(#"<[A-Za-z][A-Za-z0-9+.-]*:[^>\s]*>"#, in: text, with: "")
        // Never more than a whole line of characters with all their marks.
        let most = limit * (markLimit + 1)
        var scalars = String.UnicodeScalarView()
        var count = 0, onCharacter = 0, cut = false
        for scalar in text.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .format:
                // The invisible ones that steer how text runs or joins go.
                continue
            case .control, .lineSeparator, .paragraphSeparator, .spaceSeparator:
                // Line breaks, tabs and runs of spaces are one space, and none at the start.
                onCharacter = 0
                if let last = scalars.last, last != " " {
                    scalars.append(" ")
                    count += 1
                }
                continue
            case .nonspacingMark, .spacingMark, .enclosingMark:
                // A few marks on a character, never a pile of them.
                onCharacter += 1
                if onCharacter > markLimit { continue }
            default:
                onCharacter = 0
            }
            guard count < most else {
                cut = true
                break
            }
            scalars.append(scalar)
            count += 1
        }
        if scalars.last == " " { scalars.removeLast() }
        let line = String(scalars)
        guard !line.isEmpty else { return nil }
        guard cut || line.count > limit else { return line }
        return String(line.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    private static func replacing(_ pattern: String, in text: String, with template: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return text }
        return expression.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    // MARK: Which run

    /// One line of a card's timeline, as `runSession` reads it: its kind, who wrote it, and the columns it moved between.
    public struct Entry: Equatable, Sendable {
        public var kind: String
        public var author: String
        public var byAgent: Bool
        public var text: String
        public var from: String?
        public var to: String?

        public init(kind: String, author: String, byAgent: Bool, text: String = "", from: String? = nil, to: String? = nil) {
            self.kind = kind
            self.author = author
            self.byAgent = byAgent
            self.text = text
            self.from = from
            self.to = to
        }
    }

    /// The session of the Claude Code run Binders started for a card, while the agent holding it (`holder`) is on it: the
    /// one the card's latest wake receipt names ("… To look in: claude --resume <session> there."), when that receipt
    /// woke the holder, by exactly its name, and nothing since has ended that run or called for a newer one. You taking
    /// the card over stops its run, and so does its going quiet until the card lapsed; another agent taking it means it's
    /// that agent's now, whoever has it later; answering, sending it back or making it ready wakes a newer run, with a
    /// receipt of its own, or none if its wake didn't start. `timeline` is oldest first, and `column` is where the card is
    /// now. Nil when Binders didn't start the run.
    public static func runSession(timeline: [Entry], holder: String, column: BoardColumn) -> String? {
        runReceipt(timeline: timeline, holder: holder, column: column).flatMap { session(inReceipt: $0.text) }
    }

    /// The card's latest wake receipt, while the run it started is still the card's: it woke the holder, by exactly its
    /// name, and nothing since has ended that run or called for a newer one (as `runSession` says). Nil otherwise.
    public static func runReceipt(timeline: [Entry], holder: String, column: BoardColumn) -> Entry? {
        guard column == .inProgress, let index = timeline.lastIndex(where: { $0.kind == "woke" }) else { return nil }
        let receipt = timeline[index]
        // A run Binders started acts under exactly its agent's name. A shorter one is someone else: "Claude Code", your own
        // session's name on the boards, isn't "Claude Code · app", the agent Binders started.
        guard sameName(holder, receipt.author) else { return nil }
        let over = timeline[timeline.index(after: index)...].contains { entry in
            guard !entry.byAgent else { return entry.kind == "lapsed" || (entry.kind == "claimed" && !sameName(entry.author, receipt.author)) }
            // Your comment comes while the run goes: the wake it makes waits for the run to end, with a receipt of its own.
            let reason = AgentWake.reason(kind: entry.kind, from: entry.from.flatMap(BoardColumn.init(rawValue:)),
                                          to: entry.to.flatMap(BoardColumn.init(rawValue:)), column: column, byPerson: true)
            return entry.kind == "claimed" || (reason != nil && reason != .commented)
        }
        return over ? nil : receipt
    }

    /// The same name on the boards, whatever the case or the spaces around it, as Binders knows an agent's own cards.
    static func sameName(_ a: String, _ b: String) -> Bool {
        a.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(b.trimmingCharacters(in: .whitespaces)) == .orderedSame
    }

    /// The kinds of timeline line `runSession` reads: the receipts, and what ends a run or wakes a newer one.
    public static let runKinds = ["woke", "claimed", "lapsed", "answer", "moved", "created", "released", "assigned"]

    /// The session a Claude Code wake receipt names, in lowercase: the last "claude --resume <id>" in it, after the run's
    /// folder.
    public static func session(inReceipt text: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: #"claude --resume ([0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12})\b"#),
              let match = expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).last,
              let range = Range(match.range(at: 1), in: text), let id = UUID(uuidString: String(text[range])) else { return nil }
        return id.uuidString.lowercased()
    }

    // MARK: The CLI tools' runs

    /// The tool a wake receipt started, when it says "Started <tool> in ", after any note before it. Nil for any other
    /// receipt, Claude Code's included.
    public static func cliRun(inReceipt text: String) -> CLIAgent? {
        CLIAgent.allCases.first { text.contains("Started \($0.name) in ") }
    }

    /// The run's own log among the card's links: the last of the form file://<logs>/<card8>-<stamp>.jsonl, in exactly
    /// that folder, with the card's own prefix. An agent can add links, but it can't write that folder, so at worst this
    /// points at an older run of the same card.
    public static func runLog(links: [String], card: UUID, logs: String) -> String? {
        runLogs(links: links, card: card, logs: logs).last
    }

    /// Every run's log among the card's links, oldest first, each once: the card's session as the Agents page's terminal
    /// reads it, run after run.
    public static func runLogs(links: [String], card: UUID, logs: String) -> [String] {
        let folder = (logs as NSString).standardizingPath
        let prefix = String(card.uuidString.prefix(8)).lowercased()
        var seen: Set<String> = []
        return links.compactMap { link -> String? in
            guard let url = URL(string: link), url.isFileURL else { return nil }
            let path = (url.path as NSString).standardizingPath
            let name = (path as NSString).lastPathComponent
            guard (path as NSString).deletingLastPathComponent == folder, name.hasPrefix(prefix + "-"), name.hasSuffix(".jsonl"),
                  name.dropFirst(prefix.count + 1).dropLast(".jsonl".count).allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }),
                  seen.insert(path).inserted
            else { return nil }
            return path
        }
    }

    /// A CLI run's line: its plan as its own output says it, cleaned.
    public static func cliLine(_ output: String, tool: CLIAgent) -> String? {
        CLIAgentOutput.read(tool, output).plan.flatMap(clean)
    }
}
