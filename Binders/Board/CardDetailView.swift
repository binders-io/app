import AppKit
import SwiftData
import SwiftUI
import BindersKit

/// One card, opened in its own window: the place you talk with whoever does the work. The conversation gets the room,
/// what waits on you (a question, a request for your approval, finished work) sits right above the composer with what to
/// do, and the description, links and source are in a Details panel beside it that you can hide. The header says what the
/// card is, where it stands, who has it and what they're doing now, with one primary action for its state; everything
/// else is a click away in the chips' menus and ⋯. Every action calls what the board already does.
struct CardDetailView: View {
    @Environment(DictationController.self) private var controller
    @Environment(HubNavigation.self) private var navigation
    @Environment(\.dismiss) private var dismiss
    @Environment(\.closeCard) private var closeCard
    @ReducedMotion private var reduceMotion
    @Bindable var card: TaskCard
    @Query private var events: [TaskEvent]
    @State private var registry = AgentRegistry.shared
    @State private var problem: String?
    @State private var confirmDelete = false
    /// What Binders wrote from the binder, open to edit.
    @State private var editingContext: TaskEvent?
    /// What you're typing, kept as the card's draft while Binders runs.
    @State private var draft: String
    /// Under 1000 pt wide: Details laid over the conversation, until hidden again. Doesn't change `detailsOpen`.
    @State private var detailsOver = false
    /// Details beside the conversation, for every card, from 1000 pt wide: in the app's own defaults, as every preference.
    @AppStorage(CardWindows.detailsKey, store: AppDefaults.store) private var detailsOpen = true

    /// `detailsOver`, for the drawings: under 1000 pt wide, Details laid over the conversation from the start.
    init(card: TaskCard, detailsOver: Bool = false) {
        self.card = card
        let id = card.id
        _events = Query(filter: #Predicate<TaskEvent> { $0.taskID == id }, sort: [SortDescriptor(\TaskEvent.createdAt)])
        _draft = State(initialValue: CardWindows.shared.draft(for: card.id))
        _detailsOver = State(initialValue: detailsOver)
    }

    var body: some View {
        let binder = Store.shared.binder(card.binderID)
        GeometryReader { geometry in
            let docked = CardLayout.detailsDocked(width: Double(geometry.size.width), open: detailsOpen)
            VStack(alignment: .leading, spacing: 0) {
                CardHeader(card: card, events: events, registry: registry, detailsShown: docked || detailsOver,
                           toggleDetails: { toggleDetails(width: geometry.size.width) }, close: close, problem: $problem,
                           confirmDelete: $confirmDelete)
                Divider()
                // A board shared through a team database that's off or out of reach says what waits (lane DB8).
                TeamReachLine(binderID: card.binderID, compact: true)
                HStack(alignment: .top, spacing: 0) {
                    // A short window (under about 700 pt, its title bar with it): the approval's text in its shorter box.
                    CardConversationColumn(card: card, events: events, registry: registry, draft: $draft, problem: $problem,
                                           editingContext: $editingContext, close: close, compactApproval: geometry.size.height < 668,
                                           detailsOver: !docked && detailsOver ? AnyView(detailsPanel(overlaid: true, width: geometry.size.width)) : nil)
                    if docked {
                        Divider()
                        detailsPanel(overlaid: false, width: geometry.size.width)
                    }
                }
            }
        }
        // The page's ground runs under the transparent title bar (`pageGround` ignores the safe area); the card itself
        // keeps below the title bar and, with two cards or more, below their tabs.
        .pageGround()
        .binderTint(binder?.colorIndex)
        .onExitCommand(perform: close)
        .onChange(of: draft) { CardWindows.shared.setDraft(draft, for: card.id) }
        .onChange(of: card.title) { retitle() }
        // Moved to another binder, or its binder renamed: the Window menu names the binder it's in now.
        .onChange(of: card.binderID) { retitle() }
        .onChange(of: binder?.name) { retitle() }
        .onAppear(perform: retitle)
        .alert("Couldn't do that", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(problem ?? "") }
        .sheet(item: $editingContext) { event in ContextEditor(event: event).environment(controller) }
        .followingAgentDoing()
        .confirmationDialog("Delete “\(card.title)”?", isPresented: $confirmDelete) {
            Button("Delete Card", role: .destructive) {
                // On a board shared through a team database that's off or out of reach, it stays until it's back (lane DB8).
                if let refused = controller.board.teamRefusal(.delete, on: card, by: .you) { return problem = refused }
                close()
                let doomed = card
                DispatchQueue.main.async { controller.board.delete(doomed) }
            }
        } message: { Text("Its timeline goes with it. This can't be undone.") }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(card.title)
    }

    /// Done, Esc and ⌘W: the card's window closes, and what you typed stays as its draft.
    private func close() {
        if let closeCard { closeCard() } else { dismiss() }
    }

    private func retitle() {
        CardWindows.shared.retitle(card.id, title: card.title, binder: Store.shared.binder(card.binderID)?.name)
    }

    private func toggleDetails(width: CGFloat) {
        let next = Self.toggledDetails(width: Double(width), open: detailsOpen, over: detailsOver)
        // It slides in from the right edge, or fades under Reduce Motion.
        withAnimation(BindersTheme.motion(.snappy(duration: 0.25), reduced: reduceMotion)) {
            if next.open != detailsOpen { detailsOpen = next.open }
            detailsOver = next.over
        }
    }

    /// Show or Hide Details at `width`, from your choice for every card (`open`) and whether they lie over the conversation
    /// (`over`): Details laid over it go away, whatever the width is now, and your choice stays as it was; otherwise, from
    /// 1000 pt wide it's your choice that changes, and narrower, the panel lies over the conversation until you hide it.
    static func toggledDetails(width: Double, open: Bool, over: Bool) -> (open: Bool, over: Bool) {
        if over, !CardLayout.detailsDocked(width: width, open: open) { return (open, false) }
        if width >= CardLayout.detailsDockedFrom { return (!open, false) }
        return (open, true)
    }

    @ViewBuilder
    private func detailsPanel(overlaid: Bool, width: CGFloat) -> some View {
        let panel = CardDetailsPanel(card: card, confirmDelete: $confirmDelete, hide: { toggleDetails(width: width) })
            .frame(width: CardLayout.detailsWidth)
            .frame(maxHeight: .infinity, alignment: .top)
        if overlaid {
            // Laid over the conversation: an opaque card on the ground, the surface colour with the stronger hairline and
            // a shadow on its left edge, so it reads as on top in dark as in light.
            panel
                .background(BindersTheme.surface)
                .overlay(alignment: .leading) { Rectangle().fill(BindersTheme.lineStrong).frame(width: 1) }
                .shadow(color: .black.opacity(0.3), radius: 12, x: -4)
        } else {
            panel
        }
    }
}

// MARK: - What the card's buttons do

/// The card's buttons that change it, for the view and the self-tests alike: each only calls what the board already does.
@MainActor
enum CardActions {
    /// Accept, on finished work in Review: your words, if any, go on the card first; then it's moved to Done, as the column
    /// chip's Done does.
    static func accept(_ card: TaskCard, words: String, board: BoardService) throws {
        // Waiting for the team's database, your words wait with it, rather than go on their own (lane DB8).
        if let refused = board.teamRefusal(.move(.done), on: card, by: .you) { throw TeamWaitRefusal(words: refused) }
        let words = words.trimmingCharacters(in: .whitespacesAndNewlines)
        if !words.isEmpty { board.comment(card, text: words, by: .you) }
        try board.move(card, to: .done, by: .you)
    }

