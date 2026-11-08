import AVFoundation
import BindersKit
import os
import SwiftUI

/// One turn of Talk: what you said, or what your hub said back, with the notes and cards it went on.
struct TalkTurn: Identifiable, Equatable {
    enum Who { case you, hub }
    let id = UUID()
    let who: Who
    var text: String
    var sources: [String] = []
    /// Talked over: you cut in before it finished.
    var cut = false
}

extension MacConnection {
    /// The feature a hub lists when it talks (binders/talk): a model to answer with.
    static let talkFeature = "talks"

    /// Whether Talk is there to open: on a hub that talks.
    var talks: Bool { brain == .hub && macFeatures.contains(Self.talkFeature) }
}

/// Talk: a conversation out loud with your hub. It listens on this iPhone (as dictating does), notices when you stop,
/// and sends what you said with the conversation so far (binders/talk). The hub's model answers in a few sentences, and
/// its voice reads them out (binders/speak, a sentence at a time, the next fetched while one plays), or this iPhone's
/// when the hub has none. Then it listens again. Talk over it and it stops and listens: the iPhone's echo cancellation
/// keeps it from hearing itself. Like dictating, it pauses All-day capture while it's on.
@MainActor @Observable
final class TalkSession: Identifiable {
    static let log = Logger(subsystem: "io.binders.app", category: "talk")
    let id = UUID()
    private var name: String { String(id.uuidString.prefix(4)) }

    enum Phase: Equatable {
        case off, starting, listening, thinking, speaking, paused
        case failed(String)
    }

    private(set) var phase: Phase = .off
    private(set) var turns: [TalkTurn] = []
    /// What you're saying now, as it's heard.
    private(set) var heard = ""
    private(set) var level: Double = 0
    /// While it thinks: how many notes and cards it found in your binders, once it says.
    private(set) var found: Int?
    /// What last went wrong, shown under the conversation until the next turn.
    private(set) var problem: String?

    private weak var connection: MacConnection?
    private let audio = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var playFormat: AVAudioFormat?
    private let feed = TalkFeed()
    private let synthesizer = AVSpeechSynthesizer()
    /// The speech engine hearing you now. Counted, so words from one let go of are ignored.
    private var engine: SpeechEngine?
    private var engineCount = 0
    /// Counted too: a reply to a turn you've moved on from (you kept talking, or cut in) is let go of.
    private var turnCount = 0
    /// What you'd said before a pause while it thought, carried on when you kept talking.
    private var carried = ""
    /// Leading words the engine heard that were the hub's own voice coming back, as you cut in: left out.
    private var skipWords = 0
    private var lastText = ""
    private var lastWords = Date.distantPast
    private var firstWords: Date?
    private var watcher: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    /// Clips scheduled and not played yet, and whether the whole reply is scheduled.
    private var playing = 0
    private var allScheduled = false
    /// The reply's words: what you say over it counts only when it isn't them.
    private var replyWords: Set<String> = []

    /// AirPods and other headsets, their microphone too, as a call has (AVAudioSession's allowBluetooth, by its value:
    /// renamed in iOS 26).
    private static let headsets = AVAudioSession.CategoryOptions(rawValue: 0x4)
    /// Words a sentence goes on after: a pause after one isn't the end of what you're saying.
    private static let goesOn: Set<String> = ["and", "but", "so", "or", "because", "then", "um", "uh", "the", "a", "to", "with", "if", "like"]

    init(seed: [TalkTurn] = []) {
        turns = seed
    }

    // MARK: Starting and stopping

    /// The views showing it. iOS can build a full-screen cover's view twice as it shows it, or let go of it and take it
    /// back at once: Talk starts with the first view, once, and stops only when none has shown it for a moment.
    private var viewers = 0
    private var leaving: Task<Void, Never>?
    private var began = false
    private var ended = false

