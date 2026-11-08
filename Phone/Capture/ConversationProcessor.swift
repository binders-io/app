import AVFoundation
import BackgroundTasks
import BindersKit
import FluidAudio
import Foundation
import Observation
import UIKit
import UserNotifications

/// Turns each conversation All-day capture heard into text, on this iPhone: Parakeet writes down what was said, the
/// diarizer tells the voices apart, and your own voice, if you taught it, becomes "You". The text goes into the outbox
/// for the Mac, and only then is the audio deleted. It runs straight away while the app is open; in the background, right
/// after a conversation ends while capture keeps the app running and the phone can spare it (only with "Write down while
/// the iPhone is locked" on), or while the phone charges. Every step is saved, so it picks up where it stopped. In the
/// background nothing is ever written down less well than in front: whatever can't run cleanly there waits for the app.
@MainActor
@Observable
final class ConversationProcessor {
    static let shared = ConversationProcessor()
    static let taskIdentifier = "io.binders.app.conversations"
    static let reminderIdentifier = "capture-waiting"
    static let stoppedIdentifier = "capture-stopped"

    /// The conversation being worked on, and what's happening to it.
    private(set) var working: UUID?
    private(set) var activity: String?

    /// Developer setting: keep each conversation's audio for a day after its transcript is in the outbox, to check how
    /// well it was transcribed. Debug builds only: a release never keeps audio.
    var keepsAudio: Bool {
        didSet { UserDefaults.standard.set(keepsAudio, forKey: "captureKeepAudio") }
    }

    /// "Write down while the iPhone is locked": conversations are written down in the pocket, on battery, as they end.
    /// Off by default, for everyone: then they wait for the app or the charger. Moments don't go by it.
    var writesDownWhileLocked: Bool {
        didSet { UserDefaults.standard.set(writesDownWhileLocked, forKey: Self.whileLockedKey) }
    }
    private static let whileLockedKey = "captureWritesDownWhileLocked"

    @ObservationIgnored weak var connection: MacConnection?
    @ObservationIgnored private var run: Task<Void, Never>?
    /// Models being readied, or fetched from the capture screen: the big ones go once these are done, if nothing else
    /// needs them.
    @ObservationIgnored private var preparing: Task<Void, Never>?
    @ObservationIgnored private var fetching: Task<Void, Never>?
    /// The charging task under way, until it's told it's done.
    @ObservationIgnored private var backgroundTask: BGProcessingTask?
    /// The app has been in the background since it was last in front: coming back is a new visit.
    @ObservationIgnored private var cameFromBackground = true
    /// Failed conversations tried again since the app last came to the front: once each per visit.
    @ObservationIgnored private var retriedThisVisit: Set<UUID> = []
    /// Running in the background task iOS gives while the phone charges.
    @ObservationIgnored private var inBackgroundTask = false
    /// Something went wrong writing down in the pocket: no more of that until the app is next in front.
    @ObservationIgnored private var backgroundPaused = false
    /// Why the charging task can't run, when iOS refused it: Background App Refresh off, say.
    @ObservationIgnored private(set) var chargingBlocked: String?
    /// The step under way (loading a model, a window, telling the voices apart) started with the app in the background.
    @ObservationIgnored private var stepInBackground = false
    /// A step that went wrong in the background stopped the run with the app open again: it starts over, in front.
    @ObservationIgnored private var resumeInFront = false
    @ObservationIgnored private var budget = CPUBudget()
    /// The conversation being written down with the app in front. Still set at launch, it ended Binders: a failure.
    private static let attemptKey = "captureAttempt"
    /// The same in the background. Still set at launch, Binders was stopped there: that one waits for the app.
    private static let backgroundAttemptKey = "captureBackgroundAttempt"
    private var store: CaptureStore { .shared }
    private var models: CaptureModels { .shared }

    private init() {
        #if DEBUG
        keepsAudio = UserDefaults.standard.bool(forKey: "captureKeepAudio")
        #else
        keepsAudio = false
        #endif
        writesDownWhileLocked = UserDefaults.standard.bool(forKey: Self.whileLockedKey)
    }

    /// Open on screen. Inactive (Control Center or a notification pulled down, the app switcher) still counts: iOS treats
    /// the app as in front then.
    private var inFront: Bool { UIApplication.shared.applicationState != .background }

    /// Conversations with work left before they can go to the Mac, oldest first, by their lines in the index.
    var waiting: [CaptureEntry] {
        // One being labelled whose words are written down goes even without its audio (as one voice), after three days.
        store.conversations.filter { [.recorded, .transcribing, .labelling].contains($0.state)
            && (!$0.audioDeleted || ($0.state == .labelling && $0.hasSegments)) }
            .sorted { $0.started < $1.started }
    }

    /// Something waiting that the background may still write down, not only captures left for the app.
    private var waitingForBackground: Bool { waiting.contains { $0.appOnly != true } }

    /// Failed with the app open and with tries left: tried again while the app is open, once a visit, oldest first.
    private var retryable: [CaptureEntry] {
        guard inFront else { return [] }
        return store.conversations.filter { $0.canRetry && !retriedThisVisit.contains($0.id) }.sorted { $0.started < $1.started }
    }

    // MARK: Where it may run

    /// The app is open; or iOS lets the models run with it in the background, and it's the charging task or the phone
    /// can spare the work now. Moments go by this; conversations by `mayWriteDownConversationsNow`.
    private var mayRunNow: Bool {
        if inFront { return true }
        guard CaptureModels.mayInferInBackground else { return false }
        return inBackgroundTask || mayWriteDownOnBatteryNow
    }

    /// The same for conversations, which on battery in the background also need "Write down while the iPhone is locked":
    /// off, they wait for the app or the charging task.
    private var mayWriteDownConversationsNow: Bool {
        if inFront { return true }
        guard CaptureModels.mayInferInBackground else { return false }
        return inBackgroundTask || (writesDownWhileLocked && mayWriteDownOnBatteryNow)
    }

    /// Something keeps the app running in the background: capture listening, or the keyboard's microphone.
    private var appStaysAlive: Bool { CaptureSession.shared.isListening || MicrophoneUsers.isClaimed }

