import SwiftData
import SwiftUI
import BindersKit

/// Sizes the Agents page keeps to.
enum AgentsLayout {
    /// The list of agents on the left; narrower in a narrow window, so the terminal keeps its room.
    static let listWidth: CGFloat = 264
    static let narrowListWidth: CGFloat = 216
    /// Under this much across, the list is the narrower one.
    static let narrowPage: CGFloat = 780
    /// How wide a conversation's lines run before they wrap, however wide the window.
    static let readingWidth: CGFloat = 720
}

/// What's picked on the Agents page, as the scene keeps it: the Manager, an agent, or one of its sessions (a card it works
/// on, a chat with it), which shows that agent with that session open.
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

/// Agents, from the sidebar: the Manager and each of your agents, one row each with what it's doing, and on the right the one
/// you pick: the Manager's conversation, or an agent's workspace, its sessions as a terminal you can talk to it in
/// (`AgentWorkspace`). Cards stay on the board and in their own windows.
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
        GeometryReader { page in
            HStack(spacing: 0) {
                list(people, pick: pick, owner: owner)
                    .frame(width: page.size.width < AgentsLayout.narrowPage ? AgentsLayout.narrowListWidth : AgentsLayout.listWidth)
                Divider()
                detail(pick, owner: owner)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
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

    /// The agent whose workspace shows: the one picked, or the one a picked session is for.
    private func owner(of pick: AgentsPick, among people: [Someone]) -> Someone? {
        switch pick {
        case .manager: return nil
        case .agent(let id): return people.first { $0.profile?.id == id }
        case .other(let name): return people.first { $0.profile == nil && $0.name == name }
        case .card(let id):
            guard let card = cards.first(where: { $0.id == id }) else { return nil }
            if let found = people.first(where: { Self.isFor(card, $0.name) }) { return found }
            // Held by, or meant for, a name the list doesn't have: shown as one working from its own session.
            return (card.assignee ?? card.meantFor).map { Someone(name: $0, profile: registry.agent(named: $0)) }
        case .chat(let id):
            guard let chat = controller.chats.chat(id) else { return nil }
            return people.first { BoardRules.isNamed(chat.agent, as: $0.name) || BoardRules.isNamed($0.name, as: chat.agent) }
        }
    }

    /// A card is one of an agent's sessions when it holds it, or it's meant for it by you.
    static func isFor(_ card: TaskCard, _ name: String) -> Bool {
        if card.assigneeIsAgent, let holder = card.assignee, BoardRules.isNamed(holder, as: name) { return true }
        guard let meant = card.meantFor, !card.meantForByAgent else { return false }
        return BoardRules.isNamed(meant, as: name) || BoardRules.isNamed(name, as: meant)
    }

    // MARK: The list

    private func list(_ people: [Someone], pick: AgentsPick, owner: Someone?) -> some View {
        let working = people.filter { Self.status(of: $0, cards: cards, controller: controller, registry: registry).tone == .live }.count
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Agents").font(BindersTheme.title(24)).lineLimit(1).fixedSize().fitProbe("agents.header")
                if working > 0 {
                    // In a narrow list the count gives way rather than cut short.
                    ViewThatFits(in: .horizontal) {
                        Text("\(working) working").font(.callout).foregroundStyle(BindersTheme.muted).lineLimit(1).fixedSize()
                        Color.clear.frame(width: 0, height: 0)
                    }
                }
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
                    if !people.isEmpty {
                        Text("Your agents").font(.system(size: 12, weight: .medium)).foregroundStyle(BindersTheme.faint)
                            .padding(.leading, 10).padding(.top, 16).padding(.bottom, 4)
                        ForEach(people) { person in agentRow(person, selected: owner?.id == person.id && pick != .manager) }
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

    private func rowBackground(_ selected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous).fill(selected ? BindersTheme.selection : Color.clear)
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

    /// One agent: its avatar with what it's doing, its name, and that in a few words.
    private func agentRow(_ person: Someone, selected: Bool) -> some View {
        let state = Self.status(of: person, cards: cards, controller: controller, registry: registry)
        return Button { picked = person.pick.raw } label: {
            HStack(spacing: 11) {
                AgentAvatar(name: person.name, profile: person.profile, size: 30, activity: state.activity)
                VStack(alignment: .leading, spacing: 2) {
                    Text(person.name).font(.system(size: 13.5, weight: .medium)).foregroundStyle(BindersTheme.ink).lineLimit(1)
                    Text(state.words).font(.system(size: 12))
                        .foregroundStyle(state.tone == .needsYou ? BindersTheme.needsYou : state.tone == .problem ? BindersTheme.ink : BindersTheme.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(rowBackground(selected))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(person.name), \(state.words)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// What it's doing, in a few words, how to show them (working, needs you, a problem, off, or plainly idle), and its
    /// avatar's dot.
    @MainActor
    static func status(of person: Someone, cards: [TaskCard], controller: DictationController, registry: AgentRegistry)
        -> (words: String, tone: StatusLabel.Tone?, activity: AgentAvatar.Activity) {
        if let agent = person.profile {
            if registry.changedOutside.contains(agent.id) { return ("Changed outside Binders", .needsYou, .needsYou) }
            if let why = registry.held[agent.id] { return (why, .problem, .idle) }
            if !agent.isEnabled { return ("Off", .waiting, .off) }
        }
        let open = cards.filter { isFor($0, person.name) && $0.column != .done }
        if let chat = controller.chats.chats(with: person.name).first(where: { $0.status == .running }) { return ("Answering “\(chat.title)”", .live, .working) }
        if let working = open.first(where: { controller.agents.isWorking(on: $0.id) }) { return ("Working on “\(working.title)”", .live, .working) }
        let needs = open.filter { BoardDesign.needsYou($0.column) }.count
        if needs > 0 { return (needs == 1 ? "Needs you" : "\(needs) cards need you", .needsYou, .needsYou) }
        if registry.paused { return ("Paused", .waiting, .off) }
        if open.isEmpty { return ("Idle", nil, .idle) }
        return (open.count == 1 ? "1 open card" : "\(open.count) open cards", nil, .idle)
    }

    /// Whether it chats (lane AC1): Claude Code, or one that checks the board itself.
    static func chats(_ person: Someone) -> Bool { person.profile.map { AgentChatReach.chats($0.wake.kind) } ?? false }

    // MARK: The right side

    @ViewBuilder
    private func detail(_ pick: AgentsPick, owner: Someone?) -> some View {
        switch pick {
        case .manager:
            ManagerChat()
        case .agent, .other, .card, .chat:
            if let owner {
                AgentWorkspace(person: owner, sessions: AgentWorkSessions.of(owner.name, cards: cards, controller: controller), picked: session(of: pick),
                               cards: cards) { next in picked = next.raw }
                    .id(owner.id)
            } else {
                gone
            }
        }
    }

    /// The session a pick names.
    private func session(of pick: AgentsPick) -> AgentWorkSession.Kind? {
        switch pick {
        case .card(let id): .card(id)
        case .chat(let id): .chat(id)
        default: nil
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