    /// A view shows it: the first starts Talk, and says `firstWords` (typed rather than heard: for development).
    func appeared(with connection: MacConnection, firstWords: String? = nil) async {
        viewers += 1
        leaving?.cancel()
        leaving = nil
        guard !began, !ended else { return }
        began = true
        await start(with: connection)
        if let firstWords, !firstWords.isEmpty { say(firstWords) }
    }

    func disappeared() {
        viewers = max(0, viewers - 1)
        guard viewers == 0 else { return }
        leaving?.cancel()
        leaving = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self, self.viewers == 0 else { return }
            self.end()
        }
    }

    /// Talk over: End, or its screen gone.
    func end() {
        ended = true
        leaving?.cancel()
        leaving = nil
        stop()
    }

    func start(with connection: MacConnection) async {
        Self.log.notice("Talk \(self.name, privacy: .public): start, from \(String(describing: self.phase), privacy: .public)")
        guard phase == .off || isFailed else { return }
        self.connection = connection
        phase = .starting
        problem = nil
        do {
            guard await AVAudioApplication.requestRecordPermission() else { throw DictationError.microphone }
            guard phase == .starting else { return }
            MicrophoneUsers.claim("talk")
            let session = AVAudioSession.sharedInstance()
            // Play and record, as a call does: echo cancellation, the speaker (or AirPods, their microphone too).
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, Self.headsets])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            try startAudio()
            observe()
            // The hub's model and voice get ready while you start talking: one on your machines loads when first asked.
            Task { _ = try? await connection.request("binders/warm", ["talk": true]) }
            phase = .listening
            listenAfresh()
            watch()
        } catch {
            stop()
            phase = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    func stop() {
        Self.log.notice("Talk \(self.name, privacy: .public): stop, from \(String(describing: self.phase), privacy: .public)")
        watcher?.cancel()
        watcher = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        turnCount += 1
        engineCount += 1
        engine?.abandon()
        engine = nil
        feed.drop()
        synthesizer.stopSpeaking(at: .immediate)
        player.stop()
        if audio.isRunning { audio.stop() }
        audio.inputNode.removeTap(onBus: 0)
        try? audio.inputNode.setVoiceProcessingEnabled(false)
        MicrophoneUsers.release("talk")
        if !MicrophoneUsers.captureNeedsSession {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        level = 0
        heard = ""
        phase = .off
    }

    /// The microphone off and nothing said until you resume: what was in flight is let go of.
    func pause() {
        guard phase == .listening || phase == .thinking || phase == .speaking else { return }
        quiet()
        engine?.abandon()
        engine = nil
        engineCount += 1
        feed.drop()
        if audio.isRunning { audio.pause() }
        heard = ""
        carried = ""
        level = 0
        phase = .paused
    }

    func resume() {
        guard phase == .paused else { return }
        problem = nil
        do {
            try audio.start()
            player.play()
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }
        phase = .listening
        listenAfresh()
    }

    /// Something typed instead of said: a turn of its own, over whatever was going on.
    func say(_ text: String) {
        let said = text.trimmingCharacters(in: .whitespacesAndNewlines)
        Self.log.notice("Talk \(self.name, privacy: .public): typed, in \(String(describing: self.phase), privacy: .public)")
        guard !said.isEmpty, phase != .off, phase != .starting else { return }
        if phase == .speaking { cutIn() }
        heard = ""
        carried = ""
        turns.append(TalkTurn(who: .you, text: said))
        send()
        listenAfresh()
    }

    /// The big button: done talking (send it now), stop talking over you, or listen again.
    func tapped() {
        switch phase {
        case .listening: if !heard.trimmingCharacters(in: .whitespaces).isEmpty { endTurn() }
        case .speaking:
            cutIn()
            phase = .listening
            listenAfresh()
        case .paused: resume()
        default: break
        }
    }

    /// The conversation as a note: its title, then each turn.
    func transcript(at date: Date = Date()) -> String {
        let when = date.formatted(.dateTime.day().month(.abbreviated).hour().minute())
        let lines = turns.map { "**\($0.who == .you ? "You" : "Your hub"):** \($0.text)" }
        return (["Talk with your hub, \(when)"] + lines).joined(separator: "\n\n")
    }

    private var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }

    // MARK: Audio

    private func startAudio() throws {
        let input = audio.inputNode
        // Echo cancellation: what this iPhone says isn't heard back as you.
        try input.setVoiceProcessingEnabled(true)
        if !audio.attachedNodes.contains(player) { audio.attach(player) }
        try connectAudio()
        audio.prepare()
        try audio.start()
        player.play()
    }

    /// The player at the output's rate, and the microphone's tap in its format: again after a route change.
    private func connectAudio() throws {
        let rate = audio.outputNode.outputFormat(forBus: 0).sampleRate
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate > 0 ? rate : 48_000, channels: 1) else { throw DictationError.unavailable }
        playFormat = format
        audio.connect(player, to: audio.mainMixerNode, format: format)
        let input = audio.inputNode
        input.removeTap(onBus: 0)
        let heard = input.outputFormat(forBus: 0)
        guard heard.sampleRate > 0, heard.channelCount > 0 else { throw DictationError.microphoneBusy }
        let feed = self.feed
        input.installTap(onBus: 0, bufferSize: 1024, format: heard) { [weak self] buffer, _ in
            feed.append(buffer)
            let loudness = DictationSession.loudness(buffer)
            Task { @MainActor in self?.level = loudness }
        }
    }

    /// A route change (AirPods in or out) stops the engine: it starts again in the new format. A call stops Talk until
    /// you tap to go on.
    private func observe() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: audio, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.audioChanged() }
        })
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let began = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) == AVAudioSession.InterruptionType.began.rawValue
            Task { @MainActor in if began { self?.pause() } }
        })
    }

    private func audioChanged() {
        guard phase == .listening || phase == .thinking || phase == .speaking, !audio.isRunning else { return }
        do {
            try connectAudio()
            try audio.start()
            player.play()
        } catch {
            pause()
            problem = "The audio changed and Talk couldn't go on. Tap to talk again."
        }
    }

    // MARK: Hearing you

    /// A new speech engine for what you say next. The one before is let go of now, so its late words aren't taken for
    /// you going on; the microphone's audio waits for the new one (TalkFeed), so nothing said while it gets ready is lost.
    /// One that won't start pauses Talk and says why.
    private func listenAfresh() {
        engineCount += 1
        let mine = engineCount
        feed.hold()
        engine?.abandon()
        engine = nil
        skipWords = 0
        lastText = ""
        Task {
            do {
                let next = try await DictationSession.makeEngine()
                next.onText = { [weak self] words in self?.heard(words, by: mine) }
                try await next.prepare()
                guard mine == engineCount, phase != .off, phase != .paused else {
                    next.abandon()
                    return
                }
                engine = next
                feed.attach(next)
            } catch {
                guard mine == engineCount, phase != .off else { return }
                pause()
                problem = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private func heard(_ words: String, by mine: Int) {
        guard mine == engineCount else { return }
        let all = Self.words(words)
        let text = Self.dropping(skipWords, from: words)
        switch phase {
        case .listening:
            heard = carried.isEmpty ? text : [carried, text].filter { !$0.isEmpty }.joined(separator: " ")
            if text != lastText, !text.isEmpty {
                lastText = text
                lastWords = Date()
                if firstWords == nil { firstWords = Date() }
            }
        case .thinking:
            // You kept talking: what you said goes on, and the answer to the first part is let go of.
            guard all.count >= 3, let last = turns.last, last.who == .you else { return }
            turns.removeLast()
            turnCount += 1
            carried = last.text
            found = nil
            phase = .listening
            heard = "\(carried) \(text)"
            lastText = text
            lastWords = Date()
            firstWords = Date()
        case .speaking:
            // Talked over: it stops and listens. Its own voice coming back isn't you: only words it isn't saying count,
            // and what you said starts at the first of them.
            guard let first = all.firstIndex(where: { !replyWords.contains($0) }), all[first...].filter({ !replyWords.contains($0) }).count >= 2 else { return }
            cutIn()
            skipWords = first
            phase = .listening
            heard = Self.dropping(first, from: words)
            lastText = heard
            lastWords = Date()
            firstWords = Date()
        default:
            break
        }
    }

    /// Every so often while listening: a long enough pause after what you said ends your turn (longer after "and" or
    /// "so"), as does a minute of talking.
    private func watch() {
        watcher?.cancel()
        watcher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(150))
                guard let self else { return }
                guard self.phase == .listening, !self.heard.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                let wait = Self.goesOn.contains(Self.words(self.heard).last ?? "") ? 2.4 : 1.3
                if Date().timeIntervalSince(self.lastWords) >= wait || Date().timeIntervalSince(self.firstWords ?? Date()) > 60 {
                    self.endTurn()
                }
            }
        }
    }

    private func endTurn() {
        let said = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        guard phase == .listening, !said.isEmpty else { return }
        heard = ""
        carried = ""
        firstWords = nil
        turns.append(TalkTurn(who: .you, text: said))
        send()
        // Listening on while it thinks and speaks: to hear you go on, or cut in.
        listenAfresh()
    }

    // MARK: Its answer

    private func send() {
        guard let connection else { return }
        turnCount += 1
        let turn = turnCount
        Self.log.notice("Talk \(self.name, privacy: .public): turn \(turn) sent, \(self.turns.count) turns")
        phase = .thinking
        found = nil
        problem = nil
        let token = UUID().uuidString
        AskStreams.shared.listen(token) { [weak self] update in
            guard let self, turn == self.turnCount, update.stage == .sources else { return }
            self.found = MacConnection.passages(in: update)?.count
        }
        let history = turns.suffix(12).map { ["role": $0.who == .you ? "user" : "assistant", "text": $0.text] }
        Task {
            defer { AskStreams.shared.stop(token) }
            do {
                let reply = try await connection.request("binders/talk", ["turns": history, "token": token]) as? [String: Any]
                guard turn == turnCount, phase == .thinking else { return }
                guard let words = (reply?["reply"] as? String).map(HubVoice.spoken)?.trimmingCharacters(in: .whitespacesAndNewlines), !words.isEmpty else {
                    throw TalkError(reply == nil ? "\(MacConnection.brainWords.prefix(1).uppercased())\(MacConnection.brainWords.dropFirst()) is out of reach right now." : "Your hub gave no answer.")
                }
                var titles: [String] = []
                for source in reply?["sources"] as? [[String: Any]] ?? [] {
                    if let title = source["title"] as? String, !titles.contains(title) { titles.append(title) }
                }
                turns.append(TalkTurn(who: .hub, text: words, sources: titles))
                speak(words, turn: turn)
            } catch {
                guard turn == turnCount else { return }
                problem = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                if phase == .thinking { phase = .listening }
            }
        }
    }

    private func speak(_ text: String, turn: Int) {
        let sentences = Self.sentences(HubVoice.spoken(text))
        guard !sentences.isEmpty, let format = playFormat else {
            phase = .listening
            return
        }
        phase = .speaking
        replyWords = Set(Self.words(text))
        playing = 0
        allScheduled = false
        let hubVoice = connection?.macFeatures.contains(HubVoice.feature) == true
        Task {
            // Each sentence's audio, the next fetched while this one plays.
            var next: Task<AVAudioPCMBuffer?, Never>? = Task { await self.clip(sentences[0], hub: hubVoice, format: format) }
            for index in sentences.indices {
                let buffer = await next?.value
                guard turn == turnCount, phase == .speaking else { return }
                next = index + 1 < sentences.count ? Task { [sentence = sentences[index + 1]] in await self.clip(sentence, hub: hubVoice, format: format) } : nil
                if let buffer { schedule(buffer, turn: turn) }
            }
            allScheduled = true
            if playing == 0 { doneSpeaking(turn: turn) }
        }
    }

    /// A sentence's audio, in the player's format: the hub's voice, or this iPhone's when the hub has none or it fails.
    private func clip(_ sentence: String, hub: Bool, format: AVAudioFormat) async -> AVAudioPCMBuffer? {
        if hub, let connection,
           let reply = try? await connection.request("binders/speak", ["text": sentence]) as? [String: Any],
           let encoded = reply["audio"] as? String, let data = Data(base64Encoded: encoded) {
            let mime = reply["mime"] as? String ?? ""
            if let buffer = await Task.detached(operation: { TalkAudio.decode(data, mime: mime, to: format) }).value { return buffer }
        }
        return await deviceVoice(sentence, format: format)
    }

    private func deviceVoice(_ sentence: String, format: AVAudioFormat) async -> AVAudioPCMBuffer? {
        let utterance = AVSpeechUtterance(string: sentence)
        utterance.voice = AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())
        let parts = TalkClips()
        return await withCheckedContinuation { continuation in
            parts.whenDone = { buffers in continuation.resume(returning: TalkAudio.convert(buffers, to: format)) }
            synthesizer.write(utterance) { buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                if pcm.frameLength == 0 { parts.finish() } else { parts.add(pcm) }
            }
            // Never left waiting: past ten seconds, what's there is enough.
            Task {
                try? await Task.sleep(for: .seconds(10))
                parts.finish()
            }
        }
    }

    private func schedule(_ buffer: AVAudioPCMBuffer, turn: Int) {
        playing += 1
        if !player.isPlaying { player.play() }
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in self?.played(turn: turn) }
        }
    }

    private func played(turn: Int) {
        guard turn == turnCount else { return }
        playing = max(0, playing - 1)
        if playing == 0, allScheduled { doneSpeaking(turn: turn) }
    }

    private func doneSpeaking(turn: Int) {
        guard turn == turnCount, phase == .speaking else { return }
        phase = .listening
        heard = ""
        // What the engine heard while it spoke may be its own voice coming back: a new one for you.
        listenAfresh()
    }

    /// Stops what it's saying, and lets go of the rest of the reply.
    private func cutIn() {
        quiet()
        if let index = turns.lastIndex(where: { $0.who == .hub }) { turns[index].cut = true }
    }

    private func quiet() {
        turnCount += 1
        synthesizer.stopSpeaking(at: .immediate)
        player.stop()
        playing = 0
        allScheduled = false
    }

    // MARK: Words

    nonisolated static func words(_ text: String) -> [String] {
        text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }

    /// `text` without its first `count` words.
    nonisolated static func dropping(_ count: Int, from text: String) -> String {
        guard count > 0 else { return text.trimmingCharacters(in: .whitespaces) }
        var seen = 0
        var index = text.startIndex
        var inWord = false
        while index < text.endIndex {
            let isWordCharacter = text[index].unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) }
            if isWordCharacter && !inWord {
                if seen == count { break }
                seen += 1
            }
            inWord = isWordCharacter
            index = text.index(after: index)
        }
        return String(text[index...]).trimmingCharacters(in: .whitespaces)
    }

    /// A reply in pieces to read out one by one: its sentences, a short one kept with the next, so none is a word on its
    /// own and the first comes quickly.
    nonisolated static func sentences(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .bySentences) { sentence, _, _, _ in
            guard let sentence = sentence?.trimmingCharacters(in: .whitespacesAndNewlines), !sentence.isEmpty else { return }
            current = current.isEmpty ? sentence : "\(current) \(sentence)"
            if current.count >= 24 {
                out.append(current)
                current = ""
            }
        }
        if !current.isEmpty {
            if let last = out.popLast() { out.append("\(last) \(current)") } else { out.append(current) }
        }
        return out
    }
}