    /// Writing a conversation down in the background, on battery, right after it ends: once both models have been
    /// readied with the app open, while something keeps the app running, nothing has gone wrong there since the app was
    /// last open, and the phone is cool, not in Low Power Mode, and charged enough (or charging).
    private var mayWriteDownOnBatteryNow: Bool {
        guard CaptureModels.mayInferInBackground, !backgroundPaused, models.isReadyForBackground, appStaysAlive else { return false }
        let info = ProcessInfo.processInfo
        guard info.thermalState == .nominal || info.thermalState == .fair, !info.isLowPowerModeEnabled else { return false }
        let device = UIDevice.current
        device.isBatteryMonitoringEnabled = true
        if device.batteryState == .charging || device.batteryState == .full { return true }
        return device.batteryLevel < 0 || device.batteryLevel >= 0.2
    }

    /// In the background, a conversation that once stopped Binders there waits for the app; on battery, so does one
    /// with more than 15 minutes of speech.
    private func mayTakeOn(_ conversation: some CaptureFacts) -> Bool {
        if inFront { return true }
        if conversation.appOnly == true { return false }
        return inBackgroundTask || conversation.speech <= 15 * 60
    }

    /// Whether this conversation, being written down in front, could carry on if the app left the front.
    private func couldCarryOn(_ conversation: some CaptureFacts) -> Bool {
        writesDownWhileLocked && mayWriteDownOnBatteryNow && conversation.appOnly != true && conversation.speech <= 15 * 60
    }

    // MARK: When it runs

    private static var isSetUp = false

