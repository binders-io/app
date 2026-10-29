import SwiftUI
import BindersKit

/// The Manager on the Agents page (lanes MG1, MG2), as a conversation: what you asked, oldest first, and what it said and
/// changed under each, with Stop, Undo and Reply; the note edits it suggests to accept or dismiss; and a box to ask it
/// something or have it tidy.
struct ManagerChat: View {
    @Environment(HubNavigation.self) private var navigation
    @Environment(DictationController.self) private var controller
    @State private var asking = ""
    /// The request whose conversation the next message goes on, when you chose Reply on one.
    @State private var thread: UUID?
    @State private var reviewing: NoteEditSuggestion?
    @State private var said: String?

    /// How many of its requests show, the latest.
    static let shown = 40

    var body: some View {
        let manager = controller.manager
        let requests = Array(manager.requests.suffix(Self.shown))
        VStack(spacing: 0) {
            header(manager)
            Divider()
            ScrollViewReader { reader in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if requests.isEmpty {
                            Text(manager.agent == nil
                                 ? "Give an agent the Manager's role in Settings → Agents: Claude Code, or a local model."
                                 : "Ask it what's on your plate, what an agent is doing, or to tidy a binder. It answers here, and every change it makes can be undone.")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        ForEach(requests) { request in
                            exchange(request, manager: manager).id(request.id)
                        }
                    }
                    .frame(maxWidth: AgentsLayout.readingWidth, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    .padding(20)
                }
                .onAppear { if let last = requests.last { reader.scrollTo(last.id, anchor: .bottom) } }
                .onChange(of: requests.last?.id) { _, last in
                    if let last { withAnimation { reader.scrollTo(last, anchor: .bottom) } }
                }
                .onChange(of: requests.last?.reply) { _, _ in
                    if let last = requests.last { withAnimation { reader.scrollTo(last.id, anchor: .bottom) } }
                }
            }
            Divider()
            footer(manager)
        }
        .fitProbe("manager.panel")
        .sheet(item: $reviewing) { suggestion in
            SuggestionReview(suggestion: suggestion) { accepted in
                if accepted {
                    switch manager.accept(suggestion.id) {
                    case .success(let message): said = message
                    case .failure(let failure): said = failure.why
                    }
                } else {
                    manager.dismiss(suggestion.id)
                }
                reviewing = nil
            }
        }
    }

