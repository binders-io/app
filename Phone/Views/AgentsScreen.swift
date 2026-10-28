import SwiftUI
import BindersKit

/// Where the Agents screen goes: the Manager's conversation, or one of your agents.
enum AgentsPlace: Hashable {
    case manager
    case agent(String)
}

/// Agents, as a tab of its own (lane MG3): the list, and the cards its conversations are.
struct AgentsTab: View {
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            AgentsList()
                .navigationDestination(for: CardLink.self) { CardDetailView(id: $0.id) }
        }
        .onAppear(perform: openForDevelopment)
    }

    /// For development, as the Simulator can't be tapped from a script: `-open manager` opens the Manager's conversation,
    /// and `-open agent -agent <name>` that agent.
    private func openForDevelopment() {
        guard path.isEmpty else { return }
        switch UserDefaults.standard.string(forKey: "open") {
        case "manager": path.append(AgentsPlace.manager)
        case "agent": if let name = UserDefaults.standard.string(forKey: "agent") { path.append(AgentsPlace.agent(name)) }
        default: break
        }
    }
}

/// Every agent you have, and where you talk to each, as the Mac's Agents page: the Manager at the top, then your agents,
/// each saying what it's doing. Pick one to see what it holds and what's meant for it, and to write to it.
struct AgentsList: View {
    @Environment(MacConnection.self) private var connection
    @State private var agents: AgentList?
    @State private var cards: [Card] = []
    @State private var feed: ManagerLink.Feed?
    /// Your chats, all agents', for who's answering one (lane AC1).
    @State private var chats: [ChatLink.Chat] = []
    @State private var unreached = false

    var body: some View {
        List {
            if hasManager {
                Section { NavigationLink(value: AgentsPlace.manager) { managerRow } }
                    .surfaceRows()
            }
            let yours = agents?.agents ?? []
            if !yours.isEmpty {
                Section("Your agents") {
                    ForEach(yours, id: \.name) { agent in
                        NavigationLink(value: AgentsPlace.agent(agent.name)) { row(agent) }
                    }
                }
                .surfaceRows()
            } else if agents != nil {
                Section {
                    Text("No agents yet. Set one up on your Mac, in Settings → Agents: Claude Code or a coding tool in a repository, a script, a web hook, or one that checks the board itself.")
                        .font(.callout).foregroundStyle(Palette.muted)
                }
                .surfaceRows()
            } else if unreached {
                WaitingForMac(what: "Your agents show here") { await load() }
                    .listRowBackground(Color.clear)
            } else {
                ProgressView().frame(maxWidth: .infinity).listRowBackground(Color.clear)
            }
        }
        .listGround()
        .navigationTitle("Agents")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { MacButton() } }
        .navigationDestination(for: AgentsPlace.self) { place in
            switch place {
            case .manager: ManagerChatView()
            case .agent(let name): AgentChatView(name: name)
            }
        }
        .task(id: connection.revision("tasks")) { await load() }
        .task(id: connection.revision("chats")) {
            if connection.macFeatures.contains(LinkFeatures.chats), let list = await ChatLink.list(agent: "", over: connection) { chats = list }
        }
        .task(id: connection.revision("manager")) {
            if feed == nil { feed = ManagerLink.cached(connection) }
            if let fresh = await ManagerLink.load(connection) { feed = fresh }
        }
        .refreshable {
            await load()
            if let fresh = await ManagerLink.load(connection) { feed = fresh }
        }
    }

    /// The Manager, from a Mac that has it.
    private var hasManager: Bool { connection.macFeatures.contains(LinkFeatures.manager) }

    private var managerRow: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "person.crop.circle.badge.checkmark").foregroundStyle(Palette.agent).font(.title3).frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text("The Manager").font(.headline).foregroundStyle(Palette.ink)
                if let feed {
                    let waiting = feed.waiting.count
                    if feed.running != nil {
                        AgentStatusText(words: "On it", tone: .working)
                    } else if waiting > 0 {
                        AgentStatusText(words: waiting == 1 ? "1 edit to review" : "\(waiting) edits to review", tone: .needsYou)
                    } else if let agent = feed.agent {
                        AgentStatusText(words: agent, tone: .plain)
                    } else {
                        AgentStatusText(words: "Not set up", tone: .plain)
                    }
                } else {
                    AgentStatusText(words: "Ask it what's on your plate, or to tidy a binder", tone: .plain)
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityIdentifier("agents.manager")
    }

    private func row(_ agent: AgentList.Agent) -> some View {
        let answering = chats.first { $0.status == "running" && $0.agent == agent.name }
        let status: (words: String, tone: AgentWork.Tone) = answering.map { (words: "Answering “\($0.title)”", tone: AgentWork.Tone.working) } ?? AgentWork.status(of: agent.name, in: cards, paused: agents?.paused == true)
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: "sparkles").foregroundStyle(Palette.agent).font(.title3).frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(agent.name).font(.headline).foregroundStyle(Palette.ink).lineLimit(1)
                AgentStatusText(words: status.words, tone: status.tone)
            }
        }
        .padding(.vertical, 4)
        .accessibilityIdentifier("agents.agent.\(agent.name)")
    }

    private func load() async {
        if agents == nil { agents = connection.cached("agents", as: AgentList.self) }
        if cards.isEmpty, let copy = connection.cached("tasks-all", as: [Card].self) { cards = copy }
        async let agentList = connection.fetch("list_agents", cache: "agents", as: AgentList.self)
        async let cardList = connection.fetch("list_tasks", cache: "tasks-all", as: [Card].self)
        if let fresh = await agentList.value { agents = fresh }
        if let fresh = await cardList.value { cards = fresh }
        unreached = agents == nil
        if connection.macFeatures.contains(LinkFeatures.chats), let list = await ChatLink.list(agent: "", over: connection) { chats = list }
    }
}

