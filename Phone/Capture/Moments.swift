import AVFoundation
import BindersKit
import CryptoKit
import Foundation
import Observation
import UIKit
import UserNotifications

/// Something you said to yourself near the iPhone, a moment, as this iPhone keeps it: the words (never the audio), and
/// what your Mac made of them. Only `id` and `heard` are required, and the state is a word, so a newer build's records
/// never stop an older build reading these.
struct CapturedMoment: Codable, Identifiable, Equatable {
    let id: UUID
    var heard: Date
    /// kept (waiting for the Mac), sent, refused.
    var state: String?
    var text: String?
    var wake: Bool?
    var cue: String?
    var engine: String?
    /// What the Mac made of it: the line, its state word, the Lock Screen title and what can be done now.
    var outcome: String?
    var outcomeState: String?
    var title: String?
    var actions: [String]?
    var agent: String?
    /// How long it took: this iPhone's part, then the Mac's from its outcome. Numbers only.
    var timings: MomentTimings?
    /// Found in a conversation's transcript once it was written down, rather than heard as it was said.
    var fromTranscript: Bool?
    /// From its outcome: what it made, for Open (a card's id; a to-do's, as list_todos gives it), its binder, what it was
    /// read as (MomentKind), and an answer's sources.
    var card: String?
    var todo: String?
    var binder: String?
    var kind: String?
    var sources: [String]?
    /// When you said its answer wasn't right, and when you asked it again since.
    var notRight: Date?
    var askedAgain: Date?
    /// Heard on its own: how alike the voice was to your print, and what Apple's model on this iPhone read it as, when it
    /// was asked and agreed (MomentGate). Numbers and a kind, never more words.
    var voice: Double?
    var checked: String?
    /// When you said it wasn't you ("Not me").
    var notMe: Date?
    /// The mode for what you say on your own when it was heard (MomentMode's word); nil before the modes, and for Siri's
    /// and a transcript's.
    var mode: String?
    /// From its outcome: "auto" or "start" when Binders handed its card over without asking (CaptureOutcome.handedOver);
    /// "wake" or "give" when it waits on you (`waiting`); and whether it reached the Mac late, so the iPhone says when it
    /// was said (`late`).
    var handedOver: String?
    var waiting: String?
    var late: Bool?
    /// When the Mac decided it: what was said yesterday and handed over today is listed today.
    var decided: Date?
    /// Lane Y2, Optional as above: the conversation it was heard in; the capture it was read from (one of a capture's
    /// items, whose own outcome never rings: its capture's notification covers it); and the capture it waits for (said in
    /// one in Auto, it goes with it if only you spoke in it).
    var conversation: UUID?
    var capture: UUID?
    var joins: UUID?

    /// Binders handed its card to an agent without asking, and Stop can still reach it.
    var isHandedOver: Bool { handedOver != nil && outcomeState == "acted" && (actions ?? []).contains("stop") }

    /// Heard in Auto.
    var heardInAuto: Bool { mode == MomentMode.auto.rawValue }

    /// It waits on you elsewhere than Add and Not Now: a card made ready and not woken (Wake Now on your Mac), or one held
    /// back with Give to. Amber, and in Needs you.
    var isHeldForYou: Bool {
        outcomeState == "acted" && notMe == nil && (waiting == CaptureOutcome.Waiting.wake || waiting == CaptureOutcome.Waiting.give)
            && (actions ?? []).contains(where: { $0 == "assign" || $0 == "stop" })
    }

    /// An answer, or "Nothing in your binders about …": what Not Right is for.
    var isAnswer: Bool {
        (outcomeState == "answered" || outcomeState == "nothing") && !(outcome ?? "").isEmpty
    }

    /// Heard on its own, through the four checks, rather than said with "Binders, …", told to Siri or found in a
    /// transcript: what graduation counts, and what Not Me is for.
    var isHeardOnItsOwn: Bool { wake != true && engine != "siri" && fromTranscript != true && capture == nil }

    /// Not Me can still be said of it: heard on its own, or handed to an agent without a tap ("Binders, …" too: in Auto it
    /// went at Auto's bar), with what the Mac made of it, and not said already.
    var mayBeNotMe: Bool {
        (isHeardOnItsOwn || handedOver != nil) && notMe == nil
            && ["offered", "acted", "dismissed", "undone", "answered", "nothing"].contains(outcomeState ?? "")
    }

    /// Marked not right and not asked again: it stays on the capture screen until it is.
    var isToAskAgain: Bool { notRight != nil && askedAgain == nil }

    /// What the Mac made of it as the iPhone shows it: an answer without the titles of its sources after it, nor its
    /// [1]-style marks.
    var shownOutcome: String {
        let line = CaptureOutcome(id: id, state: outcomeState ?? "", line: outcome ?? "", sources: sources).spoken
        // Reached the Mac late: when it was said, by this iPhone's clock and time zone (the Mac's lines hold no time).
        guard late == true, !line.isEmpty else { return line }
        return AutoText.joined(line, AutoText.youSaidIt(heard, now: Date()))
    }

    /// Offered with Add and Not Now ("Add to Personal?"), and not answered yet: it waits on you, in Needs you too. Not once
    /// you've said it wasn't you, though your Mac hasn't heard yet.
    var waitsOnYou: Bool { outcomeState == "offered" && (actions.map { $0.contains("add") } ?? true) && notMe == nil }

    /// What its row says under your words: what the Mac made of it, or why it waits and what comes next (MomentWait),
    /// never a bare "Working on it".
    var line: String {
        if let wait = MomentWait.line(state: state, outcome: outcomeState) { return wait }
        if outcomeState == nil, state == "refused" { return "\(MacConnection.BrainWords) couldn't read it." }
        return shownOutcome
    }

    /// The binder its to-do, card or note went into, once your Mac acted on it: for the chip beside it.
    var filedIn: String? {
        guard outcomeState == "acted", let binder, !binder.isEmpty else { return nil }
        return binder
    }
}

/// Things you say to yourself while All-day capture listens. Each short thing said on its own is written down here; it's
/// kept only when it starts with "Binders", or when it passes four checks: a cue ("I need to…", "don't forget…"), your
/// voice, the quiet around it (the detector's), and Apple's on-device model agreeing what kind of thing it is, where this
/// iPhone has one. Said in a conversation, it's kept only when it starts with "Binders": a quick check of its first second
/// and a half says, a few times a minute at most, and a conversation's transcript is looked through again once it's
/// written down. Only the words go to your Mac, which says what it made of them: added, with Undo, or offered, with Add
/// and Not Now, or answered. A kind you've added nearly every time is added at once with Undo too (MomentGraduation).
/// Nothing is kept of the rest.
@MainActor
@Observable
final class MomentCenter {
    static let shared = MomentCenter()

    /// Listening for moments at all. Off until you turn it on.
    var isOn: Bool {
        didSet {
            UserDefaults.standard.set(isOn, forKey: "captureMoments")
            CaptureSession.shared.momentsChanged()
        }
    }
    private(set) var moments: [CapturedMoment] = []
    /// Per kind (to-do, idea, note): offered, or added at once with Undo once you've said yes to it often enough, from your
    /// taps on what was heard on its own. Verdicts only, never words.
    private(set) var graduation = MomentCenter.loadGraduation()
    @ObservationIgnored weak var connection: MacConnection?
    /// Write-downs in the last ten minutes: past 20 (a TV, a podcast), moments rest for ten minutes.
    @ObservationIgnored private var recent: [Date] = []
    @ObservationIgnored private var restingUntil = Date.distantPast

    static let offerCategory = "moment-offer"
    /// An offer on something you asked for ("Binders, find out when…", nothing answering it): no Not Me.
    static let askedOfferCategory = "moment-offer-asked"
    /// Done, with Give to for an agent that has no category of its own (`giveCategory`).
    static let doneCategory = "moment-done"
    static let undoCategory = "moment-undo-only"
    static let answerCategory = "moment-answer"
    /// A word about one: it couldn't be done, or it waits for your Mac.
    static let noteCategory = "moment-note"
    static let add = "moment-add"
    static let notNow = "moment-not-now"
    static let undo = "moment-undo"
    static let assign = "moment-assign"
    static let open = "moment-open"
    static let notRight = "moment-not-right"
    static let notMe = "moment-not-me"
    /// Binders handed its card to an agent without asking: Stop, Undo, Not Me and Open. A walk's worth shares a thread.
    static let handedCategory = "moment-handed"
    static let handedThread = "moment-handed"
    /// Lane Y2: a capture's hand-overs, in one notification, with Open and Stop All.
    static let captureHandedCategory = "capture-handed"
    static let stopAll = "capture-stop-all"
    static let stop = "moment-stop"
    /// Auto turned itself off, or can hand things over now: opens the capture screen (and the sheet, for the second).
    static let autoCategory = "moment-auto"
    /// A kind now added at once with Undo, or offered again: opens the capture screen, where it can be switched back.
    static let kindsCategory = "moment-kinds"
    /// What a Give to says when your Mac is out of reach.
    static var keptForMac: String { "Kept. It goes to \(MacConnection.brainWords) when it's back." }

