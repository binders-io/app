import BindersKit
import SwiftUI

/// Where a moment's notification leads, on a stack that opens what notifications are about.
enum MomentLink: Hashable {
    /// Its own page.
    case moment(UUID)
    /// The to-dos of the binder its to-do went into.
    case todos(binder: String)
    /// The things you said that wait on your Add or Not Now, from Needs you.
    case waiting
}

/// Opens what a moment's notification is about on this stack (Today in the tabs, the classic home): the card it made, the
/// to-do in its binder, or its own page.
private struct OpensMoments: ViewModifier {
    @Binding var path: NavigationPath
    let enabled: Bool

    func body(content: Content) -> some View {
        content
            .navigationDestination(for: MomentLink.self) { link in
                switch link {
                case .moment(let id): MomentDetailView(id: id)
                case .todos(let binder): BinderTodos(binder: binder)
                case .waiting: OfferedMomentsView()
                }
            }
            .onChange(of: PhoneNavigation.shared.pendingMoment, initial: true) { _, id in
                guard enabled, let id else { return }
                PhoneNavigation.shared.pendingMoment = nil
                path = NavigationPath()
                let page = PhoneNavigation.shared.pendingMomentPage
                PhoneNavigation.shared.pendingMomentPage = false
                switch page ? MomentCenter.Place.moment(id) : MomentCenter.shared.place(id) {
                case .card(let card): path.append(CardLink(id: card))
                case .todos(let binder): path.append(MomentLink.todos(binder: binder))
                case .moment(let id): path.append(MomentLink.moment(id))
                }
            }
    }
}

extension View {
    /// A moment's notification, opened, opens what it's about here.
    func opensMoments(path: Binding<NavigationPath>, enabled: Bool = true) -> some View {
        modifier(OpensMoments(path: path, enabled: enabled))
    }
}

/// A binder's to-dos, where a moment's to-do went: the binder's own page when this iPhone knows the binder, its to-dos
/// alone until it does.
struct BinderTodos: View {
    @Environment(MacConnection.self) private var connection
    let binder: String

    var body: some View {
        if let known = connection.cached("binders", as: [BinderInfo].self)?.first(where: { $0.name == binder }) {
            BinderDetailView(binder: known)
        } else {
            TodoBoard(binder: binder, allowsAdding: true).navigationTitle(binder)
        }
    }
}

/// One thing you said to yourself, opened from its notification or the capture screen: what you said, what your Mac made
/// of it, and what can be done now. An answer that wasn't right can be marked so, and asked again in Ask.
struct MomentDetailView: View {
    @Environment(MacConnection.self) private var connection
    let id: UUID
    @State private var center = MomentCenter.shared
    @State private var message: String?
    @State private var working = false
    @State private var consenting = false
    @State private var askingAgain = false
    /// Turn Off Auto tapped here: the mode it went back to.
    @State private var turnedOffTo: MomentMode?

    private var moment: CapturedMoment? { center.moments.first { $0.id == id } }

