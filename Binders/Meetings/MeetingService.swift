import AppKit
import AVFoundation
import FluidAudio
import Observation
import SwiftData
import UniformTypeIdentifiers
import BindersKit

/// Streams one meeting audio channel to disk and hands out transcription chunks at natural pauses.
final class MeetingChannel: @unchecked Sendable {
    let channel: AudioChannel
    let fileURL: URL

    private static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private let lock = NSLock()
    private var pending: [Float] = []
    /// Samples of `pending` already handed out; compacted in bulk to avoid copying on every chunk.
    private var consumed = 0
    /// Absolute sample index of `pending[0]`.
    private var pendingStart = 0
    private var totalSamples = 0
    private var muted = false
    private var heardAnything = false
    private var lastSpeech = Date()
    private var lastRealAudio = Date()
    private var file: AVAudioFile?
    private let writer = DispatchQueue(label: "io.binders.mac.meeting-writer", qos: .utility)

    init(channel: AudioChannel, fileURL: URL) throws {
        self.channel = channel
        self.fileURL = fileURL
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ]
        file = try AVAudioFile(forWriting: fileURL, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    /// While muted (the user is dictating elsewhere) silence is recorded so both channels stay aligned.
    var isMuted: Bool {
        get { lock.withLock { muted } }
        set {
            lock.withLock {
                muted = newValue
                if !newValue { lastRealAudio = Date() }
            }
        }
    }

    var duration: TimeInterval { lock.withLock { Double(totalSamples) / 16_000 } }
    /// False while capture has delivered nothing but exact zeros (a denied permission, not a quiet room).
    var hasReceivedAudio: Bool { lock.withLock { heardAnything } }
    var secondsSinceSpeech: TimeInterval { lock.withLock { Date().timeIntervalSince(lastSpeech) } }
    /// Seconds since capture delivered anything but exact zeros: padding and a dead device are zeros, a live mic never is.
    var secondsSinceRealAudio: TimeInterval { lock.withLock { Date().timeIntervalSince(lastRealAudio) } }

    func append(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        let hasSpeech = AudioMath.decibels(AudioMath.rms(samples)) > -48
        let data: [Float] = lock.withLock {
            let data = muted ? [Float](repeating: 0, count: samples.count) : samples
            pending.append(contentsOf: data)
            totalSamples += data.count
            if hasSpeech, !muted { lastSpeech = Date() }
            if !muted, samples.contains(where: { $0 != 0 }) {
                heardAnything = true
                lastRealAudio = Date()
            }
            return data
        }
        writer.async { [weak self] in self?.write(data) }
    }

    /// Inserts silence when capture fell behind the wall clock (device switch, stalled tap) so channels stay aligned.
    func padToElapsed(_ elapsed: TimeInterval) {
        let missing = Int(elapsed * 16_000) - lock.withLock { totalSamples }
        guard missing > 8_000 else { return }
        append([Float](repeating: 0, count: missing))
    }

    func nextChunk(isFinal: Bool) -> (start: TimeInterval, samples: [Float])? {
        lock.withLock {
            let available = pending[consumed...]
            guard !available.isEmpty, let length = SpeechChunker.nextBoundary(available, isFinal: isFinal), length > 0 else { return nil }
            let chunk = Array(available.prefix(length))
            let start = Double(pendingStart + consumed) / 16_000
            consumed += length
            if consumed >= 60 * 16_000 {
                pending.removeFirst(consumed)
                pendingStart += consumed
                consumed = 0
            }
            return (start, chunk)
        }
    }

    /// Flushes and closes the WAV file.
    func finish() {
        writer.sync { file = nil }
    }

    private func write(_ samples: [Float]) {
        guard let file, let buffer = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            buffer.floatChannelData![0].update(from: source.baseAddress!, count: samples.count)
        }
        try? file.write(from: buffer)
    }
}

/// Reads time ranges from a recording without loading the whole file.
final class ChannelAudioReader {
    private let file: AVAudioFile
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    init(url: URL) throws {
        file = try AVAudioFile(forReading: url)
    }

    var duration: TimeInterval { Double(file.length) / file.processingFormat.sampleRate }

    func samples(from start: TimeInterval, to end: TimeInterval) throws -> [Float] {
        let format = file.processingFormat
        let startFrame = AVAudioFramePosition(max(0, start) * format.sampleRate)
        guard startFrame < file.length, end > start else { return [] }
        let frames = AVAudioFrameCount(min(Double(file.length - startFrame), (end - max(0, start)) * format.sampleRate))
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return [] }
        file.framePosition = startFrame
        try file.read(into: buffer, frameCount: frames)
        if format.sampleRate == 16_000, format.channelCount == 1, format.commonFormat == .pcmFormatFloat32, let data = buffer.floatChannelData {
            return Array(UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)))
        }
        guard let converter = AVAudioConverter(from: format, to: target) else { throw RecorderError.converterUnavailable }
        converter.downmix = true
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * 16_000 / format.sampleRate + 1024)
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return [] }
        var delivered = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if delivered {
                status.pointee = .endOfStream
                return nil
            }
            delivered = true
            status.pointee = .haveData
            return buffer
        }
        if let error { throw error }
        return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
    }
}

@MainActor
private final class LiveMeeting {
    let record: MeetingRecord
    let mic: MeetingChannel
    let system: MeetingChannel
    let micCapture = AudioRecorder()
    let systemCapture = SystemAudioCapture()
    let startedAt = Date()
    var sourceBundleID: String?
    var lastSourceActiveAt = Date()
    var warnedSilentSystem = false
    var warnedSilentMic = false
    var micRestarts = 0
    var lastMicRestart = Date.distantPast
    var warnedMicDropped = false
    var loop: Task<Void, Never>?

