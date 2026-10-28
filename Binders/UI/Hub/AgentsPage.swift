import SwiftData
import SwiftUI
import BindersKit

/// Sizes the Agents page keeps to.
enum AgentsLayout {
    /// The list of agents on the left.
    static let listWidth: CGFloat = 320
    /// How wide a conversation's lines run before they wrap, however wide the window.
    static let readingWidth: CGFloat = 720
    /// How many finished conversations show under an agent.
    static let earlier = 8
}

/// What's picked on the Agents page, as the scene keeps it: the Manager, an agent, or one of its conversations.
enum AgentsPick: Hashable {
    case manager
    /// One you set up, by its id.
    case agent(UUID)
    /// One working on your boards from its own session, by its name.
    case other(String)
    /// A conversation: a card meant for an agent or held by one.
    case card(UUID)
    /// A chat with an agent (lane AC1).
    case chat(UUID)

    init?(_ raw: String) {
        if raw == "manager" { self = .manager; return }
        let parts = raw.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        switch parts[0] {
        case "agent": guard let id = UUID(uuidString: parts[1]) else { return nil }; self = .agent(id)
        case "other": self = .other(parts[1])
        case "card": guard let id = UUID(uuidString: parts[1]) else { return nil }; self = .card(id)
        case "chat": guard let id = UUID(uuidString: parts[1]) else { return nil }; self = .chat(id)
        default: return nil
        }
    }

    var raw: String {
        switch self {
        case .manager: "manager"
        case .agent(let id): "agent:\(id.uuidString)"
        case .other(let name): "other:\(name)"
        case .card(let id): "card:\(id.uuidString)"
        case .chat(let id): "chat:\(id.uuidString)"
        }
    }
}

/// Agents, from the sidebar: every agent you have, and where you talk to each. On the left the Manager and your agents,
/// each saying what it's doing, and under the one you pick, its conversations: each a card meant for it, or one it holds.
/// On the right, what it holds and what's meant for it with a box to start a new conversation, or the conversation you
/// picked, as the card's own window has it. The Manager answers in its own conversation.
struct AgentsView: View {
    @Environment(HubNavigation.self) private var navigation
    @Environment(DictationController.self) private var controller
    @State private var registry = AgentRegistry.shared
    @Query(sort: \TaskCard.updatedAt, order: .reverse) private var cards: [TaskCard]
    /// What's picked. The hub's window isn't a SwiftUI scene, so the pick lives in its navigation.
    private var picked: String {
        get { navigation.agentsPick }
        nonmutating set { navigation.agentsPick = newValue }
    }

    /// An agent on the page: one you set up, or one working from its own session.
    struct Someone: Identifiable {
        var name: String
        var profile: AgentProfile?
        var id: String { profile.map { "agent:\($0.id.uuidString)" } ?? "other:\(name)" }
        var pick: AgentsPick { profile.map { .agent($0.id) } ?? .other(name) }
    }

