import Foundation
import Observation
import BindersKit

/// A run's session, live: Binders' own log of a run it started, read from where it was last read every second while
/// something shows it, through `AgentSessionReader`. Only that log is read, never a tool's own files, and what it says is
/// kept in memory while it shows. The agent's words are data, shown as its. Once it has ended it's read every 5 seconds,
/// as a run that takes your words carries on after a turn's end.
@MainActor
@Observable
final class AgentSessionWatch {
    let log: URL
    let tool: AgentSessionTool

    private(set) var events: [AgentSessionEvent] = []
    /// How each turn ended, by its end's event id.
    private(set) var stats: [String: AgentSessionStats] = [:]
    private(set) var plan: [AgentSessionPlanItem] = []
    /// What it's doing now, while it runs.
    private(set) var current: String?
    private(set) var ended = false
    /// When the run started: the log's own creation.
    private(set) var startedAt: Date?
    /// The log has been read once, whatever it held.
    @ObservationIgnored private(set) var readOnce = false

    /// The most of a log read at first: a longer one is read from its last part.
    static let firstRead: UInt64 = 8 * 1024 * 1024

    @ObservationIgnored private var reader: AgentSessionReader
    @ObservationIgnored private var offset: UInt64 = 0
    @ObservationIgnored private var partial = Data()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var reading = false
    @ObservationIgnored private var ticks = 0

    /// `output` and `diff`: how much of each tool's output and edit it keeps (`AgentSessionReader`); a terminal keeps more.
    init(log: URL, tool: AgentSessionTool, output: Int = AgentSessionReader.outputLimit, diff: Int = AgentSessionReader.diffLines) {
        self.log = log
        self.tool = tool
        reader = AgentSessionReader(tool: tool, output: output, diff: diff)
        startedAt = (try? FileManager.default.attributesOfItem(atPath: log.path))?[.creationDate] as? Date
    }

    /// Reads what's there, then what comes, every second, until `stop`.
    func start() {
        poll()
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.ticks += 1
                if !self.ended || self.ticks.isMultiple(of: 5) { self.poll() }
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// What was added to the log since it was last read, off the main thread.
    func poll() {
        guard !reading else { return }
        reading = true
        let url = log, from = offset, carried = partial, reader = reader
        Task.detached(priority: .utility) {
            let read = Self.read(url, from: from, carried: carried, reader: reader)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.reading = false
                self.readOnce = true
                guard let read else { return }
                self.offset = read.offset
                self.partial = read.partial
                guard read.changed else { return }
                self.reader = read.reader
                self.events = read.reader.events
                self.stats = read.reader.stats
                self.plan = read.reader.plan
                self.current = read.reader.current
                self.ended = read.reader.ended
            }
        }
    }

    /// Reads what's there now and returns once it's read, or after `within` seconds: for a reply that shows the session.
    func caughtUp(within seconds: Double = 2) async {
        poll()
        let until = Date().addingTimeInterval(seconds)
        while reading || !readOnce, Date() < until {
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    private nonisolated static func read(_ url: URL, from: UInt64, carried: Data, reader: AgentSessionReader)
        -> (offset: UInt64, partial: Data, reader: AgentSessionReader, changed: Bool)? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true, values.isSymbolicLink != true, let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = UInt64(values.fileSize ?? 0)
        // A log that started again is read from its start.
        var start = from > size ? 0 : from
        var reader = reader
        var carried = from > size ? Data() : carried
        var skipFirst = false
        if start == 0, size > firstRead {
            start = size - firstRead
            skipFirst = true
        }
        guard size > start else { return (start, carried, reader, false) }
        try? handle.seek(toOffset: start)
        guard var data = try? handle.read(upToCount: Int(size - start)), !data.isEmpty else { return (start, carried, reader, false) }
        let end = start + UInt64(data.count)
        if skipFirst, let newline = data.firstIndex(of: 0x0A) { data = data[(newline + 1)...] }
        data = carried + data
        // Whole lines only: what's after the last newline waits for the rest of its line.
        guard let last = data.lastIndex(of: 0x0A) else { return (end, data, reader, false) }
        let lines = data[data.startIndex...last]
        let rest = Data(data[(last + 1)...])
        for line in lines.split(separator: 0x0A) where line.count <= CLIAgentOutput.lineLimit {
            reader.feed(Substring(String(decoding: line, as: UTF8.self)))
        }
        return (end, rest, reader, true)
    }

    /// The run a card's latest wake started, when Binders started it and its log is among the card's links.
    static func run(of card: TaskCard, timeline: [TaskEvent]) -> (log: URL, tool: AgentSessionTool)? {
        guard let receipt = timeline.last(where: { $0.kind == .woke }),
              let path = AgentDoing.runLog(links: card.links, card: card.id, logs: AgentPlaces.logs.path) else { return nil }
        let tool = AgentDoing.cliRun(inReceipt: receipt.text).map(AgentSessionTool.init) ?? .claude
        guard AgentDoing.cliRun(inReceipt: receipt.text) != nil || receipt.text.contains("Started Claude Code") else { return nil }
        return (URL(fileURLWithPath: path), tool)
    }
}