    var body: some View {
        List {
            if let moment {
                Section {
                    // Your own words, as Binders quotes them.
                    Text("“\(moment.text ?? "")”").font(Typeface.quote()).foregroundStyle(Palette.ink)
                } header: {
                    Text("You said")
                } footer: {
                    Text(heard(moment)).monospacedDigit()
                }
                .surfaceRows()
                Section {
                    made(moment)
                } header: {
                    Text(moment.title ?? "\(MacConnection.BrainWords)")
                }
                .surfaceRows()
                next(moment)
                auto(moment)
            } else {
                EmptyState("Not on this iPhone any more", symbol: "text.bubble",
                           description: "What you say to yourself is kept here for a week.")
            }
        }
        .listGround()
        .navigationTitle("Said to yourself")
        .navigationBarTitleDisplayMode(.inline)
        // The first time something goes to an agent: where it goes, and what goes with it (App Store 5.1.2(i)).
        .confirmationDialog("Give cards to \(moment?.agent ?? "this agent")?", isPresented: $consenting, titleVisibility: .visible) {
            if let agent = moment?.agent {
                Button("Give to \(agent)") {
                    MomentCenter.agree(to: agent)
                    run("assign")
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(MomentRow.disclosure(moment?.agent, connection: connection))
        }
        .sheet(isPresented: $askingAgain, onDismiss: { center.askedAgain(id) }) { AskView(question: moment?.text ?? "") }
    }

    /// When it was heard, and how: said with "Binders, …", heard on its own (and checked by Apple's model here), to Siri,
    /// or found in a conversation later.
    private func heard(_ moment: CapturedMoment) -> String {
        let when = moment.heard.formatted(date: Calendar.current.isDateInToday(moment.heard) ? .omitted : .abbreviated, time: .shortened)
        // Lane Y2: one of a capture's items.
        if moment.capture != nil { return AutoPhoneText.itemHeard(when, mode: MomentMode(stored: moment.mode)) }
        let how = moment.engine == "siri" ? "told to Siri"
            : moment.fromTranscript == true ? "found in a conversation once it was written down"
            : moment.wake == true ? "said with “Binders”"
            : moment.checked != nil ? "heard on its own, and Apple Intelligence on this iPhone agreed what it was" : "heard on its own"
        let auto = moment.heardInAuto && moment.engine != "siri" && moment.fromTranscript != true ? AutoPhoneText.inAuto : ""
        return "\(when), \(how)\(auto)"
    }

    /// One step from where a hand-over's notification lands: Turn Off Auto, on a page whose moment was heard in Auto,
    /// while Auto is on. Its footer names the mode it goes back to; once tapped, the section says so.
    @ViewBuilder
    private func auto(_ moment: CapturedMoment) -> some View {
        if let back = turnedOffTo {
            Section {
                Text(AutoPhoneText.turnedOff(back: back)).foregroundStyle(Palette.ink)
            } header: {
                Text("Auto")
            }
            .surfaceRows()
        } else if moment.heardInAuto, center.mode == .auto {
            Section {
                Button("Turn Off Auto") {
                    turnedOffTo = center.turnOffAuto()
                    UIAccessibility.post(notification: .announcement, argument: AutoPhoneText.turnedOff(back: turnedOffTo ?? .suggest))
                }
                .accessibilityHint(AutoPhoneText.pageFooter(back: center.modeAfterAuto))
                .accessibilityIdentifier("momentTurnOffAuto")
            } header: {
                Text("Auto")
            } footer: {
                Text(AutoPhoneText.pageFooter(back: center.modeAfterAuto)).accessibilityHidden(true)
            }
            .surfaceRows()
        }
    }

    /// What your Mac made of it: the answer with where it came from, or what was done; and what you did about it.
    @ViewBuilder
    private func made(_ moment: CapturedMoment) -> some View {
        switch moment.outcomeState {
        case nil where moment.state == "refused":
            ProblemLabel("\(MacConnection.BrainWords) couldn't read it.")
        case nil, "working"?:
            // Waiting, with why and what happens next.
            Label(moment.line, systemImage: "clock").foregroundStyle(Palette.muted)
        case "answered"?:
            MarkdownText(markdown: moment.shownOutcome)
            if let sources = moment.sources, !sources.isEmpty {
                Text("From " + sources.joined(separator: " · ")).font(.footnote).foregroundStyle(Palette.muted)
            }
        default:
            Text(moment.shownOutcome.isEmpty ? "Nothing to do" : moment.shownOutcome).foregroundStyle(Palette.ink)
        }
        if moment.notRight != nil {
            Label("You said this answer wasn't right.", systemImage: "hand.thumbsdown")
                .font(.footnote).foregroundStyle(Palette.muted)
        }
        if moment.notMe != nil {
            Label("You said this wasn't you. It's kept against your voice print.", systemImage: "person.crop.circle.badge.xmark")
                .font(.footnote).foregroundStyle(Palette.muted)
        }
        if let giving = connection.givingLater(moment: moment.id) {
            Label("Kept. It goes to \(giving.agent ?? "the agent") when \(MacConnection.brainWords) is back.", systemImage: "clock")
                .font(.footnote).foregroundStyle(Palette.muted)
        } else if let message, !message.isEmpty {
            Text(message).font(.footnote).foregroundStyle(Palette.muted)
        }
    }

    /// What it made, a tap away, and what can be done now.
    @ViewBuilder
    private func next(_ moment: CapturedMoment) -> some View {
        let actions = moment.actions ?? []
        let made = moment.outcomeState == "acted"
        Section {
            if made, let card = moment.card, !card.isEmpty {
                NavigationLink { CardDetailView(id: card) } label: { Label("Open Card", systemImage: "rectangle.split.3x1") }
            } else if made, moment.todo?.isEmpty == false, let binder = moment.binder, !binder.isEmpty {
                // A to-do with no card: on a Mac from before to-dos were cards, in its binder's to-dos; else its card is on the board.
                if MacConnection.current?.macFeatures.contains(LinkFeatures.todosAreCards) == true {
                    NavigationLink { CardBoardView(binder: binder) } label: { Label("Open the Board in \(binder)", systemImage: "rectangle.split.3x1") }
                } else {
                    NavigationLink { BinderTodos(binder: binder) } label: { Label("Open To-dos in \(binder)", systemImage: "checklist") }
                }
            }
            if moment.kind == MomentKind.status.rawValue || moment.title == "Your work streams" {
                NavigationLink { WorkStreamsPage() } label: { Label("What's Happening", systemImage: "waveform.path.ecg") }
            }
            // Lane Y2: read from a capture, or waiting for one: its page, and the capture's own wait.
            if let capture = moment.capture ?? moment.joins ?? (moment.conversation.flatMap { found in
                CaptureStore.shared.conversation(found)?.found?.contains { $0.id == moment.id } == true ? found : nil }) {
                if moment.joins != nil { Text(captureWait(capture)).font(.footnote).foregroundStyle(Palette.muted) }
                NavigationLink { ConversationDetailView(id: capture) } label: { Label(AutoPhoneText.openCapture, systemImage: "waveform") }
            }
            // Not Me is the page's own (below), which keeps the voice print too.
            ForEach(actions.filter { $0 != "not-me" }, id: \.self) { action in
                Button(MomentRow.title(action, agent: moment.agent)) {
                    if action == "assign", let agent = moment.agent, !MomentCenter.agreed(to: agent) { return consenting = true }
                    run(action)
                }
                .disabled(working || (action == "assign" && connection.givingLater(moment: moment.id) != nil)
                          || (["stop", "undo"].contains(action) && center.keptAction(for: moment.id) != nil))
            }
            if moment.isAnswer {
                if moment.notRight == nil {
                    Button("Not Right") { center.markNotRight(moment.id) }
                        .accessibilityIdentifier("momentNotRight")
                }
                Button("Ask Again") { askingAgain = true }
                    .accessibilityIdentifier("momentAskAgain")
            }
            if moment.mayBeNotMe {
                Button("Not Me") {
                    working = true
                    Task {
                        message = await center.notMe(id).message
                        working = false
                    }
                }
                .disabled(working)
                .accessibilityIdentifier("momentNotMe")
                if moment.capture != nil {
                    Text(AutoPhoneText.itemNotMeFooter).font(.footnote).foregroundStyle(Palette.muted)
                }
            }
        }
        .surfaceRows()
    }

    private func run(_ action: String) {
        working = true
        Task {
            message = await center.act(id, action).message
            working = false
        }
    }
}

/// One thing you said to yourself, as Today lists it: your words, when, and what your Mac made of them, or why it waits
/// and what comes next. One offered asks its question in amber ("Add to Personal?"), with what it would add and Add and
/// Not Now under it. Once it's filed, its binder's chip slides in beside your words.
struct SaidRow: View {
    let moment: CapturedMoment

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                // Your own words, as Binders quotes them.
                Text("“\(moment.text ?? "")”").font(Typeface.quote()).foregroundStyle(Palette.ink).lineLimit(2)
                Spacer(minLength: 0)
                FiledChip(binder: moment.filedIn)
            }
            if moment.isHeldForYou {
                // Waits on you elsewhere: its word in amber (Wake Now on your Mac, or Give to), then what was done.
                (Text(time).monospacedDigit().foregroundStyle(Palette.muted) + Text(" · ").foregroundStyle(Palette.muted)
                    + Text(moment.waiting == CaptureOutcome.Waiting.wake ? AutoPhoneText.notWokenWord : AutoPhoneText.waitsForGiveWord)
                        .fontWeight(.semibold).foregroundStyle(Palette.needsYou))
                    .font(.caption).lineLimit(2)
                if !moment.shownOutcome.isEmpty {
                    Text(moment.shownOutcome).font(.caption).foregroundStyle(Palette.muted).lineLimit(2)
                }
            } else if moment.waitsOnYou {
                // Yours to decide: the question in amber, then what would be added.
                (Text(time).monospacedDigit().foregroundStyle(Palette.muted) + Text(" · ").foregroundStyle(Palette.muted)
                    + Text(moment.title ?? "Add it?").fontWeight(.semibold).foregroundStyle(Palette.needsYou))
                    .font(.caption).lineLimit(2)
                if !moment.shownOutcome.isEmpty {
                    Text(moment.shownOutcome).font(.caption).foregroundStyle(Palette.muted).lineLimit(2)
                }
                MomentOfferButtons(moment: moment).padding(.top, 4)
            } else {
                Text([time, moment.line].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption.monospacedDigit()).foregroundStyle(Palette.muted).lineLimit(2)
            }
        }
    }

    private var time: String { moment.heard.formatted(date: .omitted, time: .shortened) }
}