    var body: some View {
        let people = someone()
        let pick = AgentsPick(picked) ?? defaultPick(people)
        let owner = owner(of: pick, among: people)
        HStack(spacing: 0) {
            list(people, pick: pick, owner: owner)
                .frame(width: AgentsLayout.listWidth)
            Divider()
            detail(pick, owner: owner)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .pageGround()
    }

    // MARK: Who's here

    private func someone() -> [Someone] {
        let registered = registry.agents.map(\.name)
        let open = cards.filter { $0.column != .done }
        let others = Set(open.filter { $0.assigneeIsAgent }.compactMap(\.assignee)
            .filter { name in !registered.contains { BoardRules.isNamed(name, as: $0) || BoardRules.isNamed($0, as: name) } }).sorted()
        // A local model is only ever the Manager, which has its own place at the top.
        let talkable = registry.agents.filter { if case .localModel = $0.wake { false } else { true } }
        return talkable.map { Someone(name: $0.name, profile: $0) } + others.map { Someone(name: $0, profile: nil) }
    }

    private func defaultPick(_ people: [Someone]) -> AgentsPick {
        if registry.manager != nil { return .manager }
        return people.first?.pick ?? .manager
    }

    /// The agent whose conversations show: the one picked, or the one a picked conversation is for.
    private func owner(of pick: AgentsPick, among people: [Someone]) -> Someone? {
        switch pick {
        case .manager: return nil
        case .agent(let id): return people.first { $0.profile?.id == id }
        case .other(let name): return people.first { $0.profile == nil && $0.name == name }
        case .card(let id):
            guard let card = cards.first(where: { $0.id == id }) else { return nil }
            return people.first { Self.isFor(card, $0.name) }
        case .chat(let id):
            guard let chat = controller.chats.chat(id) else { return nil }
            return people.first { BoardRules.isNamed(chat.agent, as: $0.name) || BoardRules.isNamed($0.name, as: chat.agent) }
        }
    }

    /// A card is a conversation with an agent when it holds it, or it's meant for it by you.
    static func isFor(_ card: TaskCard, _ name: String) -> Bool {
        if card.assigneeIsAgent, let holder = card.assignee, BoardRules.isNamed(holder, as: name) { return true }
        guard let meant = card.meantFor, !card.meantForByAgent else { return false }
        return BoardRules.isNamed(meant, as: name) || BoardRules.isNamed(name, as: meant)
    }

    private func conversations(_ name: String) -> (open: [TaskCard], earlier: [TaskCard]) {
        let all = cards.filter { Self.isFor($0, name) }
        return (all.filter { $0.column != .done }, Array(all.filter { $0.column == .done }.prefix(AgentsLayout.earlier)))
    }

    // MARK: The list

    /// The conversations the list shows, by binder: every card an agent holds or is meant for that isn't done, and those
    /// done in the last day.
    private func threads(_ people: [Someone]) -> [(binder: BinderRecord?, cards: [TaskCard])] {
        let since = Date().addingTimeInterval(-86_400)
        let all = cards.filter { card in
            (card.column != .done || card.updatedAt > since) && people.contains { Self.isFor(card, $0.name) }
        }
        let grouped = Dictionary(grouping: all) { $0.binderID }
        return grouped.map { (Store.shared.binder($0.key), $0.value.sorted { $0.updatedAt > $1.updatedAt }) }
            .sorted { ($0.cards.first?.updatedAt ?? .distantPast) > ($1.cards.first?.updatedAt ?? .distantPast) }
    }

    private func list(_ people: [Someone], pick: AgentsPick, owner: Someone?) -> some View {
        let groups = threads(people)
        let working = Set(cards.filter { controller.agents.isWorking(on: $0.id) }.compactMap(\.assignee)).count
        let chats = people.filter(Self.chats).flatMap { controller.chats.chats(with: $0.name) }
            .sorted { $0.updatedAt > $1.updatedAt }.prefix(AgentsLayout.earlier)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Agents").font(BindersTheme.title(24)).fitProbe("agents.header")
                if working > 0 { Text("\(working) working").font(.callout).foregroundStyle(BindersTheme.muted) }
                Spacer()
                Menu {
                    ForEach(people.filter(Self.chats)) { person in
                        Button("New Chat with \(person.name)") { picked = person.pick.raw }
                    }
                    Divider()
                    Toggle("Pause All Agents", isOn: Binding(get: { registry.paused }, set: { registry.setPaused($0) }))
                    Button("Agent Settings…") {
                        navigation.pendingSettingsPage = .agents
                        navigation.selection = .settings
                    }
                } label: {
                    Image(systemName: "plus").font(.system(size: 12, weight: .semibold))
                        .frame(width: 26, height: 26)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(BindersTheme.surface2))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Start a chat, pause agents, or set them up")
            }
            .padding(.horizontal, 18)
            .padding(.top, 20)
            .padding(.bottom, 12)
            if registry.paused {
                StatusLabel("Agents are paused", .waiting).font(.caption).padding(.horizontal, 18).padding(.bottom, 8)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    managerRow(selected: pick == .manager)
                    ForEach(groups, id: \.binder?.id) { group in
                        groupHeading(group.binder?.name ?? "No binder", color: group.binder.map { BinderPalette.color($0.colorIndex) })
                        ForEach(group.cards) { card in threadRow(card, people: people, selected: pick == .card(card.id)) }
                    }
                    if !chats.isEmpty {
                        groupHeading("Chats", color: nil)
                        ForEach(Array(chats)) { chat in chatRow(chat, people: people, selected: pick == .chat(chat.id)) }
                    }
                    if !people.isEmpty {
                        groupHeading("Your agents", color: nil)
                        ForEach(people) { person in agentRow(person, selected: pick == person.pick) }
                    } else {
                        Text("No agents yet. Set one up in Settings → Agents: Claude Code or a coding tool in a repository, a script, a web hook, or one that checks the board itself.")
                            .font(.callout).foregroundStyle(.secondary)
                            .padding(10)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 16)
            }
        }
        .background(BindersTheme.ground)
    }

    private func groupHeading(_ name: String, color: Color?) -> some View {
        HStack(spacing: 7) {
            if let color { Circle().fill(color).frame(width: 6, height: 6) }
            Text(name).font(.system(size: 12, weight: .medium)).foregroundStyle(BindersTheme.faint).lineLimit(1)
        }
        .padding(.leading, 10).padding(.top, 16).padding(.bottom, 4)
    }

    private func rowBackground(_ selected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous).fill(selected ? BindersTheme.selection : Color.clear)
    }

    /// A conversation: its agent's avatar with what it's doing, the card's title, a line of its state and when.
    private func threadRow(_ card: TaskCard, people: [Someone], selected: Bool) -> some View {
        let person = people.first { Self.isFor(card, $0.name) }
        let name = card.assignee ?? card.meantFor ?? person?.name ?? ""
        let working = controller.agents.isWorking(on: card.id)
        let needs = BoardDesign.needsYou(card.column)
        let state: (words: String, color: Color) = working ? (AgentDoingFeed.shared.lines[card.id] ?? "Working", BindersTheme.muted)
            : needs ? (card.column == .review ? "Ready to check" : "Waiting for you", BindersTheme.needsYou)
            : card.column == .done ? ("Done", BindersTheme.faint) : (card.column.title, BindersTheme.muted)
        return Button { picked = AgentsPick.card(card.id).raw } label: {
            HStack(spacing: 11) {
                AgentAvatar(name: name, profile: person?.profile, size: 30,
                            activity: working ? .working : needs ? .needsYou : card.column == .done ? .off : .idle)
                VStack(alignment: .leading, spacing: 2) {
                    Text(card.title.isEmpty ? "Untitled" : card.title).font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(card.column == .done ? BindersTheme.muted : BindersTheme.ink).lineLimit(1)
                    Text(state.words).font(.system(size: 12)).foregroundStyle(state.color).lineLimit(1)
                }
                Spacer(minLength: 4)
                Text(card.updatedAt, format: .relative(presentation: .numeric, unitsStyle: .narrow))
                    .font(BindersTheme.time(.caption)).foregroundStyle(BindersTheme.faint)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(rowBackground(selected))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(card.title), \(name), \(state.words)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func chatRow(_ chat: AgentChat, people: [Someone], selected: Bool) -> some View {
        let person = people.first { BoardRules.isNamed(chat.agent, as: $0.name) || BoardRules.isNamed($0.name, as: chat.agent) }
        let running = chat.status == .running
        return Button { picked = AgentsPick.chat(chat.id).raw } label: {
            HStack(spacing: 11) {
                AgentAvatar(name: chat.agent, profile: person?.profile, size: 30, activity: running ? .working : chat.status == .waiting ? .needsYou : nil)
                VStack(alignment: .leading, spacing: 2) {
                    Text(chat.title).font(.system(size: 13.5, weight: .medium)).foregroundStyle(BindersTheme.ink).lineLimit(1)
                    Text(running ? "Answering" : chat.status == .waiting ? "Waiting for it to check" : chat.agent)
                        .font(.system(size: 12)).foregroundStyle(BindersTheme.muted).lineLimit(1)
                }
                Spacer(minLength: 4)
                Text(chat.updatedAt, format: .relative(presentation: .numeric, unitsStyle: .narrow))
                    .font(BindersTheme.time(.caption)).foregroundStyle(BindersTheme.faint)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(rowBackground(selected))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Chat: \(chat.title), with \(chat.agent)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func managerRow(selected: Bool) -> some View {
        let manager = controller.manager
        let running = manager.runningID != nil
        let waiting = manager.waitingSuggestions.count
        return Button { picked = AgentsPick.manager.raw } label: {
            HStack(spacing: 11) {
                AgentAvatar(name: "Manager", kind: .manager, size: 30, activity: running ? .working : waiting > 0 ? .needsYou : nil)
                VStack(alignment: .leading, spacing: 2) {
                    Text("The Manager").font(.system(size: 13.5, weight: .medium)).foregroundStyle(BindersTheme.ink)
                    Group {
                        if let agent = manager.agent {
                            if running {
                                Text("On it").foregroundStyle(BindersTheme.muted)
                            } else if waiting > 0 {
                                Text(waiting == 1 ? "1 edit to review" : "\(waiting) edits to review").foregroundStyle(BindersTheme.needsYou)
                            } else {
                                Text(ManagerSettingsSection.kindWords(agent).map { "\(agent.name) · \($0)" } ?? agent.name).foregroundStyle(BindersTheme.muted)
                            }
                        } else {
                            Text("Not set up").foregroundStyle(BindersTheme.muted)
                        }
                    }
                    .font(.system(size: 12)).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(rowBackground(selected))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func agentRow(_ person: Someone, selected: Bool) -> some View {
        let state = status(person)
        let activity: AgentAvatar.Activity = state.tone == .live ? .working : state.tone == .needsYou ? .needsYou
            : state.words == "Off" ? .off : .idle
        return Button { picked = person.pick.raw } label: {
            HStack(spacing: 11) {
                AgentAvatar(name: person.name, profile: person.profile, size: 26, activity: activity)
                VStack(alignment: .leading, spacing: 1) {
                    Text(person.name).font(.system(size: 13, weight: .medium)).foregroundStyle(BindersTheme.ink).lineLimit(1)
                    Text(state.words).font(.system(size: 11.5)).foregroundStyle(state.tone == .needsYou ? BindersTheme.needsYou : BindersTheme.muted).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(rowBackground(selected))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// What it's doing, in a few words, and how to show them: working, needs you, off, or plainly idle.
    private func status(_ person: Someone) -> (words: String, tone: StatusLabel.Tone?) {
        if let agent = person.profile {
            if registry.changedOutside.contains(agent.id) { return ("Changed outside Binders", .needsYou) }
            if let why = registry.held[agent.id] { return (why, .problem) }
            if !agent.isEnabled { return ("Off", .waiting) }
        }
        let open = conversations(person.name).open
        if let chat = controller.chats.chats(with: person.name).first(where: { $0.status == .running }) { return ("Answering “\(chat.title)”", .live) }
        if let working = open.first(where: { controller.agents.isWorking(on: $0.id) }) { return ("Working on “\(working.title)”", .live) }
        let needs = open.filter { BoardDesign.needsYou($0.column) }.count
        if needs > 0 { return (needs == 1 ? "1 card needs you" : "\(needs) cards need you", .needsYou) }
        if registry.paused { return ("Paused", .waiting) }
        if open.isEmpty { return ("Idle", nil) }
        return (open.count == 1 ? "1 open conversation" : "\(open.count) open conversations", nil)
    }

    /// Whether it chats (lane AC1): Claude Code, or one that checks the board itself.
    static func chats(_ person: Someone) -> Bool { person.profile.map { AgentChatReach.chats($0.wake.kind) } ?? false }

    // MARK: The right side

    @ViewBuilder
    private func detail(_ pick: AgentsPick, owner: Someone?) -> some View {
        switch pick {
        case .manager:
            ManagerChat()
        case .card(let id):
            if let card = cards.first(where: { $0.id == id }) {
                AgentConversation(card: card, agent: owner?.name) { picked = (owner?.pick ?? .manager).raw }
                    .id(card.id)
            } else {
                gone
            }
        case .agent, .other:
            if let owner, Self.chats(owner) {
                // One that chats: a new chat with it, its cards beside it in the list.
                AgentChatPanel(agent: owner.name, chatID: nil) { chat in picked = (chat.map(AgentsPick.chat) ?? owner.pick).raw }
                    .id("new-" + owner.id)
            } else if let owner {
                AgentOverview(person: owner, open: conversations(owner.name).open) { card in picked = AgentsPick.card(card.id).raw }
                    .id(owner.id)
            } else {
                gone
            }
        case .chat(let id):
            if let chat = controller.chats.chat(id) {
                AgentChatPanel(agent: chat.agent, chatID: id) { next in picked = (next.map(AgentsPick.chat) ?? owner?.pick ?? .manager).raw }
                    .id(id)
            } else {
                gone
            }
        }
    }

    private var gone: some View {
        VStack(spacing: 8) {
            Text("It isn't here any more.").foregroundStyle(.secondary)
            Button("Show the Manager") { picked = AgentsPick.manager.raw }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One agent, picked on the Agents page: how it's woken and what it's doing, what it holds and what's meant for it (each
/// opens its conversation), and a box to start a new conversation, which becomes a card meant for it, in Ready, and wakes it.
struct AgentOverview: View {
    @Environment(HubNavigation.self) private var navigation
    @Environment(DictationController.self) private var controller
    @State private var registry = AgentRegistry.shared
    let person: AgentsView.Someone
    let open: [TaskCard]
    let show: (TaskCard) -> Void
    @State private var message = ""
    @State private var binderID: UUID?
    @State private var problem: String?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    work
                }
                .frame(maxWidth: AgentsLayout.readingWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(20)
            }
            Divider()
            composer
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(person.name).font(BindersTheme.title(24)).lineLimit(1)
                Text(person.profile.map { AgentsSections.describe($0.wake) } ?? "Works on your boards from its own session")
                    .font(.callout).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            if person.profile != nil {
                Button("Settings…") {
                    navigation.pendingSettingsPage = .agents
                    navigation.selection = .settings
                }
            }
        }
    }

    private var work: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Its work").font(BindersTheme.cardTitle)
            if open.isEmpty {
                Text("Nothing for it right now. Write to it below to start a conversation: it goes on a board as a card meant for it, and its replies come back here.")
                    .foregroundStyle(.secondary)
            }
            ForEach(open) { card in
                Button { show(card) } label: {
                    HStack(alignment: .firstTextBaseline) {
                        Text(card.title).lineLimit(1)
                        Spacer()
                        note(card)
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if card.id != open.last?.id { Divider() }
            }
        }
        .paperCard(padding: 16)
    }

    /// How its last wake went, or where the card is: one that failed in the problem style.
    @ViewBuilder
    private func note(_ card: TaskCard) -> some View {
        if let outcome = controller.agents.outcomes[card.id], !outcome.ok {
            StatusLabel(outcome.message, .problem).font(.caption).lineLimit(1)
        } else if controller.agents.isWorking(on: card.id) {
            StatusLabel("Working on it", .live).font(.caption)
        } else {
            let holds = card.assigneeIsAgent && card.assignee.map { BoardRules.isNamed($0, as: person.name) } == true
            Text(controller.agents.outcomes[card.id]?.message ?? (holds ? card.column.title : "Meant for it, \(card.column.title)"))
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    /// The binders whose cards it takes, for where a new conversation goes.
    private var binders: [BinderRecord] {
        let all = Store.shared.binders()
        guard let agent = person.profile else { return all }
        return all.filter { agent.takesCards(from: $0.id) }
    }

    private var composer: some View {
        let choices = binders
        let chosen = binderID.flatMap { id in choices.first { $0.id == id } } ?? choices.first { $0.id == navigation.binderID } ?? choices.first
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Message \(person.name)", text: $message, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...8)
                    .onSubmit { send(to: chosen) }
                    .fitProbe("agents.message")
                if choices.count > 1 {
                    Picker("Board", selection: Binding(get: { chosen?.id }, set: { binderID = $0 })) {
                        ForEach(choices) { binder in Text(binder.name).tag(UUID?.some(binder.id)) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .help("The board the conversation's card goes on")
                }
                Button("Send") { send(to: chosen) }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || chosen == nil)
            }
            if let problem {
                StatusLabel(problem, .problem).font(.callout)
            } else if chosen == nil {
                StatusLabel("It takes cards from none of your binders. Choose its binders in Settings → Agents.", .waiting).font(.callout)
            } else {
                Text("Starts a conversation: a card meant for \(person.name) on the \(chosen?.name ?? "") board, in Ready, and "
                     + (person.profile.map { $0.wake == .board } ?? true ? "it picks it up there." : "Binders hands it over."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: AgentsLayout.readingWidth, alignment: .leading)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private func send(to binder: BinderRecord?) {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let binder else { return }
        problem = nil
        let parts = AgentNote.card(from: text)
        let card = controller.board.create(title: parts.title, details: parts.details, binderID: binder.id, column: .backlog, by: .you)
        let handed = controller.board.give(card, to: person.name, by: .you)
        message = ""
        // One that checks the board itself picks it up there: Binders wakes nothing for it.
        let checksItself = person.profile.map { $0.wake == .board } ?? true
        if case .notWoken(let why) = handed, !checksItself {
            // Stay here, where it says so; the card waits among its work.
            problem = "The card is on the \(binder.name) board, meant for \(person.name), but it wasn't handed over: \(why)"
            return
        }
        show(card)
    }
}


/// One conversation with an agent, on the Agents page: the card's conversation as its own window shows it, with what waits
/// on you and the composer, under a line that names the card, its board and where it is, and opens it in its window.
struct AgentConversation: View {
    @Environment(HubNavigation.self) private var navigation
    @Environment(DictationController.self) private var controller
    @Bindable var card: TaskCard
    let agent: String?
    let back: () -> Void
    @Query private var events: [TaskEvent]
    @State private var registry = AgentRegistry.shared
    @State private var draft: String
    @State private var problem: String?
    @State private var editingContext: TaskEvent?
    /// The run its latest wake started, read live (lane LS1).
    @State private var session: AgentSessionWatch?

    init(card: TaskCard, agent: String?, back: @escaping () -> Void) {
        self.card = card
        self.agent = agent
        self.back = back
        let id = card.id
        _events = Query(filter: #Predicate<TaskEvent> { $0.taskID == id }, sort: [SortDescriptor(\TaskEvent.createdAt)])
        _draft = State(initialValue: CardWindows.shared.draft(for: card.id))
    }

    var body: some View {
        let binder = Store.shared.binder(card.binderID)
        let working = controller.agents.isWorking(on: card.id)
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 7) {
                            Circle().fill(BinderPalette.color(binder?.colorIndex ?? 0)).frame(width: 6, height: 6)
                            Text(headline(binder: binder, working: working)).font(.callout).foregroundStyle(BindersTheme.muted).lineLimit(1)
                        }
                        Text(card.title.isEmpty ? "Untitled" : card.title).font(BindersTheme.title(26)).lineLimit(2)
                    }
                    Spacer()
                    HStack(spacing: 8) {
                        Button("Open Card") { navigation.open(card: card) }
                            .buttonStyle(.soft)
                            .fitProbe("agents.conversation.header")
                            .help("Open the card in its own window, with its details")
                        if working {
                            Button("Stop") { controller.agents.stop(card.id) }
                                .buttonStyle(.soft)
                                .help("Stop this run. Your next message starts it again, carrying on its session.")
                        }
                    }
                }
                if let session, !session.plan.isEmpty { AgentPlanBar(items: session.plan) }
            }
            .padding(.horizontal, 28)
            .padding(.top, 20)
            .padding(.bottom, 14)
            .accessibilityElement(children: .contain)
            Divider().opacity(0.6)
            CardConversationColumn(card: card, events: events, registry: registry, draft: $draft, problem: $problem,
                                   editingContext: $editingContext, close: back, compactApproval: false, detailsOver: nil)
                .environment(\.agentSession, session)
        }
        .onAppear { watchRun() }
        .onChange(of: events.count) { watchRun() }
        .onDisappear { session?.stop() }
        .binderTint(Store.shared.binder(card.binderID)?.colorIndex)
        .onChange(of: draft) { CardWindows.shared.setDraft(draft, for: card.id) }
        .alert("Couldn't do that", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(problem ?? "") }
        .sheet(item: $editingContext) { event in ContextEditor(event: event).environment(controller) }
        .followingAgentDoing()
    }

    /// "Binders · Claude Code · working for 14 min".
    private func headline(binder: BinderRecord?, working: Bool) -> String {
        var parts = [binder?.name, agent].compactMap { $0 }
        if working, let started = session?.startedAt {
            parts.append("working for \(max(1, Int(Date().timeIntervalSince(started) / 60))) min")
        } else {
            parts.append(card.column.title)
        }
        return parts.joined(separator: " · ")
    }

    /// Follows the run of the latest wake, a newer one once it starts.
    private func watchRun() {
        guard let run = AgentSessionWatch.run(of: card, timeline: events) else { return }
        guard session?.log != run.log else { return }
        session?.stop()
        let watch = AgentSessionWatch(log: run.log, tool: run.tool)
        watch.start()
        session = watch
    }
}