private struct TalkError: LocalizedError {
    let errorDescription: String?
    init(_ words: String) { errorDescription = words }
}

/// The microphone's audio on its way to the speech engine hearing you: held while the next one gets ready (a few seconds'
/// worth at most), then handed over. Used from the audio thread and the main thread, so it locks.
final class TalkFeed: @unchecked Sendable {
    private let lock = NSLock()
    private var engine: SpeechEngine?
    private var holding = false
    private var pending: [AVAudioPCMBuffer] = []
    private var frames: AVAudioFrameCount = 0

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        if let engine { return engine.append(buffer) }
        guard holding, frames < AVAudioFrameCount(buffer.format.sampleRate * 8), let copy = TalkAudio.copy(buffer) else { return }
        pending.append(copy)
        frames += copy.frameLength
    }

    /// The engine let go of: what comes now waits for the next.
    func hold() {
        lock.lock()
        defer { lock.unlock() }
        engine = nil
        holding = true
    }

    func attach(_ next: SpeechEngine) {
        lock.lock()
        defer { lock.unlock() }
        for buffer in pending { next.append(buffer) }
        pending = []
        frames = 0
        engine = next
    }

    /// Nothing kept: paused or stopped.
    func drop() {
        lock.lock()
        defer { lock.unlock() }
        engine = nil
        holding = false
        pending = []
        frames = 0
    }
}