    init(record: MeetingRecord, mic: MeetingChannel, system: MeetingChannel) {
        self.record = record
        self.mic = mic
        self.system = system
    }
}

/// Bot-free meeting notes: records mic + system audio, transcribes live, labels speakers and writes notes afterwards.
@MainActor
@Observable
final class MeetingService {
    static let placeholderPrefix = "Meeting · "

    private(set) var recordingMeetingID: UUID?
    private(set) var liveSegments: [TranscriptSegment] = []
    private(set) var liveStartedAt: Date?
    private(set) var systemAudioIssue: String?
    private(set) var busyMeetingIDs: Set<UUID> = []
    private(set) var chattingMeetingIDs: Set<UUID> = []
    /// What is happening to a meeting right now ("Taking notes on part 2 of 6…"), or how the last thing that happened ended.
    private(set) var activity: [UUID: String] = [:]

    @ObservationIgnored private let speech: SpeechService
    @ObservationIgnored private let flowBar: FlowBarController
    @ObservationIgnored private var live: LiveMeeting?
    @ObservationIgnored private var isStarting = false
    @ObservationIgnored private var detectionTimer: Timer?
    @ObservationIgnored private var promptedAt: [String: Date] = [:]
    @ObservationIgnored private var diarizer: OfflineDiarizerManager?
    @ObservationIgnored private var draining = false

    private var settings: AppSettings { AppSettings.shared }

    init(speech: SpeechService, flowBar: FlowBarController) {
        self.speech = speech
        self.flowBar = flowBar
        flowBar.onOpenMeeting = { [weak self] in self?.showLiveWindow(activate: true) }
        flowBar.onStopMeeting = { [weak self] in Task { await self?.stop() } }
    }

    var isRecording: Bool { recordingMeetingID != nil }

    func startMonitoring() {
        detectionTimer?.invalidate()
        detectionTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        recoverInterruptedMeetings()
    }

    func toggle() async {
        if isRecording { await stop() } else { await start() }
    }

    /// Mutes the meeting mic while the user dictates, so dictation doesn't end up in the transcript.
    func setDictationActive(_ active: Bool) {
        live?.mic.isMuted = active
    }

    // MARK: Recording

    func start(detected: (bundleID: String, name: String)? = nil) async {
        guard live == nil, !isStarting else {
            if live != nil { showLiveWindow(activate: true) }
            return
        }
        // Permission prompts suspend; don't let a second hotkey press or prompt start another session meanwhile.
        isStarting = true
        defer { isStarting = false }

        switch Permissions.microphone {
        case .authorized: break
        case .notDetermined:
            guard await Permissions.requestMicrophone() else { return }
        default:
            flowBar.toast("Microphone access is off — enable it in Settings", symbol: "mic.slash")
            return
        }
        if !settings.recordingNoticeAcknowledged {
            // Recording other people needs their consent in many places; say so once, before the first recording.
            guard RecordingNotice.confirm() else { return }
            settings.recordingNoticeAcknowledged = true
        }
        if settings.meetingUseCalendar, !CalendarContext.isAuthorized {
            _ = await CalendarContext.requestAccess()
        }
        guard live == nil else { return }

        let source = detected ?? MeetingDetector.meetingApp(capturingInput: AudioProcesses.bundleIDsCapturingInput())
        let event = settings.meetingUseCalendar ? CalendarContext.event(at: Date()) : nil
        let placeholder = Self.placeholderPrefix + Date().formatted(date: .abbreviated, time: .shortened)
        let title = event.map(\.title).flatMap { $0.trimmed.isEmpty ? nil : $0 } ?? placeholder
        let record = MeetingRecord(title: title, appName: source?.name, templateID: settings.meetingTemplateID)
        record.attendees = event?.attendees ?? []
        let binder = Store.shared.binder(settings.currentBinderID) ?? Store.shared.defaultBinder()
        record.binderID = binder.id
        record.sharedWithTeam = binder.sharedWithTeam
        let micName = "\(record.id.uuidString)-mic.wav"
        let systemName = "\(record.id.uuidString)-system.wav"
        let micURL = AppPaths.meetings.appendingPathComponent(micName)
        let systemURL = AppPaths.meetings.appendingPathComponent(systemName)

        do {
            let mic = try MeetingChannel(channel: .microphone, fileURL: micURL)
            let system = try MeetingChannel(channel: .system, fileURL: systemURL)
            let session = LiveMeeting(record: record, mic: mic, system: system)
            // Browsers use the mic for many things, so only native call apps can end a recording on their own.
            session.sourceBundleID = source.flatMap { MeetingDetector.browsers[$0.bundleID] == nil ? $0.bundleID : nil }

            session.micCapture.retainsSamples = false
            session.micCapture.onSamples = { [mic] samples in mic.append(samples) }
            try session.micCapture.start(deviceUID: settings.microphoneUID)

            session.systemCapture.onSamples = { [system] samples in system.append(samples) }
            do {
                try session.systemCapture.start()
                systemAudioIssue = nil
            } catch {
                systemAudioIssue = error.localizedDescription
                Log.meeting.error("System audio unavailable: \(error.localizedDescription)")
            }

            record.micAudioFile = micName
            record.systemAudioFile = systemName
            Store.shared.insert(record)
            live = session
            recordingMeetingID = record.id
            liveSegments = []
            liveStartedAt = session.startedAt
            flowBar.meetingStarted(at: session.startedAt)
            if settings.playSounds { Sounds.start() }
            if systemAudioIssue != nil {
                flowBar.toast("Recording your mic only — allow System Audio Recording for the other side", symbol: "exclamationmark.triangle", duration: 6)
            }
            session.loop = Task { [weak self] in await self?.runLoop(session) }
            showLiveWindow(activate: false)
            Log.meeting.info("Meeting recording started (\(source?.name ?? "manual"))")
        } catch {
            try? FileManager.default.removeItem(at: micURL)
            try? FileManager.default.removeItem(at: systemURL)
            Sounds.error()
            flowBar.toast("Couldn't start meeting notes: \(error.localizedDescription)", symbol: "exclamationmark.triangle")
        }
    }

