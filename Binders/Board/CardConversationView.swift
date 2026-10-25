import AppKit
import SwiftData
import SwiftUI
import BindersKit

/// The card's left column: the conversation, then (only while something waits on you) the needs-you tray with what to do,
/// then the composer. The conversation keeps at least 160 pt; when the window is short, the composer stops growing at 3
/// lines while a tray is up, and then the tray scrolls in its own box. In a wide window all three keep to a reading width,
/// centred, so a line's time stays near its words; their scroll views still span the column.
struct CardConversationColumn: View {
    @Environment(DictationController.self) private var controller
    @Bindable var card: TaskCard
    let events: [TaskEvent]
    let registry: AgentRegistry
    @Binding var draft: String
    @Binding var problem: String?
    @Binding var editingContext: TaskEvent?
    @ReducedMotion private var reduceMotion
    let close: () -> Void
    /// A short window: the approval's text in its shorter box.
    let compactApproval: Bool
    /// Details laid over the conversation's right side, under 1000 pt wide.
    let detailsOver: AnyView?
    @State private var trayHeight: CGFloat = 0
    /// The column's width, for how wide the tray's words may run.
    @State private var columnWidth = CGFloat(CardLayout.defaultWidth)

    var body: some View {
        let answering = CardAnswering.of(card, events: events)
        let reach = controller.agents.commentReach(for: card, events: events)
        let trayUp = NeedsYouTray.shows(card, answering: answering)
        // The composer takes its height first, then what waits on you up to its own, keeping the conversation's 160 pt; the
        // conversation takes the rest. A tray taller than its room scrolls in its own box.
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                GeometryReader { geometry in
                    ConversationView(card: card, events: events, registry: registry, width: min(geometry.size.width, Self.readingWidth),
                                     editingContext: $editingContext)
                        .onAppear { columnWidth = geometry.size.width }
                        .onChange(of: geometry.size.width) { _, width in columnWidth = width }
                }
                .frame(minHeight: CardLayout.conversationMinHeight, maxHeight: .infinity)
                if trayUp {
                    TrayBox(height: $trayHeight) {
                        NeedsYouTray(card: card, events: events, answering: answering, reach: reach, compactApproval: compactApproval,
                                     draft: $draft, problem: $problem, wordsWidth: wordsWidth)
                            .frame(maxWidth: Self.readingWidth)
                            .frame(maxWidth: .infinity)
                    }
                    .frame(maxHeight: max(trayHeight, 1))
                    .layoutPriority(1)
                    .transition(.opacity)
                }
            }
            .overlay(alignment: .topTrailing) {
                if let detailsOver {
                    detailsOver.transition(reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity))
                }
            }
            CardComposer(card: card, events: events, answering: answering, draft: $draft, problem: $problem, trayUp: trayUp, close: close)
                .frame(maxWidth: Self.readingWidth)
                .frame(maxWidth: .infinity)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(2)
        }
    }

    /// The most the conversation, what waits on you and the composer take across.
    static let readingWidth = CGFloat(CardLayout.readingWidth)

    /// How wide words in the tray may run: as a message's in the conversation.
    private var wordsWidth: CGFloat {
        CGFloat(CardLayout.messageWidth(conversation: Double(max(0, min(columnWidth, Self.readingWidth) - 40))))
    }
}

/// What waits on you, at its own height while there's room, in a box that scrolls when the window is too short for it.
/// Cut short, it shows its end, where what to do is (Approve and Decline's field, Accept and Send Back), and a fade at its
/// top says there's more above; it goes back to its end as it or its content changes height.
private struct TrayBox<Content: View>: View {
    @Binding var height: CGFloat
    @ViewBuilder let content: () -> Content
    @Environment(\.binderTint) private var tint
    /// The box's own height, which the window gives it.
    @State private var shown: CGFloat = 0
    private static var end: String { "tray-end" }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    content()
                    Color.clear.frame(height: 1).id(Self.end)
                }
                .background(GeometryReader { measured in
                    Color.clear
                        .onAppear { height = measured.size.height }
                        .onChange(of: measured.size.height) { _, new in height = new }
                })
            }
            .background(GeometryReader { box in
                Color.clear
                    .onAppear { shown = box.size.height }
                    .onChange(of: box.size.height) { _, new in shown = new }
            })
            .onAppear { proxy.scrollTo(Self.end, anchor: .bottom) }
            .onChange(of: height) { proxy.scrollTo(Self.end, anchor: .bottom) }
            .onChange(of: shown) { proxy.scrollTo(Self.end, anchor: .bottom) }
            .overlay(alignment: .top) {
                if height > shown + 1 {
                    let ground = tint?.wash ?? BindersTheme.ground
                    LinearGradient(colors: [ground, ground.opacity(0)], startPoint: .top, endPoint: .bottom)
                        .frame(height: 20)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
        }
    }
}

// MARK: - The conversation

/// The card's timeline as a conversation: what the agent said on the left with its sparkle and a lavender rule, what you
/// said on the right in your words' own type with what became of them under it, Binders' own notes apart, and the board's
/// own events as one quiet line each. It opens at the newest entry and keeps to it as new ones arrive, unless you've
/// scrolled up to read, when a pill says how many are new.
struct ConversationView: View {
    @Environment(DictationController.self) private var controller
    @ReducedMotion private var reduceMotion
    let card: TaskCard
    let events: [TaskEvent]
    let registry: AgentRegistry
    /// The conversation's width, for how wide a message may be.
    let width: CGFloat
    @Binding var editingContext: TaskEvent?
    @State private var probe = ScrollProbe.Handle()
    @State private var atNewest = true
    @State private var newCount = 0
    /// Quiet lines and folded receipts opened to their words, by event.
    @State private var opened: Set<UUID> = []
    @State private var announced: Set<UUID> = []