/// This iPhone's voice saying a sentence: its pieces as they come, handed on once, when it's done or out of time.
private final class TalkClips: @unchecked Sendable {
    private let lock = NSLock()
    private var buffers: [AVAudioPCMBuffer] = []
    private var done = false
    var whenDone: (([AVAudioPCMBuffer]) -> Void)?

    func add(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        if !done, let copy = TalkAudio.copy(buffer) { buffers.append(copy) }
    }

    func finish() {
        lock.lock()
        guard !done else { return lock.unlock() }
        done = true
        let all = buffers
        let then = whenDone
        lock.unlock()
        then?(all)
    }
}

/// Audio for Talk: the hub's clips decoded, and anything put in the player's format.
enum TalkAudio {
    /// A clip from the hub (MP3, WAV, M4A, AIFF), in `format`.
    static func decode(_ data: Data, mime: String, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let lower = mime.lowercased()
        let ext = lower.contains("wav") ? "wav" : lower.contains("aiff") ? "aiff" : lower.contains("mp4") || lower.contains("m4a") || lower.contains("aac") ? "m4a" : lower.contains("flac") ? "flac" : lower.contains("caf") ? "caf" : "mp3"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("talk-\(UUID().uuidString).\(ext)")
        defer { try? FileManager.default.removeItem(at: url) }
        guard (try? data.write(to: url)) != nil, let file = try? AVAudioFile(forReading: url),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil else { return nil }
        return convert([buffer], to: format)
    }

