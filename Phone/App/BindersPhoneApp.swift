import SwiftUI
import UserNotifications
import BindersKit

@main
struct BindersPhoneApp: App {
    @UIApplicationDelegateAdaptor(PhoneAppDelegate.self) private var delegate
    @State private var connection: MacConnection
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Before anything reads them: preferences an earlier test build saved under Auto mode's old name, under today's.
        EarlierSpellings.moveDefaults(in: .standard)
        // A voice threshold set from scores of the earlier voice scoring goes back to the default, once.
        VoicePrint.upgradeScoring()
        // First: recovering a capture left waiting asks for a background run, which needs the task registered.
        ConversationProcessor.setUp()
        // Made here rather than when a window appears: a background launch, to process conversations while the phone
        // charges, has no window.
        let connection = MacConnection()
        _connection = State(initialValue: connection)
        MacConnection.current = connection
        CaptureWiring.connect(connection)
        // An agent's question rings here too, whenever a board changes while the app holds the link.
        BoardQuestions.shared.connection = connection
        connection.onTasksChanged = { Task { await BoardQuestions.shared.check() } }
        connection.onApproval = { notice in Task { await BoardQuestions.shared.approvalAsked(notice) } }
        connection.onAnswerSettled = { card, sent in BoardQuestions.shared.answerSettled(card: card, sent: sent) }
        // Navigation titles rounded and heavy, before any bar shows.
        PhoneTheme.configureBars()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(connection)
                .onOpenURL { url in
                    // The Binders keyboard opens binders://keyboard to have the app listen for it.
                    // The Live Activity and the widgets open binders://capture, binders://needs-you and binders://today:
                    // Today opens at its top, where what needs you is.
                    if url.scheme == "binders", url.host == "capture" || url.host == "needs-you" || url.host == "today" {
                        if url.host == "capture" { PhoneNavigation.shared.pendingCapture = true } else { PhoneNavigation.shared.pendingNeedsYou = true }
                        return
                    }
                    // A card's link back to its note opens inside the card (CardDetailView); from anywhere else, just the app.
                    if url.scheme == "binders", url.host == "note" { return }
                    // A hub's sign-in handing its token back, when it came to the app rather than to the sign-in sheet.
                    if url.scheme == "binders", url.host == "auth" {
                        Task { _ = await connection.finishHubSignIn(url) }
                        return
                    }
                    if url == KeyboardBridge.listenURL {
                        // Opened cold by the keyboard, this can come before .task.
                        KeyboardListener.shared.connection = connection
                        KeyboardListeningWindow.show()
                        Task { await KeyboardListener.shared.listen() }
                    } else {
                        // The Camera opens binders://pair links from the QR code on the Mac.
                        Task { await connection.pair(with: url) }
                    }
                }
                .task {
                    KeyboardListener.shared.connection = connection
                    #if DEBUG
                    // For development: `-unpair YES` forgets the Mac on launch, to see the iPhone on its own.
                    if UserDefaults.standard.bool(forKey: "unpair") { connection.unpair() }
                    #endif
                    #if DEBUG
                    // For development: `-hubURL <address> -hubToken <bnp_…>` signs in to a hub without the browser, and
                    // makes it the brain, as the Simulator's sign-in can't be driven from a script.
                    if let typed = UserDefaults.standard.string(forKey: "hubURL"), let token = UserDefaults.standard.string(forKey: "hubToken"),
                       let address = HubSignIn.address(typed) ?? URL(string: typed) {
                        await connection.signedInToHub(address: address, token: token)
                    }
                    #endif
                    // For development: `-pairURL <link>` pairs on launch, as the Simulator has no camera.
                    if let link = UserDefaults.standard.string(forKey: "pairURL"), let url = URL(string: link) {
                        await connection.pair(with: url)
                    }
                }
        }
        .onChange(of: scenePhase) { _, phase in
            // Control Center, a notification pulled down or the app switcher only make it inactive: the link stays.
            if phase != .inactive { connection.sceneChanged(active: phase == .active) }
            if phase == .active {
                ConversationProcessor.shared.appBecameActive()
                CaptureSession.shared.appBecameActive()
                CaptureActivity.refreshIfOld()
            } else {
                ConversationProcessor.shared.appLeftForeground(toBackground: phase == .background)
            }
        }
    }
}

