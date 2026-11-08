import SwiftUI
import BindersKit

/// Opens a card when pushed onto the navigation stack.
struct CardLink: Hashable, Identifiable {
    let id: String
}

/// A binder's board, or every binder's: what needs you first (an agent's question, finished work to check), then what's
/// in progress, ready and waiting. Swipe to approve, start or promote a card; tap one for its story.
struct CardBoardView: View {
    @Environment(MacConnection.self) private var connection
    /// One binder's board; every binder's when nil.
    let binder: String?
    @State private var cards: [Card] = []
    @State private var done: [Card] = []
    @State private var loaded = false
    /// Nothing from the Mac yet, and no copy from last time.
    @State private var unreached = false
    @State private var newCard = ""
    @State private var adding = false
    @State private var problem: String?
    @State private var opened: CardLink?
    /// A card meant for an agent, on its way to Ready, waiting for your first yes to that agent.
    @State private var awaitingYes: PendingHandOff?
    @Environment(\.binderTint) private var binderTint

    /// Attention first: the cards waiting on you, then the work in hand, then the queue.
    static let order: [BoardColumn] = [.blocked, .review, .inProgress, .ready, .backlog]

    var body: some View {
        List {
            if let binder {
                Section {
                    HStack {
                        TextField("Add a card to \(binder)", text: $newCard)
                            .submitLabel(.done)
                            .onSubmit(add)
                        if adding { ProgressView() } else if !newCard.isEmpty {
                            Button("Add", action: add).buttonStyle(.borderless)
                        }
                    }
                } footer: {
                    Text("New cards start in Backlog. Swipe one right to make it Ready for an agent to pick up.")
                }
                .surfaceRows()
            }
            ForEach(Self.order, id: \.self) { column in
                let items = cards.filter { $0.board == column }
                if !items.isEmpty {
                    Section {
                        ForEach(items) { row($0) }
                    } header: {
                        // The count rounded and heavy, as counts are, rolling as cards come and go: muted, as the header is,
                        // inside a binder too.
                        HStack(spacing: 0) {
                            SectionTitle("\(column.title) · ")
                            Text("\(items.count)").font(Typeface.count(.footnote))
                                .foregroundStyle(Palette.muted)
                                .rollingCount(items.count)
                        }
                        .accessibilityElement(children: .combine)
                    }
                    .surfaceRows()
                }
            }
            if !done.isEmpty {
                Section {
                    ForEach(done.prefix(10)) { row($0) }
                } header: {
                    SectionTitle("Done")
                }
                .surfaceRows()
            }
        }
        .listGround()
        .overlay {
            if loaded && cards.isEmpty && done.isEmpty {
                EmptyState("No cards yet", symbol: "rectangle.split.3x1",
                           description: "Cards are work that you or an agent picks up. Add one here, or swipe a to-do onto the board.")
            } else if unreached {
                WaitingForMac(what: "The board shows here") { await load() }
            }
        }
        .navigationDestination(item: $opened) { CardDetailView(id: $0.id) }
        .refreshable { await load() }
        .task(id: connection.revision("tasks")) { await load() }
        .problemToast($problem)
        // Making a card ready hands it to the agent it's meant for, and moving one back from Review sends it back to its
        // agent: the first time for each agent, it asks, as Give to does.
        .confirmationDialog(awaitingYes.map { $0.sendsBack ? "Send it back to \($0.agent.name)?" : "Give cards to \($0.agent.name)?" } ?? "",
                            isPresented: Binding(get: { awaitingYes != nil }, set: { if !$0 { awaitingYes = nil } }),
                            titleVisibility: .visible, presenting: awaitingYes) { pending in
            Button(pending.sendsBack ? "Send Back to \(pending.agent.name)" : "Give to \(pending.agent.name)") {
                AgentConsents.agree(pending.agent)
                perform(pending.tool, pending.card, to: pending.column)
            }
            Button("Cancel", role: .cancel) {}
        } message: { pending in
            Text(AgentConsents.disclosure(pending.agent))
        }
    }

    private func row(_ card: Card) -> some View {
        NavigationLink(value: CardLink(id: card.id)) {
            CardRow(card: card, showsBinder: binder == nil)
        }
        .swipeActions(edge: .leading) {
            switch card.board {
            case .review:
                // Approved is done: green.
                Button { perform("update_task", card, to: .done) } label: { Label("Approve", systemImage: "checkmark") }
                    .tint(Palette.done)
            case .ready:
                Button { perform("claim_task", card) } label: { Label("Start", systemImage: "play") }
                    .tint(binderTint?.fill ?? Palette.accent)
            case .backlog:
                Button { perform("update_task", card, to: .ready) } label: { Label("Ready", systemImage: "arrow.right") }
                    .tint(binderTint?.fill ?? Palette.accent)
            default:
                EmptyView()
            }
        }
        .contextMenu {
            Menu("Move to") {
                ForEach(BoardColumn.allCases.filter { $0 != card.board }, id: \.self) { column in
                    Button(column.title) { perform("update_task", card, to: column) }
                }
            }
            if card.board != .done {
                if card.assignee.isEmpty {
                    Button("Take It") { perform("claim_task", card) }
                } else if card.assignee == "You" {
                    Button("Let Go") { perform("release_task", card) }
                }
            }
        }
    }

