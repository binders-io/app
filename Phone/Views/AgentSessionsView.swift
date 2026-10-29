import SwiftUI
import BindersKit

/// One of your agents, as the Mac's Agents page shows it (lane AC2), from a Mac that lists `LinkFeatures.sessions`: what
/// it is and what it's doing, a strip of its sessions (each card it works on, each chat with it), and the session as a
/// terminal: what it was told, what it says, each command or file it touches with what came back, an edit's lines in red
/// and green, and how each turn ended. The box at the foot talks to it there: into a chat, or onto the card, straight
/// into a run that takes your words. The first time anything goes to an agent as it's set up now, Binders asks you first
/// (App Store 5.1.2(i)). Its words are the agent's: data, shown as its.
struct AgentSessionsView: View {
    @Environment(MacConnection.self) private var connection
    let name: String
    @State private var list: AgentSessionList?
    /// The session you picked; nil shows the one running, else the newest.
    @State private var picked: AgentSessionSummary?
    /// A new chat being written: no session shows.
    @State private var starting = false
    @State private var shown: AgentSessionShown?
    /// Why the picked session can't show: the Mac doesn't have it any more.
    @State private var gone: String?
    @State private var unreached = false
    @State private var message = ""
    /// This message's own id: sent again after the Mac didn't answer, it's the same message.
    @State private var messageID = UUID()
    @State private var sending = false
    @State private var problem: String?
    @State private var consenting: AgentList.Agent?
    @State private var openedCard: CardLink?
    @State private var showingCards = false
    @FocusState private var typing: Bool