    /// Send Back, on an agent's work in Review: your words first (in Review a comment wakes no one), then back to In
    /// progress, which the board logs as sent back and the dispatcher wakes with `sent_back` and your words. In that order,
    /// so your words go with the send-back rather than as a comment of their own.
    static func sendBack(_ card: TaskCard, words: String, board: BoardService) throws {
        if let refused = board.teamRefusal(.move(.inProgress), on: card, by: .you) { throw TeamWaitRefusal(words: refused) }
        let words = words.trimmingCharacters(in: .whitespacesAndNewlines)
        if !words.isEmpty { board.comment(card, text: words, by: .you) }
        try board.move(card, to: .inProgress, by: .you)
    }

    /// Send to <agent>, where a comment alone wouldn't reach the agent the card is meant for: your words on the card, then
    /// Wake Now, which carries them in `answer`. One wake. Nil, or Wake Now's refusal, for the card's alert.
    static func sendToAgent(_ card: TaskCard, words: String, controller: DictationController) -> String? {
        let words = words.trimmingCharacters(in: .whitespacesAndNewlines)
        if !words.isEmpty { controller.board.comment(card, text: words, by: .you) }
        return controller.agents.wakeNow(card)
    }

    /// Stop: the run stops. One Binders started without a tap also goes back to Backlog, meant for no one, until the agent
    /// has finished it (Review or Done): a run still ending there just stops. Nil, or why nothing changed.
    static func stop(_ card: TaskCard, controller: DictationController) -> String? {
        if let started = controller.router.startedBy(card), card.column != .review, card.column != .done {
            let result = controller.router.stopStarted(card, agent: started)
            return result.changed ? nil : result.line
        }
        controller.agents.stop(card.id)
        controller.router.log.outcome("stopped", card: card.id, todo: card.sourceRef)
        return nil
    }

    /// A card's link, as its Details list opens it: a run's log Binders wrote opens; anything else (an agent's, added with
    /// update_task) as an approval's link does: a web page in the browser, a file shown in the Finder, and nothing else.
    static func open(link: String) {
        if let log = runLog(link) {
            NSWorkspace.shared.open(log)
        } else if let web = ApprovalBox.web(link) {
            NSWorkspace.shared.open(web)
        } else if let file = ApprovalBox.file(link) {
            NSWorkspace.shared.activateFileViewerSelecting([file])
        }
    }

    /// A link to a log Binders wrote for one of its runs, in its own logs folder.
    static func runLog(_ link: String) -> URL? {
        guard let url = URL(string: link), url.isFileURL else { return nil }
        let folder = AgentDispatcher.logs.standardizedFileURL.path
        return url.standardizedFileURL.deletingLastPathComponent().path == folder ? url : nil
    }

    /// Whether a link opens with a click (a run's log, a web page, a file); anything else stays words to copy.
    static func opens(_ link: String) -> Bool {
        runLog(link) != nil || ApprovalBox.web(link) != nil || ApprovalBox.file(link) != nil
    }
}

/// What your words answer while the card waits in Blocked: its question, its request for approval, or the reason it
/// stopped. Nil when the card isn't Blocked.
enum CardAnswering: Equatable {
    case question(asker: String)
    case approval(asker: String)
    case reason(String)

