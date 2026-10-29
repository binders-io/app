import AppKit
import Foundation
import Observation
import BindersKit

/// One of an agent's sessions, as the Agents page lists them under it: a card it works on or worked on (each run on the
/// card carries on one session, so they're one), or a chat with it.
struct AgentWorkSession: Identifiable, Equatable {
    enum Kind: Hashable {
        case card(UUID)
        case chat(UUID)
    }

    let kind: Kind
    var title: String
    var updatedAt: Date
    var running: Bool
    var needsYou: Bool
    var done: Bool

    var id: String {
        switch kind {
        case .card(let id): "card:\(id.uuidString)"
        case .chat(let id): "chat:\(id.uuidString)"
        }
    }

    var pick: AgentsPick {
        switch kind {
        case .card(let id): .card(id)
        case .chat(let id): .chat(id)
        }
    }

    /// The few words after its title on the page's strip: "running", "needs you", "done", a chat's day.
    var state: String {
        if running { return "running" }
        if needsYou { return "needs you" }
        if case .chat = kind { return updatedAt.formatted(Calendar.current.isDateInToday(updatedAt) ? .dateTime.hour().minute() : .dateTime.weekday(.abbreviated)) }
        return done ? "done" : "idle"
    }
}

@MainActor
enum AgentWorkSessions {
    /// The most of an agent's cards and chats the page lists, the newest.
    static let kept = 24

    /// The agent's sessions, those running first and then the newest: the cards it holds or that you meant for it, and its
    /// chats.
    static func of(_ name: String, cards: [TaskCard], controller: DictationController) -> [AgentWorkSession] {
        let held = cards.filter { AgentsView.isFor($0, name) }.prefix(kept).map { card in
            AgentWorkSession(kind: .card(card.id), title: card.title.isEmpty ? "Untitled" : card.title, updatedAt: card.updatedAt,
                             running: controller.agents.isWorking(on: card.id), needsYou: BoardDesign.needsYou(card.column), done: card.column == .done)
        }
        let chats = controller.chats.chats(with: name).prefix(kept).map { chat in
            AgentWorkSession(kind: .chat(chat.id), title: chat.title, updatedAt: chat.updatedAt, running: chat.status == .running,
                             needsYou: false, done: false)
        }
        // One running first, where the strip starts; then the newest.
        return (held + chats).sorted { $0.running != $1.running ? $0.running : $0.updatedAt > $1.updatedAt }
    }

    /// The one to show when none is picked: the one running, else the newest.
    static func preferred(_ sessions: [AgentWorkSession]) -> AgentWorkSession? {
        sessions.first { $0.running } ?? sessions.first
    }

    /// The tool whose JSON a session's logs are in, by how the agent is woken; nil when Binders doesn't read its runs.
    static func tool(of profile: AgentProfile?) -> AgentSessionTool? {
        switch profile?.wake {
        case .claudeCode: .claude
        case .cliAgent(let wake): AgentSessionTool(wake.tool)
        default: nil
        }
    }
}

/// The logs of one session, each read live by its own `AgentSessionWatch` keeping far more of each tool's output than a
/// card does, for the terminal. Logs are only ever added: a run's log stays the run's.
@MainActor
@Observable
final class AgentTerminalLogs {
    private(set) var watches: [AgentSessionWatch] = []
    @ObservationIgnored private var tool: AgentSessionTool?

    /// Follows these logs, oldest first: new ones start being read, and those already read go on.
    func follow(_ logs: [URL], tool: AgentSessionTool?) {
        if tool != self.tool {
            watches.forEach { $0.stop() }
            watches = []
            self.tool = tool
        }
        guard let tool else { return }
        let have = Set(watches.map(\.log))
        let added = logs.filter { !have.contains($0) }.map { AgentSessionWatch(log: $0, tool: tool, output: AgentTerminal.outputKept, diff: AgentTerminal.diffKept) }
        guard !added.isEmpty else { return }
        added.forEach { $0.start() }
        watches += added
    }