/// Add and Not Now on something you said that your Mac offers, wherever it's listed: Add filled, Not Now beside it. Each
/// takes only its own tap, so the row around them still opens the moment's page. Add files it (a success by touch once
/// your Mac says so); Not Now lets it go. What your Mac said when it couldn't shows under them.
struct MomentOfferButtons: View {
    let moment: CapturedMoment
    @State private var working = false
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Button { run("add") } label: { Text("Add").frame(minWidth: 52) }
                    .primaryButton()
                    .accessibilityIdentifier("momentAdd")
                Button { run("not-now") } label: { Text("Not Now") }
                    .buttonStyle(.bordered)
                    .tint(Palette.ink)
                    .accessibilityIdentifier("momentNotNow")
            }
            .font(.subheadline.weight(.semibold))
            .controlSize(.small)
            .disabled(working)
            if let problem { ProblemLabel(problem).font(.caption) }
        }
    }

    private func run(_ action: String) {
        working = true
        Task {
            let result = await MomentCenter.shared.act(moment.id, action)
            working = false
            problem = result.ok ? nil : result.message
            // Let go, by hand: a light tap. (Added, it's the success when your Mac says it's filed.)
            if result.ok, action == "not-now" { Haptics.shared.tap() }
        }
    }
}

extension View {
    /// Add and Not Now as VoiceOver actions on a row that opens the moment's page, when your Mac offers it: a link's
    /// label can be read as one element, which would leave the buttons in it out of reach. What your Mac said when it
    /// couldn't is read out.
    func momentOfferActions(_ moment: CapturedMoment) -> some View {
        modifier(MomentOfferActions(moment: moment))
    }
}