    @MainActor
    static func of(_ card: TaskCard, events: [TaskEvent]) -> CardAnswering? {
        guard card.column == .blocked else { return nil }
        if let index = BoardRules.waitingAsk(in: events.map { (kind: $0.kindRaw, to: $0.toColumn ?? "") }) {
            return events[index].kind == .approval ? .approval(asker: events[index].author) : .question(asker: events[index].author)
        }
        let moved = events.last { $0.toColumn == BoardColumn.blocked.rawValue && $0.kind == .moved }
        return .reason(moved?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
    }

    /// What your words are called in the composer's line: an answer to a question, words otherwise.
    var noun: String {
        switch self {
        case .question: "answer"
        case .approval, .reason: "words"
        }
    }
}

extension String {
    /// An agent's name as the card's buttons say it: before " · " ("Claude Code", not "Claude Code · harbor-web").
    var shortAgentName: String { components(separatedBy: " · ").first ?? self }
}

// MARK: - The header

/// The top of the card: what it is (the title, to edit in place), where it stands (its column), who has it or who it's
/// for, its binder and when it's due, as chips that are also their menus; what the agent says it's doing now; the last
/// wake; "Working on it · Stop" whenever a run goes; and one primary action for states the board moves.
struct CardHeader: View {
    @Environment(DictationController.self) private var controller
    @Environment(HubNavigation.self) private var navigation
    @Bindable var card: TaskCard
    let events: [TaskEvent]
    let registry: AgentRegistry
    let detailsShown: Bool
    let toggleDetails: () -> Void
    let close: () -> Void
    @Binding var problem: String?
    @Binding var confirmDelete: Bool
    /// Giving it to a teammate's agent, waiting for your yes (lane DB2).
    @State private var asking: TeamConsent?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            titleRow
            statusRow
            // What its run says it's doing between its reports, in its words: the sparkle lavender, the words muted.
            if card.column == .inProgress, let line = AgentDoingFeed.shared.lines[card.id] {
                DoingLine(agent: card.assignee ?? "The agent", line: line, lines: 2, words: BindersTheme.muted)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .cardIdentityPanel()
        .padding(.horizontal, 16)
        // Just under the title bar, and under the tab bar when cards are tabs: the window's safe area holds both.
        .padding(.top, 8)
        .padding(.bottom, 4)
        .teamConsent($asking) { consent in
            controller.teamBoard.agree(to: consent.agent)
            giveTo(consent.name)
        }
    }

    /// Give to: on a board whose team database is off or out of reach, who it's for is kept, and the card says why
    /// nothing was handed over (lane DB8).
    private func giveTo(_ name: String) {
        let waiting = controller.teamBoard.reach(card).map { $0 != .reachable } ?? false
        if case .notWoken(let why) = controller.board.give(card, to: name, by: .you), waiting { problem = why }
    }

    /// For the self-tests, in a throwaway folder: where each card's title row starts, from the top of its window.
    @MainActor static var titleTops: [UUID: CGFloat] = [:]

    private var titleRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            TextField("Title", text: $card.title, axis: .vertical)
                .font(CardDesign.title)
                .textFieldStyle(.plain)
                .lineLimit(1...2)
                .accessibilityLabel("Title")
                .background {
                    if AppPaths.isDemo {
                        GeometryReader { proxy in
                            Color.clear
                                .onAppear { Self.titleTops[card.id] = proxy.frame(in: .global).minY }
                                .onChange(of: proxy.frame(in: .global).minY) { _, top in Self.titleTops[card.id] = top }
                        }
                    }
                }
            Spacer(minLength: 12)
            // The quick ways back to where the card lives: its board and, when it's a note's, the note.
            Button { navigation.showOnBoard(card) } label: {
                Image(systemName: "rectangle.split.3x1")
            }
            .buttonStyle(.borderless)
            .quietControl()
            .help("Show it on its board")
            .accessibilityLabel("Show on Board")
            if let note = card.groupNote.flatMap({ Store.shared.note($0) }) {
                Button { open(note) } label: {
                    Image(systemName: "square.stack.3d.down.right")
                }
                .buttonStyle(.borderless)
                .quietControl()
                .help("Open “\(note.title)”")
                .accessibilityLabel("Open the note")
            }
            Button(action: toggleDetails) { Image(systemName: "sidebar.right") }
                .buttonStyle(.borderless)
                .quietControl()
                .keyboardShortcut("0", modifiers: [.command, .option])
                .help(detailsShown ? "Hide Details (⌥⌘0)" : "Show Details (⌥⌘0)")
                .accessibilityLabel(detailsShown ? "Hide Details" : "Show Details")
            moreMenu
            // An ordinary button: Return never closes the card from a focused chip or button.
            Button("Done", action: close)
                .buttonStyle(.bordered)
                .help("Close the card (Esc)")
        }
    }

    /// The note this card is part of, opened at the note in the Binders window.
    private func open(_ note: NoteItem) {
        HubWindowController.shared.navigation.open(note: note)
        HubWindowController.shared.show()
    }