    var body: some View {
        let conversation = events.map(\.conversation)
        let agent = Self.deliveryAgent(card, registry)
        let deliveries = agent.map { CardConversation.delivery(conversation, agent: $0, failureLines: AgentDispatcher.failureLines) } ?? [:]
        let entries = CardConversation.entries(conversation, column: card.column, binders: BoardService.binders.name,
                                               folded: CardConversation.folded(deliveries))
        let rows = Self.rows(entries, events: events)
        let newestWords = events.lastIndex { CardConversation.isYours($0.conversation) }
        let failure = newestWords.flatMap { failureSpoken($0, status: status($0, deliveries: deliveries, agent: agent, newestWords: newestWords)) }
        let messageWidth = CGFloat(CardLayout.messageWidth(conversation: Double(max(0, width - 40))))
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { row in
                    rowView(row, deliveries: deliveries, agent: agent, newestWords: newestWords, messageWidth: messageWidth)
                        .padding(.top, row.spacing)
                        .transition(.filed)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            // At most the reading width, centred in a wider window; the scroll view itself spans the column.
            .frame(maxWidth: CardConversationColumn.readingWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
            .background(ScrollProbe(handle: probe) { atNewest = $0 })
            .filing(rows.map(\.id))
            .accessibilityRotor("Messages") {
                ForEach(rows.filter(\.isMessage)) { row in AccessibilityRotorEntry(Text(row.spoken), id: row.id) }
            }
        }
        .settlesAfterAppearing()
        .overlay(alignment: .bottom) {
            if newCount > 0, !atNewest {
                NewEntriesPill(count: newCount) { probe.scrollToNewest(animated: !reduceMotion) }
                    .padding(.bottom, 10)
                    .transition(.opacity)
            }
        }
        .onChange(of: events.count) { old, new in
            if !atNewest, new > old { newCount += new - old }
            announce(Array(events.suffix(max(0, new - old))))
        }
        .onChange(of: atNewest) { if atNewest { newCount = 0 } }
        // Your newest words didn't reach the agent, or weren't sent, while the card is open: said once, politely.
        .onChange(of: failure) { _, said in if let said { AccessibilityNotification.Announcement(said).post() } }
        .onChange(of: newCount) { if AppPaths.isDemo { Self.newCounts[card.id] = newCount } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Conversation")
    }

    /// For the self-tests, in a throwaway folder: how many new entries each card's pill says.
    @MainActor static var newCounts: [UUID: Int] = [:]

    /// The agent your words go to, whose deliveries are drawn under them: the one you meant the card for, or the one
    /// holding it, when it's one Binders wakes (not one that checks the board itself, nor a name that isn't one of yours).
    static func deliveryAgent(_ card: TaskCard, _ registry: AgentRegistry) -> String? {
        func woken(_ name: String) -> AgentProfile? { registry.agents.first { AgentRegistry.isAgent($0, named: name) && $0.wake != .board } }
        if let meant = card.meantFor, !card.meantForByAgent, let agent = woken(meant) { return agent.name }
        if card.assigneeIsAgent, let holder = card.assignee, let agent = woken(holder) { return agent.name }
        return nil
    }

    /// An agent's new message, read out politely while the card is open; board events aren't.
    private func announce(_ added: [TaskEvent]) {
        for event in added where event.authorIsAgent && ["progress", "question", "approval", "completed", "comment"].contains(event.kindRaw)
            && !announced.contains(event.id) {
            announced.insert(event.id)
            AccessibilityNotification.Announcement("\(event.author) \(Self.verb(event, column: card.column))").post()
        }
    }

    // MARK: Rows

    struct Row: Identifiable {
        let id: String
        let entry: CardConversation.Entry
        /// Space above it: 14 pt between messages, 6 between quiet lines, 10 between the two.
        let spacing: CGFloat
        let isMessage: Bool
        let spoken: String
    }

    static func rows(_ entries: [CardConversation.Entry], events: [TaskEvent]) -> [Row] {
        var rows: [Row] = []
        var previous: CardConversation.Entry?
        for entry in entries {
            let quiet: (CardConversation.Entry?) -> Bool = { if case .line = $0 { true } else { false } }
            let spacing: CGFloat
            switch (previous, entry) {
            case (nil, _): spacing = 0
            case (.day?, _), (_, .day): spacing = 12
            case _ where quiet(previous) && quiet(entry): spacing = 6
            case _ where quiet(previous) || quiet(entry): spacing = 10
            default: spacing = 14
            }
            switch entry {
            case .day(let date):
                rows.append(Row(id: "day-\(date.timeIntervalSince1970)", entry: entry, spacing: spacing, isMessage: false, spoken: ""))
            case .message(let index, _, _), .line(let index), .context(let index):
                let event = events[index]
                let isMessage = if case .message = entry { true } else { false }
                let words = event.kind == .approval ? AgentApproval(timeline: event.text)?.summary ?? event.text : event.text
                rows.append(Row(id: event.id.uuidString, entry: entry, spacing: spacing, isMessage: isMessage,
                                spoken: "\(event.author), \(verb(event, column: nil)): \(words)"))
            }
            previous = entry
        }
        return rows
    }

    @ViewBuilder
    private func rowView(_ row: Row, deliveries: [Int: CardConversation.Delivery], agent: String?, newestWords: Int?, messageWidth: CGFloat) -> some View {
        switch row.entry {
        case .day(let date):
            DayHeading(date: date)
        case .message(let index, .agent, let waiting):
            AgentMessage(event: events[index], verb: Self.verb(events[index], column: card.column), waiting: waiting, column: card.column,
                         wordsWidth: messageWidth, opened: $opened)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .message(let index, .you, _):
            YourMessage(event: events[index], verb: Self.verb(events[index], column: card.column), status: status(index, deliveries: deliveries, agent: agent, newestWords: newestWords),
                        opened: $opened)
                .frame(maxWidth: messageWidth, alignment: .trailing)
                .frame(maxWidth: .infinity, alignment: .trailing)
        case .message(let index, .binders, _):
            BindersNote(event: events[index], wordsWidth: messageWidth)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .line(let index):
            QuietLine(event: events[index], words: Self.lineWords(events[index]), symbol: Self.symbol(events[index]),
                      byAgent: Self.agentDidIt(events[index]), opened: $opened)
        case .context(let index):
            ContextBlock(event: events[index], edit: { editingContext = events[index] }, delete: { controller.board.editContext(events[index], text: "") })
        }
    }

    /// What VoiceOver says when your newest words didn't go: "Your comment didn't reach Grok Bot: …", or nil.
    private func failureSpoken(_ index: Int, status: DeliveryStatus?) -> String? {
        guard let status else { return nil }
        let noun = events[index].kind == .answer ? "answer" : "comment"
        switch status.kind {
        case .failed: return "Your \(noun) \(status.spoken)"
        case .notSent where status.words.hasPrefix("Not sent: "): return "Your \(noun) wasn't sent: " + status.words.dropFirst("Not sent: ".count)
        default: return nil
        }
    }

    /// What became of your words at `index`, for the line under them, or nil where none is said.
    private func status(_ index: Int, deliveries: [Int: CardConversation.Delivery], agent: String?, newestWords: Int?) -> DeliveryStatus? {
        guard let agent, let delivery = deliveries[index] else { return nil }
        let who = agent.shortAgentName
        switch delivery {
        case .sent(let receipt):
            return DeliveryStatus(kind: .sent, words: "Sent to \(who) · \(events[receipt].createdAt.formatted(date: .omitted, time: .shortened))",
                                  receipt: events[receipt], spoken: "sent to \(who)")
        case .didntArrive(let receipt, let failure):
            let why = Self.failureReason(events[failure].text)
            let at = events[failure].createdAt.formatted(date: .omitted, time: .shortened)
            return DeliveryStatus(kind: .failed, words: "Didn't reach \(who) at \(at): \(why). Wake Now sends it again.", receipt: events[receipt],
                                  spoken: "didn't reach \(who): \(why)")
        case .finishedFirst:
            let words = card.column == .review ? "Not sent: \(who) finished first. Send Back sends your words." : "Not sent: \(who) finished first."
            return DeliveryStatus(kind: .notSent, words: words, receipt: nil, spoken: "not sent, \(who) finished first")
        case .notSent:
            // The newest of your words: why, while Binders knows it.
            if index == newestWords, let unsent = controller.agents.unsent(for: card), unsent.at.map({ $0 >= events[index].createdAt.addingTimeInterval(-1) }) ?? true {
                let later = unsent.at == nil
                return DeliveryStatus(kind: later ? .later : .notSent, words: unsent.why, receipt: nil, spoken: unsent.why)
            }
            return DeliveryStatus(kind: .notSent, words: "Not sent to \(who)", receipt: nil, spoken: "not sent to \(who)")
        }
    }

    // MARK: Words

    /// Why a wake's words didn't arrive, from its failure line, to follow a colon mid-sentence: without the line's opening
    /// or a full stop of its own, starting in lower case unless its first word is in capitals ("the server answered 500").
    static func failureReason(_ line: String) -> String {
        var why = line
        for opening in AgentDispatcher.failureLines where why.hasPrefix(opening) { why = String(why.dropFirst(opening.count)) }
        why = why.trimmingCharacters(in: CharacterSet(charactersIn: ": ").union(.whitespaces))
        while why.hasSuffix(".") { why.removeLast() }
        if let first = why.first, first.isUppercase, why.dropFirst().first.map({ !$0.isUppercase }) ?? true {
            why = first.lowercased() + why.dropFirst()
        }
        return why.isEmpty ? "it didn't say why" : why
    }

    /// What it did, as a message's header says it.
    static func verb(_ event: TaskEvent, column: BoardColumn?) -> String {
        let to = event.toColumn.flatMap(BoardColumn.init(rawValue:))?.title ?? ""
        switch event.kind {
        case .created: return "added it\(to.isEmpty ? "" : " to \(to)")"
        case .moved: return "moved it to \(to)"
        case .claimed: return "picked it up"
        case .released: return "let it go"
        case .lapsed: return "went quiet"
        case .progress: return "reported progress"
        case .question: return "asked"
        case .answer: return "answered"
        case .comment: return "commented"
        case .completed: return to == BoardColumn.done.title || !event.authorIsAgent ? "finished it" : "finished it, for review"
        case .edited: return "edited it"
        case .assigned: return "said who it's for"
        case .woke: return "was woken"
        case .context: return "found this in the binder"
        case .approval: return "asks your approval"
        case .decision: return "kept the receipt"
        }
    }

    /// A board event's one quiet line, in full: its glyph and time go beside it.
    static func lineWords(_ event: TaskEvent) -> String {
        let who = event.author
        let note = event.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let to = event.toColumn.flatMap(BoardColumn.init(rawValue:))?.title ?? ""
        switch event.kind {
        case .created: return "\(who) added it\(to.isEmpty ? "" : " to \(to)")" + (note.isEmpty ? "" : " · \(note)")
        case .moved: return "\(who) moved it to \(to)" + (note.isEmpty ? "" : ": \(note)")
        case .claimed:
            if note.isEmpty { return "\(who) picked it up" }
            if note.hasPrefix("Took it over") { return "\(who) took it over" + note.dropFirst("Took it over".count) }
            return note
        case .released: return "\(who) let it go" + (note.isEmpty ? "" : ": \(note)")
        case .lapsed: return note.isEmpty ? "\(who) went quiet" : note
        case .edited: return "\(who) edited it" + (note.isEmpty ? "" : ": \(note)")
        case .assigned: return "\(who) said who it's for" + (note.isEmpty ? "" : ": \(note)")
        case .woke: return note.isEmpty ? "\(who) was woken" : note
        case .decision: return "Binders kept the receipt"
        default: return "\(who) commented" + (note.isEmpty ? "" : ": \(note)")
        }
    }

    /// Whether a quiet line is something an agent did (added it, picked it up, let it go, moved it, edited it, said who
    /// it's for), whose line starts with its name and gets its sparkle. Woken and went quiet are Binders' records about the
    /// agent, as is Binders holding a card for one, so they get none.
    static func agentDidIt(_ event: TaskEvent) -> Bool {
        guard event.authorIsAgent else { return false }
        switch event.kind {
        case .created, .claimed, .released, .moved, .edited, .assigned: return lineWords(event).hasPrefix(event.author)
        default: return false
        }
    }

    static func symbol(_ event: TaskEvent) -> String {
        switch event.kind {
        case .created: "plus.circle"
        case .moved: "arrow.right.circle"
        case .claimed: "hand.raised"
        case .released, .lapsed: "arrow.uturn.backward.circle"
        case .edited: "pencil"
        case .assigned: "person.crop.circle.badge.checkmark"
        case .woke: "bell"
        case .decision: "signature"
        default: "bubble.left"
        }
    }
}

// MARK: - The conversation's rows

/// "Today", "Yesterday" or the day, centred between hairlines, before the first entry of each day.
private struct DayHeading: View {
    let date: Date

    var body: some View {
        let calendar = Calendar.current
        let words = calendar.isDateInToday(date) ? "Today" : calendar.isDateInYesterday(date) ? "Yesterday"
            : date.formatted(.dateTime.weekday(.wide).day().month(.wide))
        HStack(spacing: 10) {
            Rectangle().fill(BindersTheme.line).frame(height: 1)
            Text(words)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(BindersTheme.muted)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Capsule().fill(BindersTheme.surface2))
                .overlay(Capsule().strokeBorder(BindersTheme.line))
                .fixedSize()
            Rectangle().fill(BindersTheme.line).frame(height: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(words)
        .accessibilityAddTraits(.isHeader)
    }
}

/// An agent's words: a 2 pt lavender rule (amber while it waits on you), the sparkle, its name in ink, what it did and
/// when, then its words in ink. No fill: the rule and the sparkle say an agent did it. A request for your approval says
/// what it asks in one line ("Send an email to beta-list@example.com"): while it waits, the tray below has it whole with
/// Approve and Decline; once decided, Show All here opens its exact text.
private struct AgentMessage: View {
    let event: TaskEvent
    let verb: String
    let waiting: Bool
    let column: BoardColumn
    /// How wide its words may run: the header spans the column, so its time lines up with every other.
    let wordsWidth: CGFloat
    /// Approval requests opened to their exact text, by event.
    @Binding var opened: Set<UUID>

    var body: some View {
        let approval = event.kind == .approval ? AgentApproval(timeline: event.text) : nil
        let open = opened.contains(event.id)
        let bubbleWidth = max(140, wordsWidth - CardDesign.avatarSize - 8)
        let fill = waiting ? BindersTheme.needsYou.opacity(0.08) : BindersTheme.surface2
        let edge = waiting ? BindersTheme.needsYou.opacity(0.40) : BindersTheme.line
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                CardAvatar(kind: .agent)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(event.author).font(CardDesign.messageHeader).foregroundStyle(BindersTheme.ink).lineLimit(1)
                        if let glyph {
                            Image(systemName: glyph.name)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(glyph.color)
                                .accessibilityHidden(true)
                        }
                        Text(verb).font(CardDesign.meta).foregroundStyle(BindersTheme.muted).lineLimit(1)
                        Spacer(minLength: 8)
                        Text(event.createdAt.formatted(date: .omitted, time: .shortened))
                            .font(CardDesign.meta)
                            .monospacedDigit()
                            .foregroundStyle(BindersTheme.muted)
                            .fixedSize()
                    }
                    if let approval {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(approval.summary)
                                .font(CardDesign.message)
                                .foregroundStyle(BindersTheme.ink)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            if !waiting {
                                Button(open ? "Show Less" : "Show All") { toggle() }
                                    .buttonStyle(.borderless)
                                    .quietControl(words: true)
                                    .font(CardDesign.meta)
                                    .help(open ? "Hide what it asked to send" : "Show exactly what it asked to send")
                                if open {
                                    Text(approval.text)
                                        .font(CardDesign.message)
                                        .foregroundStyle(BindersTheme.ink)
                                        .textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .frame(maxWidth: bubbleWidth, alignment: .leading)
                        .cardBubble(fill: fill, edge: edge)
                        .overlay(alignment: .leading) {
                            if waiting {
                                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                                    .fill(BindersTheme.needsYou)
                                    .frame(width: 3)
                                    .padding(.vertical, 8)
                                    .padding(.leading, 1)
                            }
                        }
                    } else if !event.text.isEmpty {
                        Text(event.text)
                            .font(CardDesign.message)
                            .foregroundStyle(BindersTheme.ink)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .frame(maxWidth: bubbleWidth, alignment: .leading)
                            .cardBubble(fill: fill, edge: edge)
                            .overlay(alignment: .leading) {
                                if waiting {
                                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                                        .fill(BindersTheme.needsYou)
                                        .frame(width: 3)
                                        .padding(.vertical, 8)
                                        .padding(.leading, 1)
                                }
                            }
                    }
                }
            }
        }
        .contextMenu { Button("Copy") { copy(event.text) } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(event.author), \(verb)\(waiting ? ", \(waitingWords)" : ""): \(approval?.summary ?? event.text), \(event.createdAt.formatted(.relative(presentation: .named)))")
        .accessibilityActions {
            if approval != nil, !waiting { Button(open ? "Show Less" : "Show All") { toggle() } }
        }
    }

    private func toggle() {
        if opened.contains(event.id) { opened.remove(event.id) } else { opened.insert(event.id) }
    }

    private var waitingWords: String {
        switch event.kind {
        case .question: "waiting for your answer"
        case .approval: "waiting for your approval"
        default: "ready for you to check"
        }
    }

    /// The glyph of what it asks or did: amber while it waits on you, Done's green check, else muted.
    private var glyph: (name: String, color: Color)? {
        let quiet = BindersTheme.muted
        switch event.kind {
        case .question: return ("questionmark.bubble", waiting ? BindersTheme.needsYou : quiet)
        case .approval: return ("checkmark.shield", waiting ? BindersTheme.needsYou : quiet)
        case .completed:
            if column == .done { return ("checkmark.circle", BindersTheme.done) }
            return ("eye", waiting ? BindersTheme.needsYou : quiet)
        case .moved: return ("arrow.right.circle", quiet)
        case .released: return ("arrow.uturn.backward.circle", quiet)
        default: return nil
        }
    }
}

/// What became of your words, under them: sent (the receipt folded in, which opens to its words), didn't reach, not sent,
/// or on its way.
struct DeliveryStatus {
    enum Kind { case sent, failed, notSent, later }
    let kind: Kind
    let words: String
    /// The receipt of the wake that carried them, to open.
    let receipt: TaskEvent?
    /// How VoiceOver ends the message with it.
    let spoken: String
}

/// Your words: on the right, in New York italic on a faint ink bubble, with what became of them under it.
private struct YourMessage: View {
    let event: TaskEvent
    let verb: String
    let status: DeliveryStatus?
    @Binding var opened: Set<UUID>

    var body: some View {
        VStack(alignment: .trailing, spacing: 5) {
            HStack(spacing: 5) {
                Text("You").font(CardDesign.messageHeader).foregroundStyle(BindersTheme.ink)
                Text(verb).font(CardDesign.meta).foregroundStyle(BindersTheme.muted)
                Text(event.createdAt.formatted(date: .omitted, time: .shortened))
                    .font(CardDesign.meta)
                    .monospacedDigit()
                    .foregroundStyle(BindersTheme.muted)
                CardAvatar(kind: .you, size: 22)
            }
            .lineLimit(1)
            Text(event.text)
                .font(.system(size: 14.5, weight: .regular, design: .serif).italic())
                .foregroundStyle(BindersTheme.ink)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .cardBubble(fill: BindersTheme.ink.opacity(0.05), edge: BindersTheme.lineStrong)
                .contextMenu { Button("Copy") { copy(event.text) } }
            if let status { statusLine(status) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("You, \(verb): \(event.text), \(event.createdAt.formatted(.relative(presentation: .named)))\(status.map { ", \($0.spoken)" } ?? "")")
        .accessibilityActions {
            if let receipt = status?.receipt {
                Button(opened.contains(receipt.id) ? "Hide the receipt" : "Show the receipt") { toggle(receipt.id) }
            }
        }
    }

    @ViewBuilder
    private func statusLine(_ status: DeliveryStatus) -> some View {
        let label = HStack(spacing: 4) {
            switch status.kind {
            case .sent: Image(systemName: "paperplane").foregroundStyle(BindersTheme.muted)
            case .failed: Image(systemName: BindersTheme.problemSymbol).foregroundStyle(BindersTheme.ink)
            case .later: Image(systemName: "clock").foregroundStyle(BindersTheme.muted)
            case .notSent: Image(systemName: "text.bubble").foregroundStyle(BindersTheme.muted)
            }
            Text(status.words)
                .foregroundStyle(status.kind == .failed ? BindersTheme.ink : BindersTheme.muted)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption)
        if let receipt = status.receipt {
            Button { toggle(receipt.id) } label: { label }
                .buttonStyle(.plain)
                .help(receipt.text)
            if opened.contains(receipt.id) {
                Text(receipt.text)
                    .font(.caption)
                    .foregroundStyle(BindersTheme.muted)
                    .textSelection(.enabled)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            label
        }
    }

    private func toggle(_ id: UUID) {
        if opened.contains(id) { opened.remove(id) } else { opened.insert(id) }
    }
}

/// A note by Binders itself: why a run didn't start, what it committed when a run ended. Its own words, apart from
/// yours and the agent's.
private struct BindersNote: View {
    let event: TaskEvent
    let wordsWidth: CGFloat

    var body: some View {
        let bubbleWidth = max(140, wordsWidth - CardDesign.avatarSize - 8)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                CardAvatar(kind: .binders)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text("Binders").font(CardDesign.messageHeader).foregroundStyle(BindersTheme.ink)
                        Spacer(minLength: 8)
                        Text(event.createdAt.formatted(date: .omitted, time: .shortened))
                            .font(CardDesign.meta)
                            .monospacedDigit()
                            .foregroundStyle(BindersTheme.muted)
                    }
                    Text(event.text)
                        .font(CardDesign.message)
                        .foregroundStyle(BindersTheme.muted)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .frame(maxWidth: bubbleWidth, alignment: .leading)
                        .cardBubble(fill: BindersTheme.ink.opacity(0.04), edge: BindersTheme.line)
                }
            }
        }
        .contextMenu { Button("Copy") { copy(event.text) } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Binders: \(event.text), \(event.createdAt.formatted(.relative(presentation: .named)))")
    }
}

/// A board event on one quiet line: its glyph, the agent's sparkle when an agent did it, its words, its time. Words that
/// don't fit end with "…" and a chevron: a click on the line, or Space on the chevron, shows them all, selectable, and
/// again hides them. A line that fits has no chevron, so nothing on it is a stop for Tab.
private struct QuietLine: View {
    let event: TaskEvent
    let words: String
    let symbol: String
    let byAgent: Bool
    @Binding var opened: Set<UUID>

    var body: some View {
        let open = opened.contains(event.id)
        Group {
            if open {
                line(open: true, cut: true)
            } else {
                // The whole line when its words fit; cut short, with the chevron, when they don't.
                ViewThatFits(in: .horizontal) {
                    line(open: false, cut: false)
                    line(open: false, cut: true)
                }
            }
        }
        .font(.system(size: 11.5, weight: .medium))
        .help(words)
        .contextMenu { Button("Copy") { copy(words) } }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(words), \(event.createdAt.formatted(.relative(presentation: .named)))")
    }

    /// The line: whole (`cut` false: its words at their full width, no chevron), cut short with the chevron, or `open`.
    @ViewBuilder
    private func line(open: Bool, cut: Bool) -> some View {
        let row = HStack(alignment: .firstTextBaseline, spacing: 8) {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(BindersTheme.ink.opacity(0.06))
                .overlay {
                    Image(systemName: symbol)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(BindersTheme.faint)
                }
                .frame(width: 18, height: 18)
                .accessibilityHidden(true)
            if open {
                said.textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            } else if cut {
                said.lineLimit(1).truncationMode(.tail)
            } else {
                said.lineLimit(1).fixedSize()
            }
            Spacer(minLength: 8)
            // Before the time, so every time lines up at the column's edge.
            if cut {
                Button { toggle() } label: {
                    Image(systemName: open ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(BindersTheme.muted)
                }
                .buttonStyle(.plain)
                .help(open ? "Show Less" : "Show All")
                .accessibilityLabel(open ? "Show Less" : "Show All")
            }
            Text(event.createdAt.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 10.5, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(BindersTheme.muted)
                .fixedSize()
        }
        if cut {
            row.contentShape(Rectangle())
                .onTapGesture { toggle() }
                .accessibilityAction(named: open ? "Show Less" : "Show All") { toggle() }
        } else {
            row
        }
    }

    /// The words, after the agent's sparkle when an agent did it.
    private var said: Text {
        let words = Text(words).foregroundStyle(BindersTheme.muted)
        guard byAgent else { return words }
        return Text(Image(systemName: BindersTheme.agentSymbol)).foregroundStyle(BindersTheme.agent) + Text(" ") + words
    }

    private func toggle() {
        if opened.contains(event.id) { opened.remove(event.id) } else { opened.insert(event.id) }
    }
}

/// "From your binders": passages Binders found in the binder when the card first went to an agent, yours to edit or
/// delete before an agent reads them again.
private struct ContextBlock: View {
    let event: TaskEvent
    let edit: () -> Void
    let delete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(BindersTheme.ink.opacity(0.06))
                    .overlay {
                        Image(systemName: "books.vertical")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(BindersTheme.muted)
                    }
                    .frame(width: 18, height: 18)
                    .accessibilityHidden(true)
                Text("From your binders").font(CardDesign.sectionTitle).foregroundStyle(BindersTheme.ink)
                Spacer(minLength: 8)
                Button("Edit…", action: edit).buttonStyle(.borderless).quietControl(words: true).font(CardDesign.meta)
                Button("Delete", role: .destructive, action: delete).buttonStyle(.borderless).quietControl(words: true).font(CardDesign.meta)
            }
            Text(event.text)
                .font(.system(size: 12.5, weight: .regular))
                .foregroundStyle(BindersTheme.muted)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .cardBubble(fill: BindersTheme.surface2, edge: BindersTheme.line)
        }
        .contextMenu {
            Button("Edit…", action: edit)
            Button("Delete", role: .destructive, action: delete)
            Button("Copy") { copy(event.text) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("From your binders")
    }
}

/// Over the bottom of the conversation while you've scrolled up and something new came: how many, and back to them.
private struct NewEntriesPill: View {
    let count: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label { Text("\(count) new").rollingCount(count) } icon: { Image(systemName: "arrow.down") }
                .font(.system(size: 11.5, weight: .semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(TintFill().opacity(0.14)))
                .overlay(Capsule().strokeBorder(TintFill().opacity(0.45)))
                .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tintText)
        .accessibilityLabel("Show the \(count) newest")
    }
}

/// Puts words on the pasteboard, from a row's Copy.
private func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

// MARK: - Keeping to the newest

/// Reads the conversation's own NSScrollView: whether you're at the newest entry (the visible bottom within 8 pt of the
/// content's), from its clip view's bounds rather than a row, which a lazy stack builds ahead of the visible area. It opens
/// at the newest, and while you're there it keeps the newest at the bottom edge as the content grows and as the
/// conversation's own height changes (what waits on you comes or goes, the composer grows), in the same layout pass, so
/// nothing scrolls, animated or not. Scrolled up, nothing you're reading moves.
struct ScrollProbe: NSViewRepresentable {
    /// The conversation's own handle on its scroll view, for the pill's way back to the newest.
    @MainActor
    final class Handle {
        fileprivate weak var view: ProbeView?

        func scrollToNewest(animated: Bool) { view?.scrollToNewest(animated: animated) }
    }

    /// The identifier the conversation's scroll view gets, for the self-tests and drawings that find it.
    static let identifier = NSUserInterfaceItemIdentifier("card-conversation")

    let handle: Handle
    let changed: (Bool) -> Void

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.changed = changed
        handle.view = view
        return view
    }

    func updateNSView(_ view: ProbeView, context: Context) {
        view.changed = changed
        handle.view = view
        view.attach()
    }

    final class ProbeView: NSView {
        var changed: ((Bool) -> Void)?
        private weak var scrollView: NSScrollView?
        private var atNewest = true
        private var opened = false
        private var lastHeight: CGFloat = 0
        private var lastViewport: CGFloat = 0

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            attach()
        }

        /// Finds the scroll view around it, once, and watches it.
        func attach() {
            guard let scroll = enclosingScrollView, scroll !== scrollView else { return }
            NotificationCenter.default.removeObserver(self)
            scrollView = scroll
            scroll.identifier = ScrollProbe.identifier
            scroll.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(boundsChanged), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
            // The clip view keeps its top when it gets shorter, so the newest would slide out of view: watch its height too.
            scroll.contentView.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(viewportChanged), name: NSView.frameDidChangeNotification, object: scroll.contentView)
            lastViewport = scroll.contentView.frame.height
            if let document = scroll.documentView {
                document.postsFrameChangedNotifications = true
                NotificationCenter.default.addObserver(self, selector: #selector(contentChanged), name: NSView.frameDidChangeNotification, object: document)
            }
            // Opened at the newest entry, without moving anything once it has drawn.
            DispatchQueue.main.async { [weak self] in
                self?.scrollToNewest(animated: false)
                self?.opened = true
            }
        }

        /// Whether the visible bottom is within 8 pt of the content's.
        var isAtNewest: Bool {
            guard let scroll = scrollView, let document = scroll.documentView else { return true }
            let visible = scroll.contentView.bounds
            if document.isFlipped { return visible.maxY >= document.bounds.height - 8 }
            return visible.minY <= 8
        }

        @objc private func boundsChanged() {
            let now = isAtNewest
            guard now != atNewest else { return }
            atNewest = now
            let changed = changed
            DispatchQueue.main.async { changed?(now) }
        }

        /// The content grew (an entry came, a line opened): at the newest, the newest stays at the bottom edge.
        @objc private func contentChanged() {
            guard let document = scrollView?.documentView else { return }
            let height = document.bounds.height
            defer { lastHeight = height }
            guard height != lastHeight, atNewest || !opened else { return }
            scrollToNewest(animated: false)
        }

        /// The conversation itself got shorter or taller (the tray came or went, the composer grew): at the newest, the
        /// newest stays at the bottom edge.
        @objc private func viewportChanged() {
            guard let clip = scrollView?.contentView else { return }
            let height = clip.frame.height
            defer { lastViewport = height }
            guard height != lastViewport, atNewest || !opened else { return }
            scrollToNewest(animated: false)
        }

        /// To the newest entry: a short scroll you asked for, or at once.
        func scrollToNewest(animated: Bool) {
            guard let scroll = scrollView, let document = scroll.documentView else { return }
            let clip = scroll.contentView
            let bottom = document.isFlipped ? max(0, document.bounds.height - clip.bounds.height) : 0
            let target = NSPoint(x: clip.bounds.minX, y: bottom)
            if animated {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.25
                    clip.animator().setBoundsOrigin(target)
                }
            } else {
                clip.setBoundsOrigin(target)
            }
            scroll.reflectScrolledClipView(clip)
            atNewest = true
            let changed = changed
            DispatchQueue.main.async { changed?(true) }
        }
    }
}