private struct MomentOfferActions: ViewModifier {
    let moment: CapturedMoment

    func body(content: Content) -> some View {
        if moment.waitsOnYou {
            content
                .accessibilityAction(named: "Add") { run("add") }
                .accessibilityAction(named: "Not Now") { run("not-now") }
        } else if moment.isHandedOver {
            // Handed to an agent without asking: Stop, Undo and Not Me, each announcing the line of what it did.
            content
                .accessibilityAction(named: "Stop") { run("stop", always: true) }
                .accessibilityAction(named: "Undo") { run("undo", always: true) }
                .accessibilityAction(named: "Not Me") { notMe() }
        } else {
            content
        }
    }

    private func run(_ action: String, always: Bool = false) {
        let id = moment.id
        Task {
            let result = await MomentCenter.shared.act(id, action)
            if always || !result.ok { UIAccessibility.post(notification: .announcement, argument: result.message) }
        }
    }

    private func notMe() {
        let id = moment.id
        Task {
            let result = await MomentCenter.shared.notMe(id)
            UIAccessibility.post(notification: .announcement, argument: result.message)
        }
    }
}

/// The things you said to yourself that wait on your Add or Not Now, newest first, from Needs you: each with its question
/// and its buttons, and its page a tap away. One answered files away.
struct OfferedMomentsView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var center = MomentCenter.shared

    var body: some View {
        let waiting = NeedsYouSection.offered(center.moments)
        let held = NeedsYouSection.held(center.moments)
        List {
            // Waiting on your Give to, or on Wake Now on your Mac.
            if !held.isEmpty {
                Section {
                    ForEach(held, id: \.self) { id in
                        if let moment = center.moments.first(where: { $0.id == id }) {
                            NavigationLink(value: MomentLink.moment(id)) { SaidRow(moment: moment) }
                                .momentOfferActions(moment)
                        }
                    }
                } footer: {
                    Text(AutoPhoneText.waitsRow(held.count))
                }
                .surfaceRows()
            }
            if waiting.isEmpty, !held.isEmpty {
                EmptyView()
            } else if waiting.isEmpty {
                EmptyState("Nothing to add", symbol: "text.bubble", description: "You've answered everything Binders offered from what you said.")
            } else {
                Section {
                    ForEach(waiting, id: \.self) { id in
                        if let moment = center.moments.first(where: { $0.id == id }) {
                            NavigationLink(value: MomentLink.moment(id)) { SaidRow(moment: moment) }
                                .momentOfferActions(moment)
                        }
                    }
                } footer: {
                    Text("Add files it where \(MacConnection.brainWords) suggests. Not Now lets it go.")
                }
                .surfaceRows()
            }
        }
        .listGround()
        .animation(Motion.filing(reduceMotion: reduceMotion), value: waiting)
        .navigationTitle("Said to yourself")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Each kind you say to yourself, offered or added at once with Undo, and how far it has come: "To-dos: Suggesting, 12 of
/// 40". A kind added at once can be switched back to suggesting, and counts afresh from there.
struct MomentKindsRows: View {
    @State private var center = MomentCenter.shared

    var body: some View {
        ForEach(MomentGraduation.kinds, id: \.self) { kind in
            let progress = center.graduation.progress(kind)
            let summary = MomentGraduation.summary(progress)
            if progress.adding {
                Toggle(isOn: Binding(get: { true }, set: { on in if !on { center.suggestAgain(kind) } })) {
                    let detail = center.macAdds ? summary : "Added with Undo once \(MacConnection.onHub ? "your hub" : "Binders on \(MacConnection.brainWords)") is updated"
                    Text(MomentGraduation.plural(kind))
                    Text(detail).rollingCount(detail)
                }
                .accessibilityIdentifier("momentKind-\(kind.rawValue)")
            } else {
                // "Suggesting, 12 of 40": the count rolls as you answer.
                LabeledContent(MomentGraduation.plural(kind)) { Text(summary).rollingCount(summary) }
                    .accessibilityIdentifier("momentKind-\(kind.rawValue)")
            }
        }
    }
}

/// What's happening, from a moment's page, with the board a tap away.
private struct WorkStreamsPage: View {
    @State private var showingBoard = false

    var body: some View {
        WorkStreamsView { showingBoard = true }
            .navigationTitle("What's happening")
            .navigationDestination(isPresented: $showingBoard) { CardBoardView(binder: nil).navigationTitle("Board") }
    }
}

/// Your words in notifications while iOS shows previews on the Lock Screen: off unless you turn it on. With previews hidden
/// until you unlock, they're there either way, shown once you unlock.
struct LockScreenWordsSection: View {
    @State private var showsWords = LockScreen.showsWordsAlways
    @State private var previews: NotificationPreviews?

    var body: some View {
        Section {
            Toggle("Show what you said on the Lock Screen", isOn: Binding(get: { showsWords }, set: { on in
                showsWords = on
                LockScreen.showsWordsAlways = on
            }))
            .accessibilityIdentifier("lockScreenWords")
        } header: {
            Text("Lock Screen")
        } footer: {
            Text(footer)
        }
        .surfaceRows()
        .task { previews = await LockScreen.previews() }
    }

    private var footer: String {
        let rule = "When this is off, notifications say what was done, like “To-do added in Personal”, and leave what was said for Binders."
        switch previews {
        case .whenUnlocked?:
            return rule + " This iPhone shows notification previews only once it's unlocked, so they can hold your words either way."
        case .never?:
            return rule + " This iPhone doesn't show notification previews, so they can hold your words either way."
        default:
            return rule + " This iPhone shows notification previews on the Lock Screen (Settings → Notifications → Show Previews)."
        }
    }
}

extension MomentDetailView {
    /// Lane Y2: what a moment waiting for its capture waits on, as the capture's own row has it.
    func captureWait(_ capture: UUID) -> String {
        guard let record = CaptureStore.shared.conversation(capture) else { return AutoPhoneText.captureNotWrittenDown }
        switch record.state {
        case .queued: return AutoPhoneText.captureOnItsWay
        case .sent: return AutoPhoneText.captureBeingRead
        default: return AutoPhoneText.captureNotWrittenDown
        }
    }
}