struct RootView: View {
    @Environment(MacConnection.self) private var connection
    @State private var capture = CaptureSession.shared
    /// Dark unless you choose Light or Match System (`-appearance light` for development).
    @AppStorage(AppAppearance.key) private var appearance = "dark"

    var body: some View {
        Group {
            if let sample = autoSheetSample {
                // For the screenshots: the Auto sheet with a stand-in Mac's agents, paired or not.
                sampleHost(sample)
            } else if !connection.hasBrain || showsPairingForDevelopment {
                // Without a brain (a Mac paired, or a hub signed in to), what works on this iPhone alone: dictation, the
                // keyboard and All-day capture, and the two ways to get one.
                PairingView()
            } else {
                // The Mac's status, once, over every tab and every screen pushed on them.
                home.macStatusPill()
            }
        }
        // The brand's indigo as words read on the ground; primary buttons fill with it (primaryButton()).
        .tint(Palette.accentText)
        .preferredColorScheme(AppAppearance.scheme(appearance))
        // On the windows too: the keyboard's listening window, and Match System straight back to the system's.
        .onChange(of: appearance, initial: true) { AppAppearance.apply(appearance) }
        // By touch, from anywhere in the app: success when something is filed or approved, a warning when something
        // newly needs you, a light tap for a change made by hand.
        .hapticFeedback()
        // All-day capture never turns itself back on after a quit: it asks.
        .alert("Resume all-day capture?", isPresented: Binding(get: { capture.askToResume },
                                                                 set: { if !$0 { capture.askToResume = false } })) {
            Button("Resume") { Task { await capture.turnOn() } }
            Button("Not Now", role: .cancel) { capture.declineResume() }
        } message: {
            Text("It was on when Binders last closed.")
        }
    }

    @ViewBuilder
    private var home: some View {
        if #available(iOS 26.0, *), !usesClassicHome {
            HomeTabs()
        } else {
            BindersView()
        }
    }

    /// For development and the UI tests written for it: `-classicHome YES` keeps the home from before the tabs.
    private var usesClassicHome: Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: "classicHome")
        #else
        false
        #endif
    }

    /// The stand-in sheet itself, only in Debug builds (a Release build never has a sample to show).
    @ViewBuilder
    private func sampleHost(_ sample: AutoSheetSample) -> some View {
        #if DEBUG
        AutoSheetSampleHost(sample: sample)
        #else
        EmptyView()
        #endif
    }

    /// For the screenshots: `-autoSheetSample mixed|none|empty` opens the Auto sheet with a stand-in Mac's agents.
    private var autoSheetSample: AutoSheetSample? {
        #if DEBUG
        AutoSheetSample.fromLaunch
        #else
        nil
        #endif
    }

    /// For development, on a Simulator that's paired: `-showPairing YES` shows the screen an unpaired iPhone opens on.
    private var showsPairingForDevelopment: Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: "showPairing")
        #else
        false
        #endif
    }
}

/// Puts All-day capture's pieces together as the app starts.
@MainActor
enum CaptureWiring {
    static func connect(_ connection: MacConnection) {
        let processor = ConversationProcessor.shared
        processor.connection = connection
        connection.onConversationSent = { id in
            CaptureStore.shared.update(id) {
                $0.state = .sent
                $0.note(CaptureStep.sent, connection.brainName)
            }
        }
        connection.onConversationRefused = { id in
            CaptureStore.shared.update(id) {
                $0.state = .failed
                $0.error = "\(MacConnection.BrainWords) couldn't read this capture."
            }
        }
        CaptureSession.shared.onConversationClosed = { processor.conversationClosed($0) }
        // While you talk, a word to the Mac: it loads its model, and a Mac gone to sleep is noticed.
        CaptureSession.shared.onSpeech = { connection.warm() }
        processor.recover()
        // What the Mac offers once it has written a conversation up, asked for whenever the Mac's meetings change.
        let suggestions = SuggestionCenter.shared
        suggestions.connection = connection
        // And what became of each capture, asked after the same way.
        let outcomes = OutcomeCenter.shared
        outcomes.connection = connection
        // What you say to yourself, and what the Mac made of it.
        MomentCenter.shared.connection = connection
        // The kinds that have graduated, for a moment kept in Auto or Add at Once that goes as Suggest now: there before
        // the first connect, so the outbox never sends one without it.
        connection.graduatedKinds = { MomentCenter.shared.graduatedKinds }
        connection.onMomentSettled = { id, outcome, sent in MomentCenter.shared.settled(id, outcome: outcome, sent: sent) }
        // A Give to kept while the Mac was away, gone now or turned down.
        connection.onHandOffSettled = { item, sent, message in MomentCenter.shared.handOffSettled(item, sent: sent, message: message) }
        connection.onMeetingsChanged = {
            Task {
                await suggestions.refresh()
                await outcomes.refresh()
            }
        }
        // While capture listens, stay connected, so those offers arrive while you're out.
        keep { CaptureSession.shared.isListening } changing: { connection.keepsConnected = $0 }
        #if DEBUG
        // For development, as the Simulator can't listen: `-processSample YES` runs the sample recording through it all.
        if UserDefaults.standard.bool(forKey: "processSample") { processor.processSample() }
        // `-sampleCaptures YES`: made-up captures for today and the five days before, for screenshots.
        if UserDefaults.standard.bool(forKey: "sampleCaptures") { CaptureStore.shared.fillSamples() }
        // `-sayMoment "Binders, …"`: a moment, as if heard.
        if let said = UserDefaults.standard.string(forKey: "sayMoment") { MomentCenter.shared.pretend(said) }
        // `-openConversation latest` opens the newest conversation.
        if UserDefaults.standard.string(forKey: "openConversation") == "latest" {
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                PhoneNavigation.shared.pendingConversation = CaptureStore.shared.conversations.first?.id
            }
        }
        #endif
    }
}