    func stop(reason: String? = nil) async {
        guard let session = live else { return }
        live = nil
        recordingMeetingID = nil
        liveStartedAt = nil
        _ = session.micCapture.stop()
        session.systemCapture.stop()
        flowBar.meetingEnded()
        MeetingWindowController.shared.close()
        if settings.playSounds { Sounds.stop() }
        flowBar.toast("\(reason ?? "Meeting saved") — writing notes…", symbol: "note.text", duration: 4)

        let record = session.record
        record.endedAt = Date()
        record.duration = max(session.mic.duration, session.system.duration)
        record.status = "processing"
        Store.shared.save()
        busyMeetingIDs.insert(record.id)

        // Let an in-flight live drain finish its chunk rather than cancelling it and losing audio.
        await session.loop?.value
        await drain(session, isFinal: true, waitForModel: true)
        session.mic.finish()
        session.system.finish()
        await finalize(record, micURL: session.mic.fileURL, systemURL: session.system.fileURL)
        busyMeetingIDs.remove(record.id)
    }

    /// On quit: save what was recorded; the notes are finished on the next launch.
    func prepareForTermination() async {
        guard let session = live else { return }
        live = nil
        recordingMeetingID = nil
        liveStartedAt = nil
        _ = session.micCapture.stop()
        session.systemCapture.stop()
        await session.loop?.value
        await drain(session, isFinal: true, waitForModel: false)
        session.mic.finish()
        session.system.finish()
        session.record.endedAt = Date()
        session.record.duration = max(session.mic.duration, session.system.duration)
        session.record.status = "processing"
        Store.shared.save()
    }

    func showLiveWindow(activate: Bool) {
        guard let session = live else { return }
        MeetingWindowController.shared.show(service: self, meeting: session.record, activate: activate)
    }

    private func runLoop(_ session: LiveMeeting) async {
        while live === session {
            try? await Task.sleep(for: .seconds(1.5))
            guard live === session else { return }
            let elapsed = Date().timeIntervalSince(session.startedAt)
            session.mic.padToElapsed(elapsed)
            if session.systemCapture.isRunning { session.system.padToElapsed(elapsed) }
            watchMic(session, elapsed: elapsed)
            await drain(session, isFinal: false, waitForModel: false)
            guard live === session else { return }
            warnIfSilent(session, elapsed: elapsed)
            if let reason = autoStopReason(session) {
                // stop() waits for this loop to finish, so it has to run in its own task.
                Task { [weak self] in await self?.stop(reason: reason) }
                return
            }
        }
    }

    private func drain(_ session: LiveMeeting, isFinal: Bool, waitForModel: Bool) async {
        if draining {
            guard isFinal else { return }
            while draining { try? await Task.sleep(for: .milliseconds(50)) }
        }
        draining = true
        defer { draining = false }

        let engine: (any SpeechEngine)?
        if waitForModel {
            engine = try? await speech.waitUntilReady()
        } else {
            engine = speech.readyEngine
        }
        guard let engine else { return }
        let vocabulary = Store.shared.vocabulary()
        for channel in [session.mic, session.system] {
            while let chunk = channel.nextChunk(isFinal: isFinal) {
                guard !AudioMath.isSilent(chunk.samples) else { continue }
                let text = (try? await engine.transcribe(AudioMath.normalize(chunk.samples), language: settings.languageHint,
                                                         vocabulary: vocabulary, boost: settings.vocabularyBoost)) ?? ""
                guard !text.isEmpty else { continue }
                guard exists(session.record) else { return }
                let segment = TranscriptSegment(channel: channel.channel, start: chunk.start,
                                                end: chunk.start + Double(chunk.samples.count) / 16_000, text: text)
                Store.shared.appendSegment(segment, to: session.record.id)
                if recordingMeetingID == session.record.id { liveSegments.append(segment) }
            }
        }
    }

    /// A mic that only delivers exact zeros has died (a device switch, a stalled engine, a hardware mute): restart capture
    /// instead of recording silence for the rest of the call.
    private func watchMic(_ session: LiveMeeting, elapsed: TimeInterval) {
        guard elapsed > 20, !session.mic.isMuted, session.mic.secondsSinceRealAudio > 15 else { return }
        // Back off once restarts stop helping (a mute button on the device, say).
        let interval: TimeInterval = session.micRestarts < 3 ? 15 : 120
        guard Date().timeIntervalSince(session.lastMicRestart) >= interval else { return }
        session.lastMicRestart = Date()
        session.micRestarts += 1
        Log.meeting.warning("Mic delivered only silence for \(Int(session.mic.secondsSinceRealAudio)) s; restarting capture (\(session.micRestarts))")
        do {
            try session.micCapture.restart()
        } catch {
            Log.meeting.error("Mic restart failed: \(error.localizedDescription)")
        }
        if !session.warnedMicDropped, session.micRestarts >= 2 {
            session.warnedMicDropped = true
            flowBar.toast("Your mic went silent — restarted capture; check the input device", symbol: "mic.slash", duration: 6)
        }
    }