    var body: some View {
        let session = current
        VStack(alignment: .leading, spacing: 0) {
            if let list {
                header(list)
                    .padding(.horizontal)
                    .padding(.top, 6)
                    .padding(.bottom, 10)
                strip(list, session: session)
                    .padding(.bottom, 10)
                if let session, session.kind == .card, shown?.id == session.id, shown?.needsYou == true {
                    waitsOnYou(session)
                        .padding(.horizontal)
                        .padding(.bottom, 8)
                }
                terminal(list, session: session)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
            } else if unreached {
                WaitingForMac(what: "\(name)'s sessions show here") { await loadList() }
                    .padding()
                Spacer()
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .screenGround()
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { menu(session) } }
        .navigationDestination(item: $openedCard) { CardDetailView(id: $0.id) }
        .navigationDestination(isPresented: $showingCards) { AgentCardsView(name: name) }
        // Again when the link comes back, and when cards or chats change.
        .task(id: [connection.revision("tasks"), connection.revision("chats"), connection.isConnected ? 1 : 0]) { await loadList() }
        // The session shown, again every 2 seconds while it runs, else every 15.
        .task(id: (session?.id ?? (starting ? "new" : "none")) + (connection.isConnected ? "" : " · away")) {
            while !Task.isCancelled {
                await loadShown()
                try? await Task.sleep(for: shown?.running == true ? .seconds(2) : .seconds(15))
            }
        }
        .refreshable {
            await loadList()
            await loadShown()
        }
        .onChange(of: message) { _, _ in messageID = UUID() }
        .problemToast($problem)
        // The first words to it, as it's set up now: where they go, and what goes with them (App Store 5.1.2(i)).
        .confirmationDialog(consenting.map { "Send this to \($0.name)?" } ?? "", isPresented: Binding(get: { consenting != nil }, set: { if !$0 { consenting = nil } }),
                            titleVisibility: .visible, presenting: consenting) { agent in
            Button("Send to \(agent.name)") {
                AgentConsents.agree(agent)
                send()
            }
            Button("Cancel", role: .cancel) {}
        } message: { agent in
            Text(AgentConsents.disclosure(agent))
        }
    }

    /// The session showing: the one you picked, else the one running, else the newest; none while a new one is written.
    private var current: AgentSessionSummary? {
        if starting { return nil }
        if let picked { return list?.sessions.first { $0.id == picked.id } ?? picked }
        return list?.sessions.first { $0.running } ?? list?.sessions.first
    }

    // MARK: The header

    private func header(_ list: AgentSessionList) -> some View {
        let running = list.sessions.first { $0.running }
        let needs = list.sessions.filter { $0.needsYou && !$0.done }.count
        let activity: AgentAvatarView.Activity = running != nil ? .working : needs > 0 ? .needsYou : .idle
        return HStack(spacing: 12) {
            AgentAvatarView(name: list.agent, kind: AgentAvatarKind(rawValue: list.avatar) ?? .other, size: 38, activity: activity)
            VStack(alignment: .leading, spacing: 2) {
                Text(list.what).font(.subheadline).foregroundStyle(Palette.muted).lineLimit(1)
                if let running {
                    AgentStatusText(words: running.kind == .chat ? "Answering “\(running.title)”" : "Working on “\(running.title)”", tone: .working)
                } else if needs > 0 {
                    AgentStatusText(words: needs == 1 ? "1 card needs you" : "\(needs) cards need you", tone: .needsYou)
                } else {
                    AgentStatusText(words: "Idle", tone: .plain)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Its sessions

    private func strip(_ list: AgentSessionList, session: AgentSessionSummary?) -> some View {
        ScrollViewReader { reader in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    newChip(list)
                    if list.sessions.isEmpty, !starting {
                        Text("No sessions yet").font(.footnote).foregroundStyle(Palette.faint).padding(.vertical, 7)
                    }
                    ForEach(list.sessions) { item in
                        chip(item, selected: item.id == session?.id)
                            .id(item.id)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 1)
            }
            .onAppear { if let id = session?.id { reader.scrollTo(id, anchor: .center) } }
        }
    }

    /// New Chat, for one that chats; else a new card, on its cards' screen, where you choose its board.
    private func newChip(_ list: AgentSessionList) -> some View {
        Button {
            if list.chats {
                starting = true
                picked = nil
                shown = nil
                typing = true
            } else {
                showingCards = true
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "plus").font(.caption.weight(.bold))
                if starting { Text("New chat").font(.footnote.weight(.medium)) }
            }
            .foregroundStyle(starting ? Palette.ink : Palette.accentText)
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(Capsule().fill(starting ? Palette.surface : Color.clear))
            .overlay(Capsule().strokeBorder(starting ? Palette.accentText.opacity(0.6) : Palette.line))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(list.chats ? "New chat with \(name)" : "Give \(name) a new card")
        .accessibilityIdentifier("sessions.new")
    }

    private func chip(_ item: AgentSessionSummary, selected: Bool) -> some View {
        let color = item.running ? Palette.done : item.needsYou ? Palette.needsYou : item.done ? Palette.faint : Palette.muted.opacity(0.5)
        let state = item.state()
        return Button {
            starting = false
            guard picked?.id != item.id || shown?.id != item.id else { return }
            picked = item
            shown = nil
            gone = nil
        } label: {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 7, height: 7)
                Image(systemName: item.kind == .chat ? "bubble.left" : "rectangle.portrait").font(.caption2).foregroundStyle(Palette.faint)
                Text(item.title).font(.footnote.weight(.medium)).foregroundStyle(selected ? Palette.ink : Palette.muted)
                    .lineLimit(1)
                    .frame(maxWidth: 180, alignment: .leading)
                    .fixedSize(horizontal: true, vertical: false)
                Text(state).font(.caption).foregroundStyle(Palette.faint).lineLimit(1).fixedSize()
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(Capsule().fill(selected ? Palette.surface : Color.clear))
            .overlay(Capsule().strokeBorder(selected ? Palette.accentText.opacity(0.6) : Palette.line))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(item.kind == .chat ? "Chat" : "Card"): \(item.title), \(state)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// A card that waits on you: its question, approval or review is answered on the card.
    private func waitsOnYou(_ session: AgentSessionSummary) -> some View {
        Button { openedCard = CardLink(id: session.id) } label: {
            HStack(spacing: 10) {
                Image(systemName: "bell.fill").foregroundStyle(Palette.needsYou)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Waits on you").font(.subheadline.weight(.semibold)).foregroundStyle(Palette.ink)
                    Text(shown?.column.map { "In \($0). Answer or approve it on the card." } ?? "Answer or approve it on the card.")
                        .font(.caption).foregroundStyle(Palette.muted)
                }
                Spacer(minLength: 4)
                Text("Open Card").font(.subheadline.weight(.medium)).foregroundStyle(Palette.accentText)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Palette.needsYou.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("sessions.waitsOnYou")
    }

    // MARK: The terminal

    @ViewBuilder
    private func terminal(_ list: AgentSessionList, session: AgentSessionSummary?) -> some View {
        let now = session.flatMap { session in shown?.id == session.id ? shown : nil }
        VStack(spacing: 0) {
            Group {
                if let now {
                    SessionTranscript(shown: now, agent: list.agent) { stop(now) }
                } else if let gone {
                    SessionTranscript.note(gone)
                } else if session != nil {
                    ProgressView().tint(TerminalColors.muted).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    SessionTranscript.note(intro(list))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            prompt(list, session: session, shown: now)
        }
        .background(TerminalColors.ground)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(TerminalColors.edge))
        .environment(\.colorScheme, .dark)
    }

    private func intro(_ list: AgentSessionList) -> String {
        if list.chats {
            return "\(list.what).\n\nWrite to \(name) below to start a chat. Your Mac starts it, and what it does shows here as it goes."
        }
        return "\(list.what).\n\n\(name) works on cards. Tap + to give it one: it goes on a board as a card meant for it, and its runs show here."
    }

    /// The prompt at the terminal's foot: "›", the field and Send; under it, where your words go, or why they can't.
    @ViewBuilder
    private func prompt(_ list: AgentSessionList, session: AgentSessionSummary?, shown: AgentSessionShown?) -> some View {
        let blocked = shown?.blocked ?? (session == nil && !list.chats ? "Tap + to give \(name) a card." : nil)
        let hint = shown?.hint ?? (session == nil && list.chats ? "Starts a new chat with \(name) on your Mac." : nil)
        let empty = message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .bottom, spacing: 9) {
                Text("›").font(TerminalColors.font(.body, weight: .bold)).foregroundStyle(blocked == nil ? TerminalColors.warm : TerminalColors.faint)
                    .padding(.bottom, 7)
                TextField("", text: $message, prompt: Text("Message \(name)").foregroundColor(TerminalColors.faint), axis: .vertical)
                    .font(TerminalColors.font(.subheadline))
                    .foregroundStyle(TerminalColors.ink)
                    .tint(TerminalColors.warm)
                    .lineLimit(1...6)
                    .focused($typing)
                    .disabled(blocked != nil)
                    .padding(.vertical, 7)
                    .accessibilityIdentifier("sessions.message")
                if sending {
                    ProgressView().tint(TerminalColors.muted).padding(.bottom, 6)
                } else {
                    Button { Task { await ask() } } label: {
                        Image(systemName: "arrow.up.circle.fill").font(.title2)
                            .foregroundStyle(empty || blocked != nil ? TerminalColors.faint : TerminalColors.warm)
                    }
                    .disabled(empty || blocked != nil || !connection.isConnected)
                    .accessibilityLabel("Send to \(name)")
                }
            }
            if let words = blocked ?? hint {
                Text(words)
                    .font(.caption)
                    .foregroundStyle(TerminalColors.faint)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 18)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 10)
        .background(TerminalColors.bar)
        .overlay(alignment: .top) { Rectangle().fill(TerminalColors.line).frame(height: 1) }
    }

    @ViewBuilder
    private func menu(_ session: AgentSessionSummary?) -> some View {
        Menu {
            if list?.chats == true {
                Button { starting = true; picked = nil; shown = nil; typing = true } label: { Label("New Chat", systemImage: "square.and.pencil") }
            }
            if let session, session.kind == .card {
                Button { openedCard = CardLink(id: session.id) } label: { Label("Open Card", systemImage: "rectangle.portrait") }
            }
            Button { showingCards = true } label: { Label("Its Cards", systemImage: "rectangle.stack") }
        } label: {
            Label("More", systemImage: "ellipsis.circle")
        }
        .accessibilityIdentifier("sessions.menu")
    }

    // MARK: Doing

    /// Who it is and how it's set up now, never as last seen: the first words to it as it is ask you first.
    private func ask() async {
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !sending else { return }
        sending = true
        await AgentConsents.refresh(connection)
        sending = false
        guard let agent = AgentConsents.agent(named: name, connection: connection) else {
            return problem = "\(name) isn't one your Mac talks to now. Look at it on your Mac, in Settings → Agents."
        }
        if !AgentConsents.agreed(agent) { return consenting = agent }
        send()
    }

    private func send() {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending else { return }
        let session = current
        sending = true
        let id = messageID
        Task {
            defer { sending = false }
            if let session, session.kind == .card {
                if let why = await SessionLink.send(text, card: session.id, agent: name, id: id, over: connection) {
                    // Out of reach, it stays in the box with the same id: sent again, it's one message.
                    problem = why
                    if why != ManagerLink.unreached { messageID = UUID() }
                    return
                }
            } else {
                switch await ChatLink.send(text, to: name, chat: session?.id, id: id, over: connection) {
                case .sent(let chat):
                    if session == nil {
                        starting = false
                        picked = AgentSessionSummary(kind: .chat, id: chat.id, title: chat.title, updatedAt: Date(), running: chat.status == "running",
                                                     needsYou: false, done: false)
                    }
                case .refused(let words):
                    problem = words
                    messageID = UUID()
                    return
                case .unreached:
                    problem = ManagerLink.unreached
                    return
                }
            }
            Haptics.shared.success()
            message = ""
            messageID = UUID()
            await loadList()
            await loadShown()
        }
    }

    private func stop(_ shown: AgentSessionShown) {
        Task {
            let why = shown.kind == .chat ? await ChatLink.stop(shown.id, over: connection) : await SessionLink.stop(card: shown.id, over: connection)
            if let why { problem = why } else { Haptics.shared.tap() }
            await loadShown()
        }
    }

    private func loadList() async {
        if let fresh = await SessionLink.list(agent: name, over: connection) { list = fresh }
        unreached = list == nil
    }

    private func loadShown() async {
        if list == nil { await loadList() }
        guard let session = current else { return }
        switch await SessionLink.shown(session.kind, id: session.id, agent: name, over: connection) {
        case .shown(let fresh):
            // Only for the session still showing: one on its way when you picked another is left.
            if current?.id == fresh.id {
                shown = fresh
                gone = nil
            }
        case .gone(let why):
            if current?.id == session.id { gone = why }
        case .unreached:
            break
        }
        #if DEBUG
        // For development, as the Simulator can't be typed into from a script: `-message "…"` sends that, once.
        if !Self.sentForDevelopment, connection.isConnected, let text = UserDefaults.standard.string(forKey: "message"), !text.isEmpty {
            Self.sentForDevelopment = true
            message = text
            await ask()
        }
        #endif
    }

    private static var sentForDevelopment = false
}

// MARK: - The transcript

/// A session's blocks as a terminal, in Claude Code's idiom: your words after "›", what it says after "⏺", each tool as
/// `Bash(npm test)` with what came back under "⎿" (folded after 20 lines, a tap shows the rest it was sent), an edit's
/// lines in colour, the working star while it goes, and how each turn ended. It opens on the newest and keeps to it.
private struct SessionTranscript: View {
    let shown: AgentSessionShown
    let agent: String
    let stop: () -> Void
    @State private var opened: Set<String> = []
    private typealias Term = TerminalColors

    /// Words alone in the terminal: what it is, or why a session can't show.
    static func note(_ words: String) -> some View {
        ScrollView {
            Text(words)
                .font(TerminalColors.font(.footnote))
                .foregroundStyle(TerminalColors.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
        }
    }

    var body: some View {
        ScrollViewReader { reader in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 9) {
                    if shown.earlier > 0 {
                        Text(shown.earlier == 1 ? "1 earlier step is on your Mac's Agents page." : "\(shown.earlier) earlier steps are on your Mac's Agents page.")
                            .font(Term.font(.caption2)).foregroundStyle(Term.faint)
                    }
                    if let intro = shown.intro, shown.blocks.isEmpty || shown.blocks.count <= 2 {
                        Text(intro).font(Term.font(.footnote)).foregroundStyle(Term.muted).fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(shown.blocks) { block in
                        row(block)
                    }
                    if shown.running {
                        SessionWorkingLine(current: shown.current, since: shown.since, stop: stop)
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .defaultScrollAnchor(.bottom)
            .onAppear { reader.scrollTo("end", anchor: .bottom) }
            .onChange(of: shown.id) { _, _ in reader.scrollTo("end", anchor: .bottom) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Terminal")
    }

    @ViewBuilder
    private func row(_ block: AgentTerminalBlock) -> some View {
        switch block.kind {
        case .run(let label):
            HStack(spacing: 8) {
                Text(label).font(Term.font(.caption2)).foregroundStyle(Term.faint).fixedSize()
                Rectangle().fill(Term.line).frame(height: 1)
            }
            .padding(.top, 6)
        case .you(let text):
            yours(text, id: block.id)
        case .binders(let summary, let text):
            bindersPrompt(summary: summary, text: text, id: block.id)
        case .said(let text):
            line(dot: Term.ink) { said(text) }
        case .tool(let tool):
            toolRow(tool, id: block.id)
        case .plan(let items):
            line(dot: Term.ok) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Update Todos").font(Term.font(.footnote, weight: .semibold)).foregroundStyle(Term.ink)
                    under {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                                Text((item.status == .done ? "☒ " : "☐ ") + item.text)
                                    .font(Term.font(.footnote, weight: item.status == .active ? .semibold : .regular))
                                    .foregroundStyle(item.status == .done ? Term.faint : item.status == .active ? Term.ink : Term.muted)
                                    .strikethrough(item.status == .done, color: Term.faint)
                            }
                        }
                    }
                }
            }
        case .end(let ok, let words):
            Text((ok ? "✻ " : "✗ ") + words)
                .font(Term.font(.caption))
                .foregroundStyle(ok ? Term.faint : Term.failed)
                .fixedSize(horizontal: false, vertical: true)
        case .waiting(let text, let why):
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("›").font(Term.font(.footnote, weight: .bold)).foregroundStyle(Term.faint)
                    Text(text).font(Term.font(.footnote)).foregroundStyle(Term.muted).fixedSize(horizontal: false, vertical: true)
                }
                if !why.isEmpty {
                    under { Text(why).font(Term.font(.caption)).foregroundStyle(Term.faint).italic() }
                }
            }
        }
    }

    /// Your words, on their own band: the prompt's "›" in brand warmth.
    private func yours(_ text: String, id: String) -> some View {
        let lines = text.components(separatedBy: "\n")
        let long = lines.count > 8 && !opened.contains(id)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("›").font(Term.font(.footnote, weight: .bold)).foregroundStyle(Term.warm)
                Text(long ? lines.prefix(8).joined(separator: "\n") : text)
                    .font(Term.font(.footnote))
                    .foregroundStyle(Term.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if long { more(lines.count - 8, id: id).padding(.leading, 16) }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Term.yours))
        .padding(.top, 4)
    }

    /// The words Binders started a run with, in a line; a tap shows all of them.
    private func bindersPrompt(summary: String, text: String, id: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { toggle(id) } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("›").font(Term.font(.footnote, weight: .bold)).foregroundStyle(Term.faint)
                    Text(summary).font(Term.font(.footnote)).foregroundStyle(Term.muted).multilineTextAlignment(.leading)
                    Image(systemName: opened.contains(id) ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Term.faint)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(opened.contains(id) ? "Hides Binders' instructions" : "Shows Binders' instructions for the run")
            if opened.contains(id) {
                under { Text(text).font(Term.font(.caption)).foregroundStyle(Term.faint).fixedSize(horizontal: false, vertical: true) }
            }
        }
        .padding(.top, 4)
    }

    private func said(_ text: String) -> some View {
        let attributed = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
        return Text(attributed)
            .font(Term.font(.footnote))
            .foregroundStyle(Term.ink)
            .tint(Term.warm)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func toolRow(_ tool: AgentTerminalTool, id: String) -> some View {
        let color: Color = switch tool.status {
        case .running: Term.going
        case .ok: Term.ok
        case .failed: Term.failed
        }
        return line(dot: color, blinking: tool.status == .running) {
            VStack(alignment: .leading, spacing: 3) {
                (Text(tool.name).font(Term.font(.footnote, weight: .semibold)).foregroundColor(Term.ink)
                    + Text(tool.argument.isEmpty ? "" : "(\(tool.argument))").font(Term.font(.footnote)).foregroundColor(Term.muted))
                    .fixedSize(horizontal: false, vertical: true)
                if tool.summary != nil || !tool.diff.isEmpty || !tool.output.isEmpty {
                    under {
                        VStack(alignment: .leading, spacing: 5) {
                            if let summary = tool.summary {
                                Text(summary).font(Term.font(.footnote)).foregroundStyle(Term.muted).fixedSize(horizontal: false, vertical: true)
                            }
                            if !tool.diff.isEmpty { diff(tool.diff, left: tool.diffMore, id: id + "-diff") }
                            if !tool.output.isEmpty { output(tool.output, left: tool.more, failed: tool.status == .failed, id: id) }
                        }
                    }
                }
            }
        }
    }

    /// What came back, its first lines, and "… +N lines" to see the rest it was sent; what wasn't, on the Mac.
    private func output(_ lines: [String], left: Int, failed: Bool, id: String) -> some View {
        let folded = opened.contains(id) ? (shown: lines, hidden: 0) : AgentTerminal.fold(lines)
        return VStack(alignment: .leading, spacing: 3) {
            Text(folded.shown.joined(separator: "\n"))
                .font(Term.font(.caption))
                .foregroundStyle(failed ? Term.failed : Term.muted)
                .fixedSize(horizontal: false, vertical: true)
            if folded.hidden > 0 { more(folded.hidden, id: id) } else if left > 0 { onMac(left) }
        }
    }

    /// An edit's lines: what it took out on red, what it put in on green.
    private func diff(_ lines: [String], left: Int, id: String) -> some View {
        let folded = opened.contains(id) ? (shown: lines, hidden: 0) : AgentTerminal.fold(lines)
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(folded.shown.enumerated()), id: \.offset) { _, line in
                let added = line.hasPrefix("+"), removed = line.hasPrefix("-")
                Text(line)
                    .font(Term.font(.caption))
                    .foregroundStyle(added ? Term.added : removed ? Term.removed : Term.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(added ? Term.addedGround : removed ? Term.removedGround : Color.clear)
            }
            if folded.hidden > 0 { more(folded.hidden, id: id).padding(.top, 3) } else if left > 0 { onMac(left).padding(.top, 3) }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Changes: " + lines.prefix(6).joined(separator: ", "))
    }

    private func more(_ hidden: Int, id: String) -> some View {
        Button("… +\(hidden) lines") { toggle(id) }
            .buttonStyle(.plain)
            .font(Term.font(.caption))
            .foregroundStyle(Term.faint)
            .accessibilityHint("Shows all of it")
    }

    private func onMac(_ left: Int) -> some View {
        Text("… \(left) more \(left == 1 ? "line" : "lines") on your Mac").font(Term.font(.caption)).foregroundStyle(Term.faint)
    }

    private func toggle(_ id: String) {
        if opened.contains(id) { opened.remove(id) } else { opened.insert(id) }
    }

    /// A line led by its dot, as Claude Code leads each thing it does.
    private func line<Content: View>(dot color: Color, blinking: Bool = false, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            SessionDot(color: color, blinking: blinking)
            content()
        }
    }

    /// What follows a line, after "⎿".
    private func under<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("⎿").font(Term.font(.footnote)).foregroundStyle(Term.faint)
            content()
        }
        .padding(.leading, 2)
    }
}