    private var moreMenu: some View {
        Menu {
            if showsStop { Button("Stop") { problem = CardActions.stop(card, controller: controller) } }
            if card.column != .done {
                Menu("Move to") {
                    MoveToBinderItems(current: card.binderID) { target in attempt { try controller.router.move(card, to: target) } }
                }
            }
            Button("Show on Board") { navigation.showOnBoard(card) }
            // Kept on this Mac (made from what your iPhone heard), on a board shared through the team database.
            if card.teamShadow == TeamBoard.held, controller.teamBoard.covers(card) {
                Button("Share It on the Team's Board") { controller.teamBoard.shareKept(card) }
            }
            Button(detailsShown ? "Hide Details" : "Show Details", action: toggleDetails)
            Divider()
            Button("Delete Card…", role: .destructive) { confirmDelete = true }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .quietControl()
        .help("Move it, show it on its board, or delete it")
        .accessibilityLabel("More")
    }

    // MARK: Where it stands

    /// The chips, then at the right the last wake, Stop and the primary action; when they don't fit beside the chips,
    /// the last wake's line moves under them, then Stop and the primary too.
    private var statusRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                chips
                Spacer(minLength: 12)
                lastWake
                actions
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    chips
                    Spacer(minLength: 12)
                    actions
                }
                HStack {
                    Spacer(minLength: 0)
                    lastWake
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    chips
                    Spacer(minLength: 0)
                }
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    lastWake
                }
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    actions
                }
            }
        }
    }

    private var chips: some View {
        // They wrap at a narrow width, so every chip stays whole and pressable rather than running off the card.
        Wrapping(spacing: 6, lineSpacing: 6) {
            BinderChip(binderID: card.binderID, column: card.column,
                       move: { target in attempt { try controller.router.move(card, to: target) } },
                       showOnBoard: { navigation.showOnBoard(card) })
            ColumnChip(card: card, events: events) { column in attempt { try controller.board.move(card, to: column, by: .you) } }
            WhoChip(card: card, registry: registry, problem: $problem)
            // In every column, as today's Due checkbox is: a Done card can still be given a date.
            DueChip(card: card)
        }
    }

    @ViewBuilder
    private var lastWake: some View {
        // The last wake ends with its time ("Sent to Claude Code · 3:42 PM"): monospaced digits, as every time is.
        if card.column != .done, let hint = handOffHint {
            Group {
                if hint.failed {
                    StatusLabel(hint.text, .problem)
                } else {
                    Text(hint.text).foregroundStyle(BindersTheme.muted)
                }
            }
            .font(BindersTheme.time())
            .lineLimit(1)
            .truncationMode(.middle)
        }
    }

    // MARK: What to do

    private var showsStop: Bool { Self.showsStop(card, controller: controller) }

    /// Stop shows whenever a run Binders started goes, or Binders handed the card over without a tap, in any column but Done.
    static func showsStop(_ card: TaskCard, controller: DictationController) -> Bool {
        card.column != .done && (controller.agents.isWorking(on: card.id) || controller.router.showsStop(card))
    }

    /// Stop whenever a run Binders started goes, or Binders handed the card over without a tap, in any column but Done:
    /// a safety control, apart from the state's primary action. Then that action, when the header has it.
    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 8) {
            if card.column != .done, controller.agents.isWorking(on: card.id) {
                Label("Working on it", systemImage: "gearshape.2").font(.caption).foregroundStyle(BindersTheme.muted)
                Button("Stop") { problem = CardActions.stop(card, controller: controller) }
                    .help("Stop its run")
            } else if card.column != .done, controller.router.showsStop(card) {
                // Handed over without a tap to an agent with nothing running here (a web hook, a Shortcut, a command that
                // has rung it, your open session): Stop takes the card back to Backlog, as the card's note says.
                Button("Stop") { problem = CardActions.stop(card, controller: controller) }
                    .help("Move it back to Backlog, meant for no one")
            }
            primary
        }
        .fixedSize()
    }

    /// One primary action for what the board moves (rules 6 to 8 of the design): Give to, Wake Now or Take It. A question,
    /// an approval and finished work have theirs above the composer, with their words.
    @ViewBuilder
    private var primary: some View {
        switch Self.primary(card, registry: registry, showsStop: showsStop, reach: controller.agents.commentReach(for: card, events: events),
                            awaitsYou: controller.agents.waitsForYourGiveTo(card),
                            teammatesAgent: controller.teamBoard.teammatesAgent(named: card.meantFor) != nil) {
        case .giveTo(let name):
            Button("Give to \(name)") {
                // A teammate's agent: asked once, naming its owner and who it sends cards to.
                if let agent = controller.teamBoard.teammatesAgent(named: name), !controller.teamBoard.agreed(to: agent) {
                    asking = controller.teamBoard.consent(for: agent)
                } else {
                    giveTo(name)
                }
            }
                .buttonStyle(.borderedProminent)
                .disabled(registry.paused)
                .help(registry.paused ? "Agents are paused: resume them in Settings → Agents" : "It goes to Ready, and Binders hands it over")
        case .wakeNow(let prominent):
            Button("Wake Now") { problem = controller.agents.wakeNow(card) }
                .modifier(Prominent(on: prominent))
                .help("Wake \(card.meantFor ?? "it") now, past its hourly limit")
        case .takeIt:
            Button("Take It") { attempt { try controller.board.claim(card, by: .you) } }
                .buttonStyle(.borderedProminent)
                .help("Take it yourself: it goes to In progress")
        case nil:
            EmptyView()
        }
    }

    /// The header's primary action for the card's state, the first rule that holds: none in Done, nor where the tray or the
    /// composer has it (Blocked, Review); Give to for a card meant for an agent that nobody holds, in Backlog, or in Ready
    /// while it's only a suggestion; Wake Now for one meant by you for an agent Binders wakes, in Ready or In progress,
    /// while Stop isn't showing (bordered where the composer's button is Send to); Take It for one nobody holds.
    /// `awaitsYou`: a teammate's card that waits for your Give to (lane DB2); `teammatesAgent`: it's meant for a teammate's
    /// agent, which its owner's Mac starts.
    static func primary(_ card: TaskCard, registry: AgentRegistry, showsStop: Bool, reach: CommentReach, awaitsYou: Bool = false,
                        teammatesAgent: Bool = false) -> CardPrimary? {
        let meantAgent = card.meantFor.flatMap { registry.agent(named: $0) }
        let held = BoardRules.isClaimed(card.state, at: .now)
        if card.column == .done || card.column == .blocked || card.column == .review { return nil }
        if let name = card.meantFor, card.meantForByAgent || meantAgent != nil || teammatesAgent, !held,
           card.column == .backlog || (card.column == .ready && (card.meantForByAgent || awaitsYou)) {
            return .giveTo(name)
        }
        if let agent = meantAgent, !card.meantForByAgent, agent.wake != .board, card.column == .ready || card.column == .inProgress, !showsStop {
            let composerSends = switch reach {
            case .wakes, .sendsWithWakeNow: true
            default: false
            }
            return .wakeNow(prominent: !composerSends)
        }
        return held ? nil : .takeIt
    }

    /// What happens once it's handed over, or how the last wake went, and whether that failed. How Binders wakes the agent
    /// is said before the hand-off, in Backlog and Ready; once the card is with it, the line is about its last wake.
    private var handOffHint: (text: String, failed: Bool)? {
        if let outcome = controller.agents.outcomes[card.id] {
            return ("\(outcome.message) · \(outcome.at.formatted(date: .omitted, time: .shortened))", !outcome.ok)
        }
        guard let name = card.meantFor, !card.meantForByAgent, let agent = registry.agent(named: name) else { return nil }
        if registry.paused { return ("Agents are paused", false) }
        if registry.changedOutside.contains(agent.id) { return ("Changed outside Binders: save it in Settings → Agents", false) }
        if let why = registry.held[agent.id] { return (why, true) }
        guard card.column == .backlog || card.column == .ready else { return nil }
        switch agent.wake {
        case .board: return ("It checks the board itself", false)
        case .claudeCode: return ("Binders starts Claude Code when it's in Ready", false)
        case .cliAgent(let wake): return ("Binders starts \(wake.tool.name) when it's in Ready", false)
        case .localModel: return ("A local model that's only the Manager: it takes no cards", true)
        default: return ("Binders wakes it when it's in Ready", false)
        }
    }

    private func attempt(_ action: () throws -> Void) {
        do { try action() } catch { problem = error.localizedDescription }
    }
}

