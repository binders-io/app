import SwiftData
import SwiftUI
import BindersKit

/// One agent, picked on the Agents page: a header with what it is and what it's doing, Stop while a run goes and Open in
/// Terminal to look in with your own settings; a strip of its sessions (each card it works on, each chat with it); and the
/// session as a terminal, with a prompt to talk to it there. Not a board: the card's own window and the board keep the
/// card's details and moves.
struct AgentWorkspace: View {
    @Environment(HubNavigation.self) private var navigation
    @Environment(DictationController.self) private var controller
    @State private var registry = AgentRegistry.shared
    let person: AgentsView.Someone
    let sessions: [AgentWorkSession]
    /// The session the page's pick names, or nil for the one it shows by itself.
    let picked: AgentWorkSession.Kind?
    let cards: [TaskCard]
    let pick: (AgentsPick) -> Void
    /// A new chat, or a new card for it, being written: no session shows.
    @State private var starting = false

    var body: some View {
        let session: AgentWorkSession? = if starting {
            nil
        } else if let picked {
            sessions.first { $0.kind == picked } ?? stray(picked)
        } else {
            AgentWorkSessions.preferred(sessions)
        }
        VStack(alignment: .leading, spacing: 0) {
            header(session)
                .padding(.horizontal, 22)
                .padding(.top, 18)
                .padding(.bottom, 12)
            strip(session)
                .padding(.horizontal, 22)
                .padding(.bottom, 12)
            pane(session)
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
        }
        .onChange(of: picked) { starting = false }
    }

    /// A session picked that isn't among the agent's listed ones (a card it no longer holds, an older chat).
    private func stray(_ kind: AgentWorkSession.Kind) -> AgentWorkSession? {
        switch kind {
        case .card(let id):
            guard let card = cards.first(where: { $0.id == id }) else { return nil }
            return AgentWorkSession(kind: kind, title: card.title.isEmpty ? "Untitled" : card.title, updatedAt: card.updatedAt,
                                    running: controller.agents.isWorking(on: id), needsYou: BoardDesign.needsYou(card.column), done: card.column == .done)
        case .chat(let id):
            guard let chat = controller.chats.chat(id) else { return nil }
            return AgentWorkSession(kind: kind, title: chat.title, updatedAt: chat.updatedAt, running: chat.status == .running, needsYou: false, done: false)
        }
    }

    // MARK: The header

    private func header(_ session: AgentWorkSession?) -> some View {
        let state = AgentsView.status(of: person, cards: cards, controller: controller, registry: registry)
        return HStack(alignment: .center, spacing: 12) {
            AgentAvatar(name: person.name, profile: person.profile, size: 36, activity: state.activity)
            VStack(alignment: .leading, spacing: 2) {
                Text(person.name).font(BindersTheme.title(20)).lineLimit(1).fitProbe("agents.workspace.header")
                Text([Self.what(person.profile), state.words].joined(separator: " · "))
                    .font(.callout)
                    .foregroundStyle(state.tone == .needsYou ? BindersTheme.needsYou : BindersTheme.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            ViewThatFits(in: .horizontal) {
                actions(session, labelled: true)
                actions(session, labelled: false)
            }
            .layoutPriority(1)
        }
    }

    @ViewBuilder
    private func actions(_ session: AgentWorkSession?, labelled: Bool) -> some View {
        let look = lookIn(session)
        HStack(spacing: 8) {
            if let session, session.running {
                Button { stop(session) } label: {
                    if labelled { Label("Stop", systemImage: "stop.fill") } else { Image(systemName: "stop.fill") }
                }
                .buttonStyle(.soft)
                .help("Stop this run. What you write next carries on its session.")
                .accessibilityLabel("Stop")
            }
            if AgentWorkSessions.tool(of: person.profile) != nil {
                Button { openInTerminal(session, look) } label: {
                    if labelled { Label("Open in Terminal", systemImage: "terminal") } else { Image(systemName: "terminal") }
                }
                .buttonStyle(.soft)
                .disabled(look == nil || session?.running == true)
                .help(session?.running == true ? "It's running here: a second process on the same session would clash. Stop it, or open it once this run is done."
                      : look == nil ? "Open in Terminal looks in on a session once it has run."
                      : "Look in on this session in Terminal, with your own settings")
                .accessibilityLabel("Open in Terminal")
            }
            Menu {
                if let session, case .card(let id) = session.kind, let card = cards.first(where: { $0.id == id }) {
                    Button("Open Card") { navigation.open(card: card) }
                    Button("Show on Board") { navigation.showOnBoard(card) }
                    Divider()
                }
                if let look {
                    Button("Copy Look-In Command") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString([look.folder.map { "cd \(AgentLookInWords.word($0))" }, look.command].compactMap { $0 }.joined(separator: " && "), forType: .string)
                    }
                    Divider()
                }
                if person.profile != nil {
                    Button("Agent Settings…") {
                        navigation.pendingSettingsPage = .agents
                        navigation.selection = .settings
                    }
                }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold))
                    .frame(width: 28, height: 26)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
        }
        .fixedSize()
    }

