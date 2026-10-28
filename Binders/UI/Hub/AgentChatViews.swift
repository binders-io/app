import SwiftUI
import BindersKit

/// A reply's Markdown, as a chat shows it (`ChatMarkdown`): paragraphs, headings, bullets and numbered items, fenced code
/// and quotes, with bold, italics, inline code and links within them.
struct ChatMarkdownView: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(ChatMarkdown.blocks(markdown).enumerated()), id: \.offset) { _, block in
                view(block)
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func view(_ block: ChatMarkdown.Block) -> some View {
        switch block {
        case .paragraph(let text):
            inline(text)
        case .heading(let level, let text):
            inline(text).font(level <= 1 ? .title3.weight(.bold) : level == 2 ? .headline : .subheadline.weight(.semibold))
                .padding(.top, 2)
        case .bullet(let depth, let text):
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text("•").foregroundStyle(.secondary)
                inline(text)
            }
            .padding(.leading, CGFloat(depth) * 16)
        case .numbered(let depth, let number, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(number).foregroundStyle(.secondary).monospacedDigit()
                inline(text)
            }
            .padding(.leading, CGFloat(depth) * 16)
        case .code(let code):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code).font(.system(.callout, design: .monospaced)).fixedSize()
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(BindersTheme.surface.opacity(0.7), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        case .quote(let text):
            HStack(spacing: 8) {
                Rectangle().fill(BindersTheme.lineStrong).frame(width: 3)
                inline(text).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .rule:
            Divider()
        }
    }

    private func inline(_ text: String) -> some View {
        let attributed = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
        return Text(attributed).fixedSize(horizontal: false, vertical: true)
    }
}

/// A chat with one agent (lane AC1): your messages on the right, its replies on the left as Markdown, what it's writing
/// now while it works, and the box to write in. With no chat picked, the box starts a new one.
struct AgentChatPanel: View {
    @Environment(DictationController.self) private var controller
    let agent: String
    let chatID: UUID?
    /// A new chat was started, or New Chat was chosen (nil): the page picks it.
    let picked: (UUID?) -> Void
    @State private var message = ""
    @State private var problem: String?

    var body: some View {
        let service = controller.chats
        let chat = chatID.flatMap(service.chat)
        let profile = service.agent(named: agent)
        VStack(spacing: 0) {
            header(chat, profile: profile)
            Divider()
            ScrollViewReader { reader in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if let chat {
                            ForEach(chat.messages) { bubble($0).id($0.id) }
                            if chat.status == .running {
                                working(service.live[chat.id]).id("live")
                            } else if chat.status == .waiting {
                                Label("Waiting for \(agent) to check the board and read it", systemImage: "clock")
                                    .font(.callout).foregroundStyle(.secondary)
                            }
                            if let why = chat.why {
                                StatusLabel(why, .problem).font(.callout)
                            }
                        } else {
                            Text(Self.intro(agent, profile: profile))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .frame(maxWidth: AgentsLayout.readingWidth, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    .padding(20)
                }
                .onAppear { scroll(reader, chat) }
                .onChange(of: chat?.messages.count) { _, _ in withAnimation { scroll(reader, chat) } }
                .onChange(of: service.live[chatID ?? UUID()]) { _, _ in scroll(reader, chat) }
            }
            Divider()
            composer(chat, profile: profile)
        }
    }

    static func intro(_ agent: String, profile: AgentProfile?) -> String {
        guard let profile else { return "\(agent) can't chat now. Look at it in Settings → Agents." }
        if profile.wake == .board {
            return "Write to \(agent). It reads your messages when it next checks the board, and answers here."
        }
        return "Write to \(agent). Binders starts it in a worktree of its own for this chat, with the permissions its cards have, and it answers here. Each message carries the same session on."
    }

    private func scroll(_ reader: ScrollViewProxy, _ chat: AgentChat?) {
        if chat?.status == .running { reader.scrollTo("live", anchor: .bottom) } else if let last = chat?.messages.last { reader.scrollTo(last.id, anchor: .bottom) }
    }

    private func header(_ chat: AgentChat?, profile: AgentProfile?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(chat?.title ?? agent).font(BindersTheme.title(22)).lineLimit(1)
                Text([chat == nil ? nil : agent, profile.map { AgentsSections.describe($0.wake) }].compactMap { $0 }.joined(separator: " · "))
                    .font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if let chat, chat.status == .running {
                Button("Stop") { controller.chats.stop(chat.id) }
            }
            if chat != nil {
                Button("New Chat") { picked(nil) }
                    .help("Start another chat with \(agent)")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private func bubble(_ message: AgentChatMessage) -> some View {
        Group {
            if message.from == .you {
                VStack(alignment: .trailing, spacing: 3) {
                    Text(message.text)
                        .textSelection(.enabled)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(BindersTheme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 12))
                    Text([message.at.formatted(date: .abbreviated, time: .shortened), message.via == "iphone" ? "from your iPhone" : nil]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(BindersTheme.time()).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.leading, 60)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Label(agent, systemImage: BindersTheme.agentSymbol).font(.caption.weight(.semibold)).foregroundStyle(BindersTheme.agent)
                    ChatMarkdownView(markdown: message.text)
                        .padding(.horizontal, 12).padding(.vertical, 9)
                        .background(BindersTheme.agent.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
                    Text(message.at.formatted(date: .omitted, time: .shortened)).font(BindersTheme.time()).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 60)
            }
        }
    }

    private func working(_ said: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                StatusLabel("\(agent) is answering", .live).font(.callout)
            }
            if let said, !said.isEmpty {
                ChatMarkdownView(markdown: said)
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(BindersTheme.agent.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                    .opacity(0.85)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.trailing, 60)
    }

    private func composer(_ chat: AgentChat?, profile: AgentProfile?) -> some View {
        let blocked = profile.flatMap { controller.chats.problem(with: $0) }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .bottom, spacing: 8) {
                TextField(chat == nil ? "Message \(agent)" : "Reply to \(agent)", text: $message, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...8)
                    .onSubmit(send)
                    .fitProbe("agents.chat.message")
                Button("Send", action: send)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || profile == nil || blocked != nil)
            }
            if let problem {
                StatusLabel(problem, .problem).font(.callout)
            } else if let blocked {
                StatusLabel(blocked, .waiting).font(.callout)
            } else if chat?.status == .running {
                Text("What you write now goes to \(agent) when it's done answering.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: AgentsLayout.readingWidth, alignment: .leading)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private func send() {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        problem = nil
        switch controller.chats.send(text, to: agent, chat: chatID, via: "mac") {
        case .success(let chat):
            message = ""
            if chat.id != chatID { picked(chat.id) }
        case .failure(let failure):
            problem = failure.why
        }
    }
}
