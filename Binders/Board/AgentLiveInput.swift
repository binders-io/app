import Foundation
import BindersKit

/// A Claude Code run's standard input, kept open while it works so your words reach it then (`ClaudeCodeLiveInput`): its
/// prompt goes first, as a message, and each of yours after it. Its log is read every half second for each turn's
/// `result`; once every message has its answer, the input closes and the run ends as a run always has, its end handled
/// as before. A message it took into the turn before rather than answering on its own (nothing comes for a while after a
/// result) closes it too. The run's log is Binders' own; only `result` lines are read here.
@MainActor
final class AgentLiveInput {
    let log: URL
    /// The agent the run is, by its name on the boards.
    let agent: String
    private(set) var sent = 0
    private(set) var answered = 0
    private(set) var isOpen = true
    /// Each turn's answer as it comes: a chat's reply.
    var answer: ((ClaudeCodeLiveInput.Answer) -> Void)?

    /// How long it may sit after a result with a message of yours unanswered before Binders takes it that the message went
    /// into the turn before, and closes its input.
    static let quietAfterResult: TimeInterval = 30

    private let writer: FileHandle
    private let queue = DispatchQueue(label: "io.binders.live-input")
    private var timer: Timer?
    private var offset: UInt64 = 0
    private var partial = Data()
    private var lastLineWasResult = false
    private var lastGrowth = Date()

    init(log: URL, agent: String, writer: FileHandle, prompt: String) {
        self.log = log
        self.agent = agent
        self.writer = writer
        send(prompt)
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    /// Your words, into the run now. False once its input has closed: they go the way they always went.
    @discardableResult
    func send(_ text: String) -> Bool {
        guard isOpen else { return false }
        let line = Data(ClaudeCodeLiveInput.message(text).utf8)
        guard !line.isEmpty else { return false }
        sent += 1
        lastGrowth = Date()
        let writer = writer
        queue.async { try? writer.write(contentsOf: line) }
        return true
    }

    /// No more input: the run ends once it has finished what it's on.
    func close() {
        guard isOpen else { return }
        isOpen = false
        timer?.invalidate()
        timer = nil
        let writer = writer
        queue.async { try? writer.close() }
    }

    /// The run ended: nothing more is read or written.
    func ended() {
        close()
    }

    private func poll() {
        guard isOpen else { return }
        if let new = readNew(), !new.isEmpty {
            lastGrowth = Date()
            // Whole lines only: what's after the last newline waits for the rest of its line.
            let data = partial + new
            if let last = data.lastIndex(of: 0x0A) {
                partial = Data(data[(last + 1)...])
                for line in data[...last].split(separator: 0x0A) where !line.isEmpty {
                    let text = Substring(String(decoding: line, as: UTF8.self))
                    if let said = ClaudeCodeLiveInput.answer(in: text) {
                        answered += 1
                        lastLineWasResult = true
                        answer?(said)
                    } else if text.hasPrefix("{") {
                        lastLineWasResult = false
                    }
                }
            } else {
                partial = data
            }
        }
        if ClaudeCodeLiveInput.closes(sent: sent, answered: answered) {
            close()
        } else if lastLineWasResult, Date().timeIntervalSince(lastGrowth) > Self.quietAfterResult {
            close()
        }
    }

    /// What the log has gained since it was last read.
    private func readNew() -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: log) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size > offset else { return nil }
        try? handle.seek(toOffset: offset)
        let data = try? handle.read(upToCount: Int(min(size - offset, 4 * 1024 * 1024)))
        offset += UInt64(data?.count ?? 0)
        return data
    }
}
