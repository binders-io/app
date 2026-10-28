import SwiftUI
import BindersKit

// Choosing the Manager (lanes MG1, MG2): in Settings → Agents, one place that says which agent has the role and gives it to
// another, Claude Code or a local model; and the sheet for a local model, which takes no cards, only the role.

extension AppSettings {
    /// Where Distill's model runs: its own source, or the language model's provider.
    private var managerSource: DistillModelSource {
        if distillHasOwnModel { return distillModelSource }
        switch llmProvider {
        case .ollama: return .ollama
        case .mlx: return .mlx
        case .openAICompatible: return .server
        }
    }

    /// The local Manager's model (lane MG2): Distill's, or the model named on the same server. Nil when Settings → AI has
    /// none to give.
    func makeManagerClient(_ wake: LocalModelWake, lane: ModelLane.Priority = .now) -> LLMClient? {
        guard let model = wake.namedModel else { return makeDistillClient(lane: lane) }
        let source = managerSource
        let client: LLMClient?
        switch source {
        case .mlx:
            client = MLXModels.isSupported ? MLXClient(model: model, idleMinutes: modelIdleMinutes) : nil
        case .ollama:
            client = URL(string: ollamaURL).map { OllamaClient(baseURL: $0, model: model, keepAliveSeconds: modelIdleMinutes <= 0 ? -1 : modelIdleMinutes * 60) }
        case .server, .same:
            client = URL(string: openAIBaseURL).map { OpenAICompatibleClient(baseURL: $0, model: model, apiKey: openAIKey.isEmpty ? nil : openAIKey) }
        }
        return client.map { LanedClient(inner: $0, lane: lane, interrupts: source == .ollama) }
    }

    /// Where the local Manager's model runs, in words: "Ollama", "Binders (MLX)", "the server in Settings → AI".
    var managerPlace: String {
        switch managerSource {
        case .mlx: "Binders, on this Mac"
        case .ollama: "Ollama"
        case .server, .same: "the server in Settings → AI"
        }
    }
}

extension AgentProfile {
    /// It can have the Manager's role: Claude Code, or a local model.
    var canManage: Bool {
        switch wake {
        case .claudeCode, .localModel: true
        default: false
        }
    }
}

/// What the Manager is told it may do, in the turn-on alert, for the agent about to get the role.
@MainActor
enum ManagerWords {
    static func alert(for agent: AgentProfile) -> String {
        let starts: String
        if case .localModel(let wake) = agent.wake {
            let model = wake.namedModel ?? AppSettings.shared.distillModelName
            starts = "Binders runs \(model.isEmpty ? "your local model" : model) in \(AppSettings.shared.managerPlace) with Binders' tools alone, one step at a time."
        } else {
            starts = "Binders starts Claude Code with Binders' tools alone."
        }
        return "When you ask the Manager something, or ask it to tidy, \(starts) It manages your binders for you: it reads across them, and changes what you could. It makes, edits, moves, gives, closes, merges and deletes cards (giving one to an agent starts it), places or puts aside what Distill proposed, writes, changes and deletes notes (not the team's), and makes, renames and archives folders and binders. Everything it changes for a request can be undone at once. Captures, transcripts and teammates' items stay out unless Settings → MCP lets it read them."
    }
}

/// Settings → Agents → The Manager: which agent has the role, and giving it to another.
struct ManagerSettingsSection: View {
    @State private var registry = AgentRegistry.shared
    @Binding var editing: AgentProfile?
    @State private var asking: AgentProfile?
    @State private var problem: String?

    private var candidates: [AgentProfile] {
        registry.agents.filter { $0.canManage && !registry.changedOutside.contains($0.id) }
    }

    var body: some View {
        Section {
            Picker("The Manager", selection: Binding(get: { registry.manager?.id }, set: { choose($0) })) {
                Text("None").tag(UUID?.none)
                ForEach(candidates) { agent in
                    Text(agent.name + (Self.kindWords(agent).map { " (\($0))" } ?? "")).tag(UUID?.some(agent.id))
                }
            }
            .fitProbe("agents.manager-pick")
            if !registry.agents.contains(where: { if case .localModel = $0.wake { true } else { false } }) {
                Button("Add a Local Model as the Manager…") {
                    editing = AgentProfile(name: "Manager", wake: .localModel(LocalModelWake()), manager: true)
                }
            }
            if let problem { StatusLabel(problem, .problem) }
        } header: {
            Text("The Manager")
        } footer: {
            Text("The Manager tidies your boards and folders, distills notes and answers what you ask it on the Agents page, with Binders' tools alone and an Undo for each request. Claude Code or a local model can have the role, one at a time. A local model uses the model Distill uses in Settings → AI, or another you name on the same server, and takes no cards.")
        }
        .alert("Make \(asking?.name ?? "this agent") the Manager?", isPresented: Binding(get: { asking != nil }, set: { if !$0 { asking = nil } }),
               presenting: asking) { agent in
            Button("Make It the Manager") { give(agent) }
            Button("Cancel", role: .cancel) {}
        } message: { agent in
            Text(ManagerWords.alert(for: agent) + (registry.manager.map { $0.id == agent.id ? "" : " \($0.name) stops being the Manager." } ?? ""))
        }
    }

