import BindersKit
import SwiftUI

/// Whether the tabs' Dictate control is showing, so screens inside them don't add their own.
private struct TalkControlShownKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var talkControlShown: Bool {
        get { self[TalkControlShownKey.self] }
        set { self[TalkControlShownKey.self] = newValue }
    }
}

/// The home on iOS 26 and later: Today first, then your binders and capture, with one control at the bottom (tap to
/// dictate, hold to ask) in glass over everything.
@available(iOS 26.0, *)
struct HomeTabs: View {
    enum Tab: Hashable { case today, binders, agents, capture }

    /// `-open agents|manager|agent` (development) starts on Agents.
    @State private var tab: Tab = ["agents", "manager", "agent"].contains(UserDefaults.standard.string(forKey: "open") ?? "") ? .agents : .today
    @State private var dictating = false
    @State private var asking = false
    /// What was asked by holding the control: Ask opens with it asked, or empty to type when nothing was heard.
    @State private var question = ""
    @State private var capturePath = NavigationPath()

    var body: some View {
        TabView(selection: $tab) {
            SwiftUI.Tab("Today", systemImage: "sun.max", value: Tab.today) { TodayHome() }
            SwiftUI.Tab("Binders", systemImage: "books.vertical", value: Tab.binders) { BindersView(handlesNotifications: false) }
            SwiftUI.Tab("Agents", systemImage: "sparkles", value: Tab.agents) { AgentsTab() }
            SwiftUI.Tab("Capture", systemImage: "waveform.and.mic", value: Tab.capture) { NavigationStack(path: $capturePath) { CaptureView() } }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .tabViewBottomAccessory {
            TalkControl(dictate: { dictating = true }, ask: { heard in
                question = heard
                asking = true
            })
        }
        .environment(\.talkControlShown, true)
        // Inside a binder, into that binder, as its own Dictate button does without the tabs.
        .sheet(isPresented: $dictating) {
            // And into the folder open in it; its binder, should the binder's page have let go of the name as the folder opened.
            let folder = PhoneNavigation.shared.folderInView
            let binder = PhoneNavigation.shared.binderInView ?? folder?.binder
            DictationSheet(binder: binder, folder: folder.flatMap { $0.binder == binder ? $0 : nil })
        }
        .sheet(isPresented: $asking) { if question.isEmpty { AskView() } else { AskView(question: question) } }
        // A notification tapped: Today opens what it's about.
        .onChange(of: PhoneNavigation.shared.pendingCard) { _, id in if id != nil { tab = .today } }
        .onChange(of: PhoneNavigation.shared.pendingConversation) { _, id in if id != nil { tab = .today } }
        .onChange(of: PhoneNavigation.shared.pendingMoment) { _, id in if id != nil { tab = .today } }
        // The capture screen is a tab of its own: there, rather than pushed onto Today.
        .onChange(of: PhoneNavigation.shared.pendingCapture, initial: true) { _, open in
            guard open else { return }
            PhoneNavigation.shared.pendingCapture = false
            capturePath = NavigationPath()
            tab = .capture
        }
        .onChange(of: PhoneNavigation.shared.pendingNeedsYou) { _, open in if open { tab = .today } }
    }
}

/// Tap to dictate, hold to ask: the one control at the bottom. Held, it listens at once (the microphone's red glyph and
/// the level, as dictating shows them) and the words appear as they're heard; let go, and Ask opens with that question
/// asked. Let go before anything was heard, and Ask opens empty, to type. Like dictating, it pauses All-day capture while
/// it listens. iOS can take the touch away while it's held (the tab bar's own gestures): then it keeps listening, says
/// "tap to ask", and the next tap asks (TalkTouch). Writing it down has a time limit (DictationSession.finishLimit), so
/// it never stays on "Writing it down…".
@available(iOS 26.0, *)
private struct TalkControl: View {
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement
    let dictate: () -> Void
    /// Ask, with what was heard while held; empty to type the question.
    let ask: (String) -> Void
    @State private var session = DictationSession()
    /// The finger on the control, and how far it has moved: a swipe across it isn't a tap.
    @GestureState private var touch: CGSize? = nil
    @State private var travelled: CGFloat = 0
    /// The touch ended as a lift (the gesture's end), rather than taken away by iOS (no end, only the reset).
    @State private var lifted = false
    @State private var talk = TalkTouch()
    @State private var holdTimer: Task<Void, Never>?
    @State private var limit: Task<Void, Never>?
    /// Counts each hold that starts listening, for its tap by touch.
    @State private var holds = 0