// MARK: - What waits on you

/// Docked above the composer while something waits on you, with what to do right there: the question you're answering,
/// the request for your approval with Approve and Decline…, finished work with Accept and Send Back, or why the card is
/// Blocked when nothing is asked. Amber marks its edge and glyph while it waits; the words stay ink.
struct NeedsYouTray: View {
    @Environment(DictationController.self) private var controller
    let card: TaskCard
    let events: [TaskEvent]
    let answering: CardAnswering?
    let reach: CommentReach
    let compactApproval: Bool
    @Binding var draft: String
    @Binding var problem: String?
    /// How wide its words may run: as a message's in the conversation above it.
    var wordsWidth = CGFloat(CardLayout.messageWidth)
    /// For the drawings: Decline's reason field open from the start.
    var startsDeclining = false

    static func shows(_ card: TaskCard, answering: CardAnswering?) -> Bool {
        answering != nil || card.column == .review
    }

    var body: some View {
        Group {
            switch answering {
            case .question:
                if let asked = waiting { question(asked) }
            case .approval:
                if let waiting = card.waitingApproval(events: events) {
                    ApprovalBox(card: card, event: waiting.event, approval: waiting.approval, compact: compactApproval,
                                startsDeclining: startsDeclining || Self.drawingDeclines, boxed: false)
                        .overlay(alignment: .leading) { amberEdge }
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel("Waiting for your approval")
                }
            case .reason(let reason):
                blocked(reason)
            case nil:
                if card.column == .review { finished }
            }
        }
        // A callout of its own, above the composer, in amber: what waits on you and what to do about it.
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(BindersTheme.needsYou.opacity(0.055)))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(BindersTheme.needsYou.opacity(0.32))
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
    }

    /// For the drawings: every approval tray opens with Decline's field showing.
    @MainActor static var drawingDeclines = false

    private var waiting: TaskEvent? {
        BoardRules.waitingAsk(in: events.map { (kind: $0.kindRaw, to: $0.toColumn ?? "") }).map { events[$0] }
    }

    private var amberEdge: some View {
        RoundedRectangle(cornerRadius: 1, style: .continuous).fill(BindersTheme.needsYou).frame(width: 2).padding(.vertical, 2)
    }

    private func header(_ glyph: String, _ words: String, at date: Date?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: glyph)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(BindersTheme.needsYou)
                .accessibilityHidden(true)
            Text(words).font(.system(size: 13, weight: .semibold)).foregroundStyle(BindersTheme.ink)
            Spacer(minLength: 8)
            // In caption, as every time in the conversation is.
            if let date {
                Text(date.formatted(date: .omitted, time: .shortened))
                    .font(CardDesign.meta)
                    .foregroundStyle(BindersTheme.muted)
                    .fixedSize()
            }
        }
    }

    private func question(_ event: TaskEvent) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            header("questionmark.bubble", "\(event.author) asks", at: event.createdAt)
            ScrollView {
                Text(event.text)
                    .font(.system(size: 13.5))
                    .foregroundStyle(BindersTheme.ink)
                    .textSelection(.enabled)
                    .frame(maxWidth: wordsWidth, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxHeight: 72)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, 22)
        }
        .padding(.leading, 12)
        .padding(.vertical, 4)
        .overlay(alignment: .leading) { amberEdge }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Waiting for your answer. \(event.author) asks: \(event.text)")
    }

    private func blocked(_ reason: String) -> some View {
        Label {
            Text(reason.isEmpty ? "Blocked. No reason was given." : "Blocked: \(reason)")
                .font(.system(size: 13.5))
                .foregroundStyle(BindersTheme.ink)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: wordsWidth, alignment: .leading)
        } icon: {
            Image(systemName: BindersTheme.problemSymbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(BindersTheme.ink)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 6)
        .accessibilityElement(children: .combine)
    }

    /// Finished work: who finished it, the start of what it said, Accept and, for an agent's work, Send Back. Both use
    /// what's in the composer: your words go on the card first.
    @ViewBuilder
    private var finished: some View {
        let summary = events.last { $0.kind == .completed && $0.authorIsAgent }
        let agentWork = card.assigneeIsAgent && summary != nil
        VStack(alignment: .leading, spacing: 6) {
            if agentWork, let summary {
                header("eye", "\(summary.author) finished it", at: summary.createdAt)
                Text(summary.text)
                    .font(.system(size: 13.5))
                    .foregroundStyle(BindersTheme.ink)
                    .lineLimit(2)
                    .frame(maxWidth: wordsWidth, alignment: .leading)
                    .padding(.leading, 22)
            } else {
                header("eye", "Ready for you to check", at: nil)
            }
            HStack(spacing: 8) {
                Button("Accept") { attempt { try CardActions.accept(card, words: draft, board: controller.board) } }
                    .buttonStyle(.borderedProminent)
                    .help("Move it to Done. Anything you typed below goes on the card first.")
                if agentWork {
                    Button("Send Back") { attempt { try CardActions.sendBack(card, words: draft, board: controller.board) } }
                        .help(sendBackHelp)
                        .accessibilityHint("Shift Command Return")
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 22)
        }
        .padding(.leading, 12)
        .padding(.vertical, 4)
        .overlay(alignment: .leading) { amberEdge }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Ready for you to check")
    }

    private var sendBackHelp: String {
        let who = (card.assignee ?? "the agent").shortAgentName
        if case .finished(_, sendBackWakes: false) = reach {
            return "Move it back to In progress with what you typed below on it. Binders doesn't wake \(who). (⇧⌘↩)"
        }
        return "Send it back to \(who) with what you typed below (⇧⌘↩)"
    }

    private func attempt(_ action: () throws -> Void) {
        do {
            try action()
            draft = ""
        } catch {
            problem = error.localizedDescription
        }
    }
}
