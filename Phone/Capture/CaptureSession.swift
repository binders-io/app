import AVFoundation
import BindersKit
import CallKit
import Foundation
import Observation
import UIKit
import UserNotifications

/// Who else is using the microphone in this app: dictation, and the keyboard's warm microphone. While either has it,
/// All-day capture steps aside, and it carries on once they're done. Dictations aren't conversations; they're kept as
/// dictations.
@MainActor
enum MicrophoneUsers {
    private static var holders: Set<String> = []

    static func claim(_ who: String) {
        let first = holders.isEmpty
        holders.insert(who)
        if first { CaptureSession.shared.stepAside() }
    }

    static func release(_ who: String) {
        guard holders.remove(who) != nil, holders.isEmpty else { return }
        CaptureSession.shared.stepBack()
        // Capture isn't listening either: in the background nothing may keep Binders running now.
        if !CaptureSession.shared.isListening { ConversationProcessor.shared.keepAliveChanged() }
    }

    static var isClaimed: Bool { !holders.isEmpty }

    /// What capture says while it steps aside: the calibration bench ("bench…") or a dictation has the microphone.
    static var pausedReason: String { holders.contains { $0.hasPrefix("bench") } ? "While you calibrate" : holders.contains("talk") ? "While you talk with your hub" : "While you dictate" }

    /// Once another user's engine is off: true when capture is listening again, so the audio session must stay on.
    static var captureNeedsSession: Bool { CaptureSession.shared.isListening }
}

/// All-day capture: the iPhone listens, cuts the day into conversations, and hands each one, once it's over, to be
/// transcribed here and sent to the Mac as text. It mixes with whatever's playing, keeps going with the screen locked,
/// and comes back after a call or Siri, or asks to be tapped when iOS won't let it. Mute stops the microphone
/// completely. It never turns itself on: after a quit it asks.
@MainActor
@Observable
final class CaptureSession {
    static let shared = CaptureSession()

    enum Status: Equatable {
        case off, starting, listening, muted
        case paused(String)

        var title: String {
            switch self {
            case .off: "Off"
            case .starting: "Starting…"
            case .listening: "Listening"
            case .muted: "Muted"
            case .paused: "Paused"
            }
        }
    }

    /// A stretch when capture wasn't listening though it was on: "paused 10:42–10:57".
    struct Gap: Codable, Equatable, Identifiable {
        var id: Date { from }
        var from: Date
        var to: Date?
        var reason: String
    }

    private(set) var status: Status = .off {
        didSet {
            // Stopped listening: in the background nothing may keep Binders running now.
            if oldValue == .listening, status != .listening { ConversationProcessor.shared.keepAliveChanged() }
            if oldValue != status { CaptureActivity.update() }
        }
    }
    /// Someone is speaking, or was a moment ago: a conversation is open.
    private(set) var inConversation = false
    /// The conversation being heard now, for its page's Wrap Up Now.
    private(set) var openConversation: UUID?
    /// What a wrap-up just did, said for a few seconds under the button.
    private(set) var wrapUpNote: String?
    @ObservationIgnored private var wrappingUp = false
    private(set) var error: String?
    /// Today's numbers.
    private(set) var gaps: [Gap] = []
    private(set) var speechSeconds: TimeInterval = 0
    private(set) var secondsOn: TimeInterval = 0
    /// It was on when the app last quit: ask before turning it back on.
    var askToResume = false

    var isOn: Bool { status != .off }
    var isListening: Bool { status == .listening }
    var isMuted: Bool { status == .muted }
    /// Paused while dictation or the keyboard has the microphone, to listen again once they let go.
    var isWaitingForMicrophone: Bool { steppedAside && isPaused }

    /// When it began listening this time, for the Live Activity's clock.
    var listeningStarted: Date? { listeningSince }

    /// Hours listened today, so far.
    func onToday(now: Date = Date()) -> TimeInterval { secondsOn + (listeningSince.map { now.timeIntervalSince($0) } ?? 0) }