    /// The background task, registered as the app launches and before anything can ask for a run: iOS stops an app that
    /// asks for a task it hasn't registered, and a capture left waiting asks for one as soon as the app starts.
    static func setUp() {
        guard !isSetUp else { return }
        isSetUp = true
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { task in
            guard let task = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor in await ConversationProcessor.shared.runInBackground(task) }
        }
    }

    /// A conversation just ended: written down now if the app is open, or in the background while capture keeps the app
    /// running and the phone can spare it (with writing down while locked on); otherwise while the phone charges, with a
    /// quiet reminder that it's waiting.
    func conversationClosed(_ conversation: CapturedConversation) {
        // While capture keeps the app running without it coming to the front, this is when old audio goes.
        store.tidy(working: working)
        #if DEBUG
        SpeechTrial.shared.closed(conversation, inBackground: !inFront)
        #endif
        if mayWriteDownConversationsNow, mayTakeOn(conversation) {
            processWaiting()
        } else {
            scheduleBackgroundRun()
            store.update(conversation.id) { $0.note(CaptureStep.waiting, whyWaiting($0)) }
            remindLater()
        }
    }

    func scheduleBackgroundRun() {
        // Where iOS keeps the models from background apps, a background run couldn't write anything down.
        guard CaptureModels.mayInferInBackground else { return }
        let request = BGProcessingTaskRequest(identifier: Self.taskIdentifier)
        request.requiresExternalPower = true
        request.requiresNetworkConnectivity = false
        do {
            try BGTaskScheduler.shared.submit(request)
            chargingBlocked = nil
        } catch {
            chargingBlocked = UIApplication.shared.backgroundRefreshStatus != .available
                ? "Background App Refresh is off for Binders" : error.localizedDescription
        }
    }

    /// Why a capture waits rather than being written down now, and when it will be, in a few words: the first thing that
    /// stands in its way, then the way on ("…, so with Binders open or while charging"). The words are CaptureWait's.
    func whyWaiting(_ conversation: some CaptureFacts) -> String {
        let info = ProcessInfo.processInfo
        let device = UIDevice.current
        device.isBatteryMonitoringEnabled = true
        let charging = device.batteryState == .charging || device.batteryState == .full
        return CaptureWait.reason(CaptureWait.Facts(
            inFront: inFront, mayInferInBackground: CaptureModels.mayInferInBackground, appOnly: conversation.appOnly == true,
            writesDownWhileLocked: writesDownWhileLocked, backgroundPaused: backgroundPaused, modelsReady: models.isReadyForBackground,
            staysAlive: appStaysAlive, warm: !(info.thermalState == .nominal || info.thermalState == .fair), lowPowerMode: info.isLowPowerModeEnabled,
            lowBattery: !charging && device.batteryLevel >= 0 && device.batteryLevel < 0.2, long: conversation.speech > 15 * 60,
            chargingBlocked: chargingBlocked))
    }

    /// Why what you say to yourself wouldn't be written down with Binders in the background now, as it would be with it
    /// open: CaptureWait's reason and way on, the same facts as `whyWaiting` without a conversation's own (its length, Write
    /// down while locked). Nil when it would be. Moments that can't be written down as they're heard are let go, kept
    /// nowhere (MomentGate's notWrittenDown), so the capture screen says it before you go (DESIGN 3.13).
    func whyMomentsWait() -> String? {
        if CaptureModels.mayInferInBackground, mayWriteDownOnBatteryNow { return nil }
        let info = ProcessInfo.processInfo
        let device = UIDevice.current
        device.isBatteryMonitoringEnabled = true
        let charging = device.batteryState == .charging || device.batteryState == .full
        return CaptureWait.reason(CaptureWait.Facts(
            inFront: false, mayInferInBackground: CaptureModels.mayInferInBackground, appOnly: false, writesDownWhileLocked: true,
            backgroundPaused: backgroundPaused, modelsReady: models.isReadyForBackground, staysAlive: appStaysAlive,
            warm: !(info.thermalState == .nominal || info.thermalState == .fair), lowPowerMode: info.isLowPowerModeEnabled,
            lowBattery: !charging && device.batteryLevel >= 0 && device.batteryLevel < 0.2, long: false, chargingBlocked: chargingBlocked))
    }

    /// Works through what's waiting, one at a time, then what failed and has tries left, once each. With the app in the
    /// background it carries on only where iOS lets the models run there.
    func processWaiting() {
        guard run == nil else { return }
        run = Task { [weak self] in
            guard let self else { return }
            var tried: Set<UUID> = []
            while !Task.isCancelled, self.mayWriteDownConversationsNow,
                  let next = (self.waiting + self.retryable).first(where: { !tried.contains($0.id) && self.mayTakeOn($0) }) {
                tried.insert(next.id)
                if next.state == .failed {
                    self.retriedThisVisit.insert(next.id)
                    let attempt = (next.failures ?? 1) + 1
                    self.store.update(next.id) { $0.note(CaptureStep.retry, "try \(attempt) of \(CapturedConversation.maxFailures)") }
                }
                // In front, the screen stays on for one that couldn't carry on in the background: Auto-Lock would stop it.
                self.keepScreenOn(self.inFront && !self.couldCarryOn(next))
                let stopped = await self.process(next.id)
                if stopped { break }
            }
            self.keepScreenOn(false)
            self.disarmStoppedNotice()
            self.working = nil
            self.activity = nil
            self.run = nil
            let front = self.inFront
            let restart = front && (self.resumeInFront || Task.isCancelled)
            self.resumeInFront = false
            if restart {
                // Stopped from the background (a step that went wrong there, the charging task out of time) with the app
                // open by now: on with it, in front.
                self.processWaiting()
                return
            }
            // In the background the big models go once the work is done: iOS 27 counts their memory against the app.
            self.unloadIfIdle()
            if self.waiting.isEmpty {
                self.clearReminder()
            } else if !front, !self.inBackgroundTask {
                // Left for the charger or the app: a long one, or the phone couldn't spare it.
                if self.waitingForBackground { self.scheduleBackgroundRun() }
                for left in self.waiting { self.store.update(left.id) { $0.note(CaptureStep.waiting, self.whyWaiting($0)) } }
                self.remindLater()
            }
        }
    }

    /// The app came to the front: what's waiting is written down, failed ones get a try, the reminders go, and the
    /// models are readied for the background.
    func appBecameActive() {
        if cameFromBackground {
            // A new visit, not Control Center or a notification pulled down and back: failed ones get their try, and the
            // pocket may write down again.
            cameFromBackground = false
            retriedThisVisit = []
            backgroundPaused = false
        }
        models.appStateChanged(inFront: true)
        clearReminder()
        disarmStoppedNotice()
        store.tidy(working: working)
        MomentCenter.shared.tidy()
        if let current = run, current.isCancelled {
            // Still stopping from when the app left: start again once it has.
            Task { [weak self] in
                await current.value
                if self?.inFront == true { self?.processWaiting() }
            }
        } else if run != nil, let working {
            // Carrying on in front now: a crash from here counts against it, as for any attempt in front.
            let defaults = UserDefaults.standard
            defaults.removeObject(forKey: Self.backgroundAttemptKey)
            defaults.set(working.uuidString, forKey: Self.attemptKey)
        } else {
            processWaiting()
        }
        if CaptureSession.shared.isOn { prepareForBackground() }
    }

    /// The app left the front. An attempt cut short now isn't the capture's fault. A run carries on in the background only
    /// where it may, and only with a conversation it may take on there; otherwise it stops, and the rest waits.
    func appLeftForeground(toBackground: Bool) {
        UserDefaults.standard.removeObject(forKey: Self.attemptKey)
        guard toBackground else { return }
        cameFromBackground = true
        models.appStateChanged(inFront: false)
        guard let run else {
            // Nothing being written down: the big models go (iOS 27 counts their memory against the app), unless they're
            // being readied or fetched right now; that lets them go when it's done.
            unloadIfIdle()
            return
        }
        let current = working.flatMap { store.entry($0) }
        if !mayWriteDownConversationsNow || current.map({ !mayTakeOn($0) }) == true {
            run.cancel()
        } else if let current {
            UserDefaults.standard.set(current.id.uuidString, forKey: Self.backgroundAttemptKey)
            armStoppedNotice()
        }
    }

    /// Deleted while it's being written down: the work on it stops, it stays deleted, and the rest carry on.
    func forget(_ id: UUID) {
        guard working == id, let current = run else { return }
        current.cancel()
        Task { [weak self] in
            await current.value
            if self?.inFront == true { self?.processWaiting() }
        }
    }

    /// Something that kept Binders running in the background stopped: capture stopped listening (muted, turned off,
    /// interrupted by a call), or the keyboard let go of the microphone. iOS suspending it now isn't a stop: the notice
    /// goes, and work it can't do there any more stops between steps, not held against the conversation.
    func keepAliveChanged() {
        guard !inFront else { return }
        disarmStoppedNotice()
        guard !mayWriteDownConversationsNow, let run else { return }
        run.cancel()
        UserDefaults.standard.removeObject(forKey: Self.backgroundAttemptKey)
    }

    /// Loads Parakeet and the diarizer now, with the app in front, if they haven't been since this version of Binders or
    /// of iOS, so later conversations can be written down in the pocket. Their first load compiles them for the Neural
    /// Engine, a minute or two of heavy work that mustn't happen there. Let go again if the app has left the front.
    func prepareForBackground() {
        guard CaptureModels.mayInferInBackground, inFront, preparing == nil, !models.isReadyForBackground,
              models.isTranscriberDownloaded else { return }
        preparing = Task { [weak self] in
            guard let self else { return }
            _ = await self.models.transcriber()
            // The diarizer's first load is a compile too: only with the app still open. Otherwise it's readied next time.
            if self.inFront { _ = await self.models.speakerLabeller() }
            self.preparing = nil
            self.unloadIfIdle()
        }
    }

    /// The capture screen's Download button: Parakeet is fetched over Wi-Fi and, with the app open, both models are
    /// readied. Fetched with the app gone, Parakeet's first load waits for the app.
    func downloadModels() {
        guard fetching == nil else { return }
        fetching = Task { [weak self] in
            guard let self else { return }
            await self.models.download()
            self.fetching = nil
            self.unloadIfIdle()
        }
    }

    /// In the background, once nothing is written down, readied or fetched, the big models go: iOS 27 counts their memory
    /// against the app. Not while wake-word checks are coming (`keptUntil`).
    private func unloadIfIdle() {
        if !inFront, run == nil, preparing == nil, fetching == nil, Date() >= keptUntil { models.unloadLarge() }
    }

    // MARK: Moments

    /// Telling a conversation's voices apart in the background, with Parakeet unloaded to make room: moments wait it out.
    private var labellingInBackground = false
    /// A wake-word check ran in the background: Parakeet stays loaded until then, for the next one, rather than loading
    /// again for each (a few a minute while you talk). It goes once they stop.
    @ObservationIgnored private var keptUntil = Date.distantPast
    static let keepForChecks: TimeInterval = 30

    /// A moment's words, written down now: by Parakeet when it's on the phone, by Apple's engine with the app open, or
    /// nil when neither can run now. Then it isn't a moment, and the conversation keeps its words, as ever.
    /// `keepingTheModel`: a wake-word check, which keeps Parakeet loaded a little while for the next.
    func writeDownMoment(_ samples: [Float], keepingTheModel: Bool = false) async -> (text: String, engine: String)? {
        guard mayRunNow, !labellingInBackground || inFront, !samples.isEmpty else { return nil }
        if keepingTheModel {
            keptUntil = Date().addingTimeInterval(Self.keepForChecks)
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(Self.keepForChecks + 1))
                self?.unloadIfIdle()
            }
        }
        defer { unloadIfIdle() }
        let version = models.version
        let clip = AudioMath.normalize(samples)
        if models.hasTranscriber, let parakeet = await models.transcriber() {
            var state = TdtDecoderState.make(decoderLayers: await parakeet.decoderLayerCount)
            guard let text = try? await parakeet.transcribe(AudioMath.padded(clip, toAtLeast: 16_000), decoderState: &state, language: nil).text else { return nil }
            return (text.trimmingCharacters(in: .whitespacesAndNewlines), CaptureModels.engineName(version))
        }
        if inFront, #available(iOS 26.0, *), AnalyzerEngine.isSupported, let text = try? await Self.appleTranscribe(clip) {
            return (text.trimmingCharacters(in: .whitespacesAndNewlines), "apple-speech")
        }
        return nil
    }

    /// How much a moment sounds like you, from the voice that spoke most of it (80% or more); nil when that can't be told
    /// now, or two voices share it. The clip is filled to the diarizer's ten-second window with its own speech first
    /// (AudioMath.filledForVoice): padded with silence, as the diarizer would, a 2-5 s clip scores about 0.3 whoever said
    /// it, so nothing said on its own ever got past the voice threshold.
    func voiceScore(_ samples: [Float]) async -> Float? {
        guard mayRunNow, !labellingInBackground || inFront, VoicePrint.isTaught, models.isDiarizerDownloaded, let diarizer = await models.speakerLabeller(),
              let result = try? await diarizer.process(audio: AudioMath.filledForVoice(samples)) else { return nil }
        defer { unloadIfIdle() }
        var spoken: [String: Float] = [:]
        for segment in result.segments { spoken[segment.speakerId, default: 0] += segment.durationSeconds }
        let total = spoken.values.reduce(0, +)
        guard total > 0, let main = spoken.max(by: { $0.value < $1.value }), main.value / total >= 0.8,
              let embedding = result.speakerDatabase?[main.key] else { return nil }
        return VoicePrint.score(embedding)
    }

    private func keepScreenOn(_ on: Bool) {
        UIApplication.shared.isIdleTimerDisabled = on
    }

    private func runInBackground(_ task: BGProcessingTask) async {
        backgroundTask = task
        store.tidy(working: working)
        task.expirationHandler = {
            // Out of time: the run stops between steps (what's done is saved, the rest carries on next time), and the task
            // ends now, even with a model still loading.
            Task { @MainActor in
                let processor = ConversationProcessor.shared
                processor.run?.cancel()
                processor.endBackgroundTask(success: false)
            }
        }
        // A task an earlier version scheduled can still come after an update to iOS 27: then it only sends what's ready.
        if CaptureModels.mayInferInBackground {
            inBackgroundTask = true
            models.mayCompileInBackground = true
            defer {
                inBackgroundTask = false
                models.mayCompileInBackground = false
            }
            // A run stopped on the app's way out is let finish first, so this one starts afresh.
            if let current = run, current.isCancelled { await current.value }
            processWaiting()
            await run?.value
        }
        await connection?.flushOutbox()
        unloadIfIdle()
        if waitingForBackground { scheduleBackgroundRun() }
        endBackgroundTask(success: !waitingForBackground)
    }

    private func endBackgroundTask(success: Bool) {
        guard let task = backgroundTask else { return }
        backgroundTask = nil
        inBackgroundTask = false
        models.mayCompileInBackground = false
        task.setTaskCompleted(success: success)
    }

    // MARK: Telling you

    /// A quiet notification, ten minutes on, that captures are waiting to be written down: at most one an hour, gone
    /// once the app opens or they're written down, and off with Notify me.
    private func remindLater() {
        guard SuggestionCenter.shared.notifies else { return }
        let defaults = UserDefaults.standard
        let last = defaults.object(forKey: "captureRemindedAt") as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > 3_600 else { return }
        defaults.set(Date(), forKey: "captureRemindedAt")
        let content = UNMutableNotificationContent()
        content.body = CaptureModels.mayInferInBackground && waitingForBackground
            ? "Captures are waiting to be written down. Open Binders to write them down now, or they're written down while your iPhone charges."
            : "Captures are waiting to be written down. Open Binders to write them down on this iPhone."
        content.threadIdentifier = Self.reminderIdentifier
        content.interruptionLevel = .passive
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 10 * 60, repeats: false)
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: Self.reminderIdentifier, content: content, trigger: trigger))
    }

    /// The app is open, or nothing's waiting any more: the reminder goes. One taken away before it showed doesn't count
    /// toward the hour.
    func clearReminder() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [Self.reminderIdentifier])
        center.removeDeliveredNotifications(withIdentifiers: [Self.reminderIdentifier])
        let defaults = UserDefaults.standard
        if let at = defaults.object(forKey: "captureRemindedAt") as? Date, Date().timeIntervalSince(at) < 10 * 60 {
            defaults.removeObject(forKey: "captureRemindedAt")
        }
    }

    /// While a conversation is written down in the background, a notice is kept five minutes ahead and pushed back as the
    /// work goes on: if iOS stops Binders there (and All-day capture with it), it shows, so the silence has a reason.
    private func armStoppedNotice() {
        guard CaptureSession.shared.isOn else { return }
        let content = UNMutableNotificationContent()
        content.title = "All-day capture stopped"
        content.body = "iOS stopped Binders while it wrote a conversation down. Open Binders to turn capture back on."
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 5 * 60, repeats: false)
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: Self.stoppedIdentifier, content: content, trigger: trigger))
    }

    private func disarmStoppedNotice() {
        // While capture listens, its own notice takes over: Binders stopping then is still worth a word.
        if CaptureSession.shared.isListening { return CaptureSession.shared.armStoppedNotice() }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [Self.stoppedIdentifier])
    }

    // MARK: After a quit

    /// Conversations a quit or crash left open become recorded, with what reached their file; short ones go, counted with
    /// the day's too short to keep. An attempt that ended Binders with the app in front counts as a failure; one that ended
    /// it in the background leaves that conversation for the app.
    func recover() {
        let defaults = UserDefaults.standard
        if let value = defaults.string(forKey: Self.attemptKey), let id = UUID(uuidString: value) {
            defaults.removeObject(forKey: Self.attemptKey)
            store.update(id) {
                let failures = ($0.failures ?? 0) + 1
                $0.failures = failures
                guard failures >= CapturedConversation.maxFailures else { return }
                if failures == CapturedConversation.maxFailures, $0.state == .labelling, $0.segments?.isEmpty == false {
                    // Written down, and it's telling the voices apart that kept stopping Binders: it goes as one voice,
                    // with the app open, rather than not at all.
                    $0.appOnly = true
                } else {
                    $0.state = .failed
                    $0.error = "Writing it down kept stopping Binders."
                }
            }
        }
        if let value = defaults.string(forKey: Self.backgroundAttemptKey), let id = UUID(uuidString: value) {
            defaults.removeObject(forKey: Self.backgroundAttemptKey)
            store.update(id) {
                $0.appOnly = true
                if $0.state == .transcribing { $0.state = .recorded }
            }
        }
        // What the diarizer was reading when Binders stopped: a full copy of the audio, in the temporary folder.
        let temporary = FileManager.default.temporaryDirectory
        for file in (try? FileManager.default.contentsOfDirectory(at: temporary, includingPropertiesForKeys: nil)) ?? []
        where file.lastPathComponent.hasPrefix("fluidaudio-streaming-") {
            try? FileManager.default.removeItem(at: file)
        }
        for entry in store.conversations where entry.state == .recording {
            // Its spans are in the record, as capture last wrote it.
            guard let conversation = store.conversation(entry.id) else { continue }
            let spans = conversation.spans
            let heard = max(0, spans.fileDuration - 2 * CaptureWorker.padding)
            guard heard >= ConversationSplitter.Settings().minSpeech, let last = spans.spans.last else {
                // Too short to keep, as if the quiet had closed it: its audio goes, and its row says so.
                try? FileManager.default.removeItem(at: CaptureFiles.audioURL(conversation.id))
                store.update(conversation.id) {
                    if let last = spans.spans.last { $0.ended = max($0.started, last.wallStart.addingTimeInterval(last.duration - CaptureWorker.padding)) }
                    $0.speech = heard
                    $0.markTooShort(at: $0.ended)
                }
                continue
            }
            store.update(conversation.id) {
                $0.state = .recorded
                $0.ended = last.wallStart.addingTimeInterval(last.duration - CaptureWorker.padding)
                $0.speech = heard
            }
        }
        store.tidy(working: working)
        requeueLostSends()
        if waitingForBackground { scheduleBackgroundRun() }
    }

    /// Written down and waiting for the Mac, but not in the outbox (its write failed): it goes back in.
    private func requeueLostSends() {
        guard let connection else { return }
        let device = UIDevice.current.model
        for entry in store.conversations where entry.state == .queued && entry.sharedVia == nil
        && !connection.outbox.contains(where: { $0.conversation == entry.id }) {
            guard let payload = store.conversation(entry.id)?.payload(device: device) else { continue }
            Task { await connection.keepConversation(payload) }
        }
    }

    // MARK: One conversation

    private enum Failure: LocalizedError {
        case noModel, unreadable, notNow, tooBusy

        var errorDescription: String? {
            switch self {
            case .noModel: "Waiting for the speech model, which downloads over Wi-Fi."
            case .unreadable: "Its audio couldn't be read."
            case .notNow, .tooBusy: "Waiting for Binders to be open."
            }
        }
    }

    /// True when it had to stop for now (no model yet, out of time, or the background couldn't do it well): the rest wait
    /// too.
    private func process(_ id: UUID) async -> Bool {
        // The whole record, read now, as saved: so a step noted just before (a retry) isn't written over. Gone meanwhile,
        // there's nothing to do.
        guard let conversation = store.conversation(id) else { return false }
        // A record from before failures were counted, already failed, counts once.
        let failedBefore = conversation.failures ?? (conversation.state == .failed ? 1 : 0)
        working = id
        let defaults = UserDefaults.standard
        switch UIApplication.shared.applicationState {
        case .active: defaults.set(id.uuidString, forKey: Self.attemptKey)
        case .background:
            defaults.set(id.uuidString, forKey: Self.backgroundAttemptKey)
            armStoppedNotice()
        // Inactive, on the way to the app switcher, where quitting it isn't the capture's fault: neither.
        default: break
        }
        defer {
            defaults.removeObject(forKey: Self.attemptKey)
            defaults.removeObject(forKey: Self.backgroundAttemptKey)
        }
        do {
            var current = conversation
            if current.segments == nil || current.state != .labelling {
                current.state = .transcribing
                current.error = nil
                current.note(CaptureStep.transcribing, inFront ? "with Binders open" : "in the background")
                store.save(current)
                activity = "Writing down what was said…"
                let began = Date()
                let (segments, engine) = try await transcribe(current)
                // Deleted while it was written down: it stays deleted, and nothing of it goes to the Mac.
                guard store.entry(id) != nil else { return false }
                current.segments = segments
                current.engine = engine
                current.words = segments.reduce(0) { $0 + TextNorm.words($1.text).count }
                current.state = .labelling
                current.note(CaptureStep.transcribed, "\(current.words ?? 0) words · \(engine) · \(Int(Date().timeIntervalSince(began).rounded())) s")
                store.save(current)
            }
            guard current.segments?.isEmpty == false else {
                // No words at all (noise, music, a language the model can't read): not kept, and it says so, without
                // waiting to tell voices apart.
                keepAsNotKept(current, CapturedConversation.nothingToWriteDown)
                return false
            }
            try Task.checkCancellation()
            // Telling the voices apart needs the models too: where they can't run now, or it's too long for the pocket,
            // it waits in labelling with what's written; the next one may still go.
            guard mayWriteDownConversationsNow else { return true }
            guard mayTakeOn(current) else { return false }
            // Set before anything here can throw, so a cancelled wait never leaves moments refused.
            defer { labellingInBackground = false }
            if !inFront {
                // In the background Parakeet, the big model, goes before the diarizer reads the whole conversation (iOS 27
                // counts their memory against the app), and the diarizer, one long step, starts only with plenty of room
                // under iOS's limit. A moment heard meanwhile doesn't bring Parakeet back: it stays in the conversation.
                labellingInBackground = true
                models.unloadTranscriber()
                try await pace(share: 0.25)
            }
            activity = "Telling the voices apart…"
            stepInBackground = !inFront
            let told = try await label(current)
            var segments = told.0, speakers = told.1, facts = told.2
            let labels = told.3
            labellingInBackground = false
            if stepInBackground { budget.note() }
            try Task.checkCancellation()
            guard store.entry(id) != nil else { return false }
            guard !segments.isEmpty else {
                // Nothing to label after all: not kept either.
                keepAsNotKept(current, CapturedConversation.nothingToWriteDown)
                return false
            }
            // Lane Y2: whether it heard only you, on the diarizer's turns for the whole capture (SoloRule), kept with it;
            // in Add at Once and Auto, each segment marked against those turns, so only what your voices said is "You".
            facts.otherAudio = current.otherAudio == true
            facts.call = current.call == true
            facts.continues = current.continues.map { store.conversation($0)?.solo?.isOnlyYou == true }
            let verdict = SoloRule.verdict(facts)
            current.solo = verdict
            let reads = [MomentMode.add.rawValue, MomentMode.auto.rawValue].contains(current.mode ?? "")
            if reads, verdict.isOnlyYou {
                let yours = Set(verdict.yours.keys)
                for id in yours { if let label = labels[id] { speakers[label] = TranscriptSegment.you } }
                for index in segments.indices {
                    let span = SoloRule.Span(start: segments[index].start, end: segments[index].end, words: TextNorm.words(segments[index].text).count)
                    switch SoloRule.mark(span, turns: facts.turns, yours: yours) {
                    case .mixed, .unsure:
                        segments[index].speaker = SoloRule.unsureLabel
                        speakers[SoloRule.unsureLabel] = SoloRule.unsureLabel
                    case .yours, .other: break
                    }
                }
            }
            // The moments said in it whose own span lies inside your voices: the only ones that may go with it.
            let saidInIt = MomentCenter.shared.moments.filter { $0.conversation == current.id && $0.fromTranscript != true }
            var soloMoments = saidInIt.compactMap { moment -> UUID? in
                guard verdict.isOnlyYou, let start = current.spans.fileTime(atWall: moment.heard) else { return nil }
                let span = SoloRule.Span(start: start, end: start + (moment.timings?.seconds ?? 2))
                return SoloRule.mark(span, turns: facts.turns, yours: Set(verdict.yours.keys)) == .yours ? moment.id : nil
            }
            // Kept here too, to read on this iPhone and to share again.
            current.transcript = CaptureTranscript.onTheClock(segments, spans: current.spans, started: current.started, ended: current.ended)
            current.speakers = speakers
            current.segments = nil
            let voices = Set(segments.map(\.speaker)).count
            var labelled = voices <= 1 ? "one voice" : "\(voices) voices\(speakers.values.contains(TranscriptSegment.you) ? ", you among them" : "")"
            if reads { labelled = SoloRule.timeline(verdict, best: facts.scores.values.max()) }
            current.note(CaptureStep.labelled, labelled)
            // Kept, though short, for a moment said in it (lane Y2): its vouch goes, and none of its words, here or there.
            let keptForMoment = current.keptForMoment == true
            if keptForMoment { current.transcript = nil }
            guard let payload = keptForMoment
                ? ConversationPayload(id: current.id, started: current.started, ended: current.ended, segments: [], device: UIDevice.current.model,
                                      engine: current.engine ?? "")
                : current.payload(device: UIDevice.current.model) else {
                keepAsNotKept(current, CapturedConversation.nothingToWriteDown)
                return false
            }
            // "Binders, …" you said in it that wasn't heard as you said it: a moment now.
            if !keptForMoment { soloMoments += MomentCenter.shared.transcribed(current) }
            activity = "Sending…"
            current.state = .queued
            current.note(CaptureStep.queued)
            store.save(current)
            // Into the outbox, and on to the next: sending (and its wait for a Mac that may be asleep) happens beside this.
            connection?.queueConversation(payload, solo: reads ? SoloSend(verdict: verdict, mode: current.mode, moments: soloMoments,
                                                                         keptForMoment: keptForMoment) : nil)
            // The text is safe in the outbox now: the audio can go. With a hub that writes down audio, it goes to the hub
            // first, with the voices told apart here and where each stretch of the file was heard; HubAudio lets it go once
            // the hub has it. Never for one kept only for a moment's vouch: none of its words go anywhere.
            if !keptForMoment, connection?.hubWritesDown == true {
                let started = current.started
                HubAudio.shared.queue(HubAudio.Pending(
                    id: id, started: started, ended: current.ended, device: UIDevice.current.model,
                    turns: segments.map { HubAudio.Turn(start: $0.start, end: $0.end, speaker: $0.speaker) }, speakers: speakers,
                    clock: current.spans.spans.map { HubAudio.Clock(file: $0.fileStart, wall: $0.wallStart.timeIntervalSince(started)) },
                    keepAudio: keepsAudio))
                if keepsAudio { store.update(id) { $0.keepAudioUntil = Date().addingTimeInterval(86_400) } }
            } else if keepsAudio {
                store.update(id) { $0.keepAudioUntil = Date().addingTimeInterval(86_400) }
            } else {
                store.deleteAudio(id)
            }
            return false
        } catch is CancellationError {
            store.update(id) {
                if $0.state == .transcribing { $0.state = .recorded }
                $0.note(CaptureStep.waiting, "stopped between steps")
            }
            return true
        } catch Failure.unreadable {
            // Reading it again won't help, so its audio goes now.
            store.update(id) {
                $0.state = .failed
                $0.error = Failure.unreadable.localizedDescription
                $0.failures = CapturedConversation.maxFailures
                $0.note(CaptureStep.failed, Failure.unreadable.localizedDescription)
            }
            letGoOfFailedAudio(id)
            return false
        } catch Failure.noModel {
            store.update(id) {
                $0.state = .recorded
                $0.error = Failure.noModel.localizedDescription
                $0.note(CaptureStep.waiting, Failure.noModel.localizedDescription)
            }
            return true
        } catch Failure.notNow {
            waitForTheApp(id)
            return true
        } catch Failure.tooBusy {
            // Binders is busier in the background than it should be: this one waits, as it is, for the app or the charger,
            // and nothing more is tried in the pocket until the app is next open.
            store.update(id) {
                if $0.state == .transcribing { $0.state = .recorded }
                $0.note(CaptureStep.waiting, "Binders was busier in the background than it should be, so with Binders open or while charging")
            }
            backgroundPaused = true
            return true
        } catch {
            if !inFront || stepInBackground {
                waitForTheApp(id)
                return true
            }
            store.update(id) {
                $0.state = .failed
                $0.error = error.localizedDescription
                $0.failures = failedBefore + 1
                $0.note(CaptureStep.failed, error.localizedDescription)
            }
            // With no tries left, its audio goes now rather than three days after it was heard.
            letGoOfFailedAudio(id)
            retriedThisVisit.insert(id)
            return false
        }
    }

    /// Written down to nothing (noise, music, a language the speech model can't read): not kept. Its row stays, with its
    /// timeline, until it expires like any other; its audio goes (kept a day for the developer setting); and it counts
    /// with the day's numbers, as "Nothing to write down".
    private func keepAsNotKept(_ conversation: CapturedConversation, _ reason: String) {
        var current = conversation
        current.markNotKept(reason)
        store.save(current)
        if keepsAudio {
            store.update(current.id) { $0.keepAudioUntil = Date().addingTimeInterval(86_400) }
        } else {
            store.deleteAudio(current.id)
        }
    }

    /// A failed conversation with no tries left keeps its audio no longer.
    private func letGoOfFailedAudio(_ id: UUID) {
        if store.entry(id)?.failedAudioDue(at: Date()) == true { store.deleteAudio(id) }
    }

    /// Something went wrong writing this one down in the background (iOS refusing the models there, say). That's no
    /// failure: it waits for the app, which writes it down as it would in front, and nothing more is tried in the pocket
    /// until the app is next open, so a refusal can't run through the rest. With the app open again already, that's now.
    private func waitForTheApp(_ id: UUID) {
        store.update(id) {
            if $0.state == .transcribing { $0.state = .recorded }
            $0.error = nil
            $0.appOnly = true
            $0.note(CaptureStep.waiting, "something went wrong in the background, so with Binders open")
        }
        backgroundPaused = true
        if inFront { resumeInFront = true }
    }

    /// In the background, outside the charging task: waits until the last minute used no more than `share` of a core, so
    /// the app stays well under what iOS allows there, keeping the stopped notice ahead meanwhile. It stops, keeping
    /// what's done, once the pocket may no longer write down: capture stopped listening, the battery ran low, the phone
    /// got hot. Three minutes without room means Binders is busier than it should be: then it waits for the app or the
    /// charger.
    private func pace(share: Double) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 180
        while !inFront, !inBackgroundTask {
            guard mayWriteDownConversationsNow else { throw CancellationError() }
            if budget.hasRoom(share: share) { break }
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw Failure.tooBusy }
            armStoppedNotice()
            try await Task.sleep(for: .seconds(2))
        }
        if !inFront { armStoppedNotice() }
    }

    // MARK: Transcribing

    /// What was said, in segments cut at pauses, with times in the audio file. In the background only Parakeet writes
    /// it down, paced so the app stays well under what iOS allows there; anything else waits for the app.
    private func transcribe(_ conversation: CapturedConversation) async throws -> ([TranscriptSegment], String) {
        let url = CaptureFiles.audioURL(conversation.id)
        guard let file = try? AVAudioFile(forReading: url) else { throw Failure.unreadable }
        let engine: String
        let write: ([Float]) async throws -> String
        let appleEngine: Bool
        stepInBackground = !inFront
        // Read with the call, so the name is the model's even if the language changes meanwhile.
        let version = models.version
        // Never waits on the first download (about 500 MB): that goes on by itself, in front on Wi-Fi, and Apple's engine
        // writes this one down meanwhile.
        let here = models.hasTranscriber
        if !here, inFront, models.onWiFi, !models.downloading { Task { await models.download() } }
        if here, let parakeet = await models.transcriber() {
            engine = CaptureModels.engineName(version)
            appleEngine = false
            write = { samples in
                var state = TdtDecoderState.make(decoderLayers: await parakeet.decoderLayerCount)
                return try await parakeet.transcribe(AudioMath.padded(samples, toAtLeast: 16_000), decoderState: &state, language: nil).text
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } else if !inFront || stepInBackground {
            // Not on the phone yet: it waits for the download. Here but not loading in the background: Apple's engine
            // would write it down differently, so it waits for the app.
            throw models.isTranscriberDownloaded ? Failure.notNow : Failure.noModel
        } else if #available(iOS 26.0, *), AnalyzerEngine.isSupported {
            // Until Parakeet is here: Apple's own engine, also on the device.
            engine = "apple-speech"
            appleEngine = true
            write = { samples in try await Self.appleTranscribe(samples) }
        } else {
            throw Failure.noModel
        }

        var segments: [TranscriptSegment] = []
        var position: AVAudioFramePosition = 0
        var warmedUp = false
        while position < file.length {
            try Task.checkCancellation()
            try await pace(share: 0.4)
            stepInBackground = !inFront
            // Apple's engine stands in only with the app open: in the background this one waits, as it is, for the app.
            if appleEngine, stepInBackground { throw CancellationError() }
            let window = try Self.read(file, from: position, frames: 30 * 16_000)
            guard !window.isEmpty else { break }
            let length = max(1, SpeechChunker.nextBoundary(window[...], isFinal: true) ?? window.count)
            let chunk = Array(window.prefix(length))
            if !AudioMath.isSilent(chunk) {
                let before = CPUBudget.processTime
                let text = try await write(AudioMath.normalize(chunk))
                // A window this costly in the pocket means the work isn't on the Neural Engine: it waits for the app. (Not
                // the first, which carries the model's warm-up.)
                if stepInBackground, !inBackgroundTask, warmedUp, CPUBudget.processTime - before > 4 { throw Failure.notNow }
                warmedUp = true
                if stepInBackground { budget.note() }
                if !text.isEmpty {
                    let start = Double(position) / 16_000
                    segments.append(TranscriptSegment(channel: .microphone, start: start, end: start + Double(chunk.count) / 16_000,
                                                      text: text, speaker: CaptureTranscript.unlabelled))
                }
            }
            position += AVAudioFramePosition(length)
        }
        return (segments, engine)
    }

    nonisolated static func read(_ file: AVAudioFile, from position: AVAudioFramePosition, frames: Int) throws -> [Float] {
        file.framePosition = position
        let count = AVAudioFrameCount(min(Int64(frames), file.length - position))
        guard count > 0, let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count) else { return [] }
        try file.read(into: buffer, frameCount: count)
        guard let channel = buffer.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }

    @available(iOS 26.0, *)
    private static func appleTranscribe(_ samples: [Float]) async throws -> String {
        let engine = AnalyzerEngine()
        try await engine.prepare()
        if let buffer = AVAudioPCMBuffer(pcmFormat: SixteenKilohertz.format, frameCapacity: AVAudioFrameCount(samples.count)),
           let channel = buffer.floatChannelData?[0] {
            samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
            buffer.frameLength = AVAudioFrameCount(samples.count)
            engine.append(buffer)
        }
        return try await engine.finish()
    }

    // MARK: Speakers

    /// Each segment gets the voice it overlaps most, "Speaker 1", "Speaker 2"… in the order they first speak; the one
    /// that sounds like the voice you taught Binders is "You". In front, a diarizer that's missing or fails leaves one
    /// voice, as before; in the background it throws instead, so the conversation waits for the app rather than going as
    /// one voice. Only "no speech found" means one voice anywhere.
    /// Lane Y2: also the facts "only you" is decided on (SoloRule.Facts, which `process` completes), and which label each
    /// diarizer id became.
    private func label(_ conversation: CapturedConversation) async throws
        -> ([TranscriptSegment], [String: String], SoloRule.Facts, [String: String]) {
        let segments = conversation.segments ?? []
        var facts = SoloRule.Facts(diarizer: .missing, turns: [], scores: [:], printTaught: VoicePrint.isTaught,
                                   startBar: VoicePrint.startThreshold.map(Double.init),
                                   segments: segments.map { SoloRule.Span(start: $0.start, end: $0.end, words: TextNorm.words($0.text).count) })
        guard !segments.isEmpty else { return ([], [:], facts, [:]) }
        var turns: [SpeakerTurn] = []
        var voices: [String: [Float]] = [:]
        if (conversation.failures ?? 0) >= CapturedConversation.maxFailures {
            // Telling the voices apart kept stopping Binders: one voice, rather than nothing (recover() leaves these for
            // the app).
            facts.diarizer = .skipped
        } else if let diarizer = await models.speakerLabeller() {
            do {
                let result = try await diarizer.process(CaptureFiles.audioURL(conversation.id))
                turns = result.segments.map { SpeakerTurn(speakerID: $0.speakerId, start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds)) }
                voices = result.speakerDatabase ?? [:]
                facts.diarizer = .ran
            } catch OfflineDiarizationError.noSpeechDetected {
                // Nothing to tell apart: one voice.
                facts.diarizer = .noSpeech
            } catch {
                if error is CancellationError || Task.isCancelled || !inFront || stepInBackground { throw error }
                // In front: one voice, as before.
                facts.diarizer = .failed
            }
        } else if !inFront || stepInBackground {
            // Not on the phone yet (it downloads over Wi-Fi): it waits as it is. Here but not loading in the background:
            // it waits for the app.
            if !models.isDiarizerDownloaded { throw CancellationError() }
            throw Failure.notNow
        }
        let (labelled, labels) = CaptureTranscript.label(segments, turns: turns)
        var speakers: [String: String] = [:]
        if let you = VoicePrint.closest(among: voices), let label = labels[you] { speakers[label] = TranscriptSegment.you }
        facts.turns = turns
        facts.scores = voices.compactMapValues { VoicePrint.score($0).map(Double.init) }
        return (labelled, speakers, facts, labels)
    }

    // MARK: Trying it out

    /// Debug builds: runs the whole pipeline on a recording that ships with the app, for the Simulator, which can't listen.
    func processSample() {
        guard let sample = Bundle.main.url(forResource: "capture-sample", withExtension: "caf"),
              let file = try? AVAudioFile(forReading: sample) else { return }
        let id = UUID()
        let seconds = Double(file.length) / file.processingFormat.sampleRate
        let started = Date().addingTimeInterval(-seconds)
        try? FileManager.default.copyItem(at: sample, to: CaptureFiles.audioURL(id))
        var spans = CaptureSpans()
        spans.append(wallStart: started, duration: seconds)
        store.save(CapturedConversation(id: id, started: started, ended: Date(), speech: seconds, state: .recorded, spans: spans))
        processWaiting()
    }
}