/// What an agent is doing, in a few words, and how they read: lavender while it works, amber where it waits on you.
enum AgentWork {
    enum Tone { case working, needsYou, plain }

    /// A card is a conversation with an agent when it holds it, or you meant it for it (not an agent's suggestion).
    static func isFor(_ card: Card, _ name: String) -> Bool {
        if card.assigneeIsAgent, BoardRules.isNamed(card.assignee, as: name) { return true }
        guard let meant = card.meantFor, !meant.isEmpty, card.meantForConfirmed == true else { return false }
        return BoardRules.isNamed(meant, as: name) || BoardRules.isNamed(name, as: meant)
    }

    static func status(of name: String, in cards: [Card], paused: Bool) -> (words: String, tone: Tone) {
        let open = cards.filter { $0.board != .done && isFor($0, name) }
        if let working = open.first(where: { $0.board == .inProgress && $0.assigneeIsAgent }) { return ("Working on “\(working.title)”", .working) }
        let needs = open.filter { $0.board == .blocked || $0.board == .review }.count
        if needs > 0 { return (needs == 1 ? "1 card needs you" : "\(needs) cards need you", .needsYou) }
        if paused { return ("Paused", .plain) }
        if open.isEmpty { return ("Idle", .plain) }
        return (open.count == 1 ? "1 open conversation" : "\(open.count) open conversations", .plain)
    }

    /// How the Mac wakes it, in words.
    static func kind(_ wakes: String) -> String {
        switch wakes {
        case "claudeCode": "Claude Code"
        case "cliAgent": "A coding tool"
        case "command": "A script on your Mac"
        case "webhook": "A web hook"
        case "shortcut": "A shortcut on your Mac"
        case "board": "Checks the board itself"
        default: "An agent"
        }
    }
}

struct AgentStatusText: View {
    let words: String
    let tone: AgentWork.Tone

    var body: some View {
        switch tone {
        case .working:
            Label(words, systemImage: "sparkles").labelStyle(StateLabelStyle()).font(.subheadline).foregroundStyle(Palette.agent).lineLimit(1)
        case .needsYou:
            Label(words, systemImage: "bell.fill").labelStyle(StateLabelStyle()).font(.subheadline).foregroundStyle(Palette.needsYou).lineLimit(1)
        case .plain:
            Text(words).font(.subheadline).foregroundStyle(Palette.muted).lineLimit(2)
        }
    }
}

// MARK: The Manager