    /// A moment whose "Give to an Agent" was tapped in its notification before you'd said yes to that agent: its row
    /// asks, once the capture screen opens.
    var consenting: UUID?

    // MARK: The mode

    /// What Binders does with what it hears you say on your own: Suggest (the default), Add at Once, or Auto. Kept as
    /// `momentMode`, where the link reads it too as it sends what's waiting (MacConnection.momentAsSent). Auto is chosen
    /// through its sheet (`useAuto`), never set here directly by the menu.
    private(set) var mode: MomentMode {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: "momentMode")
            // The capture open now goes as the lower mode (lane Y2).
            if mode != oldValue { CaptureSession.shared.momentsChanged() }
        }
    }
    /// The mode Turn Off Auto goes back to, kept as Auto is chosen.
    private var modeBeforeAuto: MomentMode {
        get { MomentMode(stored: UserDefaults.standard.string(forKey: "momentModeBeforeAuto")) }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "momentModeBeforeAuto") }
    }
    /// The sheet has listed which agents may take what you say (it can with a Mac that lists MomentPayload.autoFeature).
    /// Until then Auto goes as Add at Once.
    private(set) var autoListed: Bool {
        didSet { UserDefaults.standard.set(autoListed, forKey: "momentAutoListed") }
    }
    /// Lane Y2: the sheet has been seen with what Auto now reads, what you think out loud, with a Mac that lists
    /// ConversationPayload.soloFeature (`soloAutoListed`). Until then a capture in Auto carries none of Y2's fields, and
    /// nothing said without a cue is kept.
    private(set) var soloListed: Bool {
        didSet { UserDefaults.standard.set(soloListed, forKey: Self.soloAutoListedKey) }
    }
    static let soloAutoListedKey = "soloAutoListed"
    /// Auto's own drop-back: two Not me's among its last ten hand-overs turn it off.
    @ObservationIgnored private var autoWatch: AutoWatch
    /// When the last hand-over's notification went: one within AutoRules.quietWithin comes quietly.
    @ObservationIgnored private var lastHandedNotice = Date.distantPast
    /// Clips let go today as they couldn't be written down (with Binders in the background): dates only.
    private(set) var notWrittenDown: [Date]
    /// Set by a "Auto can hand things over now" notification: the capture screen opens the sheet.
    var showingAutoSheet = false

    private init() {
        isOn = UserDefaults.standard.bool(forKey: "captureMoments")
        mode = MomentMode(stored: UserDefaults.standard.string(forKey: "momentMode"))
        autoListed = UserDefaults.standard.bool(forKey: "momentAutoListed")
        soloListed = UserDefaults.standard.bool(forKey: Self.soloAutoListedKey)
        autoWatch = UserDefaults.standard.data(forKey: "autoWatch").flatMap { try? JSONDecoder().decode(AutoWatch.self, from: $0) } ?? AutoWatch()
        notWrittenDown = (UserDefaults.standard.array(forKey: "momentsNotWrittenDown") as? [Date] ?? [])
            .filter { Calendar.current.isDateInToday($0) }
        moments = Self.loadAll()
    }

    /// The mode before Auto, which Turn Off Auto goes back to (Suggest if there was none).
    var modeAfterAuto: MomentMode { modeBeforeAuto == .auto ? .suggest : modeBeforeAuto }

    /// Suggest or Add at Once, chosen in the Mode menu: at once. Auto goes through its sheet.
    func choose(_ chosen: MomentMode) {
        guard chosen != .auto else { return }
        mode = chosen
    }

    /// The sheet's Use Auto: the mode before is kept for Turn Off Auto, Auto's count starts afresh, and `listed` says
    /// whether the sheet showed which agents may take what you say (until it has, Auto goes as Add at Once).
    /// `soloListed` (lane Y2): it also showed what Auto reads of what you think out loud, with a Mac that reads it.
    func useAuto(listed: Bool, soloListed: Bool = false) {
        if mode != .auto { modeBeforeAuto = mode }
        mode = .auto
        autoListed = listed
        if soloListed { self.soloListed = true }
        autoWatch.reset()
        saveAutoWatch()
    }

    /// Turn Off Auto, on a hand-over's page or in the Mode menu: back to the mode before it, at once. What's still waiting
    /// for the Mac goes as that mode (MacConnection.momentAsSent).
    @discardableResult
    func turnOffAuto() -> MomentMode {
        let back = modeAfterAuto
        if mode == .auto { mode = back }
        // Lane Y2: a capture already on the Mac but not yet read goes as that mode too.
        lowerCapturesOnTheMac(to: back)
        return back
    }

    /// What a moment goes as now, for one heard at this moment: Auto only once the sheet has listed the agents.
    private var modeToSend: MomentMode { mode == .auto && !autoListed ? .add : mode }

    /// Lane Y2: Auto reads what you think out loud now, to this Mac: Auto with both sheets seen, to a Mac that lists
    /// ConversationPayload.soloFeature. Then a capture carries its vouch, a sentence without a cue may be kept, and a
    /// moment said in a capture waits for it.
    var soloAutoNow: Bool {
        mode == .auto && autoListed && soloListed && (connection?.macFeatures.contains(ConversationPayload.soloFeature) ?? false)
    }

    /// The mode a capture opening now is stamped with (CaptureWorker.useMode): nil while Said to yourself is off.
    var captureMode: String? { isListening ? mode.rawValue : nil }

    private func saveAutoWatch() {
        if let data = try? JSONEncoder().encode(autoWatch) { UserDefaults.standard.set(data, forKey: "autoWatch") }
    }

    /// A clip that couldn't be written down: counted for today's line on the capture screen.
    private func letGoUnwritten(_ now: Date = Date()) {
        notWrittenDown = notWrittenDown.filter { Calendar.current.isDateInToday($0) } + [now]
        UserDefaults.standard.set(notWrittenDown, forKey: "momentsNotWrittenDown")
    }

    /// Today's count of things said that weren't written down.
    var notWrittenDownToday: Int { notWrittenDown.filter { Calendar.current.isDateInToday($0) }.count }

    /// The Mac's features at a hello: when it first lists MomentPayload.autoFeature with Auto chosen and the sheet not
    /// seen with its lists, a notification says Auto can hand things over now, and opens the sheet. Once.
    func macFeaturesChanged(from before: Set<String>, to now: Set<String>) {
        // Lane Y2: the Mac first reads what you think out loud: once, in Auto (opening the sheet) or in Add at Once.
        if !before.contains(ConversationPayload.soloFeature), now.contains(ConversationPayload.soloFeature),
           !UserDefaults.standard.bool(forKey: "soloAutoAnnounced"), mode == .auto || mode == .add {
            UserDefaults.standard.set(true, forKey: "soloAutoAnnounced")
            Self.tell(mode == .auto ? AutoPhoneText.soloNowInAuto : AutoPhoneText.soloNowInAdd, id: "moment-solo-listed", sheet: mode == .auto)
        }
        guard !before.contains(MomentPayload.autoFeature), now.contains(MomentPayload.autoFeature), mode == .auto, !autoListed,
              !UserDefaults.standard.bool(forKey: "momentAutoAnnounced") else { return }
        UserDefaults.standard.set(true, forKey: "momentAutoAnnounced")
        Self.tell(AutoText.canHandOverNow, id: "moment-auto-listed", sheet: true)
    }

    /// Agents you've said yes to giving cards to, here or on a card, after being told what goes with a card and where
    /// (App Store 5.1.2(i)): asked once for each, as it's set up now (`AgentConsents`).
    static func agreed(to agent: String) -> Bool { AgentConsents.agreed(toName: agent) }

    static func agree(to agent: String) { AgentConsents.agree(toName: agent) }

    /// Moments run only with them on and a Mac that reads them; until then nothing is gathered.
    var isListening: Bool { isOn && (connection?.takesMoments ?? false) }

    /// Today's, newest first: heard today, or decided today though heard earlier (late words), or handed to an agent and
    /// still with Stop among its actions, so what Auto handed over at 7 AM from 9 PM's words shows with its Stop.
    /// A capture's items are listed under their capture, not here (lane Y2).
    func today(now: Date = Date()) -> [CapturedMoment] {
        moments.filter { Self.isToday($0, now: now) && $0.capture == nil }.sorted { $0.heard > $1.heard }
    }

    private static func isToday(_ moment: CapturedMoment, now: Date) -> Bool {
        Calendar.current.isDate(moment.heard, inSameDayAs: now) || moment.decided.map { Calendar.current.isDate($0, inSameDayAs: now) } == true
            || moment.isHandedOver
    }

    // MARK: Hearing

    /// Something short, said on its own: written down, and kept or let go.
    func heard(_ clip: CaptureWorker.MomentClip) {
        Task { await decide(clip) }
    }

    private func decide(_ clip: CaptureWorker.MomentClip) async {
        let now = Date()
        recent = recent.filter { now.timeIntervalSince($0) < 600 }
        guard isListening, now > restingUntil else { return settle(clip.id, kept: false) }
        let run = await gate(clip) {
            // The wake-word check is cheap, and a few a minute at most, so it doesn't count towards the write-downs.
            if recent.count >= 20 {
                restingUntil = now.addingTimeInterval(600)
                return false
            }
            recent.append(now)
            return true
        }
        guard run.isMoment, let written = run.written else {
            // Let go, kept nowhere, as the phone couldn't spare the work in the background: counted for today's line.
            if run.failures.first == .notWrittenDown { letGoUnwritten(now) }
            return settle(clip.id, kept: false, why: run.why, in: clip.conversation)
        }
        // Kept, it takes its set-aside conversation's words; and whether it's still said on its own is asked now, after the
        // gate, as a moment just before it that wasn't kept gives its words back to a conversation.
        let stillAlone = clip.alone ? await CaptureSession.shared.keepMoment(clip.id) : false
        // Lane Y2: said in a conversation while Auto reads what you think out loud, it waits for that capture, which is
        // kept however short, for its vouch.
        let joins = !clip.alone && soloAutoNow ? clip.conversation : nil
        if !clip.alone { settle(clip.id, kept: true, joins: joins) }
        let words = run.words ?? written.text
        let seconds = clip.ended.timeIntervalSince(clip.started)
        let chosen = mode, sending = modeToSend
        let moment = CapturedMoment(id: clip.id, heard: clip.started, state: "kept", text: words, wake: run.wake, cue: run.cue, engine: written.engine,
                                    timings: MomentTimings(heard: clip.started, seconds: seconds, asrMillis: run.asrMillis),
                                    voice: run.voice.map(Double.init), checked: run.checked?.rawValue, mode: chosen.rawValue,
                                    conversation: clip.conversation, joins: joins)
        save(moment)
        let features = connection?.macFeatures ?? []
        let autoMac = features.contains(MomentPayload.autoFeature)
        // Said on its own, it took the words of the conversation that opened at its first word (CaptureWorker.hand), and
        // nothing no kept moment holds was said in the three minutes before it: a Mac that hands over in Auto reads it as
        // said on its own; every Mac keeps the conversation's id, so an older one reads the moment exactly as before.
        let alone = clip.alone && stillAlone && autoMac
        let conversation = alone ? nil : clip.conversation
        // A "Binders, …" said on its own, or in Auto anything heard on its own, to a Mac that may start or hand over from
        // it: its voice is scored against the start bar, and the yes you've given here goes with it when every condition
        // holds (MomentAgreement decides). In Auto, why it didn't go with it goes instead (`autoHold`).
        var voice = run.voice
        var agreed: [String: String]?
        var hold: String?
        let asks = run.wake || sending == .auto
        if asks, clip.checkFirst == nil, conversation == nil, features.contains(MomentPayload.agreedFeature), VoicePrint.isTaught {
            let bar = VoicePrint.startThreshold
            if voice == nil, bar != nil { voice = await ConversationProcessor.shared.voiceScore(clip.samples) }
            let heard = MomentAgreement.Heard(wake: run.wake, engine: written.engine, conversation: conversation, checkedFirst: clip.checkFirst != nil,
                                              voice: voice.map(Double.init), startBar: bar.map(Double.init),
                                              otherAudioPlaying: AVAudioSession.sharedInstance().isOtherAudioPlaying,
                                              mode: autoMac ? sending : nil)
            agreed = MomentAgreement.agreed(heard, macFeatures: features, consents: AgentConsents.agreedFingerprints())
            if agreed == nil { hold = MomentAgreement.hold(heard, macFeatures: features) }
        } else if joins != nil, VoicePrint.isTaught {
            // It goes with its capture, never on less than said on its own: its own voice is scored against the start bar,
            // a "Binders, …" too, and why it couldn't go on its own goes with it.
            let bar = VoicePrint.startThreshold
            if voice == nil, bar != nil { voice = await ConversationProcessor.shared.voiceScore(clip.samples) }
            let heard = MomentAgreement.Heard(wake: run.wake, engine: written.engine, voice: voice.map(Double.init), startBar: bar.map(Double.init),
                                              otherAudioPlaying: AVAudioSession.sharedInstance().isOtherAudioPlaying, mode: .auto)
            hold = MomentAgreement.hold(heard, macFeatures: features)
        }
        // What's heard on its own is added at once in Add at Once and Auto (a Mac without Auto hands nothing over, so it's
        // Add at Once there); in Suggest, the kinds that have graduated.
        let adding = run.wake ? nil : sending == .suggest ? adds : macAdds ? MomentModes.everyKind : nil
        let payload = MomentPayload(id: clip.id, heard: clip.started, text: words, device: UIDevice.current.model, engine: written.engine, wake: run.wake,
                                    seconds: seconds, cue: run.cue, voice: voice.map(Double.init), conversation: clip.conversation,
                                    asrMillis: run.asrMillis, adds: adding, agreed: agreed, mode: autoMac ? sending.rawValue : nil,
                                    autoHold: autoMac ? hold : nil, alone: alone ? true : nil,
                                    uncued: run.cue == nil && !run.wake ? run.uncued : nil)
        await connection?.keepMoment(payload, said: written.text)
    }

    // MARK: The gate

    /// What the gate made of a clip: every check that failed, and what each found.
    struct GateRun {
        /// Every check that failed, in MomentGate.Check's order; the first says why it isn't a moment. None: it's one.
        var failures: [MomentGate.Check] = []
        var isMoment: Bool { failures.isEmpty }
        /// What was written down, and by which engine.
        var written: (text: String, engine: String)?
        /// It opened with "Binders,"; `words` are what followed it, or else what was said.
        var wake = false
        var words: String?
        var cue: String?
        /// How alike the voice was to your print, and the threshold it was held to.
        var voice: Float?
        var threshold: Float
        /// Apple's model's reading and the rules', when they were asked.
        var model: OnDeviceModel.Reading?
        var rules: MomentReading?
        /// The kind Apple's model read and the rules agreed with, kept with the moment.
        var checked: MomentKind?
        /// Why it isn't a moment, for its conversation's timeline: said only when Apple's model disagreed.
        var why: String?
        /// Lane Y2: with no cue, what the rules read it as without one ("fix", "todo", "idea"; "" for none), and, asked in
        /// Auto with MomentGate.uncuedInstructions, Apple's model's kind ("none", or "" when it didn't answer).
        var uncued: String?
        var uncuedModel: String?
        /// Writing it down (the wake-word check included), scoring the voice, and asking the model, in milliseconds.
        var asrMillis: Int?
        var voiceMillis: Int?
        var modelMillis: Int?
    }

    /// The gate, which capture (`decide`) and the calibration bench (CalibrationBench) share: a clip through the checks in
    /// MomentGate.Check's order. Said in a conversation, its first second and a half has to open with "Binders,". Written
    /// down, it needs two words, and "Binders, …" then passes. Otherwise it has to have been said on its own, with a cue in
    /// the words and your voice at `threshold` or closer (VoicePrint.momentThreshold unless said); and Apple's model, when
    /// it answers in time, has to agree with the rules on the kind. Capture stops at the first check that fails.
    /// `scoringAll`, for the bench, runs every check it can, for the scores, and fails the same ones. `mayWriteDown` is
    /// asked once, just before the clip is written down in full: capture's limit on write-downs. Nothing here is kept or
    /// sent.
    func gate(_ clip: CaptureWorker.MomentClip, threshold: Float? = nil, scoringAll: Bool = false,
              mayWriteDown: () -> Bool = { true }) async -> GateRun {
        let threshold = threshold ?? VoicePrint.momentThreshold
        var run = GateRun(threshold: threshold)
        /// A check failed: true when the gate stops there.
        func fails(_ check: MomentGate.Check) -> Bool {
            run.failures.append(check)
            return !scoringAll
        }
        let processor = ConversationProcessor.shared
        let writing = Date()
        if let head = clip.checkFirst {
            // Said in a conversation: a moment only if it opens with "Binders,", which its first second and a half tells.
            guard let opening = await processor.writeDownMoment(Array(clip.samples.prefix(head)), keepingTheModel: true),
                  MomentRules.opensWithWakeWord(opening.text) else {
                run.failures = [.inConversation]
                return run
            }
        }
        guard mayWriteDown() else {
            run.failures = [.resting]
            return run
        }
        guard let written = await processor.writeDownMoment(clip.samples) else {
            run.failures = [.notWrittenDown]
            return run
        }
        run.written = written
        run.asrMillis = Self.millis(since: writing)
        guard TextNorm.words(written.text).count >= 2 else {
            run.failures = [.tooFewWords]
            return run
        }
        if let rest = MomentRules.afterWakeWord(written.text) {
            // "Binders, …" always passes: you asked.
            run.wake = true
            run.words = rest
            guard scoringAll else { return run }
        } else {
            run.words = written.text
            // On its own: a cue, and your voice (the quiet around it is the detector's). Said in a conversation, nothing but
            // the wake word counts.
            if clip.checkFirst != nil, fails(.inConversation) { return run }
            if !VoicePrint.isTaught, fails(.noVoicePrint) { return run }
            run.cue = MomentRules.cue(in: written.text)
            if run.cue == nil { run.uncued = MomentRules.uncued(in: written.text) ?? "" }
            // In Auto, a sentence without a cue goes on when the rules read it as a fix, a to-do or an idea (lane Y2); the
            // start bar and Apple's model must agree below. Otherwise no cue fails, as before.
            let uncuedHere = run.cue == nil && !(run.uncued ?? "").isEmpty && soloAutoNow
            if run.cue == nil, !uncuedHere || scoringAll, fails(.noCue) { return run }
        }
        if VoicePrint.isTaught {
            let scoring = Date()
            run.voice = await processor.voiceScore(clip.samples)
            run.voiceMillis = Self.millis(since: scoring)
        }
        if !run.wake {
            if run.voice == nil, VoicePrint.isTaught, fails(.voiceUnclear) { return run }
            if let voice = run.voice, voice < threshold, fails(.notYourVoice) { return run }
        }
        // Lane Y2: kept without a cue only past the start bar Calibrate sets, and only when Apple's model, told what a fix
        // is, reads it as that kind too. No model, or no answer: let go.
        if run.cue == nil, !run.wake, let uncued = run.uncued, !uncued.isEmpty, soloAutoNow || (scoringAll && mode == .auto) {
            let asking = Date()
            let reading = await OnDeviceModel.kind(of: written.text, instructions: MomentGate.uncuedInstructions)
            if case .kind(let kind) = reading { run.uncuedModel = kind.rawValue } else { run.uncuedModel = "" }
            // The bench records it beside today's reading, which it goes on to ask as before.
            if !scoringAll {
                run.modelMillis = Self.millis(since: asking)
                let past = VoicePrint.startThreshold.map { bar in (run.voice ?? 0) >= bar } ?? false
                var agrees = false
                if case .kind(let kind) = reading { agrees = MomentGate.confirmsUncued(kind, uncued: uncued) }
                if !past || !agrees { _ = fails(.noCue) } else { run.checked = uncued == "idea" ? .idea : .todo }
                return run
            }
        }
        // And the fourth: Apple's model on this iPhone reads what kind of thing it is, which has to be what the rules read.
        // Without it, or when it's slow, the other checks stand alone.
        let asking = Date()
        run.model = await OnDeviceModel.kind(of: written.text)
        run.modelMillis = Self.millis(since: asking)
        if case .kind(let kind)? = run.model {
            let rules = MomentRules.read(written.text, binders: knownBinders, agents: knownAgents, heard: clip.started)
            run.rules = rules
            if MomentGate.confirms(kind, rules: rules, said: written.text) {
                if !run.wake { run.checked = kind }
            } else if !run.wake {
                run.why = MomentGate.disagreement(kind, rules: rules.kind)
                _ = fails(.modelDisagreed)
            }
        } else if scoringAll {
            run.rules = MomentRules.read(written.text, binders: knownBinders, agents: knownAgents, heard: clip.started)
        }
        return run
    }

    private static func millis(since start: Date) -> Int { Int((Date().timeIntervalSince(start) * 1000).rounded()) }

    /// The binders and agents this iPhone last heard of, for the rules' reading of a kind.
    private var knownBinders: [String] {
        connection?.cached("binders", as: [BinderInfo].self)?.filter { !$0.archived }.map(\.name) ?? []
    }

    private var knownAgents: [String] { connection?.cached("agents", as: AgentList.self)?.agents.map(\.name) ?? [] }

    /// A conversation's transcript, written down and labelled: "Binders, …" you said in it that wasn't heard as a moment
    /// as you said it (in the middle of talking, say) becomes one now, heard at the start of its segment. Only what you
    /// said, by the voice print, and nothing heard as a moment already (the same words within two minutes of its
    /// segment, which may run over a pause). Each goes ahead of the conversation, queued next, so the Mac has it when it
    /// writes the conversation up, and leaves its words out there.
    ///
    /// Lane Y2: in a capture the iPhone heard as only you, while Auto reads what you think out loud, each one found waits
    /// for its capture (`fromTranscript`, `mode` "auto") and its id is returned, for the capture's `soloMoments`.
    @discardableResult
    func transcribed(_ conversation: CapturedConversation) -> [UUID] {
        guard isListening, let transcript = conversation.transcript, let speakers = conversation.speakers, speakers.values.contains(TranscriptSegment.you)
        else { return [] }
        let joining = soloAutoNow && conversation.solo?.isOnlyYou == true && conversation.mode == MomentMode.auto.rawValue
        var foundIDs: [UUID] = []
        let yours = transcript.filter { speakers[$0.speaker] == TranscriptSegment.you }
            .map { (heard: conversation.started.addingTimeInterval($0.start), ended: conversation.started.addingTimeInterval($0.end), text: $0.text) }
        let earlier = moments.compactMap { moment in moment.text.map { (heard: moment.heard, text: $0) } }
        for found in MomentRules.wakeMoments(in: yours, earlier: earlier) {
            let id = UUID()
            save(CapturedMoment(id: id, heard: found.heard, state: "kept", text: found.text, wake: true, engine: conversation.engine,
                                timings: MomentTimings(heard: found.heard), fromTranscript: true, mode: joining ? MomentMode.auto.rawValue : nil,
                                conversation: conversation.id, joins: joining ? conversation.id : nil))
            let payload = MomentPayload(id: id, heard: found.heard, text: found.text, device: UIDevice.current.model, engine: conversation.engine,
                                        wake: true, voice: joining ? conversation.solo?.lowest : nil, conversation: conversation.id,
                                        mode: joining ? MomentMode.auto.rawValue : nil, fromTranscript: joining ? true : nil)
            connection?.queueMoment(payload, said: found.said)
            if joining { foundIDs.append(id) }
        }
        return foundIDs
    }

    #if DEBUG
    /// For development and the UI tests, as the Simulator can't listen: `-sayMoment "Binders, …"` goes on from where a
    /// moment heard and written down would, through the gate's rules (not the voice print) to your Mac.
    func pretend(_ said: String) {
        Task {
            for _ in 0..<60 where !isListening { try? await Task.sleep(for: .milliseconds(500)) }
            guard isListening else { return }
            var words = said
            var wake = false
            var cue: String?
            if let rest = MomentRules.afterWakeWord(said) {
                wake = true
                words = rest
            } else if let found = MomentRules.cue(in: said) {
                cue = found
            } else {
                return
            }
            let id = UUID(), now = Date()
            save(CapturedMoment(id: id, heard: now, state: "kept", text: words, wake: wake, cue: cue, engine: "test",
                                timings: MomentTimings(heard: now, seconds: 2, asrMillis: 0)))
            let payload = MomentPayload(id: id, heard: now, text: words, device: "iPhone", engine: "test", wake: wake, seconds: 2, cue: cue,
                                        voice: nil, conversation: nil, asrMillis: 0, adds: wake ? nil : adds)
            await connection?.keepMoment(payload, said: said)
        }
    }
    #endif

    /// The kinds to add at once rather than offer, for a Mac that can (MomentPayload.adds); nil for none.
    private var adds: [String]? {
        guard macAdds else { return nil }
        let kinds = graduation.adding.map(\.rawValue)
        return kinds.isEmpty ? nil : kinds
    }

    /// The kinds that have graduated, as `adds` carries them; nil for none. For the link, as it sends a moment kept in
    /// another mode that goes as Suggest now (MacConnection.graduatedKinds).
    var graduatedKinds: [String]? {
        let kinds = graduation.adding.map(\.rawValue)
        return kinds.isEmpty ? nil : kinds
    }

    /// The Mac adds at once the kinds this iPhone says have graduated.
    var macAdds: Bool { connection?.macFeatures.contains(MomentPayload.addsFeature) ?? false }

    /// Something told to Siri: listed with the rest, with what the Mac made of it.
    func record(_ payload: MomentPayload, outcome: CaptureOutcome) {
        save(CapturedMoment(id: payload.id, heard: payload.heard, state: "sent", text: payload.text, wake: true, engine: payload.engine,
                            outcome: outcome.line, outcomeState: outcome.state, title: outcome.title, actions: outcome.actions, agent: outcome.agent,
                            timings: MomentTimings(heard: payload.heard).merging(outcome.timings), card: outcome.card, todo: outcome.todo,
                            binder: outcome.binder, kind: outcome.kind, sources: outcome.sources))
    }

    /// p50 and p90 of how long the last 50 moments heard as they were said took, for the capture screen: numbers only.
    /// Siri's and those found in a transcript later don't count.
    var timingSummary: MomentTimingSummary? {
        MomentTimingSummary(moments.filter { $0.engine != "siri" && $0.fromTranscript != true }.compactMap(\.timings))
    }

    /// What became of a clip, for the conversation the same words are in; `why` it wasn't a moment goes on that
    /// conversation's timeline, when there's a reason worth saying.
    private func settle(_ id: UUID, kept: Bool, why: String? = nil, in conversation: UUID? = nil, joins: UUID? = nil) {
        CaptureSession.shared.settleMoment(id, kept: kept, why: why, in: conversation, joins: joins)
    }

    // MARK: What the Mac made of it

    /// It reached the Mac (or was turned down), with the Mac's outcome when it said in time.
    func settled(_ id: UUID, outcome: CaptureOutcome?, sent: Bool) {
        update(id) { $0.state = sent ? "sent" : "refused" }
        if let outcome { apply(outcome, notify: true) }
    }

    /// A newer outcome (asked for later, or after a tap). Only the Mac's own decision rings: what you did with Add, Not
    /// Now, Undo or Give to doesn't come back to you as a notification.
    func apply(_ outcome: CaptureOutcome, notify: Bool) {
        guard let before = moments.first(where: { $0.id == outcome.id }) else { return }
        let decidedNow = before.outcomeState == nil || before.outcomeState == "working"
        // "Working on it" is kept, not rung: the decision that follows rings.
        let changed = decidedNow && outcome.state != "working" && (before.outcomeState != outcome.state || before.outcome != outcome.line)
        update(outcome.id) {
            $0.outcome = outcome.line
            $0.outcomeState = outcome.state
            $0.title = outcome.title
            $0.actions = outcome.actions
            $0.agent = outcome.agent
            $0.card = outcome.card
            $0.todo = outcome.todo
            $0.binder = outcome.binder
            $0.kind = outcome.kind ?? $0.kind
            $0.sources = outcome.sources
            $0.handedOver = outcome.handedOver
            $0.waiting = outcome.waiting
            $0.late = outcome.late
            $0.joins = outcome.joins
            if decidedNow, outcome.state != "working" { $0.decided = Date() }
            if let timings = outcome.timings { $0.timings = ($0.timings ?? MomentTimings()).merging(timings) }
        }
        // Handed over in Auto: counted towards Auto turning itself off, should Not me's follow.
        if decidedNow, outcome.handedOver != nil, before.heardInAuto {
            autoWatch.handedOver(outcome.id)
            saveAutoWatch()
        }
        // Heard on its own and added at once, as its kind has graduated: kept, until it's taken back.
        if decidedNow, outcome.state == "acted", let after = moments.first(where: { $0.id == outcome.id }), after.isHeardOnItsOwn,
           let kind = Self.kind(of: after), graduation.isAdding(kind) {
            judge(after, .kept)
        }
        // Acted on, by your Mac or by your Add: filed, by touch (with Binders in front). Offered, it joined Needs you as it
        // was saved, which warns by touch (CaptureActivity.update).
        if outcome.state == "acted", before.outcomeState != "acted" { Haptics.shared.success() }
        // A capture's item never rings: its capture's one notification covers it (lane Y2).
        if notify, changed, MomentNotice.rings(capture: before.capture, decidedNow: decidedNow) { post(outcome) }
    }

    /// Those sent and not settled yet, for binders/outcomes.
    var waiting: [UUID] {
        let since = Date().addingTimeInterval(-86_400)
        return moments.filter { $0.state == "sent" && $0.heard > since && ($0.outcomeState == nil || $0.outcomeState == "working") }.map(\.id)
    }

    /// Add, Not Now, Undo or Assign, from the notification or the row: whether the Mac did it, and what it said. Give to
    /// with the Mac out of reach is kept, and goes once it's back (`keptForMac`). On something heard on its own, Add, Not
    /// Now and Undo count towards its kind's graduation.
    @discardableResult
    func act(_ id: UUID, _ action: String) async -> (ok: Bool, message: String) {
        guard let connection else { return (false, "Pair with your Mac, or sign in to your hub, first.") }
        let before = moments.first { $0.id == id }
        let agent = before?.agent
        if action == "assign" {
            if let agent, !Self.agreed(to: agent) { return (false, "Say yes to giving cards to \(agent) first.") }
            switch await connection.give(moment: id, to: agent) {
            case .sent(let message):
                await OutcomeCenter.shared.refresh()
                return (true, message)
            case .kept: return (true, Self.keptForMac)
            case .refused(let message): return (false, message)
            }
        }
        // Stop and Undo on what Binders handed over, to a Mac that has Auto: kept for it when it's out of reach.
        if ["stop", "undo"].contains(action), before?.handedOver != nil, connection.macFeatures.contains(MomentPayload.autoFeature) {
            switch await connection.outcomeAction(id, action: action) {
            case .sent(let message):
                await OutcomeCenter.shared.refresh()
                return (true, message)
            case .refused(let message): return (false, message)
            case .kept:
                keep(id, action)
                return (true, action == "stop" ? AutoText.keptStop(agent: before?.agent ?? "the agent") : AutoText.keptUndo)
            }
        }
        let result = await connection.actOnOutcome(id, action: action)
        if result.ok {
            let verdict: MomentVerdict? = switch (action, before?.outcomeState) {
            case ("add", "offered"?): .added
            case ("not-now", "offered"?): .notNow
            case ("undo", "acted"?): .undone
            default: nil
            }
            if let before, let verdict { judge(before, verdict) }
            await OutcomeCenter.shared.refresh()
        }
        return result
    }

    /// "Not me" on something heard on its own: it wasn't you, or it wasn't said to Binders. A hard no for its kind, kept
    /// against your voice print, and taken back on the Mac (Not Now on an offer, Undo once added).
    /// On something Binders handed over without asking ("Binders, …" too), it also stops the agent and takes the card
    /// back (`not-me`, to a Mac that has Auto), raises the start bar above that voice when it was past it, and counts
    /// towards Auto turning itself off. What's about the voice happens here at once; what the Mac does is kept for it
    /// while it's out of reach.
    @discardableResult
    func notMe(_ id: UUID) async -> (ok: Bool, message: String) {
        guard let moment = moments.first(where: { $0.id == id }), moment.mayBeNotMe else {
            return (false, "That isn't something you can do with it now.")
        }
        update(id) { $0.notMe = Date() }
        // One of a capture's items has no clip of its own: the bar goes above the capture's lowest voice of yours (lane Y2).
        let score = moment.voice ?? moment.capture.flatMap { CaptureStore.shared.conversation($0) }?.solo?.lowest
        let raised = VoicePrint.notMe(score)
        judge(moment, .notMe)
        let handed = moment.handedOver != nil
        if handed, moment.heardInAuto, autoWatch.notMe(id) {
            saveAutoWatch()
            turnOffAuto()
            Self.tell(AutoText.turnedOff, id: "moment-auto-off")
        } else if handed {
            saveAutoWatch()
        }
        let autoMac = connection?.macFeatures.contains(MomentPayload.autoFeature) ?? false
        let action = switch moment.outcomeState {
        case "offered": autoMac ? "not-me" : "not-now"
        case "acted": autoMac ? "not-me" : "undo"
        default: ""
        }
        let done = handed ? AutoText.notMeLine(raised: raised) : "Not you: taken back, and kept against your voice print."
        guard !action.isEmpty else { return (true, "Not you: kept against your voice print.") }
        guard let connection else { return (false, "Pair with your Mac, or sign in to your hub, first.") }
        if autoMac {
            switch await connection.outcomeAction(id, action: action) {
            case .sent:
                await OutcomeCenter.shared.refresh()
                return (true, done)
            case .refused(let message): return (false, message)
            case .kept:
                keep(id, action)
                return (true, handed ? AutoText.keptNotMe : AutoPhoneText.keptNotMe)
            }
        }
        let result = await connection.actOnOutcome(id, action: action)
        guard result.ok else { return result }
        await OutcomeCenter.shared.refresh()
        return (true, done)
    }

    // MARK: A capture that's only you (lane Y2)

    /// A capture's outcome came with what it read from it: its items become moments of their own (`capture` set), and the
    /// moments said in it that went with it stop waiting for it.
    func foundIn(_ record: CapturedConversation, found: [CaptureOutcome.Found]) {
        for item in found {
            if moments.contains(where: { $0.id == item.id }) {
                update(item.id) { $0.joins = nil }
            } else {
                save(CapturedMoment(id: item.id, heard: item.heard, state: "sent", text: item.said, engine: record.engine,
                                    timings: MomentTimings(heard: item.heard), kind: item.kind, mode: record.mode, conversation: record.id,
                                    capture: item.joined == true ? nil : record.id))
            }
        }
    }

    /// The capture's one notification, once its items' outcomes are in: what went to which agent, and what was added.
    /// Exactly one thing: that moment's own notification. Nothing for one that made nothing.
    func noticeCapture(_ capture: UUID, found: [CaptureOutcome.Found], line: String) async {
        let items = found.compactMap { item in moments.first { $0.id == item.id } }
        let offered = line.range(of: #"(\d+) more offered"#, options: .regularExpression)
            .flatMap { Int(line[$0].split(separator: " ").first ?? "") } ?? 0
        let things = items.filter { $0.outcomeState == "acted" }.map { moment in
            LockScreenText.FoundThing(title: Self.task(of: moment), agent: moment.handedOver != nil ? moment.agent : nil, binder: moment.binder,
                                      waits: moment.isHeldForYou)
        }
        guard !things.isEmpty else { return }
        let started = CaptureStore.shared.conversation(capture)?.started ?? Date()
        let time = started.formatted(date: .omitted, time: .shortened)
        let showsWords = await LockScreen.showsWords()
        guard let text = LockScreenText.captureFound(things, offered: offered, time: time, showsWords: showsWords) else {
            // One thing only: its own notification, with its Stop, Undo, Not Me and Open.
            if let one = items.first(where: { $0.outcomeState == "acted" }) { post(Self.outcome(of: one)) }
            return
        }
        let content = UNMutableNotificationContent()
        content.title = text.title
        content.body = text.body
        content.categoryIdentifier = Self.captureHandedCategory
        content.threadIdentifier = Self.handedThread
        if Date().timeIntervalSince(lastHandedNotice) < AutoRules.quietWithin { content.interruptionLevel = .passive }
        lastHandedNotice = Date()
        content.userInfo = ["capture": capture.uuidString]
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "capture-\(capture.uuidString)", content: content, trigger: nil))
    }

    /// What a moment's line says it made, without the binder before it or what came after: "Fix the login timeout".
    static func task(of moment: CapturedMoment) -> String {
        let line = moment.outcome ?? moment.text ?? ""
        guard let colon = line.range(of: ": ") else { return line }
        let rest = String(line[colon.upperBound...])
        return (rest.components(separatedBy: ". ").first ?? rest).trimmingCharacters(in: CharacterSet(charactersIn: ". "))
    }

    /// A moment's outcome as last kept, for its own notification.
    private static func outcome(of moment: CapturedMoment) -> CaptureOutcome {
        CaptureOutcome(id: moment.id, state: moment.outcomeState ?? "acted", line: moment.outcome ?? "", title: moment.title, binder: moment.binder,
                       actions: moment.actions, agent: moment.agent, card: moment.card, todo: moment.todo, kind: moment.kind,
                       handedOver: moment.handedOver, waiting: moment.waiting, late: moment.late)
    }

    /// The things a capture made, for its page: each item and each moment that went with it, in the order heard.
    func found(in capture: UUID) -> [CapturedMoment] {
        let ids = CaptureStore.shared.conversation(capture)?.found?.map(\.id) ?? []
        return ids.compactMap { id in moments.first { $0.id == id } }
    }

    /// Stop All on a capture: what Binders handed over from it stops, its cards back in Backlog; kept for the Mac when it's
    /// away.
    func stopAll(_ capture: UUID) async -> (ok: Bool, message: String) {
        guard let connection else { return (false, "Pair with your Mac, or sign in to your hub, first.") }
        switch await connection.outcomeAction(capture, action: "stop-all") {
        case .sent(let message):
            await OutcomeCenter.shared.refresh()
            return (true, message)
        case .refused(let message): return (false, message)
        case .kept:
            keep(capture, "stop-all")
            return (true, AutoPhoneText.keptStopAll)
        }
    }

    /// Not Only Me on a capture, asked first on its page: someone else was in it. The start bar goes above its lowest voice
    /// of yours at once, Auto counts one Not Me, and the Mac takes back what it made (kept for it when it's away).
    func notOnlyMe(_ capture: UUID) async -> (ok: Bool, message: String) {
        let record = CaptureStore.shared.conversation(capture)
        _ = VoicePrint.notMe(record?.solo?.lowest)
        let items = found(in: capture)
        for item in items { update(item.id) { $0.notMe = Date() } }
        if let handed = items.first(where: { $0.handedOver != nil }), autoWatch.notMe(handed.id) {
            saveAutoWatch()
            turnOffAuto()
            Self.tell(AutoText.turnedOff, id: "moment-auto-off")
        } else {
            saveAutoWatch()
        }
        guard let connection else { return (false, "Pair with your Mac, or sign in to your hub, first.") }
        switch await connection.outcomeAction(capture, action: "not-only-me") {
        case .sent(let message):
            await OutcomeCenter.shared.refresh()
            return (true, message)
        case .refused(let message): return (false, message)
        case .kept:
            keep(capture, "not-only-me")
            return (true, AutoPhoneText.keptNotOnlyMe)
        }
    }

    /// Turn Off Auto: each capture sent in Auto and not yet read on the Mac goes as `mode` there.
    private func lowerCapturesOnTheMac(to mode: MomentMode) {
        guard let connection, connection.macFeatures.contains(ConversationPayload.soloFeature) else { return }
        let waiting = CaptureStore.shared.conversations.filter { $0.state == .sent && !OutcomeCenter.settled($0.outcomeState) }
            .compactMap { CaptureStore.shared.conversation($0.id) }.filter { $0.mode == MomentMode.auto.rawValue }
        for record in waiting {
            Task { _ = await connection.outcomeAction(record.id, action: "mode", mode: mode.rawValue) }
        }
    }

    // MARK: Kept for the Mac

    /// Stop, Undo and Not Me kept while the Mac was out of reach, in order: their own small queue (`momentActionsKept`),
    /// not the outbox, which an older build would block on a word it doesn't know. Ids and action words only.
    private struct KeptAction: Codable, Equatable {
        var moment: UUID
        var action: String
    }

    private static var keptActions: [KeptAction] {
        get { UserDefaults.standard.data(forKey: "momentActionsKept").flatMap { try? JSONDecoder().decode([KeptAction].self, from: $0) } ?? [] }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: "momentActionsKept") }
    }

    private func keep(_ id: UUID, _ action: String) {
        var all = Self.keptActions
        all.removeAll { $0.moment == id && $0.action == action }
        all.append(KeptAction(moment: id, action: action))
        Self.keptActions = all
    }

    /// Kept for the Mac, waiting: Stop still to go.
    func keptAction(for id: UUID) -> String? { Self.keptActions.last { $0.moment == id }?.action }

    /// The Mac is back: what was kept goes, in order, to a Mac that has Auto. Each one's line replaces its notification,
    /// so one that did less than its button says (the agent had finished, the card had moved) is never silent.
    @ObservationIgnored private var sendingKept = false

    func sendKeptActions() async {
        guard !sendingKept, let connection, connection.macFeatures.contains(MomentPayload.autoFeature), !Self.keptActions.isEmpty else { return }
        sendingKept = true
        defer { sendingKept = false }
        var sent = false
        while let next = Self.keptActions.first {
            let result = await connection.outcomeAction(next.moment, action: next.action)
            if case .kept = result { break }
            Self.keptActions = Self.keptActions.filter { $0 != next }
            sent = true
            switch result {
            case .sent(let message): toldAfter(next.moment, (true, message))
            case .refused(let message): toldAfter(next.moment, (false, message))
            case .kept: break
            }
        }
        if sent { await OutcomeCenter.shared.refresh() }
    }

    /// After Stop, Undo or Not Me from a hand-over's notification, or one kept for the Mac that has gone: the line takes
    /// the hand-over's notification's place (the same request), quietly, whatever it says. Your words only where the Lock
    /// Screen shows them (LockScreen).
    func toldAfter(_ id: UUID, _ result: (ok: Bool, message: String)) {
        let message = result.message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        let agent = moments.first { $0.id == id }?.agent
        Task {
            let content = UNMutableNotificationContent()
            content.title = result.ok ? (agent ?? "Said to yourself") : "Couldn't do that"
            content.body = await LockScreen.showsWords() ? message : "\(MacConnection.BrainWords) said what it did: open it to see."
            content.categoryIdentifier = Self.noteCategory
            content.interruptionLevel = .passive
            content.userInfo = ["moment": id.uuidString]
            try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "moment-\(id.uuidString)", content: content, trigger: nil))
        }
    }

    /// A notification of Auto's own (it turned itself off, or can hand things over now), opening the capture screen.
    private static func tell(_ text: NotificationText, id: String, sheet: Bool = false) {
        let content = UNMutableNotificationContent()
        content.title = text.title
        content.body = text.body
        content.categoryIdentifier = autoCategory
        if sheet { content.userInfo = ["sheet": true] }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    // MARK: Graduating

    /// A verdict on something heard on its own, for its kind: told once when the kind now adds at once with Undo, or
    /// offers again.
    private func judge(_ moment: CapturedMoment, _ verdict: MomentVerdict) {
        // Graduation is Suggest's own: what was heard in Add at Once or Auto was never offered, so it says nothing of it.
        guard moment.isHeardOnItsOwn, moment.mode == nil || moment.mode == MomentMode.suggest.rawValue,
              let kind = Self.kind(of: moment), MomentGraduation.kinds.contains(kind) else { return }
        let offered = verdict == .added || verdict == .notNow || (verdict == .notMe && moment.outcomeState == "offered")
        let change = graduation.record(verdict, moment: moment.id, kind: kind, offered: offered, mayAdd: macAdds)
        saveGraduation()
        if let change { announce(change) }
    }

    /// What a moment was read as: the Mac's word, or worked out from what it made, for a Mac before that.
    private static func kind(of moment: CapturedMoment) -> MomentKind? {
        LockScreenText.kind(of: CaptureOutcome(id: moment.id, state: moment.outcomeState ?? "", line: moment.outcome ?? "", title: moment.title,
                                               card: moment.card, todo: moment.todo, kind: moment.kind))
    }

    /// You switched a kind back to suggesting: it's offered again, and counts afresh.
    func suggestAgain(_ kind: MomentKind) {
        graduation.suggest(kind)
        saveGraduation()
    }

    /// One notification when a kind graduates; a quiet one when it drops back. Either opens the capture screen.
    private func announce(_ change: MomentGraduation.Change) {
        let text = MomentGraduation.notification(change)
        let content = UNMutableNotificationContent()
        content.title = text.title
        content.body = text.body
        content.categoryIdentifier = Self.kindsCategory
        if case .droppedBack = change { content.interruptionLevel = .passive }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "moment-kinds-\(UUID().uuidString)", content: content, trigger: nil))
    }

    private static func loadGraduation() -> MomentGraduation {
        UserDefaults.standard.data(forKey: "momentGraduation").flatMap { try? JSONDecoder().decode(MomentGraduation.self, from: $0) } ?? MomentGraduation()
    }

    private func saveGraduation() {
        if let data = try? JSONEncoder().encode(graduation) { UserDefaults.standard.set(data, forKey: "momentGraduation") }
    }

    /// After Add on an offer's notification: what was done comes back in its place, with Undo, Give to when an agent fits,
    /// and Open. What it says follows the Lock Screen rule like any other.
    func followUp(_ id: UUID) async {
        if let connection, connection.hasOutcomes,
           let reply = try? await connection.request(CaptureOutcome.listMethod, ["ids": [id.uuidString]]) as? [String: Any],
           let items = reply["outcomes"] as? [Any], let outcome = CaptureOutcome.decodeEach(items).first(where: { $0.id == id }) {
            apply(outcome, notify: false)
        }
        // The Mac's word on it now, or what the refresh after Add brought.
        guard let moment = moments.first(where: { $0.id == id }), moment.outcomeState == "acted" else { return }
        post(CaptureOutcome(id: id, state: "acted", line: moment.outcome ?? "", title: moment.title, binder: moment.binder, actions: moment.actions,
                            agent: moment.agent, card: moment.card, todo: moment.todo, sources: moment.sources, kind: moment.kind))
    }

    /// A Give to kept for your Mac went, and the Mac hands the card over (the agent's own news follows), or the Mac turned
    /// it down: a notification says why, opening the moment or the card.
    func handOffSettled(_ item: PendingSave, sent: Bool, message: String?) {
        if sent {
            if item.moment != nil { Task { await OutcomeCenter.shared.refresh() } }
            return
        }
        let who = item.agent.flatMap { $0.isEmpty ? nil : $0 }
        let reason = (message ?? "").isEmpty ? "\(MacConnection.BrainWords) couldn't do it." : message ?? ""
        if let id = item.moment {
            return Self.note(id, title: "Couldn't give it to \(who ?? "the agent")", body: reason)
        }
        guard let card = item.card else { return }
        Task {
            let content = UNMutableNotificationContent()
            content.title = who.map { "Couldn't give the card to \($0)" } ?? "Couldn't change who the card is for"
            // The card's title can be what you said: on a Lock Screen that shows previews, where it is instead.
            content.subtitle = LockScreenText.card(item.text, binder: item.binder ?? BoardQuestions.binder(of: card),
                                                   showsWords: await LockScreen.showsWords())
            content.body = reason
            content.categoryIdentifier = BoardQuestions.statusCategory
            content.userInfo = ["card": card]
            try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "hand-off-\(item.id.uuidString)", content: content,
                                                                                     trigger: nil))
        }
    }

    /// An action from a moment's notification that the Mac couldn't do: said in a notification of its own, opening the
    /// moment to try again.
    static func couldNot(_ id: UUID, _ message: String) {
        note(id, title: "Couldn't do that", body: message)
    }

    /// A word about a moment, in a notification of its own that opens it: something you did couldn't be done, or waits.
    /// The Mac's reasons and these words hold none of yours.
    static func note(_ id: UUID, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = noteCategory
        content.userInfo = ["moment": id.uuidString]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "moment-\(id.uuidString)-problem", content: content, trigger: nil))
    }

    // MARK: Open, and Not Right

    /// Where a moment's Open goes (the kit's rule, MomentPlace.of): what it made, or its own page, which is where one
    /// Binders handed over without asking opens, as Stop, Undo, Not Me and Turn Off Auto are there.
    typealias Place = MomentPlace

    func place(_ id: UUID) -> Place {
        guard let moment = moments.first(where: { $0.id == id }) else { return .moment(id) }
        return MomentPlace.of(outcome: CaptureOutcome(id: id, state: moment.outcomeState ?? "", line: moment.outcome ?? "", binder: moment.binder,
                                                      card: moment.card, todo: moment.todo, handedOver: moment.handedOver))
    }

    /// Open, or its notification tapped: what it made, or its own page (PhoneNavigation.pendingMoment). `page`: its own
    /// page whatever it made, for a word about it (`note`), where it can be tried again. One gone from this iPhone opens
    /// the capture screen.
    func open(_ id: UUID, page: Bool = false) {
        guard moments.contains(where: { $0.id == id }) else { return PhoneNavigation.shared.pendingCapture = true }
        PhoneNavigation.shared.pendingMomentPage = page
        PhoneNavigation.shared.pendingMoment = id
    }

    /// Not Right on an answer: marked on it, shown on its row, and the question stays on the capture screen to ask again.
    func markNotRight(_ id: UUID) {
        guard moments.first(where: { $0.id == id })?.isAnswer == true else { return }
        update(id) {
            $0.notRight = Date()
            $0.askedAgain = nil
        }
    }

    /// Asked again, in Ask: off the list of ones to ask again.
    func askedAgain(_ id: UUID) {
        update(id) { $0.askedAgain = Date() }
    }

    /// The capture screen's list, newest first: today's, and earlier answers you said weren't right and haven't asked again.
    func listed(now: Date = Date()) -> [CapturedMoment] {
        moments.filter { (Self.isToday($0, now: now) || $0.isToAskAgain) && $0.capture == nil }.sorted { $0.heard > $1.heard }
    }

    /// Told to Siri while the Mac was away: kept with the rest, so what the Mac makes of it shows here once it's back.
    func keptForLater(_ payload: MomentPayload) {
        save(CapturedMoment(id: payload.id, heard: payload.heard, state: "kept", text: payload.text, wake: true, engine: payload.engine))
    }

    // MARK: Notifications

    /// The buttons moments' notifications carry, and what they show while previews are hidden: the title, which never
    /// holds your words, and a count. Open, on each, opens what it made or its own page. Not Me, on an offer, says it
    /// wasn't you.
    static var categories: [UNNotificationCategory] {
        let opening = UNNotificationAction(identifier: open, title: "Open", options: [.foreground])
        let undoing = UNNotificationAction(identifier: undo, title: "Undo")
        /// Done, with Give to naming the agent.
        func done(_ identifier: String, giveTo title: String) -> UNNotificationCategory {
            UNNotificationCategory(identifier: identifier, actions: [
                undoing,
                // Never the first button (a Watch's double tap runs the first), and only on an unlocked iPhone, in the app,
                // which asks first the first time for each agent.
                UNNotificationAction(identifier: assign, title: title, options: [.authenticationRequired, .foreground]),
                opening,
            ], intentIdentifiers: [], hiddenPreviewsBodyPlaceholder: LockScreenText.keptPlaceholder, options: [.hiddenPreviewsShowTitle])
        }
        // Adding takes an unlocked iPhone, as anything Binders then does with it might leave your devices.
        let adding = UNNotificationAction(identifier: add, title: "Add", options: [.authenticationRequired])
        let notNowing = UNNotificationAction(identifier: notNow, title: "Not Now")
        /// An offer. Swiping it away says Not Now, as the button does.
        func offer(_ identifier: String, _ actions: [UNNotificationAction]) -> UNNotificationCategory {
            UNNotificationCategory(identifier: identifier, actions: actions, intentIdentifiers: [], hiddenPreviewsBodyPlaceholder: LockScreenText.waitingPlaceholder,
                                   options: [.customDismissAction, .hiddenPreviewsShowTitle])
        }
        // Handed to an agent without asking: Stop needs no unlock, as stopping sends nothing.
        let handed = UNNotificationCategory(identifier: handedCategory, actions: [
            UNNotificationAction(identifier: stop, title: "Stop"), undoing, UNNotificationAction(identifier: notMe, title: "Not Me"), opening,
        ], intentIdentifiers: [], hiddenPreviewsBodyPlaceholder: LockScreenText.handedPlaceholder, options: [.hiddenPreviewsShowTitle])
        let auto = UNNotificationCategory(identifier: autoCategory, actions: [], intentIdentifiers: [],
                                          hiddenPreviewsBodyPlaceholder: LockScreenText.aboutPlaceholder, options: [.hiddenPreviewsShowTitle])
        // A capture's hand-overs (lane Y2): Stop All needs no unlock, as stopping sends nothing.
        let capture = UNNotificationCategory(identifier: captureHandedCategory, actions: [
            opening, UNNotificationAction(identifier: stopAll, title: "Stop All"),
        ], intentIdentifiers: [], hiddenPreviewsBodyPlaceholder: LockScreenText.foundPlaceholder, options: [.hiddenPreviewsShowTitle])
        return [handed, auto, capture, offer(offerCategory, [adding, notNowing, UNNotificationAction(identifier: notMe, title: "Not Me"), opening]),
                offer(askedOfferCategory, [adding, notNowing, opening]),
                done(doneCategory, giveTo: "Give to an Agent"),
                UNNotificationCategory(identifier: undoCategory, actions: [undoing, opening], intentIdentifiers: [],
                                       hiddenPreviewsBodyPlaceholder: LockScreenText.keptPlaceholder, options: [.hiddenPreviewsShowTitle]),
                UNNotificationCategory(identifier: answerCategory, actions: [opening, UNNotificationAction(identifier: notRight, title: "Not Right")],
                                       intentIdentifiers: [], hiddenPreviewsBodyPlaceholder: LockScreenText.answeredPlaceholder,
                                       options: [.hiddenPreviewsShowTitle]),
                UNNotificationCategory(identifier: noteCategory, actions: [opening], intentIdentifiers: [],
                                       hiddenPreviewsBodyPlaceholder: LockScreenText.aboutPlaceholder, options: [.hiddenPreviewsShowTitle]),
                UNNotificationCategory(identifier: kindsCategory, actions: [], intentIdentifiers: [],
                                       hiddenPreviewsBodyPlaceholder: LockScreenText.aboutPlaceholder, options: [.hiddenPreviewsShowTitle])]
            + givingAgents.map { done(giveCategory($0), giveTo: LockScreenText.giveTo($0)) }
    }

    /// The agents a Give to button has named, newest last: each keeps a category of its own, as a button's title is fixed
    /// with its category.
    private static var givingAgents: [String] {
        get { UserDefaults.standard.stringArray(forKey: "momentGiveAgents") ?? [] }
        set { UserDefaults.standard.set(Array(newValue.suffix(12)), forKey: "momentGiveAgents") }
    }

    /// The category whose Give to names this agent.
    static func giveCategory(_ agent: String) -> String {
        "moment-done-" + SHA256.hash(data: Data(agent.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    /// The buttons that fit what the Mac made of it: Add, Not Now and Open on an offer, and Not Me on one heard on its own;
    /// Undo, Give to (naming the agent) and Open once done; Open and Not Right on an answer.
    private static func category(for outcome: CaptureOutcome, heardOnItsOwn: Bool) async -> String {
        switch outcome.state {
        case "offered": return heardOnItsOwn ? offerCategory : askedOfferCategory
        case "acted" where outcome.handedOver != nil && (outcome.actions ?? []).contains("stop"): return handedCategory
        case "acted":
            let actions = outcome.actions ?? []
            guard actions.contains("assign") else { return actions.contains("undo") ? undoCategory : noteCategory }
            guard let agent = outcome.agent, !agent.isEmpty else { return doneCategory }
            let known = givingAgents.contains(agent)
            // The newest last, so the one let go past twelve is the one used longest ago.
            givingAgents = givingAgents.filter { $0 != agent } + [agent]
            if !known {
                SuggestionCenter.registerCategories()
                // Read back, so the new category is in place before the notification that uses it.
                _ = await UNUserNotificationCenter.current().notificationCategories()
            }
            return giveCategory(agent)
        default: return answerCategory
        }
    }

    /// What the Mac made of a moment, as a notification with what can be done next. On a Lock Screen that shows previews
    /// it says what was done and leaves your words out, unless you turned them on (LockScreen).
    private func post(_ outcome: CaptureOutcome) {
        // Answers heard on their own come quietly.
        var quietly = outcome.state == "answered" && moments.first(where: { $0.id == outcome.id })?.wake != true
        let heardOnItsOwn = moments.first { $0.id == outcome.id }?.isHeardOnItsOwn ?? false
        // Handed over: one each, in one thread, so iOS stacks a walk's worth; one soon after the last comes quietly.
        let handed = outcome.handedOver != nil
        if handed {
            let now = Date()
            if now.timeIntervalSince(lastHandedNotice) < AutoRules.quietWithin { quietly = true }
            lastHandedNotice = now
        }
        var shown = outcome
        // Late words: when they were said, by this iPhone's clock.
        if outcome.late == true, let heard = moments.first(where: { $0.id == outcome.id })?.heard {
            shown.line = AutoText.joined(outcome.line, AutoText.youSaidIt(heard, now: Date()))
        }
        Task {
            guard let text = LockScreenText.moment(shown, showsWords: await LockScreen.showsWords()) else { return }
            let content = UNMutableNotificationContent()
            content.title = text.title
            content.body = text.body
            content.categoryIdentifier = await Self.category(for: outcome, heardOnItsOwn: heardOnItsOwn)
            if handed { content.threadIdentifier = Self.handedThread }
            if quietly { content.interruptionLevel = .passive }
            content.userInfo = ["moment": outcome.id.uuidString]
            try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "moment-\(outcome.id.uuidString)", content: content,
                                                                                     trigger: nil))
        }
    }

    // MARK: Storage

    /// Inside the capture folder, so out of backups, and in a folder of their own, so nothing reads one as a conversation.
    private static var folder: URL {
        let folder = CaptureFiles.folder.appendingPathComponent("Moments", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                 attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        return folder
    }

    private static func loadAll() -> [CapturedMoment] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { try? JSONDecoder().decode(CapturedMoment.self, from: EarlierSpellings.json(Data(contentsOf: $0))) }
    }

    private func save(_ moment: CapturedMoment) {
        moments.removeAll { $0.id == moment.id }
        moments.append(moment)
        if let data = try? JSONEncoder().encode(moment) {
            try? data.write(to: Self.folder.appendingPathComponent("\(moment.id.uuidString).json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
        // Heard and done today, on the Today widget.
        CaptureActivity.update()
    }

    private func update(_ id: UUID, _ change: (inout CapturedMoment) -> Void) {
        guard var moment = moments.first(where: { $0.id == id }) else { return }
        change(&moment)
        save(moment)
    }

    /// Sent ones, and ones the Mac couldn't read, go after a week; nothing heard and not kept was ever written.
    func tidy(now: Date = Date()) {
        func old(_ moment: CapturedMoment) -> Bool {
            (moment.state == "sent" || moment.state == "refused") && now.timeIntervalSince(moment.heard) > 7 * 86_400
        }
        for moment in moments where old(moment) {
            try? FileManager.default.removeItem(at: Self.folder.appendingPathComponent("\(moment.id.uuidString).json"))
        }
        moments.removeAll(where: old)
    }
}