/// Measured CPU time, so work in the background stays well under what iOS allows an app there (about 80% of a core over
/// a minute, beyond which it stops the app).
struct CPUBudget {
    private var samples: [(wall: TimeInterval, cpu: TimeInterval)] = []

    /// This process's CPU time so far, all threads, in seconds.
    static var processTime: TimeInterval {
        var time = timespec()
        clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &time)
        return TimeInterval(time.tv_sec) + TimeInterval(time.tv_nsec) / 1_000_000_000
    }

    /// Whether the last minute, as far as it was measured, used no more than `share` of a core. The oldest reading kept
    /// is the newest from a minute or more ago, so a long step just before (the diarizer) still counts.
    mutating func hasRoom(share: Double) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        let cpu = Self.processTime
        // Nothing measured for a while, not even a step ending: what was says nothing about the last minute.
        if let last = samples.last, now - last.wall > 90 { samples.removeAll() }
        record(now, cpu)
        guard let first = samples.first, now - first.wall >= 5 else { return true }
        return (cpu - first.cpu) / (now - first.wall) <= share
    }

    /// A reading as a step ends, so the next check measures across the step, however long it took.
    mutating func note() {
        record(ProcessInfo.processInfo.systemUptime, Self.processTime)
    }

    private mutating func record(_ now: TimeInterval, _ cpu: TimeInterval) {
        samples.append((now, cpu))
        while samples.count > 1, now - samples[1].wall >= 60 { samples.removeFirst() }
    }
}