/// The Manager's conversation (lane MG3), as the Mac's: what you asked on the right, its replies on the left, with Stop,
/// Undo and Reply, and the note edits it suggests, to accept or dismiss. What you ask goes to the Manager on your Mac.
struct ManagerChatView: View {
    @Environment(MacConnection.self) private var connection
    @State private var feed: ManagerLink.Feed?
    @State private var asking = ""
    /// The request whose conversation the next message goes on, when you chose Reply on one.
    @State private var replyingTo: ManagerLink.Request?
    /// This message's own id: sent again after a failure, it's the same request.
    @State private var messageID = UUID()
    @State private var sending = false
    @State private var acting: String?
    @State private var problem: String?
    @State private var said: String?
    @State private var reviewing: ManagerLink.Suggestion?
    @State private var binders: [BinderInfo] = []
    /// What waits for your yes to the Manager's agent: a question, or a tidy (and of which binder).
    @State private var consenting: AgentList.Agent?
    @State private var awaiting: (text: String, kind: String, binder: String?, agent: String)?
    @State private var unreached = false
    @FocusState private var typing: Bool

    var body: some View {
        ScrollViewReader { reader in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if let feed {
                        ForEach(feed.waiting) { suggestion in suggestionCard(suggestion) }
                        if feed.requests.isEmpty {
                            Text(feed.agent == nil
                                 ? "Give an agent the Manager's role on your Mac, in Settings → Agents: Claude Code, or a local model."
                                 : "Ask it what's on your plate, what an agent is doing, or to tidy a binder. It answers here, and every change it makes can be undone on your Mac or here.")
                                .font(.callout).foregroundStyle(Palette.muted)
                        }
                        ForEach(feed.conversation) { request in exchange(request).id(request.id) }
                    } else if unreached {
                        WaitingForMac(what: "The Manager's conversation shows here") { await load() }
                    } else {
                        ProgressView().frame(maxWidth: .infinity)
                    }
                }
                .padding()
            }
            .onAppear { if let last = feed?.conversation.last { reader.scrollTo(last.id, anchor: .bottom) } }
            .onChange(of: feed?.requests.first?.id) { _, last in
                if let last { withAnimation { reader.scrollTo(last, anchor: .bottom) } }
            }
            .onChange(of: feed?.requests.first?.reply) { _, _ in
                if let last = feed?.requests.first?.id { withAnimation { reader.scrollTo(last, anchor: .bottom) } }
            }
        }
        .screenGround()
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("The Manager")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Every Binder") { tidy(nil) }
                    if !binders.isEmpty { Divider() }
                    ForEach(binders) { binder in Button(binder.name) { tidy(binder.name) } }
                } label: {
                    Label("Tidy", systemImage: "wand.and.stars")
                }
                .disabled(feed?.agent == nil || feed?.problem != nil)
                .accessibilityIdentifier("manager.tidy")
            }
        }
        .safeAreaInset(edge: .bottom) { if feed != nil { composer } }
        .task(id: connection.revision("manager")) {
            if feed == nil { feed = ManagerLink.cached(connection) }
            await load()
        }
        .task { await loadBinders() }
        // Changed words are a new message: never the one an earlier send that didn't arrive was for.
        .onChange(of: asking) { _, _ in messageID = UUID() }
        .refreshable { await load() }
        .problemToast($problem)
        .sheet(item: $reviewing) { suggestion in
            SuggestionSheet(suggestion: suggestion, busy: acting == suggestion.id) { accept in
                decide(suggestion, accept: accept)
            }
        }
        // The first time what you ask goes to the Manager's agent, as set up now: where it goes, and what goes with it
        // (App Store 5.1.2(i)). A local model as the Manager stays on your Mac, and isn't asked about.
        .confirmationDialog(consenting.map { "Send this to \($0.name)?" } ?? "", isPresented: Binding(get: { consenting != nil }, set: { if !$0 { consenting = nil } }),
                            titleVisibility: .visible, presenting: consenting) { agent in
            Button("Send to \(agent.name)") {
                AgentConsents.agree(agent)
                if let waiting = awaiting { send(waiting.text, kind: waiting.kind, binder: waiting.binder, agent: waiting.agent) }
                awaiting = nil
            }
            Button("Cancel", role: .cancel) { awaiting = nil }
        } message: { agent in
            Text("It's your Manager. " + AgentConsents.disclosure(agent))
        }
    }

    // MARK: Parts

    private func exchange(_ request: ManagerLink.Request) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .trailing, spacing: 3) {
                Text(request.text)
                    .foregroundStyle(Palette.ink)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Palette.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                Text([request.date.map { $0.formatted(date: .abbreviated, time: .shortened) }, Self.from(request.from)].compactMap { $0 }.joined(separator: " · "))
                    .font(Typeface.time(.caption2)).foregroundStyle(Palette.muted)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.leading, 40)
            VStack(alignment: .leading, spacing: 8) {
                switch request.status {
                case "waiting": AgentStatusText(words: "Waiting for the Manager", tone: .plain)
                case "running":
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        AgentStatusText(words: "\(request.agent ?? "The Manager") is on it", tone: .working)
                    }
                case "failed": ProblemLabel(request.why ?? "It didn't finish.")
                case "stopped": Text(request.why ?? "Stopped.").font(.subheadline).foregroundStyle(Palette.muted)
                default: EmptyView()
                }
                if let reply = request.reply {
                    // The Manager's words: shown as its, never as yours.
                    VStack(alignment: .leading, spacing: 4) {
                        Label(request.agent ?? "The Manager", systemImage: "sparkles").labelStyle(StateLabelStyle())
                            .font(.caption.weight(.semibold)).foregroundStyle(Palette.agent)
                        ChatMarkdownText(markdown: reply)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Palette.agent.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                if !request.changes.isEmpty {
                    DisclosureGroup("\(request.changes.count) change\(request.changes.count == 1 ? "" : "s")\(request.undoneAt != nil ? ", undone" : "")") {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(Array(request.changes.enumerated()), id: \.offset) { _, change in
                                Text("• " + change.line).font(.callout).foregroundStyle(Palette.muted)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)
                    }
                    .font(.callout)
                    .tint(Palette.accentText)
                }
                HStack(spacing: 16) {
                    if !request.isOver {
                        Button("Stop") { act("stop", on: request) }
                    }
                    // Once it's over: a run still going would go on changing what Undo can't put back.
                    if request.isOver, request.canUndo {
                        Button("Undo Its Changes") { act("undo", on: request) }
                    }
                    if request.status == "answered" {
                        Button("Reply") {
                            replyingTo = request
                            typing = true
                        }
                    }
                    if acting == request.id { ProgressView().controlSize(.small) }
                }
                .font(.subheadline.weight(.medium))
                .tint(Palette.accentText)
                .disabled(acting != nil || !connection.isConnected)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 40)
        }
    }

    private func suggestionCard(_ suggestion: ManagerLink.Suggestion) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Suggests an edit to “\(suggestion.title)”", systemImage: "pencil.and.list.clipboard")
                .labelStyle(StateLabelStyle()).font(.subheadline.weight(.semibold)).foregroundStyle(Palette.needsYou)
            if !suggestion.why.isEmpty { Text(suggestion.why).font(.callout).foregroundStyle(Palette.ink) }
            Button("Review") { reviewing = suggestion }
                .buttonStyle(.bordered)
                .tint(Palette.accentText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .needsYouCard()
    }

    /// The box to ask in. It floats over the conversation: from iOS 26 a glass capsule of its own, before that on the bar
    /// material across the foot of the screen.
    @ViewBuilder
    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let problem = feed?.problem {
                ProblemLabel(problem).padding(.horizontal, 20)
            }
            if let said {
                Text(said).font(.footnote).foregroundStyle(Palette.muted).padding(.horizontal, 20)
            }
            if let replyingTo {
                HStack {
                    Text("Replying to “\(replyingTo.text)”").font(.footnote).foregroundStyle(Palette.muted).lineLimit(1)
                    Spacer()
                    Button("Cancel") { self.replyingTo = nil }.font(.footnote).tint(Palette.accentText)
                }
                .padding(.horizontal, 20)
            }
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
    }

    private func composerRow(field: Color?) -> some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField(replyingTo == nil ? "Ask the Manager" : "Reply to the Manager", text: $asking, axis: .vertical)
                .lineLimit(1...5)
                .focused($typing)
                .padding(.horizontal, field == nil ? 0 : 12)
                .padding(.vertical, 8)
                .background { if let field { RoundedRectangle(cornerRadius: 18, style: .continuous).fill(field) } }
                .accessibilityIdentifier("manager.ask")
            if sending {
                ProgressView().padding(.bottom, 6)
            } else {
                Button { Task { await ask(asking, kind: "ask", binder: nil) } } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.title)
                }
                .disabled(asking.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !connection.isConnected || feed?.problem != nil)
                .accessibilityLabel("Ask the Manager")
            }
        }
    }

    static func from(_ from: String) -> String? {
        switch from {
        case "iphone": "from your iPhone"
        case "mac": "from your Mac"
        case "schedule": "on its schedule"
        default: nil
        }
    }

    // MARK: Doing

    private func tidy(_ binder: String?) {
        Task { await ask(ManagerRequest.tidyText(binder: binder), kind: "tidy", binder: binder) }
    }

    /// What you ask goes to the agent with the Manager's role on your Mac, as the Mac says now: a local model stays on
    /// your Mac; any other, the first time for it as it's set up now, asks you first. The Mac runs it only on that one.
    private func ask(_ raw: String, kind: String, binder: String?) async {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending else { return }
        sending = true
        // Who has the role and how they're set up now, never as last seen.
        async let fresh = ManagerLink.load(connection)
        async let agents: Void = AgentConsents.refresh(connection)
        let latest = await fresh
        await agents
        sending = false
        guard let latest else { return problem = ManagerLink.unreached }
        feed = latest
        guard let name = latest.agent else { return problem = latest.problem ?? "No agent is the Manager yet. Give one the role on your Mac, in Settings → Agents." }
        if latest.local == true { return send(text, kind: kind, binder: binder, agent: name) }
        guard let agent = AgentConsents.agent(named: name, connection: connection) else {
            return problem = "Couldn't check where this would go. Try again in a moment."
        }
        if !AgentConsents.agreed(agent) {
            awaiting = (text, kind, binder, name)
            return consenting = agent
        }
        send(text, kind: kind, binder: binder, agent: name)
    }

    private func send(_ text: String, kind: String, binder: String?, agent: String) {
        sending = true
        said = nil
        // A tidy is its own request, whatever waits in the box.
        let id = kind == "ask" ? messageID : UUID()
        // The request replied to: the Mac finds its conversation, even once the first of it is gone.
        let thread = kind == "ask" ? replyingTo?.id : nil
        Task {
            defer { sending = false }
            switch await ManagerLink.ask(text, kind: kind, binder: binder, thread: thread, id: id, agent: agent, over: connection) {
            case .asked:
                Haptics.shared.success()
                if kind == "ask" {
                    asking = ""
                    replyingTo = nil
                    typing = false
                    messageID = UUID()
                }
                await load()
            case .refused(let message):
                problem = message
                if kind == "ask" { messageID = UUID() }
            case .unreached:
                // Kept in the box, with the same id: sent again, it's one request.
                problem = ManagerLink.unreached
            }
        }
    }

    private func act(_ action: String, on request: ManagerLink.Request) {
        acting = request.id
        Task {
            defer { acting = nil }
            switch await ManagerLink.act(action, request: request.id, over: connection) {
            case .success(let message):
                Haptics.shared.tap()
                said = message.isEmpty ? nil : message
                await load()
            case .failure(let failure): problem = failure.words
            }
        }
    }

    private func decide(_ suggestion: ManagerLink.Suggestion, accept: Bool) {
        acting = suggestion.id
        Task {
            defer { acting = nil }
            switch await ManagerLink.act(accept ? "accept" : "dismiss", suggestion: suggestion.id, over: connection) {
            case .success(let message):
                if accept { Haptics.shared.success() } else { Haptics.shared.tap() }
                said = message.isEmpty ? nil : message
                reviewing = nil
                await load()
            case .failure(let failure):
                reviewing = nil
                problem = failure.words
            }
        }
    }

    private func load() async {
        if let fresh = await ManagerLink.load(connection) { feed = fresh }
        unreached = feed == nil
        #if DEBUG
        // For development, as the Simulator can't be typed into from a script: `-askManager "…"` asks that, once.
        if !Self.askedForDevelopment, feed != nil, connection.isConnected, let text = UserDefaults.standard.string(forKey: "askManager"), !text.isEmpty {
            Self.askedForDevelopment = true
            asking = text
            Task { await ask(text, kind: "ask", binder: nil) }
        }
        #endif
    }

    private static var askedForDevelopment = false

    private func loadBinders() async {
        if binders.isEmpty, let copy = connection.cached("binders", as: [BinderInfo].self) { binders = copy.filter { !$0.archived } }
        if let fresh = await connection.fetch("list_binders", cache: "binders", as: [BinderInfo].self).value { binders = fresh.filter { !$0.archived } }
    }
}