/// The header's primary action, by kind.
enum CardPrimary: Equatable {
    case giveTo(String)
    case wakeNow(prominent: Bool)
    case takeIt
}

/// A primary button where it's the state's one action, an ordinary one where something else is.
struct Prominent: ViewModifier {
    let on: Bool

    func body(content: Content) -> some View {
        // The page's ink for the one that matters, a soft fill for the rest (lane UI2).
        if on { content.buttonStyle(.primary) } else { content.buttonStyle(.soft) }
    }
}

// MARK: - The chips

/// A chip's look: a glyph in its colour, ink words, a small chevron when it opens a menu or a popover, on a soft rounded
/// chip. Under the pointer it lifts its fill and edge.
private struct ChipLabel: View {
    var glyph: String?
    var glyphColor: Color = BindersTheme.muted
    let words: String
    var trailing: String?
    var fill: Color = BindersTheme.ink.opacity(0.07)
    var opens = true

    var body: some View {
        CardChipLabel(glyph: glyph, glyphColor: glyphColor, words: words, trailing: trailing, fill: fill, opens: opens)
    }
}

/// The binder the card is on: its colour's swatch and its name, the only place its colour shows besides what you press.
/// Its menu moves the card to another binder (not in Done, as ⋯'s Move to) or shows it on its board.
struct BinderChip: View {
    let binderID: UUID?
    let column: BoardColumn
    let move: (BinderRecord) -> Void
    let showOnBoard: () -> Void
    @State private var hovering = false

