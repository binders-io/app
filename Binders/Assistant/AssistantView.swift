import SwiftUI
import BindersKit

/// A binder's Assistant tab: a conversation with the language model about this binder alone. It reads the binder's
/// meetings, captures, notes and board to answer, says what it's reading as it goes, and lists what the answer drew on.
struct AssistantView: View {
    let binder: BinderRecord
    @Environment(KnowledgeService.self) private var knowledge
    @Environment(AppSettings.self) private var settings
    @State private var question = ""
    @FocusState private var focused: Bool
    private var assistant: AssistantService { .shared }

    private static let suggestions = [
        "Summarize what's happened in this binder so far",
        "What have we decided, and when?",
        "What's still open, and who owns it?",
        "Make a timeline of the meetings",
    ]

    var body: some View {
        let conversation = assistant.conversation(binder.id)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                PageHeader(title: "Assistant",
                           subtitle: "Ask anything about this binder. It reads the meetings, captures, notes and board here to answer, and changes nothing.")
                Spacer()
                if !conversation.messages.isEmpty {
                    Button("New Conversation") {
                        assistant.clear(binder.id)
                        focused = true
                    }
                    .help("Start over: this conversation is forgotten")
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 18)
            .padding(.bottom, 12)
            ScrollViewReader { scroller in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if conversation.messages.isEmpty { suggestions }
                        ForEach(conversation.messages) { message in
                            row(message, conversation: conversation).id(message.id)
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .frame(maxWidth: 760, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: conversation.messages.last?.text) { scroller.scrollTo("end", anchor: .bottom) }
                .onChange(of: conversation.messages.count) { withAnimation { scroller.scrollTo("end", anchor: .bottom) } }
                .onChange(of: conversation.steps.count) { scroller.scrollTo("end", anchor: .bottom) }
            }
            Divider()
            composer(conversation)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
        }
        .onAppear { focused = true }
    }

    private var suggestions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Try asking").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(Self.suggestions, id: \.self) { suggestion in
                Button {
                    send(suggestion)
                } label: {
                    Label(suggestion, systemImage: BindersTheme.askSymbol)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(BindersTheme.surface))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(BindersTheme.line))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 8)
    }

    @ViewBuilder
    private func row(_ message: AssistantService.Message, conversation: AssistantService.Conversation) -> some View {
        switch message.role {
        case .user:
            Text(message.text)
                .font(.body.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .assistant:
            let working = conversation.isRunning && message.id == conversation.messages.last?.id
            VStack(alignment: .leading, spacing: 10) {
                if working, !conversation.steps.isEmpty || message.text.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(conversation.steps.enumerated()), id: \.offset) { _, step in
                            Label(step, systemImage: "checkmark").font(.caption).foregroundStyle(.secondary)
                        }
                        if let activity = conversation.activity {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.mini)
                                Text(activity).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if !message.text.isEmpty {
                    if message.failed {
                        Text(message.text).foregroundStyle(.secondary).textSelection(.enabled)
                    } else {
                        MarkdownBlocks(markdown: message.text)
                    }
                }
                if !message.sources.isEmpty { sources(message.sources) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func sources(_ sources: [BinderAssistant.Source]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("From").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(sources, id: \.self) { source in
                Button {
                    KnowledgeNavigator.openSource(kind: Self.kind(source.kind), sourceID: source.id)
                } label: {
                    Label(source.title.isEmpty ? "Untitled" : source.title, systemImage: Self.kind(source.kind).symbol)
                        .font(.callout)
                }
                .buttonStyle(.link)
            }
        }
    }

    private static func kind(_ shown: String) -> KnowledgeKind {
        switch shown {
        case "capture": .conversation
        case "note": .note
        default: .meeting
        }
    }

    private func composer(_ conversation: AssistantService.Conversation) -> some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Ask about this binder…", text: $question, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .focused($focused)
                .onSubmit { send(question) }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(BindersTheme.surface))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(BindersTheme.line))
            if conversation.isRunning {
                Button("Stop") { assistant.stop(binder.id) }
                    .keyboardShortcut(".", modifiers: .command)
            } else {
                Button {
                    send(question)
                } label: {
                    Label("Ask", systemImage: BindersTheme.askSymbol)
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func send(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !assistant.conversation(binder.id).isRunning else { return }
        assistant.ask(text, binder: binder, knowledge: knowledge, settings: settings)
        question = ""
    }
}