/// A note edit the Manager suggests, line by line: what it adds and takes away from the note as it is now, and why. Accept
/// makes it your edit, and the note keeps its earlier version in its history; Dismiss leaves the note as it is.
private struct SuggestionSheet: View {
    @Environment(\.dismiss) private var dismiss
    let suggestion: ManagerLink.Suggestion
    let busy: Bool
    let decide: (Bool) -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !suggestion.why.isEmpty {
                        Text(suggestion.why).foregroundStyle(Palette.ink)
                    }
                    if suggestion.outdated == true {
                        ProblemLabel("The note changed since it suggested this, so it can't be applied. Dismiss it, or ask the Manager again.")
                    } else {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array((suggestion.changes ?? []).enumerated()), id: \.offset) { _, line in
                                let added = line.hasPrefix("+ ")
                                Text(line.dropFirst(2))
                                    .font(.callout)
                                    .foregroundStyle(Palette.ink)
                                    .strikethrough(!added, color: Palette.muted)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 10).padding(.vertical, 4)
                                    .background((added ? Palette.done : Palette.muted).opacity(added ? 0.14 : 0.10),
                                                in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                                    .accessibilityLabel((added ? "Adds: " : "Takes away: ") + line.dropFirst(2))
                            }
                        }
                        .surfaceCard(padding: 8)
                    }
                    Text("Accepted, it's your edit, and the earlier version stays in the note's history.")
                        .font(.footnote).foregroundStyle(Palette.muted)
                }
                .padding()
            }
            .screenGround()
            .navigationTitle(suggestion.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button("Dismiss", role: .destructive) { decide(false) }
                    Spacer()
                    if busy { ProgressView() }
                    Button("Accept") { decide(true) }
                        .bold()
                        .disabled(suggestion.outdated == true)
                }
            }
            .disabled(busy)
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: One agent