    /// Surfaces permission problems during the call instead of producing an empty meeting afterwards.
    private func warnIfSilent(_ session: LiveMeeting, elapsed: TimeInterval) {
        guard elapsed > 12 else { return }
        if !session.warnedSilentSystem, session.systemCapture.isRunning, !session.system.hasReceivedAudio, AudioProcesses.isOutputPlaying() {
            session.warnedSilentSystem = true
            systemAudioIssue = "Audio is playing but Binders hears silence. Allow Binders under Screen & System Audio Recording, then start the meeting again."
            flowBar.toast("Not hearing the other side — allow System Audio Recording", symbol: "speaker.slash", duration: 6)
            showLiveWindow(activate: false)
        }
        if !session.warnedSilentMic, !session.mic.hasReceivedAudio {
            session.warnedSilentMic = true
            flowBar.toast("Your microphone is sending silence — check Microphone access in Settings", symbol: "mic.slash", duration: 6)
        }
    }

    private func autoStopReason(_ session: LiveMeeting) -> String? {
        let elapsed = Date().timeIntervalSince(session.startedAt)
        if elapsed >= Double(settings.meetingMaxHours) * 3600 {
            return "Reached the \(settings.meetingMaxHours)-hour limit"
        }
        let minutes = settings.meetingAutoStopMinutes
        if minutes > 0, min(session.mic.secondsSinceSpeech, session.system.secondsSinceSpeech) >= Double(minutes) * 60 {
            return "Stopped after \(minutes) minutes of silence"
        }
        return nil
    }

    /// Offers to take notes when a call app starts using the mic; stops when the call is clearly over.
    private func tick() {
        if let session = live {
            guard let source = session.sourceBundleID else { return }
            let capturing = AudioProcesses.bundleIDsCapturingInput()
            // Muted participants may release the mic, so the other side must also have gone quiet.
            if capturing.contains(where: { $0 == source || $0.hasPrefix(source + ".") }) || session.system.secondsSinceSpeech < 30 {
                session.lastSourceActiveAt = Date()
            } else if Date().timeIntervalSince(session.lastSourceActiveAt) > 60 {
                Task { [weak self] in await self?.stop(reason: "Call ended") }
            }
            return
        }
        guard settings.meetingDetection, !isStarting,
              let app = MeetingDetector.meetingApp(capturingInput: AudioProcesses.bundleIDsCapturingInput()) else { return }
        if let last = promptedAt[app.bundleID], Date().timeIntervalSince(last) < 30 * 60 { return }
        promptedAt[app.bundleID] = Date()
        flowBar.showPrompt("\(app.name) is using your mic") { [weak self] in
            Task { await self?.start(detected: app) }
        }
    }