    /// How long a touch is before it's a hold.
    private static let holdAfter: Duration = .milliseconds(350)

    var body: some View {
        content
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .updating($touch) { value, state, _ in state = value.translation }
                .onEnded { _ in lifted = true })
            .onChange(of: touch) { before, now in
                if let now { travelled = max(travelled, hypot(now.width, now.height)) }
                if before == nil, now != nil {
                    touchDown()
                } else if before != nil, now == nil {
                    // The gesture's end and its reset come in the same update: told apart once both have had their say.
                    Task { @MainActor in
                        let wasLifted = lifted
                        lifted = false
                        touchUp(lifted: wasLifted)
                    }
                }
            }
            .sensoryFeedback(.impact(weight: .medium), trigger: holds)
            // Gone while listening (the app left, the tabs changed): the microphone goes back.
            .onDisappear {
                holdTimer?.cancel()
                limit?.cancel()
                if talk.isListening || session.phase == .listening || session.phase == .starting { session.cancel() }
                if talk.phase != .finishing { talk.reset() }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(talk.isListening ? "Listening" : "Dictate")
            .accessibilityHint("Say a note or a to-do. Touch and hold to ask your binders by voice.")
            .accessibilityAction { dictate() }
            // Holding is hard with VoiceOver: Ask opens, to type the question or say it with its microphone.
            .accessibilityAction(named: "Ask") { ask("") }
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("talkControl")
    }

    /// Let go to ask, or, once iOS took the touch away, tap.
    private var askLine: String { talk.phase == .loose || talk.phase == .looseTapping ? "tap to ask" : "let go to ask" }

    @ViewBuilder
    private var content: some View {
        if talk.phase == .finishing {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).tint(Palette.muted)
                Text("Writing it down…").foregroundStyle(Palette.muted).lineLimit(1)
            }
        } else if talk.isListening, isFailed {
            // No microphone (refused in Settings, say): Ask opens to type instead.
            HStack(spacing: 8) {
                Image(systemName: Problem.symbol)
                Text(talk.phase == .holding ? "Can't listen. Let go to type the question" : "Can't listen. Tap to type the question").lineLimit(1)
            }
            .foregroundStyle(Palette.ink)
        } else if talk.isListening, session.phase != .listening {
            HStack(spacing: 8) {
                Image(systemName: "mic.fill").foregroundStyle(Palette.faint)
                Text("Getting ready…").foregroundStyle(Palette.muted).lineLimit(1)
            }
        } else if talk.isListening {
            HStack(spacing: 8) {
                // Red while the microphone is live, and only then; the bars move only as it hears you.
                Image(systemName: "mic.fill").foregroundStyle(Palette.live)
                Meter(level: session.level, height: 18).fixedSize()
                if session.text.isEmpty {
                    Text("Listening… \(askLine)").foregroundStyle(Palette.muted).lineLimit(1)
                } else {
                    // Your words as they're heard, quoted as said; the latest stay in view.
                    Text(session.text).font(Typeface.quote(.subheadline)).foregroundStyle(Palette.ink).lineLimit(1).truncationMode(.head)
                }
            }
        } else {
            HStack(spacing: 8) {
                Image(systemName: "mic.fill")
                Text(placement == .inline ? "Dictate" : "Tap to dictate · hold to ask")
                    .lineLimit(1)
            }
        }
    }

    /// A touch: once it's held long enough, the microphone starts.
    private func touchDown() {
        travelled = 0
        lifted = false
        talk.down()
        guard talk.phase == .pressed else { return }
        holdTimer?.cancel()
        holdTimer = Task {
            try? await Task.sleep(for: Self.holdAfter)
            guard !Task.isCancelled, talk.phase == .pressed, session.phase == .idle || session.phase == .done || isFailed else { return }
            guard talk.held() == .listen else { return }
            holds += 1
            DictationSession.log.notice("Hold to ask: listening")
            // On its own: letting go cancels the wait for a hold, never the listening.
            Task { await session.start() }
            // However the touch goes, listening ends.
            limit?.cancel()
            limit = Task {
                try? await Task.sleep(for: .seconds(TalkTouch.longest))
                guard !Task.isCancelled, talk.timedOut() == .ask else { return }
                DictationSession.log.notice("Hold to ask: listened for the longest, asking")
                finishAsking()
            }
        }
    }

    /// Lifted: a tap dictates; a hold asks what was heard, or opens Ask empty when nothing was. Taken away by iOS while
    /// held: it keeps listening, and the next tap asks.
    private func touchUp(lifted: Bool) {
        holdTimer?.cancel()
        holdTimer = nil
        let before = talk.phase
        let outcome = lifted ? talk.up(travelled: travelled) : talk.cancelled(travelled: travelled)
        if !lifted, before == .holding || before == .looseTapping {
            DictationSession.log.notice("Hold to ask: the touch was taken away (\(String(describing: before), privacy: .public)), listening on until a tap")
        }
        switch outcome {
        case .dictate: dictate()
        case .ask: finishAsking()
        case .listen, .none: break
        }
    }

    /// Done listening: what was heard, written down within its time limit, then Ask.
    private func finishAsking() {
        limit?.cancel()
        limit = nil
        DictationSession.log.notice("Hold to ask: writing it down")
        Task {
            let heard = await session.finishHeard()
            DictationSession.log.notice("Hold to ask: asking (\(heard.isEmpty ? "nothing heard" : "\(heard.count) characters", privacy: .public))")
            talk.reset()
            ask(heard)
        }
    }

    private var isFailed: Bool {
        if case .failed = session.phase { return true }
        return false
    }
}