    /// "Claude Code · in ~/code/app", "Checks the board itself".
    static func what(_ profile: AgentProfile?) -> String {
        func place(_ path: String) -> String { (path as NSString).abbreviatingWithTildeInPath }
        switch profile?.wake {
        case .claudeCode(let wake): return "Claude Code · in \(place(wake.repository))"
        case .cliAgent(let wake): return "\(wake.tool.name) · in \(place(wake.repository))"
        case nil: return "Works on your boards from its own session"
        case let wake?: return AgentsSections.describe(wake)
        }
    }

    private func lookIn(_ session: AgentWorkSession?) -> TerminalLookIn.Command? {
        switch session?.kind {
        case .card(let id):
            guard let card = cards.first(where: { $0.id == id }) else { return nil }
            return TerminalLookIn.card(card, timeline: controller.board.timeline(id), agent: person.profile)
        case .chat(let id):
            return controller.chats.chat(id).flatMap { TerminalLookIn.chat($0, agent: person.profile) }
        case nil:
            return nil
        }
    }

    private func openInTerminal(_ session: AgentWorkSession?, _ look: TerminalLookIn.Command?) {
        guard let session, let look, !session.running else { return }
        TerminalLookIn.run(look, title: "\(person.name): \(session.title)", name: session.id.replacingOccurrences(of: ":", with: "-"))
    }

    private func stop(_ session: AgentWorkSession) {
        switch session.kind {
        case .card(let id): controller.agents.stop(id)
        case .chat(let id): controller.chats.stop(id)
        }
    }

    // MARK: Its sessions

