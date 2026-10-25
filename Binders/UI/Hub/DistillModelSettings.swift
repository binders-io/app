import SwiftUI

/// Settings → AI: the model Distill reads notes with (lane DS3). The language model by default; or another, for Distill
/// and `distill_note` only, so a slower model that lists work better doesn't slow dictation down: one running in Binders,
/// one in Ollama, or one on the OpenAI-compatible server.
struct DistillModelSection: View {
    @Environment(AppSettings.self) private var settings
    @State private var ollamaModels: [String] = []
    @State private var serverModels: [String] = []
    @State private var askingName = false
    @State private var typedName = ""
    @State private var typedSource = DistillModelSource.mlx
    /// Lane DS9: Distill in the background while you write.
    @AppStorage(DistillBackgroundReader.enabledKey, store: AppDefaults.store) private var inBackground = true

    private var models: MLXModels { .shared }

    var body: some View {
        Section {
            LabeledContent("Model for Distill") { menu }
            if settings.distillModelSource == .mlx, settings.distillHasOwnModel {
                mlxState(settings.distillModel.trimmingCharacters(in: .whitespaces))
            }
            Toggle(isOn: $inBackground) {
                Text("Distill in the background while I write")
                Text("For notes with Distill on, it reads what you changed with the Distill model a little after you stop typing, so new items wait in the list. It pauses while you dictate or record.")
            }
            .fitProbe("settings.distill.background")
        } header: {
            Text("Distill")
        } footer: {
            Text(footer)
        }
        .task(id: "\(settings.ollamaURL)|\(settings.openAIBaseURL)") { await loadModels() }
        .alert("Use another model for Distill", isPresented: $askingName) {
            TextField(typedSource == .mlx ? "mlx-community/…" : typedSource == .ollama ? "An Ollama tag, such as qwen3:32b" : "The model name your server expects",
                      text: $typedName)
            Button("Use") {
                let name = typedName.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return }
                choose(typedSource, name)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(typedSource == .mlx ? "A model converted for MLX, by its Hugging Face name." : "Type the model name exactly as it's listed.")
        }
    }

    private var footer: String {
        guard settings.distillHasOwnModel else {
            return "Distill reads notes with the language model above. A larger model lists work more fully, but is slower: choose one here for Distill only, and dictation keeps the quicker one."
        }
        let mlx = settings.distillModelSource == .mlx && settings.llmProvider == .mlx
        return "Distill and distill_note read with \(settings.distillModelName); everything else keeps \(settings.llmModelName)."
            + (mlx ? " Both run in Binders: they stay in memory together when this Mac has room for both, and otherwise take turns, each loading again when it's next needed." : "")
    }

    private var menu: some View {
        let current = settings.distillHasOwnModel ? settings.distillModel.trimmingCharacters(in: .whitespaces) : ""
        let source = settings.distillModelSource
        func checked(_ kind: DistillModelSource, _ name: String) -> String { source == kind && current == name ? "checkmark" : "" }
        let suggestion = MLXModels.distillSuggestion
        let downloaded = models.installed().map(\.id).filter { $0 != suggestion.id && !$0.lowercased().contains("embed") }
        return Menu {
            Button { settings.distillModelSource = .same } label: {
                Label("Same as the Language Model", systemImage: settings.distillHasOwnModel ? "" : "checkmark")
            }
            if MLXModels.isSupported {
                Section("Runs in Binders") {
                    Button { choose(.mlx, suggestion.id) } label: {
                        let here = MLXModels.directory(for: suggestion.id) != nil ? "downloaded" : "\(suggestion.gigabytes.formatted()) GB download"
                        Label("\(suggestion.name) · \(here) · suggested for Distill", systemImage: checked(.mlx, suggestion.id))
                    }
                    ForEach(downloaded, id: \.self) { id in
                        Button { choose(.mlx, id) } label: { Label(id, systemImage: checked(.mlx, id)) }
                    }
                }
            }
            if !ollamaModels.isEmpty {
                Section("In Ollama") {
                    ForEach(ollamaModels, id: \.self) { name in
                        Button { choose(.ollama, name) } label: { Label(name, systemImage: checked(.ollama, name)) }
                    }
                }
            }
            if !serverModels.isEmpty {
                Section("On your server") {
                    ForEach(serverModels, id: \.self) { name in
                        Button { choose(.server, name) } label: { Label(name, systemImage: checked(.server, name)) }
                    }
                }
            }
            Divider()
            if MLXModels.isSupported { Button("Another Hugging Face Model…") { ask(.mlx) } }
            Button("Another Ollama Model…") { ask(.ollama) }
        } label: {
            let known = MLXModels.known.first { $0.id == settings.distillModel.trimmingCharacters(in: .whitespaces) }?.name
            Text(settings.distillHasOwnModel ? known ?? settings.distillModelName : "Same as the language model")
        }
        .fixedSize()
    }

    private func choose(_ source: DistillModelSource, _ name: String) {
        settings.distillModel = name
        settings.distillModelSource = source
    }

    private func ask(_ source: DistillModelSource) {
        typedSource = source
        typedName = settings.distillModelSource == source ? settings.distillModel : ""
        askingName = true
    }

    /// Downloaded or not, downloading, or why it didn't, for an MLX model.
    @ViewBuilder
    private func mlxState(_ model: String) -> some View {
        HStack(spacing: 8) {
            if let fraction = models.progress[model] {
                ProgressView(value: fraction) { Text("Downloading \(settings.distillModelName)… \(Int(fraction * 100))%") }
                Button("Cancel") { models.cancel(model) }
            } else if let folder = MLXModels.directory(for: model) {
                Image(systemName: BindersTheme.readySymbol).foregroundStyle(.tintText)
                Text(model.hasPrefix("/") ? "From \(folder.path)" : "Downloaded · \(ByteCountFormatter.string(fromByteCount: MLXModels.size(of: folder), countStyle: .file))")
                Spacer()
            } else if model.hasPrefix("/") {
                StatusLabel("There's no MLX model in that folder.", .problem)
            } else {
                if let failure = models.failures[model] {
                    StatusLabel(failure, .problem)
                } else {
                    let size = MLXModels.known.first { $0.id == model }.map { " · \($0.gigabytes.formatted()) GB" } ?? ""
                    Text("Not downloaded yet\(size). Distill can't read a note with it until it is.")
                }
                Spacer()
                Button("Download") { models.download(model) }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    /// What Ollama and the server list, for the menu; nothing when they don't answer.
    private func loadModels() async {
        if let url = URL(string: settings.ollamaURL) {
            ollamaModels = ((try? await OllamaClient(baseURL: url, model: "").listModels()) ?? []).filter { !$0.lowercased().contains("embed") }
        }
        if settings.llmProvider == .openAICompatible, let url = URL(string: settings.openAIBaseURL) {
            let key = settings.openAIKey
            serverModels = (try? await OpenAICompatibleClient(baseURL: url, model: "", apiKey: key.isEmpty ? nil : key).listModels()) ?? []
        } else {
            serverModels = []
        }
    }
}