    /// Buffers in one format, as one in `format`: resampled and mixed down by one converter, so there's no click
    /// between them.
    static func convert(_ buffers: [AVAudioPCMBuffer], to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let first = buffers.first else { return nil }
        let frames = buffers.reduce(0) { $0 + Int($1.frameLength) }
        guard frames > 0 else { return nil }
        if buffers.count == 1, first.format == format { return first }
        guard let converter = AVAudioConverter(from: first.format, to: format) else { return nil }
        let capacity = AVAudioFrameCount(Double(frames) * format.sampleRate / first.format.sampleRate) + 4096
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var index = 0
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, state in
            guard index < buffers.count else {
                state.pointee = .endOfStream
                return nil
            }
            state.pointee = .haveData
            index += 1
            return buffers[index - 1]
        }
        guard status != .error, out.frameLength > 0 else { return nil }
        return out
    }

    /// A copy: the tap and the synthesizer reuse their buffers.
    static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return nil }
        copy.frameLength = buffer.frameLength
        let channels = Int(buffer.format.channelCount)
        let frames = Int(buffer.frameLength)
        if let source = buffer.floatChannelData, let target = copy.floatChannelData {
            for channel in 0..<channels { target[channel].update(from: source[channel], count: frames) }
        } else if let source = buffer.int16ChannelData, let target = copy.int16ChannelData {
            for channel in 0..<channels { target[channel].update(from: source[channel], count: frames) }
        } else {
            return nil
        }
        return copy
    }
}

