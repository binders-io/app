import SwiftUI
import BindersKit

/// A reply's Markdown, as a chat shows it (`ChatMarkdown`): paragraphs, headings, bullets and numbered items, fenced code
/// and quotes, with bold, italics, inline code and links within them.
struct ChatMarkdownText: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(ChatMarkdown.blocks(markdown).enumerated()), id: \.offset) { _, block in
                view(block)
            }
        }
        .foregroundStyle(Palette.ink)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func view(_ block: ChatMarkdown.Block) -> some View {
        switch block {
        case .paragraph(let text):
            inline(text)
        case .heading(let level, let text):
            inline(text).font(level <= 1 ? .title3.weight(.bold) : .headline).padding(.top, 2)
        case .bullet(let depth, let text):
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text("•").foregroundStyle(Palette.muted)
                inline(text)
            }
            .padding(.leading, CGFloat(depth) * 14)
        case .numbered(let depth, let number, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(number).foregroundStyle(Palette.muted).monospacedDigit()
                inline(text)
            }
            .padding(.leading, CGFloat(depth) * 14)
        case .code(let code):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code).font(.system(.footnote, design: .monospaced)).fixedSize()
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.surface.opacity(0.8), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        case .quote(let text):
            HStack(spacing: 8) {
                Rectangle().fill(Palette.line).frame(width: 3)
                inline(text).foregroundStyle(Palette.muted)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .rule:
            Divider()
        }
    }

    private func inline(_ text: String) -> some View {
        let attributed = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
        return Text(attributed).tint(Palette.accentText).fixedSize(horizontal: false, vertical: true)
    }
}

/// A chat with one of your agents (lane AC1), as on the Mac: your messages on the right, its replies on the left, what
/// it's writing while it works, and the box to write in. It opens on your latest chat with it; the menu starts a new one,
/// goes back to an earlier one, or shows its cards. The first time anything goes to an agent as it's set up now, Binders
/// asks you first (App Store 5.1.2(i)).
struct ChatThreadView: View {
    @Environment(MacConnection.self) private var connection
    let agent: String
    @State private var chatID: String?
    /// Whether the latest chat was looked for, so a new one isn't made while the list is on its way.
    @State private var looked = false
    @State private var chat: ChatLink.Chat?
    @State private var chats: [ChatLink.Chat] = []
    @State private var message = ""
    /// This message's own id: sent again after the Mac didn't answer, it's the same message.
    @State private var messageID = UUID()
    @State private var sending = false
    @State private var problem: String?
    @State private var consenting: AgentList.Agent?
    @State private var showingCards = false
    @State private var unreached = false
    @FocusState private var typing: Bool