    /// Finishes meetings left recording or half-processed by a quit or crash.
    private func recoverInterruptedMeetings() {
        let descriptor = FetchDescriptor<MeetingRecord>(predicate: #Predicate { $0.status == "recording" || $0.status == "processing" })
        let stuck = (try? Store.shared.context.fetch(descriptor)) ?? []
        guard !stuck.isEmpty else { return }
        Task {
            for record in stuck where record.id != recordingMeetingID && !busyMeetingIDs.contains(record.id) {
                let micURL = record.micAudioFile.map { AppPaths.meetings.appendingPathComponent($0) }
                let systemURL = record.systemAudioFile.map { AppPaths.meetings.appendingPathComponent($0) }
                if record.duration == 0 {
                    record.duration = [micURL, systemURL].compactMap { $0 }.compactMap { try? ChannelAudioReader(url: $0).duration }.max() ?? 0
                }
                record.status = "processing"
                Log.meeting.info("Recovering interrupted meeting \(record.id)")
                await finalize(record, micURL: micURL, systemURL: systemURL)
            }
        }
    }

    // MARK: Post-processing

    private func exists(_ record: MeetingRecord) -> Bool {
        record.modelContext != nil && !record.isDeleted
    }

    func finalize(_ record: MeetingRecord, micURL: URL?, systemURL: URL?) async {
        let meetingID = record.id
        busyMeetingIDs.insert(meetingID)
        defer { busyMeetingIDs.remove(meetingID) }

        var segments = Store.shared.segments(for: meetingID)
        var wordCount = segments.reduce(0) { $0 + $1.text.wordCount }
        if wordCount == 0 {
            // Nothing arrived live (model still loading, a storage hiccup): transcribe the saved audio before giving up.
            segments = await transcribeRecordings(micURL: micURL, systemURL: systemURL)
            wordCount = segments.reduce(0) { $0 + $1.text.wordCount }
            if wordCount > 0, exists(record) { Store.shared.replaceSegments(for: meetingID, with: segments) }
        }
        guard exists(record) else { return }
        if wordCount == 0, record.userNotes.trimmed.isEmpty {
            flowBar.toast("No speech was recorded — meeting discarded", symbol: "trash")
            Store.shared.deleteMeeting(record)
            return
        }

        segments = EchoFilter.removeEcho(from: segments)
        let hasSystemSpeech = segments.contains { $0.channel == .system }
        let diarizedChannel: AudioChannel = hasSystemSpeech ? .system : .microphone
        if let url = hasSystemSpeech ? systemURL : micURL, FileManager.default.fileExists(atPath: url.path), !segments.isEmpty,
           let turns = await diarize(url), !turns.isEmpty {
            // Live chunks can span two voices; re-transcribing each diarized turn lines text up with speakers.
            let refined = await refine(channel: diarizedChannel, url: url, turns: turns)
            if refined.isEmpty {
                segments = SpeakerAssigner.assign(segments, turns: turns, channel: diarizedChannel)
            } else {
                segments = EchoFilter.removeEcho(from: (segments.filter { $0.channel != diarizedChannel } + refined)
                    .sorted { $0.start < $1.start })
            }
        }
        guard exists(record) else { return }
        Store.shared.replaceSegments(for: meetingID, with: segments)

        if wordCount >= 20 {
            await summarize(record, segments: segments, markBusy: false)
        }
        guard exists(record) else { return }
        if let micURL, let silentFrom = await Self.micSilentFrom(micURL, duration: record.duration) {
            Log.meeting.warning("Mic track is digital silence from \(Int(silentFrom)) s to the end")
            record.errorMessage = "Your mic went silent at \(TranscriptFormatter.timestamp(silentFrom)) and stayed silent, so the notes only have the other side. If something else recorded you, use ⋯ → Replace My Mic Track…"
        }
        record.status = "ready"
        if !settings.meetingKeepAudio {
            record.audioURLs.forEach { try? FileManager.default.removeItem(at: $0) }
            record.micAudioFile = nil
            record.systemAudioFile = nil
        }
        Store.shared.save()
        if let error = record.errorMessage {
            flowBar.toast(error, symbol: "exclamationmark.triangle", duration: 5)
        } else {
            flowBar.toast("Notes ready: \(record.title)", symbol: "checkmark.circle", duration: 4)
        }
    }

    /// Transcribes both recordings from disk in 30-second windows split at pauses.
    private func transcribeRecordings(micURL: URL?, systemURL: URL?) async -> [TranscriptSegment] {
        guard let engine = try? await speech.waitUntilReady() else { return [] }
        let vocabulary = Store.shared.vocabulary()
        var segments: [TranscriptSegment] = []
        for (channel, url) in [(AudioChannel.microphone, micURL), (AudioChannel.system, systemURL)] {
            guard let url, let reader = try? ChannelAudioReader(url: url) else { continue }
            var position: TimeInterval = 0
            while position < reader.duration {
                guard let window = try? reader.samples(from: position, to: min(reader.duration, position + 30)), !window.isEmpty else { break }
                let length = max(1, SpeechChunker.nextBoundary(window[...], isFinal: true) ?? window.count)
                let chunk = Array(window.prefix(length))
                if !AudioMath.isSilent(chunk),
                   let text = try? await engine.transcribe(AudioMath.normalize(chunk), language: settings.languageHint,
                                                           vocabulary: vocabulary, boost: settings.vocabularyBoost),
                   !text.isEmpty {
                    segments.append(TranscriptSegment(channel: channel, start: position,
                                                      end: position + Double(chunk.count) / 16_000, text: text))
                }
                position += Double(length) / 16_000
            }
        }
        Log.meeting.info("Recovered \(segments.count) segments from saved audio")
        return segments.sorted { $0.start < $1.start }
    }

    /// Re-transcribes each merged speaker turn so every segment belongs to exactly one speaker.
    private func refine(channel: AudioChannel, url: URL, turns: [SpeakerTurn]) async -> [TranscriptSegment] {
        guard let engine = try? await speech.waitUntilReady(), let reader = try? ChannelAudioReader(url: url) else { return [] }
        let merged = SpeakerTurns.merge(turns)
        let labels = SpeakerTurns.labels(for: merged)
        let vocabulary = Store.shared.vocabulary()
        var refined: [TranscriptSegment] = []
        for turn in merged {
            let start = max(0, turn.start - 0.15)
            // Read only this turn from disk; whole multi-hour recordings never sit in memory.
            guard let turnSamples = try? reader.samples(from: start, to: turn.end + 0.15), turnSamples.count > 8_000 else { continue }
            let firstSample = Int(start * 16_000)
            var offset = 0
            while offset < turnSamples.count {
                let slice = turnSamples[offset...]
                // Long monologues are split at pauses to keep chunks model-friendly.
                let length = slice.count > 30 * 16_000 ? max(1, SpeechChunker.nextBoundary(slice, isFinal: true) ?? slice.count) : slice.count
                let chunk = Array(slice.prefix(length))
                if !AudioMath.isSilent(chunk),
                   let text = try? await engine.transcribe(AudioMath.normalize(chunk), language: settings.languageHint,
                                                           vocabulary: vocabulary, boost: settings.vocabularyBoost),
                   !text.isEmpty {
                    let segmentStart = Double(firstSample + offset) / 16_000
                    refined.append(TranscriptSegment(channel: channel, start: segmentStart,
                                                     end: segmentStart + Double(chunk.count) / 16_000,
                                                     text: text, speaker: labels[turn.speakerID]))
                }
                offset += length
            }
        }
        return refined
    }

    private func diarize(_ url: URL) async -> [SpeakerTurn]? {
        do {
            if diarizer == nil {
                let manager = OfflineDiarizerManager()
                try await manager.prepareModels()
                diarizer = manager
            }
            guard let diarizer else { return nil }
            let result = try await diarizer.process(url)
            return result.segments.map {
                SpeakerTurn(speakerID: $0.speakerId, start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds))
            }
        } catch {
            Log.meeting.error("Speaker diarization failed: \(error.localizedDescription)")
            return nil
        }
    }