    private func strip(_ session: AgentWorkSession?) -> some View {
        HStack(spacing: 8) {
            ScrollViewReader { reader in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        if sessions.isEmpty, !starting {
                            Text("No sessions yet").font(.system(size: 12)).foregroundStyle(BindersTheme.faint).padding(.vertical, 5)
                        }
                        if starting {
                            chip(title: AgentsView.chats(person) ? "New chat" : "New card", state: nil, color: BindersTheme.accentText, selected: true) {}
                                .id("new")
                        }
                        ForEach(sessions) { item in
                            chip(title: item.title, state: item.state, color: dot(item), selected: item.id == session?.id) {
                                starting = false
                                pick(item.pick)
                            }
                            .id(item.id)
                        }
                    }
                    .padding(.vertical, 1)
                    .padding(.trailing, 14)
                }
                // More to the right fades out under the + button.
                .mask(HStack(spacing: 0) {
                    Color.black
                    LinearGradient(colors: [.black, .black.opacity(0)], startPoint: .leading, endPoint: .trailing).frame(width: 18)
                })
                .onAppear { if let id = session?.id { reader.scrollTo(id) } }
            }
            Button {
                starting = true
            } label: {
                Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
                    .frame(width: 26, height: 26)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(BindersTheme.surface2))
            }
            .buttonStyle(.plain)
            .help(AgentsView.chats(person) ? "Start a new chat with \(person.name)" : "Give \(person.name) a new card")
            .accessibilityLabel(AgentsView.chats(person) ? "New chat" : "New card")
        }
    }

    private func dot(_ session: AgentWorkSession) -> Color {
        session.running ? BindersTheme.done : session.needsYou ? BindersTheme.needsYou : session.done ? BindersTheme.faint : BindersTheme.lineStrong
    }

    private func chip(title: String, state: String?, color: Color, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(selected ? BindersTheme.ink : BindersTheme.muted)
                    .lineLimit(1)
                    .frame(maxWidth: 200, alignment: .leading)
                    .fixedSize(horizontal: true, vertical: false)
                if let state {
                    Text(state).font(.system(size: 11)).foregroundStyle(BindersTheme.faint).lineLimit(1).fixedSize()
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(selected ? BindersTheme.surface2 : Color.clear))
            .overlay(Capsule().strokeBorder(selected ? BindersTheme.lineStrong : BindersTheme.line))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel([title, state].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: The terminal

    @ViewBuilder
    private func pane(_ session: AgentWorkSession?) -> some View {
        switch session?.kind {
        case .card(let id):
            if let card = cards.first(where: { $0.id == id }) {
                CardSessionPane(card: card, person: person).id(card.id)
            }
        case .chat(let id):
            ChatSessionPane(chatID: id, person: person).id(id)
        case nil:
            NewSessionPane(person: person) { made in
                starting = false
                pick(made)
            }
            .id("new-" + person.id)
        }
    }
}

/// Words for the shell, as the look-in's script has them.
enum AgentLookInWords {
    static func word(_ text: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._/+-@%:,~")
        return !text.isEmpty && text.unicodeScalars.allSatisfy(safe.contains) ? text : AgentMCPEntry.quoted(text)
    }
}

// MARK: - A card's session

/// A card the agent works on, as its terminal: every run of it, in order, live while one goes, with your comments where
/// they reached it; what waits on you above it; and the prompt, whose words go where the card's composer would send them
/// (straight into a run that takes them, or on the card for its next run), as the composer's own line says.
private struct CardSessionPane: View {
    @Environment(DictationController.self) private var controller
    @Bindable var card: TaskCard
    let person: AgentsView.Someone
    @Query private var events: [TaskEvent]
    @State private var logs = AgentTerminalLogs()
    @State private var draft = ""
    @State private var problem: String?

    init(card: TaskCard, person: AgentsView.Someone) {
        self.card = card
        self.person = person
        let id = card.id
        _events = Query(filter: #Predicate<TaskEvent> { $0.taskID == id }, sort: [SortDescriptor(\TaskEvent.createdAt)])
    }

    var body: some View {
        // The tool its runs are, as the receipt that started the last says; else as the agent is woken now.
        let tool = AgentSessionBlocks.tool(of: card, events: events, profile: person.profile)
        let files = AgentSessionBlocks.files(of: card)
        let answering = CardAnswering.of(card, events: events)
        let reach = controller.agents.commentReach(for: card, events: events)
        let running = controller.agents.isWorking(on: card.id)
        VStack(spacing: 10) {
            if NeedsYouTray.shows(card, answering: answering) {
                NeedsYouTray(card: card, events: events, answering: answering, reach: reach, compactApproval: true, draft: $draft, problem: $problem,
                             wordsWidth: AgentsLayout.readingWidth)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(BindersTheme.surface))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .fixedSize(horizontal: false, vertical: true)
                    .binderTint(Store.shared.binder(card.binderID)?.colorIndex)
            }
            AgentTerminalPane {
                AgentTerminalTranscript(blocks: AgentSessionBlocks.card(card, events: events, logs: logs, tool: tool, files: files, running: running, controller: controller),
                                        running: running, current: logs.watches.last?.current, since: running ? logs.watches.last?.startedAt : nil,
                                        intro: files.isEmpty && tool != nil ? AgentSessionBlocks.cardIntro(card, name: person.name) : nil)
            } prompt: {
                AgentTerminalPrompt(placeholder: "Message \(person.name.shortAgentName)", hint: reach.line(answering: answering), blocked: nil) { words in
                    AgentSessionBlocks.send(words, on: card, events: events, controller: controller)
                }
            }
        }
        .onAppear { logs.follow(files, tool: tool) }
        .onChange(of: files) { logs.follow(files, tool: tool) }
        .onDisappear { logs.stop() }
        .alert("Couldn't do that", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(problem ?? "") }
    }
}

// MARK: - A chat

/// A chat with the agent, as its terminal: its runs' logs when Binders runs it (Claude Code), else your messages and its
/// replies. The prompt carries the chat on: straight into a run that takes your words, after the one going, or a new run
/// on the chat's session.
private struct ChatSessionPane: View {
    @Environment(DictationController.self) private var controller
    let chatID: UUID
    let person: AgentsView.Someone
    @State private var logs = AgentTerminalLogs()

    var body: some View {
        let service = controller.chats
        let chat = service.chat(chatID)
        let tool = AgentSessionBlocks.chatTool(person.profile)
        let files = service.logs(of: chatID)
        let running = chat?.status == .running
        AgentTerminalPane {
            AgentTerminalTranscript(blocks: chat.map { AgentSessionBlocks.chat($0, logs: logs, tool: tool, files: files, controller: controller) } ?? [], running: running,
                                    current: logs.watches.last?.current, since: running ? logs.watches.last?.startedAt : nil,
                                    intro: chat == nil ? "That chat isn't on this Mac any more." : nil)
        } prompt: {
            AgentTerminalPrompt(placeholder: "Message \(person.name.shortAgentName)",
                                hint: AgentSessionBlocks.chatHint(chat, name: person.name, profile: person.profile, controller: controller),
                                blocked: AgentSessionBlocks.chatBlocked(name: person.name, controller: controller)) { words in
                switch service.send(words, to: person.name, chat: chatID, via: "mac") {
                case .success: return nil
                case .failure(let failure): return failure.why
                }
            }
        }
        .onAppear { logs.follow(files, tool: tool) }
        .onChange(of: files) { logs.follow(files, tool: tool) }
        .onChange(of: chat?.status) { logs.follow(service.logs(of: chatID), tool: tool) }
        .onDisappear { logs.stop() }
    }
}

// MARK: - Something new

/// Nothing picked yet, or a new chat or card being written: what the agent is, and a prompt that starts a chat with it
/// (one that chats) or gives it a card meant for it on a board it takes cards from.
private struct NewSessionPane: View {
    @Environment(HubNavigation.self) private var navigation
    @Environment(DictationController.self) private var controller
    let person: AgentsView.Someone
    let made: (AgentsPick) -> Void
    @State private var binderID: UUID?

    var body: some View {
        let chats = AgentsView.chats(person)
        let choices = binders
        let chosen = binderID.flatMap { id in choices.first { $0.id == id } } ?? choices.first { $0.id == navigation.binderID } ?? choices.first
        AgentTerminalPane {
            AgentTerminalTranscript(blocks: [], running: false, current: nil, since: nil, intro: intro(chats: chats))
        } prompt: {
            AgentTerminalPrompt(placeholder: chats ? "Message \(person.name.shortAgentName)" : "Give \(person.name.shortAgentName) a card",
                                hint: chats ? nil : chosen.map { "Becomes a card meant for \(person.name.shortAgentName) on the \($0.name) board, in Ready." },
                                blocked: blocked(chats: chats, chosen: chosen),
                                send: { words in chats ? chat(words) : card(words, on: chosen) },
                                accessory: !chats && choices.count > 1 ? AnyView(boardPicker(choices, chosen: chosen)) : nil)
        }
    }

    private func intro(chats: Bool) -> String {
        let name = person.name.shortAgentName
        let what = AgentWorkspace.what(person.profile)
        if chats {
            return person.profile?.wake == .board
                ? "\(what).\n\nWrite to \(name) below. It reads your messages when it next checks the board, and answers here."
                : "\(what).\n\nWrite to \(name) below to start a chat. Binders starts it in a worktree of its own, with the permissions its cards have, and what it does shows here as it goes."
        }
        return "\(what).\n\n\(name) works on cards. Write below to give it one: it goes on a board as a card meant for it, and its runs show here."
    }

    private var binders: [BinderRecord] {
        let all = Store.shared.binders()
        guard let agent = person.profile else { return all }
        return all.filter { agent.takesCards(from: $0.id) }
    }

    private func blocked(chats: Bool, chosen: BinderRecord?) -> String? {
        if chats {
            guard let profile = controller.chats.agent(named: person.name) else { return nil }
            return controller.chats.problem(with: profile)
        }
        return chosen == nil ? "It takes cards from none of your binders. Choose its binders in Settings → Agents." : nil
    }

    private func boardPicker(_ choices: [BinderRecord], chosen: BinderRecord?) -> some View {
        Picker("Board", selection: Binding(get: { chosen?.id }, set: { binderID = $0 })) {
            ForEach(choices) { binder in Text(binder.name).tag(UUID?.some(binder.id)) }
        }
        .labelsHidden()
        .controlSize(.small)
        .fixedSize()
        .help("The board the card goes on")
    }

    private func chat(_ words: String) -> String? {
        switch controller.chats.send(words, to: person.name, via: "mac") {
        case .success(let chat):
            made(.chat(chat.id))
            return nil
        case .failure(let failure):
            return failure.why
        }
    }

    /// A card meant for it, in Ready, handed over; one that checks the board itself picks it up there.
    private func card(_ words: String, on binder: BinderRecord?) -> String? {
        guard let binder else { return "Choose its binders in Settings → Agents first." }
        let parts = AgentNote.card(from: words)
        let card = controller.board.create(title: parts.title, details: parts.details, binderID: binder.id, column: .backlog, by: .you)
        let handed = controller.board.give(card, to: person.name, by: .you)
        made(.card(card.id))
        let checksItself = person.profile.map { $0.wake == .board } ?? true
        if case .notWoken(let why) = handed, !checksItself {
            return "The card is on the \(binder.name) board, meant for \(person.name), but it wasn't handed over: \(why)"
        }
        return nil
    }
}