    var body: some View {
        let binder = Store.shared.binder(binderID)
        Menu {
            if column != .done {
                Menu("Move to") { MoveToBinderItems(current: binderID, move: move) }
            }
            Button("Show on Board", action: showOnBoard)
        } label: {
            HStack(spacing: 6) {
                if let binder {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(BinderPalette.color(binder.colorIndex))
                        .frame(width: 11, height: 11)
                }
                Text(binder?.name ?? "No binder").font(CardDesign.chip).foregroundStyle(BindersTheme.ink).lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(BindersTheme.muted)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: CardDesign.chipRadius, style: .continuous)
                .fill(BindersTheme.ink.opacity(hovering ? 0.12 : 0.07)))
            .overlay {
                RoundedRectangle(cornerRadius: CardDesign.chipRadius, style: .continuous)
                    .strokeBorder(hovering ? BindersTheme.lineStrong : BindersTheme.line)
            }
            .contentShape(RoundedRectangle(cornerRadius: CardDesign.chipRadius, style: .continuous))
            .onHover { inside in
                withAnimation(CardDesign.hover) { hovering = inside }
                if inside { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
            }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(binder == nil ? "Its binder was deleted. Move to puts it on another board." : "Move it to another binder, or show it on its board")
        .accessibilityLabel(binder.map { "Binder: \($0.name)" } ?? "No binder")
        .accessibilityHint("Moves it to another binder, or shows it on its board")
    }
}

/// Where the card stands, with its glyph: what waits on you in amber (a question, a request for approval, work to check),
/// Blocked for a reason in the problem style, Done in green. Its menu moves the card.
struct ColumnChip: View {
    let card: TaskCard
    let events: [TaskEvent]
    let move: (BoardColumn) -> Void

    var body: some View {
        let look = Self.look(card, events: events)
        Menu {
            ForEach(BoardColumn.allCases, id: \.self) { column in
                Button { move(column) } label: {
                    if column == card.column { Label(column.title, systemImage: "checkmark") } else { Text(column.title) }
                }
            }
        } label: {
            ChipLabel(glyph: look.glyph, glyphColor: look.color, words: look.words)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Move it to another column")
        .accessibilityLabel("Column: \(look.words.replacingOccurrences(of: " · ", with: ", "))")
        .accessibilityHint("Moves it to another column")
    }

    static func look(_ card: TaskCard, events: [TaskEvent]) -> (glyph: String, color: Color, words: String) {
        switch card.column {
        case .backlog: return ("tray", BindersTheme.muted, BoardColumn.backlog.title)
        case .ready: return ("circle", BindersTheme.muted, BoardColumn.ready.title)
        case .inProgress: return ("circle.lefthalf.filled", BindersTheme.muted, BoardColumn.inProgress.title)
        case .done: return ("checkmark.circle.fill", BindersTheme.done, BoardColumn.done.title)
        case .review: return ("eye", BindersTheme.needsYou, "Review · Ready for you to check")
        case .blocked:
            switch CardAnswering.of(card, events: events) {
            case .question: return ("questionmark.bubble", BindersTheme.needsYou, "Blocked · Waiting for your answer")
            case .approval: return ("checkmark.shield", BindersTheme.needsYou, "Blocked · Waiting for your approval")
            default: return (BindersTheme.problemSymbol, BindersTheme.ink, BoardColumn.blocked.title)
            }
        }
    }
}

/// Who has the card, or who it's for: an agent's name in ink beside its lavender sparkle on a lavender capsule, with its
/// claim's minutes left, as the board's chip says it; "You", a person, "For Grok Bot", "Give to Grok Bot?" (an agent's
/// suggestion: the glyph amber), or "For anyone". Its menu takes it, takes it over or lets it go, and says who it's for.
struct WhoChip: View {
    @Environment(DictationController.self) private var controller
    @Environment(HubNavigation.self) private var navigation
    let card: TaskCard
    let registry: AgentRegistry
    @Binding var problem: String?
    @State private var typingName = false
    @State private var meantFor = ""
    /// Meaning it for a teammate's agent, waiting for your yes (lane DB2).
    @State private var asking: TeamConsent?