/// Today: what waits on you, what was heard and kept today, and what's happening on the boards. Something new drops in
/// with the filing spring, and once it's filed its binder's chip slides in.
struct TodayHome: View {
    @Environment(MacConnection.self) private var connection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var path = NavigationPath()
    @State private var cards: [Card] = []
    @State private var store = CaptureStore.shared
    @State private var suggestions = SuggestionCenter.shared
    @State private var moments = MomentCenter.shared
    @State private var headline: String?
    /// What Heard today held as Today first showed, and when that was: only what comes after drops in.
    @State private var heardAtOpening: Set<String>? = nil
    @State private var opened: Date? = nil

    enum Place: Hashable { case board, capture, happening, todos }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                NeedsYouSection(cards: cards, captures: store.conversations, offers: suggestions.suggestions, moments: moments.moments,
                                since: opened) { destination in
                    switch destination {
                    case .card(let id): path.append(CardLink(id: id))
                    case .board: path.append(Place.board)
                    case .capture: path.append(Place.capture)
                    case .conversation(let id): path.append(CapturedConversationLink(id: id))
                    case .moment(let id): path.append(MomentLink.moment(id))
                    case .moments: path.append(MomentLink.waiting)
                    }
                }
                heardToday
                Section("On the boards") {
                    if let headline { Text(headline).font(.subheadline).foregroundStyle(Palette.ink) }
                    NavigationLink(value: Place.happening) { Label("What's happening", systemImage: "waveform.path.ecg") }
                    NavigationLink(value: Place.board) { Label("Board", systemImage: "rectangle.split.3x1") }
                    NavigationLink(value: Place.todos) { Label("To-dos", systemImage: "checklist") }
                }
                .surfaceRows()
            }
            .listGround()
            // What joins Today, and where it's filed, moves with the filing spring (crossfades under Reduce Motion).
            .animation(Motion.filing(reduceMotion: reduceMotion), value: filing)
            .onAppear { if opened == nil { opened = .now } }
            .navigationTitle("Today")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { MacButton() } }
            .navigationDestination(for: Place.self) { place in
                switch place {
                case .board: CardBoardView(binder: nil).navigationTitle("Board")
                case .capture: CaptureView()
                case .happening: WorkStreamsView { path.append(Place.board) }
                case .todos: TodoBoard(binder: nil, allowsAdding: true).navigationTitle("To-dos")
                }
            }
            .navigationDestination(for: CardLink.self) { CardDetailView(id: $0.id) }
            .navigationDestination(for: CapturedConversationLink.self) { ConversationDetailView(id: $0.id) }
            // A moment's notification, opened: what it made, or its own page.
            .opensMoments(path: $path)
            .refreshable { await load() }
            .task(id: connection.revision("tasks")) { await load() }
            .onChange(of: PhoneNavigation.shared.pendingConversation, initial: true) { _, id in
                guard let id else { return }
                PhoneNavigation.shared.pendingConversation = nil
                path = NavigationPath()
                path.append(CapturedConversationLink(id: id))
            }
            // What needs you is at the top of Today.
            .onChange(of: PhoneNavigation.shared.pendingNeedsYou, initial: true) { _, open in
                guard open else { return }
                PhoneNavigation.shared.pendingNeedsYou = false
                path = NavigationPath()
            }
            .onChange(of: PhoneNavigation.shared.pendingCard, initial: true) { _, id in
                guard let id else { return }
                PhoneNavigation.shared.pendingCard = nil
                path = NavigationPath()
                path.append(CardLink(id: id))
            }
        }
    }

    /// Today's captures and the things you said to yourself, newest first, with what became of each, each opening its own
    /// page. One your Mac offers asks its question, with Add and Not Now. One heard while Today shows drops in; once it's
    /// filed, its binder's chip slides in beside it.
    @ViewBuilder
    private var heardToday: some View {
        let captures = store.today().prefix(5)
        let said = moments.today().prefix(5)
        if !captures.isEmpty || !said.isEmpty {
            Section("Heard today") {
                ForEach(Array(said)) { moment in
                    // Its page a tap away; one offered asks its question, with Add and Not Now right here.
                    NavigationLink(value: MomentLink.moment(moment.id)) { SaidRow(moment: moment) }
                        .momentOfferActions(moment)
                        .arrival("moment|\(moment.id)", present: $heardAtOpening, showing: { heardIDs }, since: opened)
                }
                ForEach(Array(captures)) { capture in
                    NavigationLink(value: CapturedConversationLink(id: capture.id)) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(alignment: .firstTextBaseline, spacing: 0) {
                                Text("\(capture.started.formatted(date: .omitted, time: .shortened))–\(capture.ended.formatted(date: .omitted, time: .shortened))")
                                    .font(.body.monospacedDigit())
                                    .foregroundStyle(Palette.ink)
                                Spacer(minLength: 0)
                                FiledChip(binder: filedBinder(capture))
                            }
                            // Not kept: nothing to write down, quieter than what was kept.
                            Text(capture.outcome ?? capture.notKept.map { "Not kept: \($0)" } ?? capture.waitingBecause.map { "waiting: \($0)" } ?? Self.word(capture))
                                .font(.caption).foregroundStyle(capture.notKept != nil ? Palette.faint : Palette.muted).lineLimit(2)
                        }
                    }
                    .arrival("capture|\(capture.id)", present: $heardAtOpening, showing: { heardIDs }, since: opened)
                }
                NavigationLink(value: Place.capture) { Label("All-day capture", systemImage: "waveform.and.mic") }
            }
            .surfaceRows()
        }
    }

    /// What Heard today shows now, by what each is.
    private var heardIDs: Set<String> {
        Set(moments.today().prefix(5).map { "moment|\($0.id)" } + store.today().prefix(5).map { "capture|\($0.id)" })
    }

    /// What the list's filing spring follows: what's heard today, where each was filed, and a moment's word (an offer
    /// answered folds its buttons away). Needs you follows its own.
    private var filing: [String] {
        moments.today().prefix(5).map { "\($0.id)|\($0.filedIn ?? "")|\($0.outcomeState ?? "")" }
            + store.today().prefix(5).map { "\($0.id)|\(filedBinder($0) ?? "")" }
    }

    /// The binder a capture was filed in, from what the Mac said of it.
    private func filedBinder(_ capture: CaptureEntry) -> String? {
        guard capture.outcomeState == CaptureOutcome.States.filed else { return nil }
        return BinderColors.filed(in: capture.outcome, connection: connection)
    }

    /// A capture's state in words, when nothing more is known about it yet.
    private static func word(_ capture: CaptureEntry) -> String {
        switch capture.state {
        case .recording: "Recording"
        case .recorded: "Waiting to be written down"
        case .transcribing, .labelling: "Being written down"
        case .queued: "Written down, waiting for your Mac"
        case .sent: "Sent to your Mac"
        case .failed: capture.hasTranscript ? "Not sent" : "Not written down"
        }
    }

    /// Last time's cards and headline at once; then the Mac's, asked for together, each shown as it lands.
    private func load() async {
        if cards.isEmpty, let copy = connection.cached("tasks-all", as: [Card].self) { cards = copy }
        if headline == nil, let digest = connection.cached("work-streams", as: WorkStreamsView.Digest.self) { headline = digest.headline }
        async let cardsLanded: Void = refreshCards()
        async let headlineLanded: Void = refreshHeadline()
        _ = await (cardsLanded, headlineLanded)
    }

    private func refreshCards() async {
        if let fresh = await connection.fetch("list_tasks", cache: "tasks-all", as: [Card].self).value { cards = fresh }
        // What needs you, on the widgets and the Live Activity too.
        CaptureActivity.update()
    }

    private func refreshHeadline() async {
        guard let fresh = await connection.fetch("work_streams", cache: "work-streams", as: WorkStreamsView.Digest.self,
                                                 keeping: WorkStreams.keepable).value else { return }
        headline = fresh.headline
        // The Today widget too: heard and done today, with the cards the Mac just said were finished.
        CaptureActivity.update(finished: fresh.doneToday.count)
    }
}