/// One of your agents: a chat with it (lane AC1) when it can chat, from a Mac that has chats; otherwise its cards.
struct AgentChatView: View {
    @Environment(MacConnection.self) private var connection
    let name: String
    @State private var agents: AgentList?

    var body: some View {
        let agent = agents?.agents.first { $0.name == name }
        Group {
            if ChatLink.chats(agent, over: connection) {
                ChatThreadView(agent: name)
            } else if agents != nil {
                AgentCardsView(name: name)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity).screenGround()
            }
        }
        .task {
            agents = connection.cached("agents", as: AgentList.self)
            if agents == nil { agents = await connection.fetch("list_agents", cache: "agents", as: AgentList.self).value ?? AgentList(paused: false, agents: []) }
        }
    }
}

/// One of your agents' cards (lane MG3): what it holds and what you meant for it, each a conversation that opens as its
/// card, the ones that finished under Earlier, and a box to write to it. What you write becomes a card meant for it, in
/// Ready, on a board it takes cards from, and your Mac hands it over as Give to does; its first line is the card's title.
/// Where an agent can't chat, this is how you talk to it; where it can, its chat's menu opens it.
struct AgentCardsView: View {
    @Environment(MacConnection.self) private var connection
    let name: String
    @State private var agents: AgentList?
    @State private var cards: [Card] = []
    @State private var done: [Card] = []
    @State private var binders: [BinderInfo] = []
    @State private var chosenBinder: String?
    @State private var message = ""
    /// This message's own id: sent again after the Mac didn't answer, it's the same card.
    @State private var messageID = UUID()
    @State private var sending = false
    @State private var problem: String?
    @State private var consenting: AgentList.Agent?
    @State private var opened: CardLink?
    @State private var unreached = false
    @FocusState private var typing: Bool