/// "⏺", in the colour of how it went; going, it pulses.
private struct SessionDot: View {
    let color: Color
    let blinking: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// "⏺" as text: iOS draws it as an emoji without the text selector.
    static let glyph = "\u{23FA}\u{FE0E}"

    var body: some View {
        if blinking, !reduceMotion {
            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                Text(Self.glyph).font(TerminalColors.font(.footnote))
                    .foregroundStyle(color.opacity(Int(context.date.timeIntervalSinceReferenceDate * 2).isMultiple(of: 2) ? 1 : 0.35))
            }
        } else {
            Text(Self.glyph).font(TerminalColors.font(.footnote)).foregroundStyle(color)
        }
    }
}

/// While it works: the turning star, what it's on, for how long, and Stop.
private struct SessionWorkingLine: View {
    let current: String?
    let since: Date?
    let stop: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let frames = ["·", "✢", "✳", "✶", "✻", "✽", "✻", "✶", "✳", "✢"]

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            TimelineView(.periodic(from: .now, by: reduceMotion ? 1 : 0.12)) { context in
                let tick = Int(context.date.timeIntervalSinceReferenceDate / 0.12)
                let elapsed = since.map { " (" + AgentTerminal.duration(max(0, context.date.timeIntervalSince($0))) + ")" } ?? ""
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(reduceMotion ? "✻" : Self.frames[tick % Self.frames.count]).font(TerminalColors.font(.footnote, weight: .bold))
                        .foregroundStyle(TerminalColors.warm)
                        .frame(width: 12)
                    Text(((current?.isEmpty == false ? current : nil) ?? "Working") + "…").font(TerminalColors.font(.footnote)).foregroundStyle(TerminalColors.warm)
                        + Text(elapsed).font(TerminalColors.font(.footnote)).foregroundColor(TerminalColors.faint)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Working: \(current ?? "")")
            Spacer(minLength: 6)
            Button("Stop", action: stop)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(TerminalColors.ink)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(TerminalColors.yours))
                .overlay(Capsule().strokeBorder(TerminalColors.line))
                .accessibilityHint("Stops this run. What you write next carries on its session.")
        }
        .padding(.top, 4)
    }
}

/// The terminal's colours, the Mac's Agents page's: dark in either appearance.
enum TerminalColors {
    static let ground = Color(rgb: 0x111114)
    static let bar = Color(rgb: 0x17171B)
    static let edge = Color.white.opacity(0.10)
    static let ink = Color(rgb: 0xE8E8EC)
    static let muted = Color(rgb: 0xA0A0A9)
    static let faint = Color(rgb: 0x6B6B74)
    static let line = Color.white.opacity(0.08)
    static let yours = Color.white.opacity(0.05)
    static let warm = Color(rgb: 0xE8875B)
    static let ok = Color(rgb: 0x4ADE80)
    static let failed = Color(rgb: 0xF87171)
    static let going = Color(rgb: 0xF5A524)
    static let added = Color(rgb: 0x9BE9B4)
    static let addedGround = Color(rgb: 0x163322)
    static let removed = Color(rgb: 0xFDB0B0)
    static let removedGround = Color(rgb: 0x3C1A1D)

    /// The code face, at a text style so it follows the reader's text size.
    static func font(_ style: Font.TextStyle, weight: Font.Weight = .regular) -> Font { .system(style, design: .monospaced).weight(weight) }
}