    private func header(_ manager: ManagerService) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("The Manager").font(BindersTheme.title(24))
                Text(manager.agent.map { "\($0.name) · \(AgentsSections.describe($0.wake))" } ?? "No agent has the role yet")
                    .font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Picker("Tidy on a schedule", selection: Binding(get: { manager.schedule }, set: { manager.schedule = $0 })) {
                Text("Tidy only when asked").tag(ManagerSchedule.off)
                Text("Tidy every day").tag(ManagerSchedule.daily)
                Text("Tidy every week").tag(ManagerSchedule.weekly)
            }
            .labelsHidden()
            .fixedSize()
            .help("A scheduled tidy runs only while this Mac is plugged in and idle, and every change it makes can be undone.")
            .disabled(manager.agent == nil)
            Button("Settings…") {
                navigation.pendingSettingsPage = .agents
                navigation.selection = .settings
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func footer(_ manager: ManagerService) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(manager.waitingSuggestions) { suggestion in
                HStack(alignment: .firstTextBaseline) {
                    StatusLabel("Suggests an edit to “\(suggestion.noteTitle)”", .needsYou, symbol: "pencil.and.list.clipboard")
                    Spacer()
                    Button("Review…") { reviewing = suggestion }
                }
            }
            if let said { Text(said).font(.callout).foregroundStyle(.secondary) }
            if let problem = manager.problem {
                StatusLabel(problem, manager.agent == nil ? .waiting : .needsYou)
            } else {
                if let thread, let request = manager.request(thread) {
                    HStack {
                        Text("Replying to “\(request.text)”").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Button("Cancel") { self.thread = nil }.buttonStyle(.link).font(.caption)
                    }
                }
                HStack(alignment: .bottom, spacing: 8) {
                    TextField(thread == nil ? "Ask the Manager, or tell it what to tidy" : "Reply to the Manager", text: $asking, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...6)
                        .onSubmit { send(manager) }
                        .fitProbe("manager.ask")
                    Button("Ask") { send(manager) }
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(asking.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Menu("Tidy") {
                        Button("Every Binder") { manager.tidy(binder: nil, from: .mac) }
                        Divider()
                        ForEach(Store.shared.binders()) { binder in
                            Button(binder.name) { manager.tidy(binder: binder.id, from: .mac) }
                        }
                    }
                    .fixedSize()
                }
            }
        }
        .frame(maxWidth: AgentsLayout.readingWidth, alignment: .leading)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private func send(_ manager: ManagerService) {
        let text = asking.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        manager.ask(text, thread: thread, from: .mac)
        asking = ""
        thread = nil
        said = nil
    }

    /// One request: yours on the right, its answer on the left, as a conversation reads.
    private func exchange(_ request: ManagerRequest, manager: ManagerService) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .trailing, spacing: 3) {
                Text(request.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(BindersTheme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 12))
                Text("\(request.at.formatted(date: .abbreviated, time: .shortened)) · \(Self.from(request.from))")
                    .font(BindersTheme.time()).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.leading, 60)
            VStack(alignment: .leading, spacing: 6) {
                switch request.status {
                case .waiting: StatusLabel("Waiting for the Manager", .waiting)
                case .running:
                    Label {
                        Text("\(request.agent ?? "The Manager") is on it")
                    } icon: {
                        ProgressView().controlSize(.small)
                    }
                case .failed: StatusLabel(request.why ?? "It didn't finish.", .problem)
                case .stopped: StatusLabel(request.why ?? "Stopped.", .waiting)
                case .answered: EmptyView()
                }
                if let reply = request.reply {
                    // The Manager's words: shown as its, never as yours.
                    ChatMarkdownView(markdown: reply)
                        .padding(.horizontal, 12).padding(.vertical, 9)
                        .background(BindersTheme.agent.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
                }
                if !request.changes.isEmpty {
                    DisclosureGroup("\(request.changes.count) change\(request.changes.count == 1 ? "" : "s")\(request.undoneAt != nil ? ", undone" : "")") {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(Array(request.changes.enumerated()), id: \.offset) { _, change in
                                Text("• " + change.line).font(.callout).foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.callout)
                }
                HStack {
                    if !request.isOver {
                        Button("Stop") { manager.stop(request.id) }
                    }
                    // Once it's over: a run still going would go on changing what Undo can't put back.
                    if request.isOver, !request.undoable.isEmpty {
                        Button("Undo Its Changes") { said = manager.undo(request.id) }
                    }
                    if request.status == .answered {
                        Button("Reply") { thread = request.id }
                    }
                    if request.status == .failed {
                        Button("Ask Again") { manager.again(request.id) }
                        if let log = manager.log(of: request.id) {
                            Button("Show Its Log") { NSWorkspace.shared.activateFileViewerSelecting([log]) }
                                .help("What Claude Code printed for this request, in Finder")
                        }
                    }
                }
                .controlSize(.small)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 60)
        }
    }

    static func from(_ from: ManagerRequest.From) -> String {
        switch from {
        case .mac: "on this Mac"
        case .iphone: "from your iPhone"
        case .schedule: "on its schedule"
        }
    }
}

/// A suggested note edit, line by line, to accept as your own edit or dismiss.
struct SuggestionReview: View {
    let suggestion: NoteEditSuggestion
    let decide: (Bool) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let current = Store.shared.note(suggestion.note)?.text
        let updated: String? = current.flatMap { if case .success(let text) = suggestion.applied(to: $0) { text } else { nil } }
        VStack(alignment: .leading, spacing: 12) {
            Text("“\(suggestion.noteTitle)”").font(BindersTheme.cardTitle)
            Text("\(suggestion.agent) suggests: \(suggestion.why)").foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if let current, let updated {
                        ForEach(Array(NoteVersions.lines(from: current, to: updated).enumerated()), id: \.offset) { _, line in
                            switch line {
                            case .added(let words): Text("+ " + words).foregroundStyle(.green)
                            case .removed(let words): Text("- " + words).foregroundStyle(.red)
                            case .same(let words): Text("  " + words).foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        StatusLabel("The note changed since, so this suggestion doesn't fit it any more.", .problem)
                    }
                }
                .font(.system(.callout, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            }
            .frame(minHeight: 200)
            HStack {
                Text("Accepted, it's your edit: the earlier version stays in the note's history.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Dismiss") { decide(false) }
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Accept") { decide(true) }.keyboardShortcut(.defaultAction).disabled(updated == nil)
            }
        }
        .padding(18)
        .frame(width: 620, height: 480)
        .pageGround()
    }
}