/// Calls `changing` with the value now and whenever it changes.
@MainActor
private func keep<T: Equatable>(_ value: @escaping @MainActor () -> T, changing: @escaping @MainActor (T) -> Void) {
    let now = withObservationTracking { value() } onChange: {
        Task { @MainActor in keep(value, changing: changing) }
    }
    changing(now)
}

/// The app's delegate, for what SwiftUI doesn't do: the background task that processes conversations while the phone
/// charges, and the "All-day capture paused" notification.
final class PhoneAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Registered in the app's init already; this is a no-op unless that ever moves.
        ConversationProcessor.setUp()
        UNUserNotificationCenter.current().delegate = self
        SuggestionCenter.registerCategories()
        // The Live Activity's buttons and the control, which iOS may run before anything else has started.
        CaptureControls.handler = { action in
            let capture = CaptureSession.shared
            switch action {
            case .mute: capture.mute()
            case .wrapUp: capture.wrapUp()
            case .listen:
                if capture.status == .off {
                    // The first time, the capture screen reminds you to let the people around you know, before it listens;
                    // and turning it on from off takes an unlocked iPhone (muting doesn't).
                    guard UserDefaults.standard.bool(forKey: "captureNoticeAcknowledged") else { return capture.askToTurnOnInApp() }
                    guard UIApplication.shared.isProtectedDataAvailable else { return capture.askToUnlockFirst() }
                    await capture.turnOn()
                } else if capture.isMuted { capture.unmute() } else { await capture.resume() }
            }
            // One of capture's own buttons is running, so iOS lets Binders show its Live Activity from the background: one
            // that ended while capture was on comes back.
            CaptureActivity.update()
        }
        return true
    }

    /// Quit on purpose: no "stopped" notice to come. (iOS doesn't always say.)
    func applicationWillTerminate(_ application: UIApplication) {
        MainActor.assumeIsolated { CaptureSession.shared.disarmNotices() }
    }

    /// Tapping "All-day capture paused" brings it back. A suggestion: Add to Board or Not Now say so to the Mac; a tap opens
    /// the conversation. An agent's question: the answer typed into it goes to the card; a request for approval: a tap or
    /// Open opens the card, where you decide; a tap, Open, or the note about an answer that didn't go, opens the card.
    /// Something you said to yourself: its buttons, and a tap or Open opens what it made (the card, the to-do in its
    /// binder) or its own page.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let content = response.notification.request.content
        if content.categoryIdentifier == CaptureSession.pausedCategory {
            await CaptureSession.shared.resume()
            return
        }
        // The capture screen: from "Turn on All-day capture in Binders"; from "Capture is still listening", where in front
        // its Live Activity shows again; and from a kind of moment now added at once with Undo or offered again, where it
        // can be switched back.
        if [CaptureSession.firstTimeCategory, CaptureActivity.lostCategory, MomentCenter.kindsCategory].contains(content.categoryIdentifier) {
            if response.actionIdentifier != UNNotificationDismissActionIdentifier {
                await MainActor.run { PhoneNavigation.shared.pendingCapture = true }
            }
            return
        }
        // Auto turned itself off, or can hand things over now: the capture screen, and for the second the sheet.
        if content.categoryIdentifier == MomentCenter.autoCategory {
            if response.actionIdentifier != UNNotificationDismissActionIdentifier {
                let sheet = content.userInfo["sheet"] as? Bool == true
                await MainActor.run {
                    PhoneNavigation.shared.pendingCapture = true
                    if sheet { MomentCenter.shared.showingAutoSheet = true }
                }
            }
            return
        }
        // A capture's hand-overs (lane Y2): Stop All stops them, its line in the notification's place; Open, or a tap, its page.
        if content.categoryIdentifier == MomentCenter.captureHandedCategory,
           let capture = (content.userInfo["capture"] as? String).flatMap(UUID.init(uuidString:)) {
            switch response.actionIdentifier {
            case MomentCenter.stopAll:
                let time = await MainActor.run { BackgroundTime(name: "Binders capture") }
                let result = await MomentCenter.shared.stopAll(capture)
                await MainActor.run {
                    MomentCenter.note(capture, title: result.ok ? "Stopped" : "Couldn't do that", body: result.message)
                    time.end()
                }
            case UNNotificationDismissActionIdentifier: break
            default:
                await MainActor.run { PhoneNavigation.shared.pendingConversation = capture }
            }
            return
        }
        if let moment = (content.userInfo["moment"] as? String).flatMap(UUID.init(uuidString:)) {
            let time = await MainActor.run { BackgroundTime(name: "Binders moment") }
            /// What the Mac said when it couldn't: the notification it came from is gone, so another says so.
            func told(_ result: (ok: Bool, message: String)) async {
                guard !result.ok else { return }
                await MainActor.run { MomentCenter.couldNot(moment, result.message) }
            }
            switch response.actionIdentifier {
            case MomentCenter.add:
                // Added: what was done comes back in the offer's place, with Undo, Give to and Open.
                let result = await MomentCenter.shared.act(moment, "add")
                if result.ok { await MomentCenter.shared.followUp(moment) } else { await told(result) }
            case MomentCenter.notNow:
                _ = await MomentCenter.shared.act(moment, "not-now")
            case UNNotificationDismissActionIdentifier where [MomentCenter.offerCategory, MomentCenter.askedOfferCategory].contains(content.categoryIdentifier):
                // An offer swiped away: Not Now, as its button says.
                _ = await MomentCenter.shared.act(moment, "not-now")
            // On a hand-over, the line of what was done takes its notification's place, whatever it says (toldAfter).
            case MomentCenter.stop:
                let result = await MomentCenter.shared.act(moment, "stop")
                await MainActor.run { MomentCenter.shared.toldAfter(moment, result) }
            case MomentCenter.notMe where content.categoryIdentifier == MomentCenter.handedCategory:
                let result = await MomentCenter.shared.notMe(moment)
                await MainActor.run { MomentCenter.shared.toldAfter(moment, result) }
            case MomentCenter.undo where content.categoryIdentifier == MomentCenter.handedCategory:
                let result = await MomentCenter.shared.act(moment, "undo")
                await MainActor.run { MomentCenter.shared.toldAfter(moment, result) }
            case MomentCenter.notMe: await told(await MomentCenter.shared.notMe(moment))
            case MomentCenter.undo: await told(await MomentCenter.shared.act(moment, "undo"))
            case MomentCenter.assign:
                // The first time for an agent, the capture screen asks before anything goes to it.
                let agent = await MainActor.run { MomentCenter.shared.moments.first { $0.id == moment }?.agent }
                if let agent, !MomentCenter.agreed(to: agent) {
                    await MainActor.run {
                        MomentCenter.shared.consenting = moment
                        PhoneNavigation.shared.pendingCapture = true
                    }
                } else {
                    let result = await MomentCenter.shared.act(moment, "assign")
                    // The Mac out of reach: kept, and a word says so, as the notification it came from is gone.
                    if result.ok, result.message == MomentCenter.keptForMac {
                        await MainActor.run { MomentCenter.note(moment, title: "Waiting for \(MacConnection.current?.brainPhrase ?? "\(MacConnection.brainWords)")", body: result.message) }
                    } else {
                        await told(result)
                    }
                }
            case MomentCenter.notRight: await MainActor.run { MomentCenter.shared.markNotRight(moment) }
            case UNNotificationDismissActionIdentifier: break
            // Open, or the notification itself. A word about it ("Couldn't do that") opens its own page, to try again.
            default:
                let page = content.categoryIdentifier == MomentCenter.noteCategory
                await MainActor.run { MomentCenter.shared.open(moment, page: page) }
            }
            await MainActor.run { time.end() }
            return
        }
        if let card = content.userInfo["card"] as? String {
            // An agent asks your approval: decided only on the card. Approve or Decline from an earlier build's notification
            // opens it (its consent variant brought the app up) or says to open it.
            let approving = [BoardQuestions.approvalCategory, BoardQuestions.approvalConsentCategory].contains(content.categoryIdentifier)
            if approving, [BoardQuestions.approve, BoardQuestions.decline].contains(response.actionIdentifier) {
                await MainActor.run {
                    BoardQuestions.shared.decisionTapped(card: card, opened: content.categoryIdentifier == BoardQuestions.approvalConsentCategory)
                }
                return
            }
            let text = (response as? UNTextInputNotificationResponse)?.userText.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let question = [BoardQuestions.category, BoardQuestions.consentCategory].contains(content.categoryIdentifier)
            if question, response.actionIdentifier == BoardQuestions.answer, !text.isEmpty {
                // Your words go to the agent that asked: one you haven't said yes to yet asks on the card first. The card's
                // title rides along (the subtitle names its binder where your words may not show); one rung by an earlier
                // build has it as the subtitle.
                await BoardQuestions.shared.answer(card, asked: content.userInfo["asked"] as? String, text: text,
                                                   about: content.userInfo["title"] as? String ?? content.subtitle,
                                                   agent: BoardQuestions.asker(content), opened: content.categoryIdentifier == BoardQuestions.consentCategory)
            } else if response.actionIdentifier != UNNotificationDismissActionIdentifier {
                await MainActor.run { PhoneNavigation.shared.pendingCard = card }
            }
            return
        }
        guard let suggestion = content.userInfo["suggestion"] as? String else { return }
        let conversation = (content.userInfo["conversation"] as? String).flatMap(UUID.init(uuidString:))
        switch response.actionIdentifier {
        case SuggestionCenter.add:
            let message = await SuggestionCenter.shared.act(suggestion, accept: true)
            let done = UNMutableNotificationContent()
            done.body = message
            try? await center.add(UNNotificationRequest(identifier: "done-\(suggestion)", content: done, trigger: nil))
        case SuggestionCenter.give:
            // Give to: the capture opens with the agents to choose from, and asks first the first time for each.
            await MainActor.run {
                SuggestionCenter.shared.pendingGive = suggestion
                PhoneNavigation.shared.pendingConversation = conversation
            }
        case SuggestionCenter.notNow, UNNotificationDismissActionIdentifier:
            await SuggestionCenter.shared.act(suggestion, accept: false)
        default:
            await MainActor.run { PhoneNavigation.shared.pendingConversation = conversation }
        }
    }

    /// With the app open: a banner. An agent's question or request for approval also rings, and stays in Notification
    /// Center until it's answered.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        BoardQuestions.waitingCategories.contains(notification.request.content.categoryIdentifier) ? [.banner, .list, .sound] : [.banner]
    }
}

extension View {
    /// What went wrong with a change, for a few seconds at the foot of the screen: it doesn't stop you. A tap dismisses it.
    func problemToast(_ problem: Binding<String?>) -> some View {
        modifier(ProblemToast(problem: problem))
    }
}

/// The toast rises from the foot of the screen; under Reduce Motion it fades in and out where it is.
private struct ProblemToast: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var problem: String?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let text = problem {
                    ProblemLabel(text)
                        .font(.footnote)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .floatingGlass(in: Capsule())
                        .padding()
                        .onTapGesture { problem = nil }
                        .task(id: text) {
                            UIAccessibility.post(notification: .announcement, argument: text)
                            try? await Task.sleep(for: .seconds(4))
                            if problem == text { problem = nil }
                        }
                        .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                        .accessibilityIdentifier("problemToast")
                }
            }
            .animation(reduceMotion ? .easeInOut(duration: 0.2) : .default, value: problem)
    }
}