    /// Someone is speaking now, as capture hears it (a second's grace for the gaps between words): what the capture
    /// screen's glyph moves with. Asked only while that screen shows.
    func hearsSpeech(now: Date = Date()) async -> Bool {
        guard status == .listening, let last = await worker.lastSpeech else { return false }
        return now.timeIntervalSince(last) < 1
    }

    /// Told when a conversation is over and ready to transcribe.
    @ObservationIgnored var onConversationClosed: ((CapturedConversation) -> Void)?
    /// Told when someone starts talking, and when a conversation closes: the Mac is about to be needed.
    @ObservationIgnored var onSpeech: (() -> Void)?
    @ObservationIgnored private var source: CaptureSource?
    @ObservationIgnored private var feed: AsyncStream<([Float], Date)>.Continuation?
    @ObservationIgnored private var listeningSince: Date?
    @ObservationIgnored private var steppedAside = false
    @ObservationIgnored private var statsDay = Calendar.current.startOfDay(for: Date())
    /// When audio last arrived, for the watchdog.
    @ObservationIgnored private let heartbeat = AudioHeartbeat()
    @ObservationIgnored private var watchdog: Task<Void, Never>?
    /// Lane Y2: whether a call is up (one routed to a Watch among them), read at the watchdog's tick: it costs nothing
    /// between calls. And when the last tick was, for what the capture wrote since.
    @ObservationIgnored private let calls = CXCallObserver()
    @ObservationIgnored private var lastTick = Date()
    /// The microphone went quiet once and was restarted: a second time, it's paused and you're told.
    @ObservationIgnored private var restartedForSilence = false
    /// The least speech the last Wrap Up kept, for saying why one wasn't.
    @ObservationIgnored private var wrapUpKeepsFrom = CaptureWorker.wrapUpMinimum
    @ObservationIgnored private var lastDetectorTry = Date.distantPast
    /// The voice detector hears speech; until it's ready, loudness stands in. Told by the worker from the first chunk
    /// loudness has to take, and again once the detector reads one.
    private(set) var hearsVoices = true
    @ObservationIgnored private let worker = CaptureWorker { event in
        Task { @MainActor in CaptureSession.shared.handle(event) }
    }

    private static let onKey = "captureOn"
    private static let statsKey = "captureStats"
    /// `-captureSource silence` listens to nothing, for the Simulator and UI tests.
    private var simulated: Bool { UserDefaults.standard.string(forKey: "captureSource") == "silence" }