    var body: some View {
        Menu {
            claimItems
            Divider()
            forItems
        } label: {
            TimelineView(.periodic(from: .now, by: 30)) { context in label(at: context.date) }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Who has it, and who it's for")
        .accessibilityLabel(spoken)
        .accessibilityHint("Who has it, and who it's for")
        .popover(isPresented: $typingName, arrowEdge: .bottom) {
            HStack(spacing: 8) {
                TextField("Someone's name", text: $meantFor).textFieldStyle(.roundedBorder).frame(width: 200)
                    .onSubmit(assignTyped)
                Button("Done", action: assignTyped)
            }
            .padding(12)
            .onAppear { meantFor = card.meantFor ?? "" }
        }
        .teamConsent($asking) { consent in
            controller.teamBoard.agree(to: consent.agent)
            controller.board.assign(card, to: consent.name, by: .you)
        }
    }

    /// Who holds it now: someone with a live claim, or whoever finished it (Review, Done).
    private var holder: String? {
        guard let assignee = card.assignee else { return nil }
        return BoardRules.isClaimed(card.state, at: .now) || card.column == .review || card.column == .done ? assignee : nil
    }

    @ViewBuilder
    private func label(at now: Date) -> some View {
        if let holder {
            if card.assigneeIsAgent {
                let minutes = card.column == .inProgress ? card.claimExpiresAt.flatMap { $0 > now ? max(1, Int($0.timeIntervalSince(now) / 60)) : nil } : nil
                // Narrower: the agent without its repository, then without the time left, before its name is cut short.
                ViewThatFits(in: .horizontal) {
                    agentChip(holder, minutes: minutes)
                    if holder.shortAgentName != holder { agentChip(holder.shortAgentName, minutes: minutes) }
                    agentChip(holder.shortAgentName, minutes: nil)
                }
            } else {
                let forAgent = holder == BoardActor.you.name && !card.meantForByAgent ? card.meantFor.flatMap { registry.agent(named: $0)?.name } : nil
                ChipLabel(glyph: "person.fill", glyphColor: BindersTheme.ink, words: forAgent.map { "\(holder) · for \($0.shortAgentName)" } ?? holder)
            }
        } else if let name = card.meantFor, card.column != .done {
            if card.meantForByAgent {
                ChipLabel(glyph: "questionmark.circle", glyphColor: BindersTheme.needsYou, words: "Give to \(name)?")
            } else {
                ChipLabel(glyph: "arrow.forward.circle", glyphColor: BindersTheme.muted, words: "For \(name)")
            }
        } else {
            ChipLabel(glyph: "arrow.forward.circle", glyphColor: BindersTheme.muted, words: "For anyone")
        }
    }

    private func agentChip(_ name: String, minutes: Int?) -> some View {
        ChipLabel(glyph: BindersTheme.agentSymbol, glyphColor: BindersTheme.agent, words: name, trailing: minutes.map { "· \($0) min" },
                  fill: BindersTheme.agent.opacity(0.16))
    }

    private var spoken: String {
        if let holder {
            let minutes = card.column == .inProgress && card.assigneeIsAgent
                ? card.claimExpiresAt.flatMap { $0 > .now ? ", \(max(1, Int($0.timeIntervalSinceNow / 60))) minutes left" : nil } ?? "" : ""
            return "\(holder) has it\(minutes)"
        }
        guard let name = card.meantFor, card.column != .done else { return "For anyone" }
        return card.meantForByAgent ? "Suggested for \(name)" : "For \(name)"
    }

    /// Take It, Take Over from whoever has it, or Let Go: whichever applies, as today's card has them.
    @ViewBuilder
    private var claimItems: some View {
        if let assignee = card.assignee, BoardRules.isClaimed(card.state, at: .now) {
            if assignee == BoardActor.you.name {
                Button("Let Go") { attempt { try controller.board.release(card, by: .you) } }
                    .help("Put it back in Ready for someone else")
            } else {
                Button("Take Over from \(assignee)") { attempt { try controller.board.claim(card, by: .you) } }
            }
        } else if card.column != .done {
            Button("Take It") { attempt { try controller.board.claim(card, by: .you) } }
        }
    }

    /// Who it's for: anyone, you, one of your agents or a person on this board, someone else by name, or setting agents up.
    @ViewBuilder
    private var forItems: some View {
        Section("For") {
            Button("Anyone") { controller.board.assign(card, to: nil, by: .you) }
            Button("You") { controller.board.assign(card, to: BoardActor.you.name, by: .you) }
        }
        let agents = registry.agents.filter(\.isEnabled)
        if !agents.isEmpty {
            Section("Agents") {
                ForEach(agents) { agent in Button(agent.name) { controller.board.assign(card, to: agent.name, by: .you) } }
            }
        }
        // On a board shared through the team database: teammates' agents that take its cards, with their owners, and teammates.
        let team = controller.teamBoard
        let theirs = team.teammatesAgents(taking: card.binderID)
        if !theirs.isEmpty {
            Section("Teammates' Agents") {
                ForEach(theirs) { agent in
                    let consent = team.consent(for: agent)
                    Button(consent.name) {
                        if team.agreed(to: agent) { controller.board.assign(card, to: consent.name, by: .you) } else { asking = consent }
                    }
                }
            }
        }
        let teammates = team.covers(card.binderID) ? team.directory.teammates.map(\.name) : []
        if !teammates.isEmpty {
            Section("Teammates") {
                ForEach(teammates, id: \.self) { name in Button(name) { controller.board.assign(card, to: name, by: .you) } }
            }
        }
        let people = peopleOnThisBoard.filter { name in !teammates.contains(name) && team.teammatesAgent(named: name) == nil }
        if !people.isEmpty {
            Section("People") {
                ForEach(people, id: \.self) { name in Button(name) { controller.board.assign(card, to: name, by: .you) } }
            }
        }
        Divider()
        Button("Someone Else…") { typingName = true }
        Button("Set Up Agents…") {
            // The card stays open; the Binders window comes forward on Settings → Agents.
            navigation.pendingSettingsPage = .agents
            HubWindowController.shared.show(section: .settings)
        }
    }

    /// The other people named on this binder's cards: who held them, and who they were for.
    private var peopleOnThisBoard: [String] {
        let cards = controller.board.cards(in: card.binderID)
        let names = cards.compactMap { $0.assigneeIsAgent ? nil : $0.assignee } + cards.compactMap { $0.meantFor }
        let agents = registry.agents.map(\.name)
        return Array(Set(names)).filter { name in
            !BoardRules.isReserved(name) && !agents.contains { BoardRules.isNamed(name, as: $0) || BoardRules.isNamed($0, as: name) }
        }.sorted()
    }

    private func assignTyped() {
        let name = meantFor.trimmingCharacters(in: .whitespacesAndNewlines)
        controller.board.assign(card, to: name.isEmpty ? nil : name, by: .you)
        typingName = false
    }

    private func attempt(_ action: () throws -> Void) {
        do { try action() } catch { problem = error.localizedDescription }
    }
}

/// When it's due: amber's clock when it's today or past, its words ink. A popover sets it.
struct DueChip: View {
    @Bindable var card: TaskCard
    @State private var editing = false