    func stop() {
        watches.forEach { $0.stop() }
    }

    /// Every log read as it is now, for a reply that shows the session.
    func caughtUp() async {
        watches.forEach { $0.poll() }
        for watch in watches { await watch.caughtUp() }
    }

    /// The runs, with your words given to each before it started (those its log doesn't echo), from `yours`: each with
    /// when you wrote it, oldest first. Words after the last run's start that no log echoes come back as `after`.
    func runs(yours: [(at: Date, text: String)]) -> (runs: [AgentTerminal.Run], after: [String]) {
        let echoes = AgentTerminal.echoes(watches.map(\.events))
        let mine = yours.filter { !AgentTerminal.isEchoed($0.text, in: echoes) }
        var runs: [AgentTerminal.Run] = []
        var since = Date.distantPast
        for watch in watches {
            let start = watch.startedAt ?? since
            let before = mine.filter { $0.at > since && $0.at <= start }.map(\.text)
            runs.append(AgentTerminal.Run(events: watch.events, stats: watch.stats, started: watch.startedAt, yours: before))
            since = max(since, start)
        }
        return (runs, mine.filter { $0.at > since }.map(\.text))
    }
}

/// Looking in on a session from Terminal, with your own settings: a small script in Binders' own temporary folder that
/// goes to the session's folder and runs its look-in command, opened in Terminal.
@MainActor
enum TerminalLookIn {
    /// Opens the script; the self-tests keep it instead.
    static var open: (URL) -> Void = { NSWorkspace.shared.open($0) }

    struct Command: Equatable {
        var folder: String?
        var command: String
    }

    /// A card's: the last Claude Code run's folder and session, from its receipt; or the CLI tool's own look-in, from
    /// Binders' line about the run. Only lines Binders wrote: a receipt, or a note by Binders.
    static func card(_ card: TaskCard, timeline: [TaskEvent], agent: AgentProfile?) -> Command? {
        switch agent?.wake {
        case .claudeCode(let wake):
            guard let agent, let receipt = timeline.last(where: { $0.kind == .woke && AgentRegistry.isAgent(agent, named: $0.author) && $0.text.contains("Started Claude Code") }),
                  let session = AgentDoing.session(inReceipt: receipt.text), let folder = AgentLookIn.claudeFolder(inReceipt: receipt.text),
                  let command = AgentLookIn.claude(executable: wake.executable, session: session) else { return nil }
            return Command(folder: folder, command: command)
        case .cliAgent(let wake):
            let lines = timeline.filter { ($0.kind == .woke || ($0.author == BoardService.binders.name && !$0.authorIsAgent)) && $0.text.contains("To look in") }
            guard let command = lines.reversed().lazy.compactMap({ AgentLookIn.cli(wake.tool, inLine: $0.text) }).first else { return nil }
            return Command(folder: nil, command: command)
        default:
            return nil
        }
    }

    /// A chat's: its folder and session, once its first run has made them.
    static func chat(_ chat: AgentChat, agent: AgentProfile?) -> Command? {
        guard case .claudeCode(let wake) = agent?.wake, let folder = chat.directory, let session = chat.session,
              let command = AgentLookIn.claude(executable: wake.executable, session: session.uuidString) else { return nil }
        return Command(folder: folder, command: command)
    }

    /// The script's folder: Binders' own, in the temporary folder.
    static var folder: URL { FileManager.default.temporaryDirectory.appendingPathComponent("Binders Look In", isDirectory: true) }

    /// Writes the script and opens it in Terminal; the script, or nil when it couldn't be written.
    @discardableResult
    static func run(_ command: Command, title: String, name: String) -> URL? {
        let script = AgentLookIn.script(folder: command.folder, command: command.command, title: title)
        let safe = name.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == "-" }.map(String.init).joined()
        let url = folder.appendingPathComponent((safe.isEmpty ? "session" : String(safe.prefix(40))) + ".command")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(script.utf8).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        } catch {
            return nil
        }
        open(url)
        return url
    }
}