    private init() {
        loadStats()
        askToResume = UserDefaults.standard.bool(forKey: Self.onKey)
        let center = NotificationCenter.default
        center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { note in
            let info = note.userInfo ?? [:]
            MainActor.assumeIsolated { CaptureSession.shared.interrupted(info) }
        }
        // iOS 27 says the same in its own words, and says when to carry on even if the interruption never says it ended.
        // Both can arrive; each step only acts once.
        if #available(iOS 27.0, *) {
            center.addObserver(forName: AVAudioSession.didBecomeInactiveNotification, object: nil, queue: .main) { note in
                guard let context = note.userInfo?[AVAudioSession.deactivationContextKey] as? AVAudioSession.DeactivationContext,
                      context.source == .system else { return }
                let muted = context.interruptionContext?.reason == .builtInMicMuted
                MainActor.assumeIsolated { CaptureSession.shared.interruptionBegan(muted: muted) }
            }
            center.addObserver(forName: AVAudioSession.resumptionRecommendationNotification, object: nil, queue: .main) { note in
                let context = note.userInfo?[AVAudioSession.resumptionContextKey] as? AVAudioSession.ResumptionContext
                let resume = context?.recommendation == .shouldResume
                MainActor.assumeIsolated { CaptureSession.shared.interruptionEnded(shouldResume: resume) }
            }
        }
        center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
            MainActor.assumeIsolated { CaptureSession.shared.routeChanged(reason) }
        }
        center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { CaptureSession.shared.restartSource() }
        }
        center.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { CaptureSession.shared.restartSource() }
        }
    }

    // MARK: On and off

    func turnOn() async {
        guard status == .off || isPaused else { return }
        // Never before the capture screen's reminder to let people know, whatever asks: a control, a Live Activity, Siri.
        guard UserDefaults.standard.bool(forKey: "captureNoticeAcknowledged") else { return askToTurnOnInApp() }
        error = nil
        status = .starting
        if !simulated {
            guard await AVAudioApplication.requestRecordPermission() else {
                status = .off
                error = CaptureError.microphone.localizedDescription
                return
            }
        }
        // For "paused, tap to resume" when iOS won't let it start again by itself.
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        UserDefaults.standard.set(true, forKey: Self.onKey)
        askToResume = false
        // Ready the models now, with the app open, so conversations can be written down in the pocket later.
        ConversationProcessor.shared.prepareForBackground()
        if MicrophoneUsers.isClaimed {
            steppedAside = true
            status = .paused(MicrophoneUsers.pausedReason)
            return
        }
        startListening()
    }

    func turnOff() {
        stopListening()
        steppedAside = false
        disarmNotices()
        status = .off
        inConversation = false
        UserDefaults.standard.set(false, forKey: Self.onKey)
        closeGap()
        deactivateSession()
    }

    /// Stops the microphone completely, so iOS's microphone indicator goes away; a conversation in progress ends here.
    func mute() {
        guard status == .listening || isPaused else { return }
        stopListening()
        steppedAside = false
        disarmNotices()
        closeGap()
        status = .muted
        deactivateSession()
    }

    func unmute() {
        guard status == .muted else { return }
        if MicrophoneUsers.isClaimed {
            steppedAside = true
            status = .paused(MicrophoneUsers.pausedReason)
            return
        }
        startListening()
    }

    /// From the "paused, tap to resume" notification, or the Resume button.
    func resume() async {
        if status == .off {
            await turnOn()
        } else if isPaused, steppedAside {
            // The keyboard keeping the microphone ready lets go of it; a dictation in progress finishes first.
            KeyboardListener.shared.letGoIfIdle()
        } else if isPaused {
            startListening()
        }
    }

    /// Asked at launch, and declined: it stays off until turned on.
    func declineResume() {
        askToResume = false
        UserDefaults.standard.set(false, forKey: Self.onKey)
    }

    private var isPaused: Bool {
        if case .paused = status { return true }
        return false
    }

    // MARK: Listening

    private func startListening() {
        do {
            try activateSession()
            let source: CaptureSource = simulated ? SilenceSource() : MicSource()
            let (stream, continuation) = AsyncStream<([Float], Date)>.makeStream()
            let heartbeat = heartbeat
            heartbeat.beat()
            source.onAudio = { samples, time in
                heartbeat.beat()
                continuation.yield((samples, time))
            }
            try source.start()
            let worker = worker
            Task.detached(priority: .userInitiated) {
                for await (samples, time) in stream { await worker.append(samples, at: time) }
                // Stopped, muted or interrupted: an open conversation ends where its speech did.
                await worker.finish()
            }
            self.source = source
            feed = continuation
            // Before the status, whose change updates the Live Activity's timer.
            listeningSince = Date()
            status = .listening
            error = nil
            rollStats()
            closeGap()
            removePausedNotice()
            restartedForSilence = false
            startWatchdog()
            momentsChanged()
            Task {
                let detector = await CaptureModels.shared.voiceDetector()
                await worker.useDetector(detector)
                lastDetectorTry = Date()
            }
        } catch {
            source?.stop()
            source = nil
            self.error = error.localizedDescription
            status = .paused("Couldn't start the microphone")
            openGap("the microphone wouldn't start")
            notifyPaused()
        }
    }

    private func stopListening() {
        watchdog?.cancel()
        watchdog = nil
        source?.stop()
        source = nil
        feed?.finish()
        feed = nil
        if let since = listeningSince {
            rollStats()
            secondsOn += Date().timeIntervalSince(since)
            listeningSince = nil
            saveStats()
        }
    }

    /// The route or the audio engine changed (AirPods connected, the media services reset): a new microphone source feeds
    /// the same stream, so the conversation being heard carries on rather than closing, and a short one isn't lost.
    /// `afterSilence`: the watchdog's restart of a microphone that went quiet, which gets no grace, so if no audio comes
    /// by its next look, capture pauses and says so rather than restarting again.
    private func restartSource(afterSilence: Bool = false) {
        guard status == .listening, let feed else { return }
        source?.stop()
        do {
            try activateSession()
            let source: CaptureSource = simulated ? SilenceSource() : MicSource()
            let heartbeat = heartbeat
            if !afterSilence { heartbeat.beat() }
            source.onAudio = { samples, time in
                heartbeat.beat()
                feed.yield((samples, time))
            }
            try source.start()
            self.source = source
        } catch {
            stopListening()
            self.error = error.localizedDescription
            status = .paused("Couldn't start the microphone")
            openGap("the microphone wouldn't start")
            notifyPaused()
        }
    }

    // MARK: The watchdog

    /// While listening, every five seconds: audio still arriving (a microphone that went quiet is restarted once, then
    /// capture pauses and says so), the voice detector tried again when it's missing, and a notice armed a few minutes
    /// ahead that only shows if Binders stops running, killed by iOS or suspended, without a word.
    private func startWatchdog() {
        watchdog?.cancel()
        armStoppedNotice()
        watchdog = Task { [weak self] in
            var ticks = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, let self, self.status == .listening else { return }
                ticks += 1
                // Lane Y2: other audio playing, or a call up, counts against a capture only while it writes speech.
                let otherAudio = AVAudioSession.sharedInstance().isOtherAudioPlaying
                let onCall = self.calls.calls.contains { $0.hasConnected && !$0.hasEnded }
                let previous = self.lastTick
                self.lastTick = Date()
                if otherAudio || onCall {
                    let worker = self.worker
                    Task { await worker.heard(otherAudio: otherAudio, call: onCall, previousTick: previous) }
                }
                if self.heartbeat.age > 10 {
                    if !self.restartedForSilence {
                        self.restartedForSilence = true
                        self.restartSource(afterSilence: true)
                    } else {
                        self.stopListening()
                        self.status = .paused("The microphone stopped")
                        self.openGap("the microphone stopped")
                        self.notifyPaused()
                        return
                    }
                } else {
                    self.restartedForSilence = false
                }
                if ticks % 12 == 0 { self.armStoppedNotice() }
                if ticks % 12 == 6 { await self.retryDetector() }
                // The Live Activity, touched before it would show as possibly stopped.
                if ticks % 60 == 0 { CaptureActivity.update() }
            }
        }
    }

    /// The voice detector missing, or given up on after it kept failing: tried again every five minutes. The worker says
    /// when it hears by voice again.
    private func retryDetector() async {
        let worker = worker
        guard await !worker.detectorWorking, Date().timeIntervalSince(lastDetectorTry) > 300 else { return }
        lastDetectorTry = Date()
        let detector = await CaptureModels.shared.voiceDetector()
        await worker.useDetector(detector)
    }

    /// Shows in five minutes unless it's armed again first: only when Binders stopped running while capture was on.
    func armStoppedNotice() {
        guard status == .listening else { return }
        let content = UNMutableNotificationContent()
        content.title = "All-day capture stopped"
        content.body = "Binders stopped listening around \(Date().formatted(date: .omitted, time: .shortened)). Open Binders to turn it back on."
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 5 * 60, repeats: false)
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: ConversationProcessor.stoppedIdentifier, content: content, trigger: trigger))
    }

    /// Muted, off, or quitting on purpose: no notice to come.
    func disarmNotices() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [ConversationProcessor.stoppedIdentifier, Self.pausedCategory])
    }

    /// The app came to the front while an interruption still holds capture paused (the call ended, but iOS never said):
    /// it tries once to listen again.
    func appBecameActive() {
        guard isPaused, !steppedAside, case .paused(let why) = status, why.hasPrefix("Interrupted") else { return }
        startListening()
    }

    private func activateSession() throws {
        guard !simulated else { return }
        let session = AVAudioSession.sharedInstance()
        // Mixed with whatever's playing, so music and podcasts carry on at full volume. Bluetooth headphones keep playing
        // in high quality (A2DP); listening through their microphone would switch them to call quality, so the iPhone's
        // own microphone listens.
        try session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .allowBluetoothA2DP, .defaultToSpeaker])
        // A call that rings as a banner doesn't stop capture; one you take does.
        try? session.setPrefersNoInterruptionsFromSystemAlerts(true)
        try session.setActive(true)
    }

    private func deactivateSession() {
        guard !simulated, !MicrophoneUsers.isClaimed else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: Others using the microphone

    /// Dictation or the keyboard wants the microphone: let go of it until they're done.
    func stepAside() {
        guard status == .listening else { return }
        stopListening()
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [ConversationProcessor.stoppedIdentifier])
        steppedAside = true
        status = .paused(MicrophoneUsers.pausedReason)
    }

    /// They're done: listen again, before the audio session goes, so iOS lets it carry on in the background.
    func stepBack() {
        guard steppedAside else { return }
        steppedAside = false
        guard isPaused else { return }
        startListening()
    }

    // MARK: Interruptions

    private func interrupted(_ info: [AnyHashable: Any]) {
        guard let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt, let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            let reason = (info[AVAudioSessionInterruptionReasonKey] as? UInt).flatMap(AVAudioSession.InterruptionReason.init(rawValue:))
            interruptionBegan(muted: reason == .builtInMicMuted)
        case .ended:
            let options = AVAudioSession.InterruptionOptions(rawValue: info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
            interruptionEnded(shouldResume: options.contains(.shouldResume))
        @unknown default:
            break
        }
    }

    /// A call, Siri or another app took the microphone: capture pauses, and a quiet notice is set two minutes ahead in
    /// case iOS never says it's over (it doesn't wake a suspended app to say so).
    private func interruptionBegan(muted: Bool) {
        guard status == .listening else { return }
        let why = muted ? "the microphone was muted" : "a call, Siri or another app"
        stopListening()
        status = .paused("Interrupted by \(why)")
        openGap(why)
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [ConversationProcessor.stoppedIdentifier])
        notifyPaused(after: 120)
    }

    private func interruptionEnded(shouldResume: Bool) {
        guard isPaused, !steppedAside else { return }
        if shouldResume {
            startListening()
            if status == .listening { return }
        }
        notifyPaused()
    }

    private func routeChanged(_ reason: AVAudioSession.RouteChangeReason?) {
        switch reason {
        case .newDeviceAvailable, .oldDeviceUnavailable, .override: restartSource()
        default: break
        }
    }

    /// iOS wouldn't let it start again by itself: a tap on this brings it back. With a delay, it's quiet, and shows only if
    /// capture hasn't listened again by then.
    private func notifyPaused(after delay: TimeInterval? = nil) {
        let content = UNMutableNotificationContent()
        content.title = delay == nil ? "All-day capture paused" : "All-day capture is still paused"
        content.body = "Tap to resume."
        content.categoryIdentifier = Self.pausedCategory
        if delay != nil { content.interruptionLevel = .passive }
        let trigger = delay.map { UNTimeIntervalNotificationTrigger(timeInterval: $0, repeats: false) }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: Self.pausedCategory, content: content, trigger: trigger))
    }

    private func removePausedNotice() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [Self.pausedCategory])
        center.removeDeliveredNotifications(withIdentifiers: [Self.pausedCategory])
    }

    static let pausedCategory = "capture-paused"
    static let firstTimeCategory = "capture-first-time"

    /// Turned on from Control Center, the Lock Screen or the Action Button with the iPhone locked: it doesn't listen until
    /// it's unlocked and asked again.
    func askToUnlockFirst() {
        let content = UNMutableNotificationContent()
        content.title = "Unlock to turn on All-day capture"
        content.body = "Then turn it on again. Mute works with the iPhone locked."
        content.categoryIdentifier = Self.firstTimeCategory
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: Self.firstTimeCategory, content: content, trigger: nil))
    }

    /// Turned on from Control Center, the Lock Screen or the Action Button before it was ever turned on in the app: it
    /// doesn't listen yet. The capture screen, which a tap on this opens, first reminds you to let people know.
    func askToTurnOnInApp() {
        PhoneNavigation.shared.pendingCapture = true
        let content = UNMutableNotificationContent()
        content.title = "Turn on All-day capture in Binders"
        content.body = "The first time, Binders reminds you to let the people around you know before it listens."
        content.categoryIdentifier = Self.firstTimeCategory
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: Self.firstTimeCategory, content: content, trigger: nil))
    }

    // MARK: Conversations

    /// Wrap up now: the conversation being heard closes and is written down, without waiting for three minutes of quiet.
    func wrapUp() {
        guard status == .listening, inConversation else { return }
        wrappingUp = true
        let worker = worker
        // From a few seconds of speech for a Mac that keeps a wrapped-up capture however short (one that says what became
        // of captures), or none paired yet; an older Mac calls anything under 40 words small talk, so the usual minimum.
        let connection = MacConnection.current
        let minimum = connection?.hasBrain != true || connection?.hasOutcomes == true ? CaptureWorker.wrapUpMinimum : ConversationSplitter.Settings().minSpeech
        wrapUpKeepsFrom = minimum
        Task { await worker.wrapUp(keepingFrom: minimum) }
    }

    /// What became of a moment: kept, it may take the words of the conversation that opened for it. Not kept, `why` goes
    /// on the timeline of the conversation that holds its words, while it's open.
    /// `joins` (lane Y2): kept in Auto in the conversation open now, it goes with that capture, which is kept however short.
    func settleMoment(_ id: UUID, kept: Bool, why: String? = nil, in conversation: UUID? = nil, joins: UUID? = nil) {
        let worker = worker
        Task { await worker.settleMoment(id, kept: kept, why: why, in: conversation, joins: joins) }
    }

    /// A moment kept: it takes the words of the conversation set aside for it. True when it's still said on its own now
    /// that it's written down: nothing was said in the three minutes before it that no kept moment holds, a moment just
    /// before it that wasn't kept included (CaptureWorker.settleMoment).
    func keepMoment(_ id: UUID) async -> Bool {
        await worker.settleMoment(id, kept: true)
    }

    /// Moments turned on or off, or the Mac's say on them changed: the worker listens for them, or stops.
    func momentsChanged() {
        guard status == .listening else { return }
        let worker = worker
        let on = MomentCenter.shared.isListening
        // The mode a capture opening now is stamped with, and the open one lowered to (lane Y2).
        let mode = MomentCenter.shared.captureMode
        Task {
            await worker.useMoments(on ? MomentDetector.Settings() : nil)
            await worker.useMode(mode)
        }
    }

    /// Says what the wrap-up did, then lets it go.
    private func wrappedUp(_ note: String) {
        guard wrappingUp else { return }
        wrappingUp = false
        wrapUpNote = note
        Task {
            try? await Task.sleep(for: .seconds(6))
            if wrapUpNote == note { wrapUpNote = nil }
        }
    }

    private func handle(_ event: CaptureWorker.Event) {
        switch event {
        case .opened(let conversation):
            inConversation = true
            openConversation = conversation.id
            CaptureStore.shared.save(conversation)
            onSpeech?()
        case .closed(let conversation):
            CaptureActivity.update()
            inConversation = false
            openConversation = nil
            wrappedUp("Wrapped up. It's being written down.")
            CaptureStore.shared.save(conversation)
            onConversationClosed?(conversation)
            onSpeech?()
        case .dropped(let conversation):
            // Too short to keep: its audio is gone, and its row says Not kept · too short, with its time and nothing else.
            // One a moment said on its own had taken, let go once the moment wasn't kept, can come after the next
            // conversation opened: that one stays open.
            if openConversation == nil || openConversation == conversation.id {
                inConversation = false
                openConversation = nil
                wrappedUp("Not kept: under \(Int(wrapUpKeepsFrom)) seconds of speech.")
            }
            CaptureStore.shared.save(conversation)
        case .voiceDetector(let working):
            hearsVoices = working
        case .heard(let speech):
            rollStats()
            speechSeconds += speech
            saveStats()
        case .unsaved(let message):
            error = message
        case .moment(let clip):
            MomentCenter.shared.heard(clip)
            onSpeech?()
        case .absorbed(let id):
            // A moment took the words: the conversation that opened for them goes, and isn't counted as too short. It was
            // set aside when the moment was heard, so the next conversation may have opened since: that one stays open.
            if openConversation == nil || openConversation == id {
                inConversation = false
                openConversation = nil
            }
            CaptureStore.shared.delete(id)
        }
    }

    // MARK: Today's numbers

    private struct Stats: Codable {
        var day: Date
        var secondsOn: TimeInterval
        var speechSeconds: TimeInterval
        var gaps: [Gap]
        /// Too short to keep, as builds before their rows counted them. No longer written (their rows count them now);
        /// Optional, so the day's numbers saved before it, and after it, still read.
        var dropped: Int?
    }

    private func openGap(_ reason: String) {
        rollStats()
        if let last = gaps.last, last.to == nil { return }
        gaps.append(Gap(from: Date(), to: nil, reason: reason))
        saveStats()
    }

    private func closeGap() {
        guard let last = gaps.last, last.to == nil else { return }
        gaps[gaps.count - 1].to = Date()
        saveStats()
    }

    /// A new day starts the numbers again.
    private func rollStats() {
        let today = Calendar.current.startOfDay(for: Date())
        guard today != statsDay else { return }
        statsDay = today
        secondsOn = 0
        speechSeconds = 0
        gaps = gaps.filter { $0.to == nil }
        if let since = listeningSince, since < today { listeningSince = today }
    }

    private func loadStats() {
        guard let data = UserDefaults.standard.data(forKey: Self.statsKey), let stats = try? JSONDecoder().decode(Stats.self, from: data),
              Calendar.current.isDateInToday(stats.day) else { return }
        secondsOn = stats.secondsOn
        speechSeconds = stats.speechSeconds
        // A gap left open by a quit ended with it.
        gaps = stats.gaps.map { gap in
            var closed = gap
            if closed.to == nil { closed.to = closed.from }
            return closed
        }
    }

    private func saveStats() {
        let stats = Stats(day: statsDay, secondsOn: secondsOn, speechSeconds: speechSeconds, gaps: gaps, dropped: nil)
        if let data = try? JSONEncoder().encode(stats) { UserDefaults.standard.set(data, forKey: Self.statsKey) }
    }
}

/// When audio last arrived from the microphone, set on the audio thread and read by the watchdog.
final class AudioHeartbeat: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date()

    func beat() { lock.withLock { last = Date() } }

    /// Seconds since audio last arrived.
    var age: TimeInterval { lock.withLock { Date().timeIntervalSince(last) } }
}