    func summarize(_ record: MeetingRecord, segments: [TranscriptSegment]? = nil, templateID: String? = nil, markBusy: Bool = true) async {
        guard let client = settings.makeLLMClient() else {
            record.errorMessage = "Choose a language model in Settings to write meeting notes"
            Store.shared.save()
            return
        }
        let meetingID = record.id
        if markBusy { busyMeetingIDs.insert(meetingID) }
        defer { if markBusy { busyMeetingIDs.remove(meetingID) } }

        let template = MeetingTemplate.template(id: templateID ?? record.templateID)
        record.templateID = template.id
        let segments = segments ?? Store.shared.segments(for: meetingID)
        var names = record.speakerNames
        let stopWhenLooping: @Sendable (String) -> Bool = { LoopGuard.isLooping($0) }
        do {
            // Put names on generic speaker labels first, so the notes and their action items get real owners.
            let unnamed = Set(segments.map(\.speaker)).subtracting([TranscriptSegment.you, TranscriptSegment.others])
                .filter { (names[$0] ?? "").trimmed.isEmpty }
            if !unnamed.isEmpty {
                activity[meetingID] = "Working out who's who…"
                let prompt = MeetingPrompts.speakerUserPrompt(attendees: record.attendees, userNotes: record.userNotes,
                                                              transcript: TranscriptFormatter.plainText(segments, names: names))
                if let output = try? await client.complete(system: MeetingPrompts.speakerSystemPrompt(), user: prompt,
                                                           maxTokens: 80, temperature: 0.1, timeout: 300) {
                    for (label, name) in SummaryParser.speakerNames(in: output) where unnamed.contains(label) { names[label] = name }
                }
                guard exists(record) else { return }
            }
            let transcript = TranscriptFormatter.plainText(segments, names: names)

            // Long calls get raw notes per part first: the final pass then has a checklist and can't lose the middle.
            var partNotes: [String] = []
            let parts = TranscriptFormatter.parts(segments)
            if parts.count > 1 {
                for (index, part) in parts.enumerated() {
                    activity[meetingID] = "Taking notes on part \(index + 1) of \(parts.count)…"
                    let user = MeetingPrompts.partNotesUserPrompt(index: index + 1, count: parts.count,
                                                                  transcript: TranscriptFormatter.plainText(part, names: names))
                    let output = try await client.stream(system: MeetingPrompts.partNotesSystemPrompt(), user: user,
                                                         maxTokens: 700, temperature: 0.2, timeout: 600, stopWhen: stopWhenLooping)
                    partNotes.append(SummaryParser.parse(output).body)
                    guard exists(record) else { return }
                }
            }

            // The notes themselves, cut off the moment the model starts repeating itself.
            activity[meetingID] = "Writing notes…"
            let hasRealTitle = !record.title.hasPrefix(Self.placeholderPrefix)
            let user = MeetingPrompts.summaryUserPrompt(title: hasRealTitle ? record.title : nil,
                                                        date: record.createdAt.formatted(date: .complete, time: .shortened),
                                                        appName: record.appName, attendees: record.attendees,
                                                        userNotes: record.userNotes, transcript: transcript, partNotes: partNotes)
            let output = try await client.stream(system: MeetingPrompts.summarySystemPrompt(template: template), user: user,
                                                 maxTokens: 3000, temperature: 0.3, timeout: 900, stopWhen: stopWhenLooping)
            guard exists(record) else { return }
            let parsed = SummaryParser.parse(output)
            guard !parsed.body.isEmpty else { throw LLMError.emptyResponse }
            if parsed.droppedRepeats > 0 {
                Log.meeting.warning("Dropped \(parsed.droppedRepeats) repeated or cut-off lines from the notes")
            }
            record.summary = parsed.body
            // Keep a title the user typed while notes were being written.
            if record.title.hasPrefix(Self.placeholderPrefix) {
                if let title = parsed.title {
                    record.title = title
                } else if let output = try? await client.complete(system: MeetingPrompts.titleSystemPrompt(), user: parsed.body,
                                                                  maxTokens: 40, temperature: 0.2, timeout: 60),
                          let title = MeetingPrompts.cleanTitle(output), exists(record), record.title.hasPrefix(Self.placeholderPrefix) {
                    record.title = title
                }
            }
            for (label, name) in parsed.speakerNames where (names[label] ?? "").isEmpty {
                names[label] = name
            }
            record.speakerNames = names
            record.errorMessage = nil
            activity[meetingID] = nil
        } catch {
            guard exists(record) else { return }
            record.errorMessage = "Couldn't write notes: \(error.localizedDescription)"
            activity[meetingID] = nil
        }
        Store.shared.save()
    }

    /// When the mic track turned into nothing but zeros for at least the last 30% of the call (a dead device, not a quiet room).
    nonisolated private static func micSilentFrom(_ url: URL, duration: TimeInterval) async -> TimeInterval? {
        await Task.detached(priority: .utility) { () -> TimeInterval? in
            guard let reader = try? ChannelAudioReader(url: url) else { return nil }
            var lastReal: TimeInterval = 0
            var position: TimeInterval = 0
            while position < reader.duration {
                let end = min(reader.duration, position + 60)
                guard let window = try? reader.samples(from: position, to: end), !window.isEmpty else { break }
                if let index = window.lastIndex(where: { $0 != 0 }) { lastReal = position + Double(index + 1) / 16_000 }
                position = end
            }
            let total = max(duration, reader.duration)
            return total - lastReal >= max(120, total * 0.3) ? lastReal : nil
        }.value
    }

    func ask(_ question: String, about record: MeetingRecord) async {
        var chat = record.chat
        let history = chat.map { (role: $0.role, text: $0.text) }
        chat.append(.init(role: "user", text: question))
        record.chat = chat
        Store.shared.save()
        guard let client = settings.makeLLMClient() else {
            chat.append(.init(role: "assistant", text: "Choose a language model in Settings first."))
            record.chat = chat
            return
        }
        let meetingID = record.id
        chattingMeetingIDs.insert(meetingID)
        defer { chattingMeetingIDs.remove(meetingID) }
        let segments = recordingMeetingID == meetingID ? liveSegments : Store.shared.segments(for: meetingID)
        let prompt = MeetingPrompts.chatUserPrompt(question: question,
                                                   transcript: TranscriptFormatter.plainText(segments, names: record.speakerNames),
                                                   notes: record.userNotes, summary: record.summary, history: history)
        let answer: String
        do {
            answer = OutputGuard.sanitize(try await client.complete(system: MeetingPrompts.chatSystemPrompt(), user: prompt,
                                                                    maxTokens: 2000, temperature: 0.4, timeout: 600))
        } catch {
            answer = "Couldn't answer: \(error.localizedDescription)"
        }
        guard exists(record) else { return }
        chat.append(.init(role: "assistant", text: answer))
        record.chat = chat
        Store.shared.save()
    }