    static func kindWords(_ agent: AgentProfile) -> String? {
        switch agent.wake {
        case .claudeCode: "Claude Code"
        case .localModel: "local model"
        default: nil
        }
    }

    private func choose(_ id: UUID?) {
        problem = nil
        guard let id else {
            guard var current = registry.manager else { return }
            current.manager = nil
            problem = registry.upsert(current, isManager: false)
            return
        }
        guard id != registry.manager?.id, let agent = candidates.first(where: { $0.id == id }) else { return }
        asking = agent
    }

    private func give(_ agent: AgentProfile) {
        var agent = agent
        agent.manager = true
        problem = registry.upsert(agent, isManager: true)
    }
}

/// A local model as the Manager (lane MG2): its name, the model, and the role. It takes no cards.
struct LocalManagerEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: AgentProfile
    @State private var model: String
    @State private var isManager: Bool
    @State private var askingManager = false
    @State private var choices: [String] = []
    @State private var problem: String?
    let isNew: Bool

    init(agent: AgentProfile, isNew: Bool) {
        self.isNew = isNew
        _draft = State(initialValue: agent)
        if case .localModel(let wake) = agent.wake {
            _model = State(initialValue: wake.model ?? "")
        } else {
            _model = State(initialValue: "")
        }
        // A new one asks with its alert on Save; one that has the role keeps it.
        _isManager = State(initialValue: isNew ? false : AgentRegistry.shared.isManager(agent))
    }

    private var assembled: AgentProfile {
        var agent = draft
        agent.name = agent.name.trimmingCharacters(in: .whitespaces)
        let named = model.trimmingCharacters(in: .whitespacesAndNewlines)
        agent.wake = .localModel(LocalModelWake(model: named.isEmpty ? nil : named))
        agent.manager = isManager ? true : nil
        return agent
    }

    private var distillModel: String {
        let name = AppSettings.shared.distillModelName
        return name.isEmpty ? "none set in Settings → AI" : name
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    StackedField(label: "Name", text: $draft.name, prompt: "Manager", caption: "Its name on the boards, beside what it changes.",
                                 probe: "local-manager.name") { EmptyView() }
                    StackedField(label: "Model", text: $model, prompt: "Distill's model (\(distillModel))",
                                 caption: "Empty: the model Distill uses in Settings → AI. Or name another on \(AppSettings.shared.managerPlace). A bigger model follows the steps better.",
                                 probe: "local-manager.model") {
                        if !choices.isEmpty {
                            Menu("Choose") {
                                Button("Distill's Model") { model = "" }
                                Divider()
                                ForEach(choices, id: \.self) { choice in Button(choice) { model = choice } }
                            }
                            .fixedSize()
                        }
                    }
                } header: {
                    Text("A Local Model")
                } footer: {
                    Text("Binders runs it on this Mac's own model setup, in turns: it shows the model your request, Binders' tools and what it did so far, and calls the one tool the model picks each time, with the same limits and Undo as a Claude Code Manager. It takes no cards from your boards.")
                }
                Section {
                    Toggle("The Manager", isOn: Binding(get: { isManager }, set: { on in
                        if on { askingManager = true } else { isManager = false }
                    }))
                    .fitProbe("local-manager.manager")
                } footer: {
                    Text(isManager ? "It answers what you ask the Manager and tidies when you ask it to." : "Off, it does nothing: a local model is here only for the Manager's role.")
                }
                if let problem {
                    Section { StatusLabel(problem, .problem) }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                if !isNew {
                    Button("Remove", role: .destructive) {
                        AgentRegistry.shared.remove(draft.id)
                        dismiss()
                    }
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(minWidth: 520, idealWidth: 560, minHeight: 440)
        .alert("Make \(assembled.name.isEmpty ? "this model" : assembled.name) the Manager?", isPresented: $askingManager) {
            Button("Make It the Manager") { isManager = true }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(ManagerWords.alert(for: assembled)
                 + (AgentRegistry.shared.manager.flatMap { $0.id == draft.id ? nil : " \($0.name) stops being the Manager." } ?? ""))
        }
        .task {
            choices = (try? await AppSettings.shared.makeManagerClient(LocalModelWake())?.listModels()) ?? []
        }
        .onAppear {
            // A new one, added to be the Manager, asks first.
            if isNew, draft.manager == true { askingManager = true }
        }
    }

    private func save() {
        let agent = assembled
        problem = AgentRegistry.shared.upsert(agent, isManager: agent.manager == true)
        guard problem == nil else { return }
        dismiss()
    }
}