    var body: some View {
        ScrollViewReader { reader in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if let chat {
                        ForEach(chat.messages ?? []) { bubble($0).id($0.id) }
                        if chat.status == "running" {
                            working(chat.live).id("live")
                        } else if chat.status == "waiting" {
                            Label("Waiting for \(agent) to check the board and read it", systemImage: "clock")
                                .labelStyle(StateLabelStyle()).font(.subheadline).foregroundStyle(Palette.muted)
                        }
                        if let why = chat.why { ProblemLabel(why) }
                    } else if looked {
                        Text("Write to \(agent). It answers here, as it would on your Mac's Agents page.")
                            .font(.callout).foregroundStyle(Palette.muted)
                    } else if unreached {
                        WaitingForMac(what: "Your chat with \(agent) shows here") { await load() }
                    } else {
                        ProgressView().frame(maxWidth: .infinity)
                    }
                }
                .padding()
            }
            .onAppear { scroll(reader) }
            .onChange(of: chat?.messages?.count) { _, _ in withAnimation { scroll(reader) } }
            .onChange(of: chat?.live) { _, _ in scroll(reader) }
        }
        .screenGround()
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle(chat?.title ?? agent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { startNew() } label: { Label("New Chat", systemImage: "square.and.pencil") }
                        .disabled(chatID == nil)
                    if chats.count > 1 || (chats.count == 1 && chats.first?.id != chatID) {
                        Section("Chats with \(agent)") {
                            ForEach(chats.prefix(12)) { other in
                                Button { open(other.id) } label: {
                                    if other.id == chatID { Label(other.title, systemImage: "checkmark") } else { Text(other.title) }
                                }
                            }
                        }
                    }
                    Button { showingCards = true } label: { Label("Its Cards", systemImage: "rectangle.stack") }
                } label: {
                    Label("Chats", systemImage: "ellipsis.bubble")
                }
                .accessibilityIdentifier("chat.menu")
            }
        }
        .navigationDestination(isPresented: $showingCards) { AgentCardsView(name: agent) }
        .safeAreaInset(edge: .bottom) { if looked { composer } }
        .task(id: connection.revision("chats")) { await load() }
        .refreshable { await load() }
        .onChange(of: message) { _, _ in messageID = UUID() }
        .problemToast($problem)
        // The first message to it, as it's set up now: where it goes, and what goes with it (App Store 5.1.2(i)).
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

    private func scroll(_ reader: ScrollViewProxy) {
        if chat?.status == "running" { reader.scrollTo("live", anchor: .bottom) } else if let last = chat?.messages?.last { reader.scrollTo(last.id, anchor: .bottom) }
    }

    private func bubble(_ message: ChatLink.Message) -> some View {
        Group {
            if message.isYours {
                VStack(alignment: .trailing, spacing: 3) {
                    Text(message.text)
                        .foregroundStyle(Palette.ink)
                        .textSelection(.enabled)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(Palette.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    if let date = message.date {
                        Text(date.formatted(date: .abbreviated, time: .shortened)).font(Typeface.time(.caption2)).foregroundStyle(Palette.muted)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.leading, 40)
            } else {
                // Its words: shown as its, never as yours.
                VStack(alignment: .leading, spacing: 4) {
                    Label(agent, systemImage: "sparkles").labelStyle(StateLabelStyle())
                        .font(.caption.weight(.semibold)).foregroundStyle(Palette.agent)
                    ChatMarkdownText(markdown: message.text)
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(Palette.agent.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 24)
            }
        }
    }

    private func working(_ said: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                AgentStatusText(words: "\(agent) is answering", tone: .working)
                Spacer()
                Button("Stop") {
                    guard let id = chatID else { return }
                    Task { if let why = await ChatLink.stop(id, over: connection) { problem = why } }
                }
                .font(.subheadline.weight(.medium))
                .tint(Palette.accentText)
            }
            if let said, !said.isEmpty {
                ChatMarkdownText(markdown: said)
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(Palette.agent.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .opacity(0.85)
            }
        }
    }

    /// The box to write in. It floats over the chat: from iOS 26 a glass capsule of its own, before that on the bar
    /// material across the foot of the screen.
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
            TextField(chatID == nil ? "Message \(agent)" : "Reply to \(agent)", text: $message, axis: .vertical)
                .lineLimit(1...5)
                .focused($typing)
                .padding(.horizontal, field == nil ? 0 : 12)
                .padding(.vertical, 8)
                .background { if let field { RoundedRectangle(cornerRadius: 18, style: .continuous).fill(field) } }
                .accessibilityIdentifier("chat.message")
            if sending {
                ProgressView().padding(.bottom, 6)
            } else {
                Button { Task { await ask() } } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.title)
                }
                .disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !connection.isConnected)
                .accessibilityLabel("Send to \(agent)")
            }
        }
    }

    // MARK: Doing

    private func startNew() {
        chatID = nil
        chat = nil
        typing = true
    }

    private func open(_ id: String) {
        chatID = id
        chat = chats.first { $0.id == id }
        Task { await load() }
    }

    /// Who it is and how it's set up now, never as last seen: the first message to it as it is asks you first.
    private func ask() async {
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !sending else { return }
        sending = true
        await AgentConsents.refresh(connection)
        sending = false
        guard let agent = AgentConsents.agent(named: self.agent, connection: connection) else {
            return problem = "\(self.agent) isn't one your Mac talks to now. Look at it on your Mac, in Settings → Agents."
        }
        if !AgentConsents.agreed(agent) { return consenting = agent }
        send()
    }

    private func send() {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending else { return }
        sending = true
        let id = messageID
        Task {
            defer { sending = false }
            switch await ChatLink.send(text, to: agent, chat: chatID, id: id, over: connection) {
            case .sent(let sent):
                Haptics.shared.success()
                message = ""
                typing = false
                chatID = sent.id
                chat = sent
                messageID = UUID()
                if let list = await ChatLink.list(agent: agent, over: connection) { chats = list }
            case .refused(let words):
                problem = words
                messageID = UUID()
            case .unreached:
                // Kept in the box, with the same id: sent again, it's one message.
                problem = ManagerLink.unreached
            }
        }
    }

    private func load() async {
        if let list = await ChatLink.list(agent: agent, over: connection) {
            chats = list
            // Opened: the latest chat, unless you chose another or a new one.
            if !looked, chatID == nil { chatID = list.first?.id }
            looked = true
        }
        // Only for the chat still shown: a load that was on its way when you picked another, or New Chat, is left.
        if let asked = chatID, let fresh = await ChatLink.chat(asked, over: connection), chatID == asked, fresh.id == asked { chat = fresh }
        unreached = !looked
        #if DEBUG
        // For development, as the Simulator can't be typed into from a script: `-message "…"` sends that, once.
        if !Self.sentForDevelopment, looked, connection.isConnected, let text = UserDefaults.standard.string(forKey: "message"), !text.isEmpty {
            Self.sentForDevelopment = true
            message = text
            await ask()
        }
        #endif
    }

    private static var sentForDevelopment = false
}