    /// Transcribes an existing recording (audio or video) into meeting notes.
    @discardableResult
    func importRecording(_ url: URL) async -> MeetingRecord? {
        let record = MeetingRecord(title: Self.placeholderPrefix + url.deletingPathExtension().lastPathComponent, appName: "Imported file",
                                   templateID: settings.meetingTemplateID)
        record.status = "processing"
        let binder = Store.shared.binder(settings.currentBinderID) ?? Store.shared.defaultBinder()
        record.binderID = binder.id
        record.sharedWithTeam = binder.sharedWithTeam
        Store.shared.insert(record)
        let meetingID = record.id
        busyMeetingIDs.insert(meetingID)
        defer { busyMeetingIDs.remove(meetingID) }
        flowBar.toast("Transcribing \(url.lastPathComponent)…", symbol: "waveform", duration: 3)
        do {
            let engine = try await speech.waitUntilReady()
            let samples = try await Task.detached(priority: .userInitiated) { try AudioRecorder.readSamples(from: url) }.value
            guard !samples.isEmpty else { throw RecorderError.noInputDevice }
            guard exists(record) else { return nil }
            record.duration = Double(samples.count) / 16_000
            let wavName = "\(meetingID.uuidString)-system.wav"
            let wavURL = AppPaths.meetings.appendingPathComponent(wavName)
            try await Task.detached(priority: .utility) { try AudioRecorder.writeWAV(samples, to: wavURL) }.value
            record.systemAudioFile = wavName

            var segments: [TranscriptSegment] = []
            let vocabulary = Store.shared.vocabulary()
            var offset = 0
            while offset < samples.count {
                let slice = samples[offset...]
                let length = max(1, SpeechChunker.nextBoundary(slice, isFinal: true) ?? slice.count)
                let chunk = Array(slice.prefix(length))
                if !AudioMath.isSilent(chunk) {
                    let text = try await engine.transcribe(AudioMath.normalize(chunk), language: settings.languageHint,
                                                           vocabulary: vocabulary, boost: settings.vocabularyBoost)
                    if !text.isEmpty {
                        segments.append(TranscriptSegment(channel: .system, start: Double(offset) / 16_000,
                                                          end: Double(offset + chunk.count) / 16_000, text: text))
                    }
                }
                offset += length
            }
            guard exists(record) else { return nil }
            Store.shared.replaceSegments(for: meetingID, with: segments)
            await finalize(record, micURL: nil, systemURL: wavURL)
            return exists(record) ? record : nil
        } catch {
            guard exists(record) else { return nil }
            record.status = "failed"
            record.errorMessage = "Couldn't transcribe this file: \(error.localizedDescription)"
            Store.shared.save()
            flowBar.toast(record.errorMessage!, symbol: "exclamationmark.triangle", duration: 5)
            return record
        }
    }

    // MARK: Rescue