// MARK: - The screen

/// Talk's screen: the conversation as it goes, and one big button that shows what Talk is doing (listening, thinking,
/// speaking) and does the obvious thing for it.
struct TalkView: View {
    @Environment(MacConnection.self) private var connection
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Kept by the screen that opened Talk, so however many times iOS builds this view, it's one conversation.
    let talk: TalkSession
    @State private var typing = false
    @State private var typed = ""
    @State private var saved = false
    @FocusState private var typingFocused: Bool
    /// Said first, typed rather than heard: `-talkSay "…"` for development (the Simulator has no microphone).
    private let firstWords = UserDefaults.standard.string(forKey: "talkSay")

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if talk.turns.isEmpty, talk.heard.isEmpty {
                            Text("Talk with your hub out loud. Say what's on your mind and pause: it looks in your binders, answers in its voice, then listens again. Talk over it to cut in.")
                                .font(.footnote).foregroundStyle(Palette.muted)
                        }
                        ForEach(talk.turns) { turn in TalkTurnRow(turn: turn) }
                        if !talk.heard.isEmpty { TalkTurnRow(turn: TalkTurn(who: .you, text: talk.heard), live: true) }
                        if let problem = talk.problem { ProblemLabel(problem) }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding()
                }
                .onChange(of: talk.turns.count) { _, _ in withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { proxy.scrollTo("end", anchor: .bottom) } }
                .onChange(of: talk.heard) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
            }
            .screenGround()
            .safeAreaInset(edge: .bottom) { controls }
            .navigationTitle("Talk")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("End") {
                        talk.end()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(action: save) { Label(saved ? "Saved" : "Save as Note", systemImage: saved ? "checkmark" : "note.text.badge.plus") }
                        .disabled(talk.turns.isEmpty || saved)
                        .accessibilityIdentifier("talkSave")
                }
            }
        }
        .task { await talk.appeared(with: connection, firstWords: firstWords) }
        .onDisappear { talk.disappeared() }
    }

    private var controls: some View {
        VStack(spacing: 10) {
            if typing {
                HStack {
                    TextField("Type instead", text: $typed, axis: .vertical)
                        .lineLimit(1...3)
                        .focused($typingFocused)
                        .submitLabel(.send)
                        .onSubmit(sendTyped)
                    Button(action: sendTyped) { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                        .disabled(typed.trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityLabel("Send")
                }
                .surfaceCard(padding: 10)
            }
            HStack(alignment: .center) {
                Button {
                    typing.toggle()
                    typingFocused = typing
                } label: { Image(systemName: typing ? "keyboard.chevron.compact.down" : "keyboard").font(.title3) }
                    .frame(width: 44, height: 44)
                    .accessibilityLabel(typing ? "Hide the keyboard" : "Type instead")
                Spacer()
                Button { talk.tapped() } label: { orb }
                    .buttonStyle(.plain)
                    .accessibilityLabel(orbLabel)
                    .accessibilityIdentifier("talkOrb")
                Spacer()
                Button { talk.phase == .paused ? talk.resume() : talk.pause() } label: {
                    Image(systemName: talk.phase == .paused ? "mic" : "mic.slash").font(.title3)
                }
                .frame(width: 44, height: 44)
                .disabled(talk.phase == .off || talk.phase == .starting || isFailed)
                .accessibilityLabel(talk.phase == .paused ? "Listen again" : "Pause")
            }
            .foregroundStyle(Palette.ink)
            Text(status)
                .font(.footnote).foregroundStyle(Palette.muted)
                .multilineTextAlignment(.center)
                .contentTransition(.opacity)
                .animation(.easeInOut(duration: 0.2), value: status)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    @ViewBuilder
    private var orb: some View {
        let listening = talk.phase == .listening
        ZStack {
            Circle()
                .fill(listening ? Palette.live.opacity(0.14) : Palette.accent.opacity(0.14))
                .scaleEffect(listening && !reduceMotion ? 1 + 0.3 * talk.level : 1)
                .animation(.easeOut(duration: 0.1), value: talk.level)
            Circle().strokeBorder(listening ? Palette.live : Palette.accent, lineWidth: 2)
            switch talk.phase {
            case .starting, .thinking:
                ProgressView().controlSize(.large).tint(Palette.accentText)
            case .listening:
                // Red while the microphone is live, as everywhere else.
                Image(systemName: "mic.fill").font(.system(size: 30, weight: .semibold)).foregroundStyle(Palette.live)
            case .speaking:
                Image(systemName: "waveform").font(.system(size: 30, weight: .semibold)).foregroundStyle(Palette.accentText)
                    .symbolEffect(.variableColor.iterative, options: .repeating, isActive: !reduceMotion)
            case .paused, .off:
                Image(systemName: "mic.slash").font(.system(size: 28, weight: .semibold)).foregroundStyle(Palette.muted)
            case .failed:
                Image(systemName: Problem.symbol).font(.system(size: 28, weight: .semibold)).foregroundStyle(Palette.muted)
            }
        }
        .frame(width: 84, height: 84)
        .contentShape(Circle())
    }

    private var isFailed: Bool {
        if case .failed = talk.phase { return true }
        return false
    }

    private var status: String {
        switch talk.phase {
        case .off: "Ended"
        case .starting: "Getting ready…"
        case .listening: talk.heard.isEmpty ? "Listening" : "Listening · pause when you're done, or tap"
        case .thinking:
            if let found = talk.found { found > 0 ? "Found \(found) in your binders · thinking" : "Thinking" } else { "Looking in your binders…" }
        case .speaking: "Talk to cut in, or tap to stop"
        case .paused: "Paused · tap to talk"
        case .failed(let why): why
        }
    }

    private var orbLabel: String {
        switch talk.phase {
        case .listening: talk.heard.isEmpty ? "Listening" : "Done talking"
        case .speaking: "Stop talking"
        case .paused: "Listen again"
        case .thinking: "Thinking"
        default: "Talk"
        }
    }

    private func sendTyped() {
        let text = typed
        typed = ""
        talk.say(text)
    }

    private func save() {
        let text = talk.transcript()
        Task {
            await connection.save("add_note", text: text, binder: nil)
            saved = true
        }
    }
}

private struct TalkTurnRow: View {
    let turn: TalkTurn
    /// What you're saying now, still being heard.
    var live = false

    var body: some View {
        let yours = turn.who == .you
        VStack(alignment: yours ? .trailing : .leading, spacing: 4) {
            Text(yours ? "You" : "Your hub").font(.caption.weight(.semibold)).foregroundStyle(Palette.faint)
            if yours {
                // Your words, quoted as said.
                Text(turn.text).font(Typeface.quote(.body)).foregroundStyle(live ? Palette.muted : Palette.ink)
                    .multilineTextAlignment(.trailing)
            } else {
                Text(turn.text).font(.body).foregroundStyle(Palette.ink).surfaceCard(padding: 12)
            }
            if !turn.sources.isEmpty {
                Text("From \(turn.sources.prefix(3).joined(separator: " · "))").font(.caption).foregroundStyle(Palette.muted)
            }
            if turn.cut { Text("You cut in").font(.caption2).foregroundStyle(Palette.faint) }
        }
        .frame(maxWidth: .infinity, alignment: yours ? .trailing : .leading)
        .textSelection(.enabled)
        .accessibilityElement(children: .combine)
    }
}

/// Talk, from a toolbar: shown when the hub talks. It opens a new conversation, kept by the screen it's on.
struct TalkButton: View {
    @Environment(MacConnection.self) private var connection
    @Binding var talk: TalkSession?

    var body: some View {
        if connection.talks {
            Button { talk = TalkSession() } label: { Image(systemName: "waveform.circle") }
                .accessibilityLabel("Talk with your hub")
                .accessibilityIdentifier("talkOpen")
        }
    }
}