    /// How many finished conversations show.
    static let earlier = 8

    var body: some View {
        let agent = agents?.agents.first { $0.name == name }
        let open = cards.filter { $0.board != .done && AgentWork.isFor($0, name) }
        let finished = Array(done.filter { AgentWork.isFor($0, name) }.prefix(Self.earlier))
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    if let agent {
                        Text(AgentWork.kind(agent.wakes)).font(.subheadline).foregroundStyle(Palette.muted)
                    }
                    let status = AgentWork.status(of: name, in: cards, paused: agents?.paused == true)
                    AgentStatusText(words: status.words, tone: status.tone)
                }
                .padding(.vertical, 2)
            }
            .surfaceRows()
            if !open.isEmpty {
                Section("Its work") {
                    ForEach(open) { card in NavigationLink(value: CardLink(id: card.id)) { conversationRow(card) } }
                }
                .surfaceRows()
            }
            if !finished.isEmpty {
                Section("Earlier") {
                    ForEach(finished) { card in NavigationLink(value: CardLink(id: card.id)) { conversationRow(card) } }
                }
                .surfaceRows()
            }
            if open.isEmpty, finished.isEmpty {
                if unreached {
                    WaitingForMac(what: "Its conversations show here") { await load() }.listRowBackground(Color.clear)
                } else {
                    Section {
                        Text("Nothing with \(name) yet. Write to it below: your message becomes a card meant for it, and your Mac hands it over.")
                            .font(.callout).foregroundStyle(Palette.muted)
                    }
                    .surfaceRows()
                }
            }
        }
        .listGround()
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { if agents != nil { composer(agent) } }
        .navigationDestination(item: $opened) { CardDetailView(id: $0.id) }
        .task(id: connection.revision("tasks")) { await load() }
        .refreshable { await load() }
        // Changed words are a new message: never the card an earlier send that didn't arrive was for.
        .onChange(of: message) { _, _ in messageID = UUID() }
        .problemToast($problem)
        // The first card that goes to it, as it's set up now: where it goes, and what goes with it (App Store 5.1.2(i)).
        .confirmationDialog(consenting.map { "Give cards to \($0.name)?" } ?? "", isPresented: Binding(get: { consenting != nil }, set: { if !$0 { consenting = nil } }),
                            titleVisibility: .visible, presenting: consenting) { agent in
            Button("Give to \(agent.name)") {
                AgentConsents.agree(agent)
                send(to: agent)
            }
            Button("Cancel", role: .cancel) {}
        } message: { agent in
            Text(AgentConsents.disclosure(agent))
        }
    }

    private func conversationRow(_ card: Card) -> some View {
        let holds = card.assigneeIsAgent && BoardRules.isNamed(card.assignee, as: name)
        return VStack(alignment: .leading, spacing: 3) {
            Text(card.title.isEmpty ? "Untitled" : card.title)
                .foregroundStyle(card.board == .done ? Palette.muted : Palette.ink)
                .lineLimit(2)
            HStack(spacing: 6) {
                if card.board == .blocked || card.board == .review {
                    Label(card.board.title, systemImage: "bell.fill").labelStyle(StateLabelStyle()).foregroundStyle(Palette.needsYou)
                } else {
                    Text(holds || card.board == .done ? card.board.title : "Meant for it, \(card.board.title)").foregroundStyle(Palette.muted)
                }
                Text("·").foregroundStyle(Palette.faint)
                Text(card.binder).foregroundStyle(Palette.muted)
                Spacer(minLength: 4)
                if let date = Date(iso: card.updated) {
                    Text(date, format: .relative(presentation: .numeric, unitsStyle: .narrow))
                        .font(Typeface.time(.caption)).foregroundStyle(Palette.muted)
                }
            }
            .font(.caption)
            .lineLimit(1)
        }
        .padding(.vertical, 2)
    }

    /// The binders whose cards it takes, as your Mac says; from a Mac that doesn't say, every binder.
    private func choices(_ agent: AgentList.Agent?) -> [String] {
        let all = binders.filter { !$0.archived }.map(\.name)
        guard let takes = agent?.binders else { return all }
        return all.filter(takes.contains)
    }

    /// Where a new conversation goes: the binder you chose, else the one its latest conversation is on, else the first.
    private func chosen(_ agent: AgentList.Agent?) -> String? {
        let choices = choices(agent)
        if let chosenBinder, choices.contains(chosenBinder) { return chosenBinder }
        if let latest = cards.first(where: { AgentWork.isFor($0, name) && choices.contains($0.binder) }) { return latest.binder }
        return choices.first
    }

    @ViewBuilder
    private func composer(_ agent: AgentList.Agent?) -> some View {
        let choices = choices(agent)
        let binder = chosen(agent)
        VStack(alignment: .leading, spacing: 6) {
            Group {
                if agent == nil {
                    Text("\(name) isn't one your Mac hands cards to now. Look at it on your Mac, in Settings → Agents.")
                } else if binder == nil {
                    Text("It takes cards from none of your binders. Choose its binders on your Mac, in Settings → Agents.")
                } else if let binder {
                    HStack(spacing: 4) {
                        Text("Goes on the")
                        if choices.count > 1 {
                            Menu {
                                ForEach(choices, id: \.self) { name in Button(name) { chosenBinder = name } }
                            } label: {
                                HStack(spacing: 2) {
                                    Text(binder).fontWeight(.semibold)
                                    Image(systemName: "chevron.up.chevron.down").font(.caption2)
                                }
                            }
                            .tint(Palette.accentText)
                            .accessibilityLabel("Board: \(binder)")
                        } else {
                            Text(binder).fontWeight(.semibold)
                        }
                        Text("board, and \(agent?.wakes == "board" ? "it picks it up there" : "your Mac hands it over").")
                    }
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                }
            }
            .font(.footnote)
            .foregroundStyle(Palette.muted)
            .padding(.horizontal, 20)
            if #available(iOS 26.0, *) {
                composerRow(agent, binder: binder)
                    .padding(.leading, 16)
                    .padding(.trailing, 6)
                    .padding(.vertical, 6)
                    .floatingGlass(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .padding(.horizontal)
                    .padding(.bottom, 8)
            } else {
                composerRow(agent, binder: binder, field: Palette.surface)
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(.bar)
            }
        }
    }

    private func composerRow(_ agent: AgentList.Agent?, binder: String?, field: Color? = nil) -> some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Message \(name)", text: $message, axis: .vertical)
                .lineLimit(1...5)
                .focused($typing)
                .padding(.horizontal, field == nil ? 0 : 12)
                .padding(.vertical, 8)
                .background { if let field { RoundedRectangle(cornerRadius: 18, style: .continuous).fill(field) } }
                .accessibilityIdentifier("agent.message")
            if sending {
                ProgressView().padding(.bottom, 6)
            } else {
                Button { give(agent) } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.title)
                }
                .disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || agent == nil || binder == nil || !connection.isConnected)
                .accessibilityLabel("Send to \(name)")
            }
        }
    }

    /// The first card for it, as it's set up now, asks.
    private func give(_ agent: AgentList.Agent?) {
        guard let agent else { return }
        if !AgentConsents.agreed(agent) { return consenting = agent }
        send(to: agent)
    }

    private func send(to agent: AgentList.Agent) {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending, let binder = chosen(agent) else { return }
        sending = true
        let parts = AgentNote.card(from: text)
        var arguments: [String: Any] = ["title": parts.title, "binder": binder, "column": "ready", "for": agent.name]
        if !parts.details.isEmpty { arguments["details"] = parts.details }
        let request = messageID
        Task {
            defer { sending = false }
            do {
                let reply = try await connection.call("create_task",
                                                      OutboxRules.arguments(arguments, id: request, dedupe: connection.macFeatures.contains(LinkFeatures.dedupe)),
                                                      timeout: LinkTimeouts.change)
                messageID = UUID()
                message = ""
                typing = false
                Haptics.shared.success()
                // The conversation it started, where its replies come.
                if let id = (try? JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any])?["id"] as? String, !id.isEmpty {
                    opened = CardLink(id: id)
                }
                await load()
            } catch LinkClient.Failure.rejected(let words) {
                messageID = UUID()
                problem = words
            } catch {
                // Kept in the box, with the same id: sent again, it's one card.
                problem = ManagerLink.unreached
            }
        }
    }

    private func load() async {
        if agents == nil { agents = connection.cached("agents", as: AgentList.self) }
        if cards.isEmpty, let copy = connection.cached("tasks-all", as: [Card].self) { cards = copy }
        if binders.isEmpty, let copy = connection.cached("binders", as: [BinderInfo].self) { binders = copy }
        async let agentList = connection.fetch("list_agents", cache: "agents", as: AgentList.self)
        async let cardList = connection.fetch("list_tasks", cache: "tasks-all", as: [Card].self)
        async let doneList = connection.fetch("list_tasks", ["column": "done"], cache: "tasks-done", as: [Card].self)
        async let binderList = connection.fetch("list_binders", cache: "binders", as: [BinderInfo].self)
        if let fresh = await agentList.value { agents = fresh }
        if let fresh = await cardList.value { cards = fresh }
        if let fresh = await doneList.value { done = fresh }
        if let fresh = await binderList.value { binders = fresh }
        unreached = agents == nil
        #if DEBUG
        // For development: `-message "…"` sends that to the agent, once.
        if !Self.sentForDevelopment, agents != nil, connection.isConnected, let text = UserDefaults.standard.string(forKey: "message"), !text.isEmpty {
            Self.sentForDevelopment = true
            message = text
            give(agents?.agents.first { $0.name == name })
        }
        #endif
    }

    private static var sentForDevelopment = false
}