    /// Swaps in an outside recording of the user (a conference speaker, a phone) as the mic track, lined up with the
    /// meeting, then transcribes that side again and rewrites the notes. The other side's transcript is kept.
    @discardableResult
    func replaceMicTrack(_ record: MeetingRecord, with url: URL, offset manualOffset: TimeInterval? = nil) async -> MicRescue? {
        let meetingID = record.id
        guard !busyMeetingIDs.contains(meetingID), recordingMeetingID != meetingID, !record.isTeamCopy else { return nil }
        busyMeetingIDs.insert(meetingID)
        defer { busyMeetingIDs.remove(meetingID) }
        activity[meetingID] = "Reading \(url.lastPathComponent)…"
        do {
            let candidate = try await Task.detached(priority: .userInitiated) { try AudioRecorder.readSamples(from: url) }.value
            guard candidate.count > 16_000 * 5 else { throw RescueError.tooShort }
            guard exists(record) else { return nil }
            let duration = record.duration > 0 ? record.duration : Double(candidate.count) / 16_000
            let micURL = record.micAudioFile.map { AppPaths.meetings.appendingPathComponent($0) }
            let systemURL = record.systemAudioFile.map { AppPaths.meetings.appendingPathComponent($0) }

            // Line it up against whatever the mic did record and against the other side (a speakerphone hears them too).
            var match: (offset: TimeInterval, confidence: Double, against: String)
            if let manualOffset {
                match = (manualOffset, .infinity, "the offset you entered")
            } else {
                activity[meetingID] = "Lining up the recording…"
                match = try await Task.detached(priority: .userInitiated) {
                    let candidateLevels = AudioAlign.levels(candidate)
                    var best: (offset: TimeInterval, confidence: Double, against: String)?
                    if let micURL, let reference = try? Self.levels(of: micURL, liveAudioOnly: true),
                       let found = AudioAlign.align(referenceLevels: reference, candidateLevels: candidateLevels) {
                        best = (found.offset, found.confidence, "your mic's own recording")
                    }
                    if let systemURL, let reference = try? Self.levels(of: systemURL, liveAudioOnly: false),
                       let found = AudioAlign.align(referenceLevels: reference, candidateLevels: candidateLevels),
                       found.confidence > (best?.confidence ?? 0) {
                        best = (found.offset, found.confidence, "the other side's audio")
                    }
                    guard let best else { throw RescueError.noReference }
                    return best
                }.value
                guard match.confidence >= AudioAlign.strongMatch else { throw RescueError.weakMatch(match.offset, match.confidence) }
                Log.meeting.info("Mic rescue: \(url.lastPathComponent) lines up at \(offsetDescription(match.offset)) against \(match.against) (confidence \(Int(match.confidence)))")
            }
            guard exists(record) else { return nil }

            // Write the aligned track as the mic file, keeping the original next to it.
            activity[meetingID] = "Saving the new mic track…"
            let micName = record.micAudioFile ?? "\(meetingID.uuidString)-mic.wav"
            let newMicURL = AppPaths.meetings.appendingPathComponent(micName)
            let offset = match.offset
            try await Task.detached(priority: .userInitiated) {
                let backup = newMicURL.deletingPathExtension().appendingPathExtension("original.wav")
                if FileManager.default.fileExists(atPath: newMicURL.path), !FileManager.default.fileExists(atPath: backup.path) {
                    try FileManager.default.moveItem(at: newMicURL, to: backup)
                }
                let total = Int(duration * 16_000)
                var aligned = [Float](repeating: 0, count: total)
                let shift = Int((offset * 16_000).rounded())
                // aligned[t] = candidate[t + shift]
                let from = max(0, -shift), to = min(total, candidate.count - shift)
                if to > from { aligned.replaceSubrange(from..<to, with: candidate[(from + shift)..<(to + shift)]) }
                try AudioRecorder.writeWAV(aligned, to: newMicURL)
            }.value
            guard exists(record) else { return nil }
            record.micAudioFile = micName
            if record.duration == 0 { record.duration = duration }

            // Transcribe that side again. A speakerphone hears the other participants too, so the track is diarized
            // and only the voice that talks while the other side is quiet becomes "You"; the echo filter then drops
            // whatever the meeting's own audio already has.
            activity[meetingID] = "Transcribing your side…"
            let others = Store.shared.segments(for: meetingID).filter { $0.channel != .microphone }
            var mine: [TranscriptSegment] = []
            if let turns = await diarize(newMicURL), !turns.isEmpty {
                mine = RescuedTrack.label(await refine(channel: .microphone, url: newMicURL, turns: turns), others: others)
            }
            if mine.isEmpty { mine = await transcribeRecordings(micURL: newMicURL, systemURL: nil) }
            guard exists(record) else { return nil }
            let merged = EchoFilter.removeEcho(from: (others + mine).sorted { $0.start < $1.start })
            Store.shared.replaceSegments(for: meetingID, with: merged)
            record.errorMessage = nil
            Store.shared.save()

            await summarize(record, segments: merged, markBusy: false)
            guard exists(record) else { return nil }
            let kept = merged.filter { $0.channel == .microphone }.count
            activity[meetingID] = "Mic track replaced from \(url.lastPathComponent): lined up at \(offsetDescription(offset)) against \(match.against); \(kept) segments of yours added."
            flowBar.toast("Mic track replaced — notes rewritten", symbol: "checkmark.circle", duration: 4)
            return MicRescue(offset: offset, confidence: match.confidence, matchedAgainst: match.against, segments: kept)
        } catch {
            guard exists(record) else { return nil }
            activity[meetingID] = "Couldn't replace the mic track: \(error.localizedDescription)"
            flowBar.toast("Couldn't replace the mic track", symbol: "exclamationmark.triangle", duration: 5)
            Log.meeting.error("Mic rescue failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// dB levels of a whole recording, read a minute at a time; `liveAudioOnly` trims the dead (all-zero) tail.
    nonisolated private static func levels(of url: URL, liveAudioOnly: Bool) throws -> [Float] {
        let reader = try ChannelAudioReader(url: url)
        let hop = 16_000 / AudioAlign.rate
        var levels: [Float] = []
        var lastReal = 0
        var position: TimeInterval = 0
        while position < reader.duration {
            let end = min(reader.duration, position + 60)
            let window = try reader.samples(from: position, to: end)
            guard !window.isEmpty else { break }
            if let index = window.lastIndex(where: { $0 != 0 }) { lastReal = levels.count + index / hop + 1 }
            levels += AudioAlign.levels(window)
            position = end
        }
        return liveAudioOnly ? Array(levels.prefix(lastReal)) : levels
    }

    // MARK: Export

    func markdown(for record: MeetingRecord) -> String {
        MeetingMarkdown.document(title: record.title, dateText: record.createdAt.formatted(date: .abbreviated, time: .shortened),
                                 duration: record.duration, appName: record.appName, attendees: record.attendees,
                                 summary: record.summary, notes: record.userNotes,
                                 segments: recordingMeetingID == record.id ? liveSegments : Store.shared.segments(for: record.id),
                                 names: record.speakerNames)
    }

    func export(_ record: MeetingRecord) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        let safeTitle = record.title.components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>")).joined(separator: "-")
        panel.nameFieldStringValue = "\(safeTitle).md"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try markdown(for: record).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            flowBar.toast("Export failed: \(error.localizedDescription)", symbol: "exclamationmark.triangle")
        }
    }
}

struct MicRescue: Sendable {
    var offset: TimeInterval
    var confidence: Double
    var matchedAgainst: String
    var segments: Int
}

enum RescueError: LocalizedError {
    case tooShort
    case noReference
    case weakMatch(TimeInterval, Double)

    var errorDescription: String? {
        switch self {
        case .tooShort: "That recording is too short"
        case .noReference: "This meeting has no audio to line the recording up with — enter the offset yourself"
        case .weakMatch(let offset, let confidence):
            "Couldn't line the recording up confidently (best guess \(offsetDescription(offset)), confidence \(Int(confidence)) of \(Int(AudioAlign.strongMatch)) needed). Enter the offset yourself: seconds into the recording where the meeting starts."
        }
    }
}

/// "+12.3 s" or "−20.0 s".
func offsetDescription(_ seconds: TimeInterval) -> String {
    String(format: "%@%.1f s", seconds < 0 ? "−" : "+", abs(seconds))
}