    // MARK: Data

    private func load() async {
        let key = binder ?? "all"
        // Last time's board straight away; then the Mac's, open and done cards asked for together.
        if !loaded, cards.isEmpty, done.isEmpty {
            let copy = connection.cached("tasks-\(key)", as: [Card].self)
            cards = copy ?? []
            done = connection.cached("tasks-done-\(key)", as: [Card].self) ?? []
            loaded = copy != nil
        }
        async let open = connection.fetch("list_tasks", Self.arguments(binder), cache: "tasks-\(key)", as: [Card].self)
        async let closed = connection.fetch("list_tasks", Self.arguments(binder, column: .done), cache: "tasks-done-\(key)", as: [Card].self)
        // The agents too, so making a card ready for one knows to ask first.
        async let agents = connection.fetch("list_agents", cache: "agents", as: AgentList.self)
        if let value = await open.value {
            cards = value
            loaded = true
        }
        if let value = await closed.value { done = value }
        _ = await agents.value
        // Only the Mac, or last time's copy, says there are no cards.
        unreached = !loaded
        openForDevelopment()
    }

    private static func arguments(_ binder: String?, column: BoardColumn? = nil) -> [String: Any] {
        var arguments: [String: Any] = [:]
        if let binder { arguments["binder"] = binder }
        if let column { arguments["column"] = column.rawValue }
        return arguments
    }

    /// Take, let go or move a card: it moves at once, by the Mac's own rules, and the Mac's change notification brings its
    /// copy. If the Mac says no, the card goes back, unless something newer came in meanwhile, and a toast says why.
    private func perform(_ tool: String, _ card: Card, to column: BoardColumn? = nil) {
        // Back from Review to the agent that did it: the card goes back to it, so it asks first too.
        if tool == "update_task", column == .inProgress, card.board == .review, card.assigneeIsAgent,
           let agent = AgentConsents.agent(named: card.assignee, connection: connection), !AgentConsents.agreed(agent) {
            return awaitingYes = PendingHandOff(card: card, agent: agent, tool: tool, column: column)
        }
        // Into Ready, by a move or by letting go of it, a card meant for an agent goes to that agent.
        if column == .ready || tool == "release_task" {
            switch handOffCheck(meantFor: card.meantFor, confirmed: card.meantForConfirmed, connection: connection) {
            case .ask(let agent): return awaitingYes = PendingHandOff(card: card, agent: agent, tool: tool, column: column)
            case .unknown:
                // Who the agents are isn't known here yet: asked first, then this again.
                Task {
                    _ = await connection.fetch("list_agents", cache: "agents", as: AgentList.self).value
                    if connection.cached("agents", as: AgentList.self) != nil { perform(tool, card, to: column) } else { problem = "Couldn't check who the card would go to. Try again in a moment." }
                }
                return
            case .fine: break
            }
        }
        guard connection.isConnected else { return problem = "\(connection.brainName ?? "\(MacConnection.BrainWords)") is out of reach. Try again when it's back." }
        // Approved, from Review to Done: success by touch. Any other move, a tap.
        if tool == "update_task", column == .done, card.board == .review { Haptics.shared.success() } else { Haptics.shared.tap() }
        let before = (cards: cards, done: done)
        if let next = card.after(tool, to: column) { place(next) }
        let shown = (cards: cards, done: done)
        var arguments: [String: Any] = ["id": card.id]
        if let column { arguments["column"] = column.rawValue }
        Task {
            do {
                _ = try await connection.call(tool, arguments)
            } catch {
                if cards == shown.cards, done == shown.done { (cards, done) = (before.cards, before.done) }
                problem = error.localizedDescription
            }
        }
    }

    /// A card where it now stands: at the top of its column, or of Done.
    private func place(_ card: Card) {
        cards.removeAll { $0.id == card.id }
        done.removeAll { $0.id == card.id }
        if card.board == .done { done.insert(card, at: 0) } else { cards.insert(card, at: 0) }
    }