    var body: some View {
        Button { editing = true } label: {
            if let due = card.dueAt {
                let urgent = card.column != .done && (due < Date() || Calendar.current.isDateInToday(due))
                ChipLabel(glyph: "clock", glyphColor: urgent ? BindersTheme.needsYou : BindersTheme.muted, words: CommitmentService.dueLabel(due).capitalizedFirst)
            } else {
                ChipLabel(glyph: "calendar", words: "No due date")
            }
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help("Set when it's due")
        .accessibilityLabel(card.dueAt.map { "Due \($0.formatted(.dateTime.weekday(.wide).day().month(.wide)))" } ?? "No due date")
        .popover(isPresented: $editing, arrowEdge: .bottom) {
            HStack(spacing: 10) {
                Toggle("Due", isOn: Binding(get: { card.dueAt != nil },
                                            set: { card.dueAt = $0 ? Calendar.current.date(byAdding: .day, value: 1, to: .now) : nil }))
                    .toggleStyle(.checkbox)
                if card.dueAt != nil {
                    DatePicker("", selection: Binding(get: { card.dueAt ?? .now }, set: { card.dueAt = $0 }), displayedComponents: [.date])
                        .labelsHidden()
                        .fixedSize()
                }
            }
            .padding(12)
        }
    }
}

private extension String {
    /// "today" → "Today", as a chip starts.
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

// MARK: - Details

/// The description (the Markdown editor, as it always was), the card's links, where it came from, its to-do, and Delete
/// Card…: second to the conversation, in a panel beside it or laid over it.
struct CardDetailsPanel: View {
    @Bindable var card: TaskCard
    @Binding var confirmDelete: Bool
    /// Hides the panel, from its own header.
    var hide: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("Details").font(CardDesign.panelTitle)
                Spacer(minLength: 8)
                if let hide {
                    Button(action: hide) {
                        Image(systemName: "sidebar.right")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(.borderless)
                    .quietControl()
                    .help("Hide Details")
                    .accessibilityLabel("Hide Details")
                }
            }
            CardSectionTitle(text: "Description")
            MarkdownNoteEditor(text: $card.details, fontSize: 14, placeholder: "What's this about? What does done look like?",
                               inset: NSSize(width: 8, height: 8), compactToolbar: true, links: LinkTargets.forEditor(in: card.binderID))
                .frame(minHeight: 160, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(BindersTheme.surface))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(BindersTheme.line))
            if !card.links.isEmpty {
                CardSectionTitle(text: "Links")
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(card.links, id: \.self) { link in linkRow(link) }
                }
            }
            // Lane DS5: the note whose group it's in on the board, and Part of… to change it.
            CardGroupLine(card: card)
            if let from = card.distilledFrom, from.byHand != true {
                // Lane DS1: its spec, its section and what changed in it since, and what it waits for.
                DistilledFromPanel(card: card)
            } else if let source = card.sourceTitle {
                Label("From \(source)", systemImage: "arrow.turn.down.right")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(BindersTheme.muted)
            }
            if !card.waitsFor.isEmpty { CardWaitsPanel(card: card) }
            if card.sourceRef != nil {
                Label("Its to-do is ticked off when this card is done.", systemImage: "checklist")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(BindersTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("Delete Card…", role: .destructive) { confirmDelete = true }
                .buttonStyle(.borderless)
                .quietControl(words: true)
                .font(.system(size: 11.5, weight: .medium))
                .padding(.top, 4)
        }
        .padding(16)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Details")
    }

    /// A run's log Binders wrote opens; a web page opens in the browser and a file shows in the Finder, as an approval's link
    /// does; anything else (another app's link) stays words to copy, so a click never runs anything an agent added.
    @ViewBuilder
    private func linkRow(_ link: String) -> some View {
        let symbol = ApprovalBox.web(link) != nil ? "link" : "doc"
        let row = HStack(spacing: 7) {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(BindersTheme.ink.opacity(0.06))
                .overlay {
                    Image(systemName: symbol)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(BindersTheme.muted)
                }
                .frame(width: 18, height: 18)
                .accessibilityHidden(true)
            Text(link)
                .font(.system(size: 11.5, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .cardBubble(fill: BindersTheme.surface2, edge: BindersTheme.line)
        if CardActions.opens(link) {
            Button { CardActions.open(link: link) } label: { row }
                .buttonStyle(.plain)
                .foregroundStyle(.tintText)
                .help(ApprovalBox.web(link) != nil ? "Open it in your browser" : CardActions.runLog(link) != nil ? "Open the run's log" : "Show it in the Finder")
        } else {
            row
                .foregroundStyle(BindersTheme.muted)
                .textSelection(.enabled)
        }
    }
}

extension View {
    /// The yes before a teammate's agent is given a card (lane DB2): "Give cards to Claude Code (Dana)?", with its owner
    /// and who it sends cards to.
    func teamConsent(_ pending: Binding<TeamConsent?>, onYes: @escaping (TeamConsent) -> Void) -> some View {
        confirmationDialog(pending.wrappedValue?.question ?? "", isPresented: Binding(get: { pending.wrappedValue != nil }, set: { if !$0 { pending.wrappedValue = nil } }),
                           titleVisibility: .visible, presenting: pending.wrappedValue) { consent in
            Button("Give to \(consent.name)") { onYes(consent) }
            Button("Cancel", role: .cancel) {}
        } message: { consent in
            Text(consent.message)
        }
    }
}