    private func add() {
        let title = newCard.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let binder, !title.isEmpty, !adding else { return }
        adding = true
        Task {
            defer { adding = false }
            do {
                _ = try await connection.call("create_task", ["title": title, "binder": binder, "column": "backlog"])
                newCard = ""
                // A card added: filed, by touch.
                Haptics.shared.success()
                await load()
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    /// For development: `-openCard blocked` (or any column) opens the first card there, once.
    private static var openedForDevelopment = false
    private func openForDevelopment() {
        guard !Self.openedForDevelopment, let wanted = UserDefaults.standard.string(forKey: "openCard"),
              let card = cards.first(where: { $0.column == wanted }) else { return }
        Self.openedForDevelopment = true
        opened = CardLink(id: card.id)
    }
}

struct CardRow: View {
    let card: Card
    var showsBinder = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(card.title)
                .strikethrough(card.board == .done)
                .foregroundStyle(card.board == .done ? Palette.muted : Palette.ink)
            // Icon and words close together; a Label in a list row sets the icon apart. Both wait on you: amber, told
            // apart by their glyphs.
            if card.board == .blocked {
                HStack(spacing: 5) {
                    Image(systemName: "questionmark.bubble")
                    Text("Waiting for your answer")
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(Palette.needsYou)
            } else if card.board == .review {
                HStack(spacing: 5) {
                    Image(systemName: "eye")
                    Text("Ready for you to check")
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(Palette.needsYou)
            }
            let due = Date(iso: card.due)
            if !card.assignee.isEmpty || !(card.meantFor ?? "").isEmpty || due != nil || card.links > 0 || showsBinder {
                HStack(spacing: 8) {
                    if !card.assignee.isEmpty {
                        let left = card.board == .inProgress ? card.minutesLeft.map { " · \($0) min" } ?? "" : ""
                        // An agent's: lavender, with the sparkle.
                        Chip(text: card.assignee + left, symbol: card.assigneeIsAgent ? "sparkles" : "person",
                             tint: card.assigneeIsAgent ? Palette.agent : Palette.muted)
                    } else if let meantFor = card.meantFor, !meantFor.isEmpty, card.board != .done {
                        // An agent's suggestion asks; your own choice says.
                        Chip(text: card.meantForConfirmed == false ? "Give to \(meantFor)?" : "For \(meantFor)", symbol: "arrow.forward.circle")
                    }
                    if let due {
                        Chip(text: due.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()), symbol: "calendar",
                             urgent: Chip.isDue(due) && card.board != .done)
                    }
                    if card.links > 0 { Chip(text: "\(card.links)", symbol: "link") }
                    if showsBinder { Text(card.binder).font(.caption).foregroundStyle(Palette.muted).lineLimit(1).layoutPriority(-1) }
                }
            }
        }
        .padding(.vertical, 2)
    }
}

/// One card: who has it, what it's about, its links and its story, with a box to answer an agent's question or comment,
/// and, while an agent waits for your approval, exactly what it asks, to approve or decline.
struct CardDetailView: View {
    @Environment(MacConnection.self) private var connection
    let id: String
    @State private var card: CardDetail?
    @State private var unreached = false
    @State private var agents: AgentList?
    /// The agent something goes to once you've said yes to what that means, and what waits for it.
    @State private var consenting: AgentList.Agent?
    @State private var awaiting: Awaiting = .give
    /// An answer from the question's notification, waiting for your yes, has been offered here once.
    @State private var offeredHeld = false
    @State private var reply = ""
    @State private var sending = false
    @State private var problem: String?
    @FocusState private var replying: Bool
    /// Declining what an agent asks, with an optional reason for it.
    @State private var declining = false
    @State private var declineReason = ""
    @State private var deciding = false
    /// A note the card links back to (binders://note/…, from Put on Board), opened from its details.
    @State private var openedNote: NoteSummary?
    @Environment(\.binderTint) private var binderTint

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let card {
                    header(card)
                    if let approval = card.approval { approvalBox(approval) }
                    if let question = card.question { questionBox(question) }
                    if card.board == .review { reviewBox(card) }
                    if !card.details.isEmpty { MarkdownText(markdown: card.details).surfaceCard() }
                    if !card.links.isEmpty { links(card.links) }
                    if !card.source.isEmpty || !(card.todo ?? "").isEmpty { origin(card) }
                    timeline(card)
                } else if unreached {
                    WaitingForMac(what: "This card opens") { await load() }
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
            .padding()
        }
        .screenGround()
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle(card?.binder ?? "Card")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let card {
                ToolbarItem(placement: .topBarTrailing) { actions(card) }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if card != nil { composer }
        }
        .task(id: connection.revision("tasks")) { await load() }
        .problemToast($problem)
        // The note a card was put on the board from opens here, in the same stack.
        .environment(\.openURL, OpenURLAction { url in
            guard let note = NoteCards.noteID(in: url) else { return .systemAction }
            openedNote = NoteSummary(id: note.uuidString, title: "", updated: "", binder: card?.binder ?? "", preview: "")
            return .handled
        })
        .navigationDestination(item: $openedNote) { NoteDetailView(summary: $0) }
        // The first time anything goes to an agent from here, a card, an answer or work sent back: where it goes, and
        // what goes with it (App Store 5.1.2(i)).
        .confirmationDialog(consenting.map { awaiting.question(for: $0.name) } ?? "", isPresented: Binding(get: { consenting != nil }, set: { if !$0 { consenting = nil } }),
                            titleVisibility: .visible, presenting: consenting) { agent in
            Button(awaiting.yes(for: agent.name)) {
                AgentConsents.agree(agent)
                let waiting = awaiting
                awaiting = .give
                switch waiting {
                case .give: handOff(to: agent)
                case .move(let tool, let column):
                    perform(tool, to: column)
                    // Sent back: say why.
                    if column == .inProgress { replying = true }
                case .answer(let text): send(text)
                case .comment(let text, let holder): send(text, to: holder)
                case .held(let held): sendHeld(held)
                case .decide(let approval, let approve, let reason): sendDecision(approval: approval, approve: approve, reason: reason)
                }
            }
            Button("Cancel", role: .cancel) { awaiting = .give }
        } message: { agent in
            Text(AgentConsents.disclosure(agent))
        }
        // A card is one of its binder's pages, wherever it's opened from.
        .binderTint(ownTint)
    }

    /// Its binder's colour, once the card says which binder; until then, the binder it's opened in, if any.
    private var ownTint: BinderTint? { BinderColors.tint(card?.binder, connection: connection) ?? binderTint }

    // MARK: Parts

    private func header(_ card: CardDetail) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(card.title).font(Typeface.title(.title2)).foregroundStyle(Palette.ink)
            HStack(spacing: 8) {
                Text(card.board.title)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(tint(card.board).opacity(0.15)))
                    .foregroundStyle(tint(card.board))
                if !card.assignee.isEmpty {
                    Chip(text: card.assignee, symbol: card.assigneeIsAgent ? "sparkles" : "person",
                         tint: card.assigneeIsAgent ? Palette.agent : Palette.muted)
                } else if let meantFor = card.meantFor, !meantFor.isEmpty, card.board != .done {
                    Chip(text: card.meantForConfirmed == false ? "Give to \(meantFor)?" : "For \(meantFor)", symbol: "arrow.forward.circle")
                }
                if let due = Date(iso: card.due) {
                    Chip(text: due.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()), symbol: "calendar",
                         urgent: Chip.isDue(due) && card.board != .done)
                }
            }
        }
    }

    private func questionBox(_ question: CardEvent) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("\(question.who) asked", systemImage: "questionmark.bubble")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Palette.needsYou)
            Text(question.text).foregroundStyle(Palette.ink).textSelection(.enabled)
            Text("Your answer sends the card back to work.").font(.caption).foregroundStyle(Palette.muted)
        }
        .needsYouCard()
    }

    /// What an agent asks your approval for: exactly who it goes to and what it says, here and nowhere on the Lock Screen.
    private func approvalBox(_ approval: CardApproval) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(approval.headline, systemImage: "checkmark.shield")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Palette.needsYou)
            if !approval.recipients.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(approval.recipients.enumerated()), id: \.offset) { _, recipient in
                        Text("To: \(recipient)").font(.callout).foregroundStyle(Palette.ink).textSelection(.enabled)
                    }
                }
            }
            // Exactly what it would send, set apart on the ground.
            Text(approval.text)
                .font(.callout)
                .foregroundStyle(Palette.ink)
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.ground))
            if !approval.link.isEmpty {
                // An agent's link is data: only a web page opens, never another app's link.
                if let url = URL(string: approval.link), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                    Link(destination: url) { Label(approval.link, systemImage: "link").lineLimit(1).truncationMode(.middle) }
                } else {
                    Label(approval.link, systemImage: "doc").lineLimit(1).truncationMode(.middle).foregroundStyle(Palette.muted)
                }
            }
            HStack {
                Button { decide(approve: true) } label: { Label("Approve", systemImage: "checkmark") }
                    .primaryButton()
                // A decision, not something destroyed: not red. The alert after it asks again.
                Button("Decline") { declining = true }
                    .buttonStyle(.bordered)
                    .tint(Palette.ink)
                if deciding { ProgressView() }
            }
            .disabled(deciding || !connection.isConnected)
            Text("Approving tells \(approval.who) to go ahead with exactly this. Binders can't stop an agent from using its own tools.")
                .font(.caption)
                .foregroundStyle(Palette.muted)
        }
        .needsYouCard()
        .alert("Decline it?", isPresented: $declining) {
            TextField("Why not? (optional)", text: $declineReason)
            Button("Decline", role: .destructive) { decide(approve: false, reason: declineReason) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(approval.who) hears that it shouldn't, and why if you say.")
        }
    }

    private func reviewBox(_ card: CardDetail) -> some View {
        let summary = card.timeline.last { $0.kind == "completed" }
        // Finished work waits on you to check it: amber, as on Today.
        return VStack(alignment: .leading, spacing: 10) {
            Label(summary.map { "\($0.who) finished it" } ?? "Ready for you to check", systemImage: "eye")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Palette.needsYou)
            if let summary, !summary.text.isEmpty { Text(summary.text).foregroundStyle(Palette.ink).textSelection(.enabled) }
            HStack {
                Button { perform("update_task", to: .done) } label: { Label("Approve", systemImage: "checkmark") }
                    .primaryButton()
                Button("Send Back") {
                    perform("update_task", to: .inProgress)
                    if consenting == nil { replying = true }
                }
                .buttonStyle(.bordered)
            }
        }
        .needsYouCard()
    }

    private func links(_ links: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Links").font(Typeface.title(.headline)).foregroundStyle(Palette.ink)
            ForEach(links, id: \.self) { link in
                if let url = URL(string: link), url.scheme != nil {
                    Link(destination: url) { Label(link, systemImage: "link").lineLimit(1).truncationMode(.middle) }
                } else {
                    Label(link, systemImage: "doc").lineLimit(1).truncationMode(.middle).foregroundStyle(Palette.muted)
                }
            }
        }
        .surfaceCard()
    }

    private func origin(_ card: CardDetail) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if !card.source.isEmpty { Label("From \(card.source)", systemImage: "arrow.turn.down.right") }
            if !(card.todo ?? "").isEmpty { Label("Its to-do is ticked off when this card is done.", systemImage: "checklist") }
        }
        .font(.caption)
        .foregroundStyle(Palette.muted)
    }

    private func timeline(_ card: CardDetail) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Timeline").font(Typeface.title(.headline)).foregroundStyle(Palette.ink)
            ForEach(Array(card.timeline.enumerated()), id: \.offset) { _, event in CardEventRow(event: event) }
        }
        .surfaceCard()
    }

    private func actions(_ card: CardDetail) -> some View {
        Menu {
            if card.board != .done {
                if card.assignee.isEmpty {
                    Button("Take It") { perform("claim_task") }
                } else if card.assignee == "You" {
                    Button("Let Go") { perform("release_task") }
                }
            }
            Section("Move to") {
                ForEach(BoardColumn.allCases.filter { $0 != card.board }, id: \.self) { column in
                    Button(column.title) { perform("update_task", to: column) }
                }
            }
            if card.board != .done, card.meantFor != nil, let agents, !agents.agents.isEmpty {
                Section(agents.paused ? "Give to (agents are paused)" : "Give to") {
                    ForEach(agents.agents, id: \.self) { agent in
                        Button(agent.name) { give(to: agent) }.disabled(agents.paused)
                    }
                    if card.meantFor?.isEmpty == false { Button("No One in Particular") { give(to: nil) } }
                }
            }
            // On a board shared through a team database (lane DB2): teammates' agents that take its cards, with their
            // owners. Their owners' Macs start them; the first time, this iPhone asks.
            if card.board != .done, let teammates = agents?.teammates.filter({ ($0.binders ?? []).contains(card.binder) }), !teammates.isEmpty {
                Section("Teammates' Agents") {
                    ForEach(teammates, id: \.self) { agent in
                        Button(agent.name) { give(to: agent) }
                    }
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .disabled(!connection.isConnected)
        .accessibilityLabel("Card actions")
    }

    /// The box to answer or comment in. It floats over the card: from iOS 26 a glass capsule of its own, before that on
    /// the bar material across the foot of the screen.
    @ViewBuilder
    private var composer: some View {
        if #available(iOS 26.0, *) {
            composerRow(field: nil)
                .padding(.leading, 16)
                .padding(.trailing, 6)
                .padding(.vertical, 6)
                .floatingGlass(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                .padding(.horizontal)
                .padding(.bottom, 8)
        } else {
            composerRow(field: Palette.surface)
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(.bar)
        }
    }

    private func composerRow(field: Color?) -> some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField(card?.question.map { "Answer \($0.who)" } ?? card?.approval.map { "Or tell \($0.who) what to change" } ?? "Add a comment",
                      text: $reply, axis: .vertical)
                .lineLimit(1...5)
                .focused($replying)
                .padding(.horizontal, field == nil ? 0 : 12)
                .padding(.vertical, 8)
                .background { if let field { RoundedRectangle(cornerRadius: 18, style: .continuous).fill(field) } }
            if sending {
                ProgressView().padding(.bottom, 6)
            } else {
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill").font(.title)
                }
                .disabled(reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !connection.isConnected)
                .accessibilityLabel(card?.question != nil ? "Send answer" : "Send comment")
            }
        }
    }

    /// The column's badge: amber where it waits on you, green once done, and while worked on muted grey on a binder's
    /// pages (words, not something to tap, as the Mac's), the accent's words elsewhere.
    private func tint(_ column: BoardColumn) -> Color {
        switch column {
        case .blocked, .review: Palette.needsYou
        case .inProgress: ownTint == nil ? Palette.accentText : Palette.muted
        case .done: Palette.done
        default: Palette.muted
        }
    }

    // MARK: Data

    /// Give to: meant for the agent, as you, then into Ready if it was in Backlog, where your Mac hands it over. The first
    /// time for each agent as it's set up now, you're told what that means and asked.
    private func give(to agent: AgentList.Agent?) {
        if let agent, !AgentConsents.agreed(agent) {
            awaiting = .give
            consenting = agent
            return
        }
        handOff(to: agent)
    }

    /// With the Mac out of reach, it's kept, and goes once the Mac is back (MacConnection.give).
    private func handOff(to agent: AgentList.Agent?) {
        Haptics.shared.tap()
        let fromBacklog = card?.board == .backlog
        Task {
            switch await connection.give(card: id, title: card?.title ?? "", to: agent?.name, fromBacklog: fromBacklog, trying: connection.isConnected) {
            case .sent: await load()
            case .kept: problem = MomentCenter.keptForMac
            case .refused(let message): problem = message
            }
        }
    }

    /// The agent `name` is, when it's one your Mac hands cards to and you haven't said yes to it as it's set up now.
    private func waitsForYes(_ name: String?) -> AgentList.Agent? {
        guard let name, let agent = AgentConsents.agent(named: name, connection: connection), !AgentConsents.agreed(agent) else { return nil }
        return agent
    }

    private func load() async {
        if agents == nil { agents = connection.cached("agents", as: AgentList.self) }
        async let agentList = connection.fetch("list_agents", cache: "agents", as: AgentList.self)
        if card == nil { card = connection.cached("task-\(id)", as: CardDetail.self) }
        let result = await connection.fetch("get_task", ["id": id], cache: "task-\(id)", as: CardDetail.self)
        if let value = result.value { card = value }
        unreached = card == nil
        if let list = await agentList.value { agents = list }
        offerHeldAnswer()
        // For development, as the Simulator can't be typed into from a script: `-reply "…"` sends that, once, when connected.
        if !Self.repliedForDevelopment, result.fresh, let text = UserDefaults.standard.string(forKey: "reply"), !text.isEmpty {
            Self.repliedForDevelopment = true
            reply = text
            send()
        }
    }

    private static var repliedForDevelopment = false

    /// Take, let go, approve, send back or move the card: it changes at once, by the Mac's own rules, and the Mac's change
    /// notification brings its copy. If the Mac says no, it goes back, unless something newer came in, and a toast says why.
    private func perform(_ tool: String, to column: BoardColumn? = nil) {
        // Sent back from Review to the agent that did it: your words and the card go back to it, so it asks first too.
        if tool == "update_task", column == .inProgress, card?.board == .review, card?.assigneeIsAgent == true, let agent = waitsForYes(card?.assignee) {
            awaiting = .move(tool: tool, column: column)
            return consenting = agent
        }
        if column == .ready || tool == "release_task" {
            switch handOffCheck(meantFor: card?.meantFor, confirmed: card?.meantForConfirmed, connection: connection) {
            case .ask(let agent):
                awaiting = .move(tool: tool, column: column)
                return consenting = agent
            case .unknown:
                Task {
                    _ = await connection.fetch("list_agents", cache: "agents", as: AgentList.self).value
                    if connection.cached("agents", as: AgentList.self) != nil { perform(tool, to: column) } else { problem = "Couldn't check who the card would go to. Try again in a moment." }
                }
                return
            case .fine: break
            }
        }
        guard connection.isConnected else { return problem = "\(connection.brainName ?? "\(MacConnection.BrainWords)") is out of reach. Try again when it's back." }
        // Approved, from Review to Done: success by touch. Any other move, a tap.
        if tool == "update_task", column == .done, card?.board == .review { Haptics.shared.success() } else { Haptics.shared.tap() }
        let before = card
        if let next = card?.after(tool, to: column) { card = next }
        let shown = card
        var arguments: [String: Any] = ["id": id]
        if let column { arguments["column"] = column.rawValue }
        Task {
            do {
                _ = try await connection.call(tool, arguments)
            } catch {
                if card == shown { card = before }
                problem = error.localizedDescription
            }
        }
    }

    private func send() {
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending else { return }
        // Answering an agent's question sends your words to it: the first time for that agent, it asks. So does saying
        // what to change about what it asks your approval for.
        if let question = card?.question, question.agent, let agent = waitsForYes(question.who) {
            awaiting = .answer(text)
            return consenting = agent
        }
        if let approval = card?.approval, let agent = waitsForYes(approval.who) {
            awaiting = .answer(text)
            return consenting = agent
        }
        // So does a comment on a card an agent holds in Blocked with no question waiting, as when its run stopped: the Mac
        // takes it as the answer, which sends the card back to that agent.
        if card?.board == .blocked, card?.assigneeIsAgent == true, let agent = waitsForYes(card?.assignee) {
            awaiting = .answer(text)
            return consenting = agent
        }
        // And, on a Mac that wakes the agent working on a card when you comment, a comment on a card an agent holds in
        // progress: it goes to that agent, so it asks first, and names the agent it asked about.
        if let holder = commentGoesTo {
            guard AgentConsents.agents(connection) != nil else {
                Task {
                    _ = await connection.fetch("list_agents", cache: "agents", as: AgentList.self).value
                    if AgentConsents.agents(connection) != nil { send() } else { problem = "Couldn't check who your comment would go to. Try again in a moment." }
                }
                return
            }
            if let agent = waitsForYes(holder) {
                awaiting = .comment(text, to: agent.name)
                return consenting = agent
            }
            return send(text, to: AgentConsents.agent(named: holder, connection: connection) != nil ? holder : nil)
        }
        send(text)
    }

    /// The agent a comment here would reach: on a Mac that wakes on comments (`LinkFeatures.commentWakes`), the agent that
    /// holds this card in progress. Nil anywhere else, where a comment wakes no one.
    private var commentGoesTo: String? {
        guard connection.macFeatures.contains(LinkFeatures.commentWakes), let card, card.board == .inProgress, card.assigneeIsAgent,
              !card.assignee.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return card.assignee
    }

    /// Approve or decline what an agent asks: your answer goes to it, so the first time for that agent, it asks.
    private func decide(approve: Bool, reason: String = "") {
        guard let approval = card?.approval else { return }
        if let agent = waitsForYes(approval.who) {
            awaiting = .decide(approval: approval.id, approve: approve, reason: reason)
            return consenting = agent
        }
        sendDecision(approval: approval.id, approve: approve, reason: reason)
    }

    /// The decision, to the Mac, for the request shown: one replaced since is refused there, and a toast says so.
    private func sendDecision(approval: String, approve: Bool, reason: String) {
        guard !deciding else { return }
        deciding = true
        Task {
            defer { deciding = false }
            let result = await BoardQuestions.send(AgentApproval.Decision(card: id, approval: approval, approve: approve, reason: reason), over: connection)
            if let problem = result.problem {
                self.problem = problem
            } else {
                // Approved: success by touch. Declined, a tap.
                if approve { Haptics.shared.success() } else { Haptics.shared.tap() }
                declineReason = ""
                await load()
            }
        }
    }

    /// Your words to the Mac. `to`: the agent you said yes to for a comment, which the Mac wakes only while it holds the card.
    private func send(_ text: String, to holder: String? = nil) {
        guard !sending else { return }
        sending = true
        var arguments: [String: Any] = ["id": id, "text": text]
        if let holder { arguments["to"] = holder }
        Task {
            defer { sending = false }
            do {
                _ = try await connection.call("comment_task", arguments)
                reply = ""
                replying = false
                AgentConsents.release(card: id)
                await load()
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    /// An answer typed into the question's notification before you'd said yes to its agent: it's in the box, and the card
    /// asks once. Yes sends it as the notification would have; to someone you've said yes to since, it just goes.
    private func offerHeldAnswer() {
        guard !offeredHeld, let held = AgentConsents.held(card: id) else { return }
        offeredHeld = true
        if reply.isEmpty { reply = held.text }
        if let agent = waitsForYes(held.agent) {
            awaiting = .held(held)
            consenting = agent
        } else if agents != nil {
            sendHeld(held)
        }
    }

    private func sendHeld(_ held: AgentConsents.HeldAnswer) {
        Task {
            sending = true
            defer { sending = false }
            let result = await connection.answer(card: id, question: held.asked, text: held.text)
            AgentConsents.release(card: id)
            switch result {
            case .sent:
                reply = ""
                await load()
            case .kept:
                reply = ""
                problem = "Your answer waits on this iPhone. It goes to \(connection.brainName ?? "\(MacConnection.brainWords)") the next time Binders reaches it."
            case .refused:
                problem = "Its question isn't waiting any more, so your answer didn't go. It's still in the box."
            }
        }
    }

    /// What waits for your yes to an agent, and how the question and the button say it.
    fileprivate enum Awaiting {
        case give
        case move(tool: String, column: BoardColumn?)
        case answer(String)
        /// A comment on a card the agent holds in progress, and the agent it goes to.
        case comment(String, to: String)
        case held(AgentConsents.HeldAnswer)
        /// Approve or decline what it asks: the request's id, which, and why not.
        case decide(approval: String, approve: Bool, reason: String)

        func question(for name: String) -> String {
            switch self {
            case .give: "Give cards to \(name)?"
            case .move(_, let column): column == .inProgress ? "Send it back to \(name)?" : "Give cards to \(name)?"
            case .answer, .held: "Send your answer to \(name)?"
            case .comment: "Send your comment to \(name)?"
            case .decide(_, let approve, _): approve ? "Send your approval to \(name)?" : "Send your decline to \(name)?"
            }
        }

        func yes(for name: String) -> String {
            switch self {
            case .give: "Give to \(name)"
            case .move(_, let column): column == .inProgress ? "Send Back to \(name)" : "Give to \(name)"
            case .answer, .held, .comment: "Send to \(name)"
            case .decide(_, let approve, _): approve ? "Approve" : "Decline"
            }
        }
    }
}

/// One line of a card's story, as on the Mac.
struct CardEventRow: View {
    let event: CardEvent

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            // What happened before: muted. What waits on you now is in the boxes at the top.
            Image(systemName: symbol)
                .foregroundStyle(Palette.muted)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(event.who).font(.caption.weight(.semibold)).foregroundStyle(event.agent ? Palette.agent : Palette.ink)
                    // An agent did it: lavender, with the sparkle.
                    if event.agent { Image(systemName: "sparkles").font(.caption2).foregroundStyle(Palette.agent) }
                    Text(headline).font(.caption).foregroundStyle(Palette.muted)
                    Spacer(minLength: 0)
                    if let date = Date(iso: event.when) {
                        Text(date, format: .relative(presentation: .named)).font(.caption2.monospacedDigit()).foregroundStyle(Palette.faint)
                    }
                }
                if !event.text.isEmpty {
                    if event.kind == "context" {
                        // "From your binders": lines from your own notes, set apart from what was said on the card.
                        Text(event.text)
                            .font(.footnote)
                            .foregroundStyle(Palette.muted)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.ground))
                    } else {
                        Text(event.text)
                            .font(.callout)
                            .foregroundStyle(Palette.ink)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var column: String { BoardColumn(rawValue: event.to)?.title ?? "" }

    private var headline: String {
        switch event.kind {
        case "created": "added it\(column.isEmpty ? "" : " to \(column)")"
        case "moved": "moved it to \(column)"
        case "claimed": "picked it up"
        case "released": "let it go"
        case "lapsed": "went quiet"
        case "progress": "reported progress"
        case "question": "asked"
        case "answer": "answered"
        case "completed": column == "Done" ? "finished it" : "finished it, for review"
        case "edited": "edited it"
        case "assigned": "said who it's for"
        case "woke": "was woken"
        case "context": "found this in the binder"
        case "approval": "asks your approval"
        case "decision": "kept the receipt"
        default: "commented"
        }
    }

    private var symbol: String {
        switch event.kind {
        case "created": "plus.circle"
        case "moved": "arrow.right.circle"
        case "claimed": "hand.raised"
        case "released", "lapsed": "arrow.uturn.backward.circle"
        case "progress": "chart.line.uptrend.xyaxis"
        case "question": "questionmark.bubble"
        case "answer": "text.bubble"
        case "completed": "checkmark.circle"
        case "edited": "pencil"
        case "assigned": "person.crop.circle.badge.checkmark"
        case "woke": "bell"
        case "context": "books.vertical"
        case "approval": "checkmark.shield"
        case "decision": "signature"
        default: "bubble.left"
        }
    }
}

/// A card on its way to Ready, or back from Review, for an agent this iPhone hasn't said yes to yet, and how it was going.
struct PendingHandOff: Identifiable {
    let card: Card
    let agent: AgentList.Agent
    let tool: String
    let column: BoardColumn?
    var id: String { card.id }
    /// Back to the agent that did it, from Review.
    var sendsBack: Bool { column == .inProgress && card.board == .review }
}

/// Whether a card on its way to Ready may go: making it ready hands it to the agent it's meant for (by your choice), so
/// the first time for each agent this iPhone asks, as Give to does (App Store 5.1.2(i)). Names match as on the Mac.
enum HandOffCheck { case fine, ask(AgentList.Agent), unknown }

@MainActor
func handOffCheck(meantFor: String?, confirmed: Bool?, connection: MacConnection) -> HandOffCheck {
    guard let name = meantFor?.trimmingCharacters(in: .whitespaces), !name.isEmpty, confirmed == true else { return .fine }
    // A Mac from before agents (one that doesn't say what became of captures) hands nothing to anyone.
    guard connection.hasOutcomes else { return .fine }
    guard let list = connection.cached("agents", as: AgentList.self) else { return .unknown }
    // A teammate's agent too (lane DB2): its owner's Mac starts it.
    guard let agent = list.all.first(where: { $0.name.trimmingCharacters(in: .whitespaces).localizedCaseInsensitiveCompare(name) == .orderedSame })
    else { return .fine }
    return AgentConsents.agreed(agent) ? .fine : .ask(agent)
}
