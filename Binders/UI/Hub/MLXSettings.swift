import AppKit
import SwiftUI

/// Settings → AI with models built in: which model, downloading it, and where downloads come from.
struct MLXModelSettings: View {
    @Environment(AppSettings.self) private var settings
    @State private var askingName = false
    @State private var typedName = ""
    @State private var folderProblem: String?
    @State private var showsSource = false

    private var models: MLXModels { .shared }

    var body: some View {
        @Bindable var settings = settings
        Text("Runs inside Binders on this Mac's graphics chip, with Apple's MLX. Nothing else to install or allow; the only thing that comes over the network is the model, once.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        LabeledContent("Model") {
            modelMenu(selection: $settings.mlxModel, suggestions: MLXModels.suggestions, other: "Another Hugging Face model…")
        }
        modelState(settings.mlxModel)
        LabeledContent("Search by meaning") {
            modelMenu(selection: $settings.mlxEmbeddingModel, suggestions: [MLXModels.embeddingSuggestion], other: nil)
        }
        modelState(settings.mlxEmbeddingModel)
        DisclosureGroup("Where models come from", isExpanded: $showsSource) {
            TextField("Download from", text: $settings.mlxEndpoint, prompt: Text("https://huggingface.co"))
            SecureField("Access token (optional)", text: Binding(get: { settings.mlxToken }, set: { settings.mlxToken = $0 }))
            Text("Hugging Face, or your company's mirror of it. A token is needed for models with a licence to accept, or a mirror that asks for one. A model IT has provided can be used from its folder: Model → Use a Model Folder….")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .alert("Use another model", isPresented: $askingName) {
            TextField("mlx-community/…", text: $typedName)
            Button("Use") {
                let name = typedName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { settings.mlxModel = name }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A model converted for MLX, by its Hugging Face name, such as mlx-community/Qwen3.5-9B-MLX-4bit.")
        }
    }

    /// The suggested models with their size, which suits this Mac, whatever else is downloaded, and other ways in.
    private func modelMenu(selection: Binding<String>, suggestions: [MLXModels.Suggestion], other: String?) -> some View {
        let current = selection.wrappedValue
        let installed = models.installed()
        let suggestedIDs = Set(suggestions.map(\.id))
        let memory = Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824)
        return Menu {
            Section(suggestions.count > 1 ? "Suggested, by Mac memory" : "Suggested") {
                ForEach(suggestions) { pick in
                    Button {
                        selection.wrappedValue = pick.id
                    } label: {
                        let here = MLXModels.directory(for: pick.id) != nil ? "downloaded" : "\(pick.gigabytes.formatted()) GB download"
                        let fits = suggestions.count > 1 && pick.id == MLXModels.suggested.id ? " · suggested for this Mac" : ""
                        let tooBig = pick.memoryGB > memory ? " · may be too big for \(memory) GB" : ""
                        Label("\(pick.name) · \(here)\(fits)\(tooBig)", systemImage: current == pick.id ? "checkmark" : "")
                    }
                }
            }
            let others = installed.filter { !suggestedIDs.contains($0.id) }
            if !others.isEmpty {
                Section("Also downloaded") {
                    ForEach(others) { model in
                        Button { selection.wrappedValue = model.id } label: { Label(model.id, systemImage: current == model.id ? "checkmark" : "") }
                    }
                }
            }
            Divider()
            if let other {
                Button(other) {
                    typedName = current.hasPrefix("/") ? "" : current
                    askingName = true
                }
            }
            Button("Use a Model Folder…") { chooseFolder(into: selection) }
        } label: {
            Text(name(of: current))
        }
        .fixedSize()
    }

    /// Downloaded or not, downloading, or why it didn't.
    @ViewBuilder
    private func modelState(_ model: String) -> some View {
        let model = model.trimmingCharacters(in: .whitespaces)
        HStack(spacing: 8) {
            if let fraction = models.progress[model] {
                ProgressView(value: fraction) { Text("Downloading \(name(of: model))… \(Int(fraction * 100))%") }
                Button("Cancel") { models.cancel(model) }
            } else if let folder = MLXModels.directory(for: model) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(model.hasPrefix("/") ? "From \(folder.path)" : "Downloaded · \(ByteCountFormatter.string(fromByteCount: MLXModels.size(of: folder), countStyle: .file))")
                Spacer()
                if !model.hasPrefix("/") {
                    Button("Delete") { models.delete(model) }
                        .help("Moves the downloaded model to the Trash")
                }
            } else if model.hasPrefix("/") {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(folderProblem ?? "There's no MLX model in that folder.")
            } else {
                if let failure = models.failures[model] {
                    Text(failure).foregroundStyle(.orange)
                } else {
                    let size = (MLXModels.suggestions + [MLXModels.embeddingSuggestion]).first { $0.id == model }.map { " · \($0.gigabytes.formatted()) GB" } ?? ""
                    Text("Not downloaded yet\(size).")
                }
                Spacer()
                Button("Download") { models.download(model) }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func name(of model: String) -> String {
        if model.isEmpty { return "Choose a model" }
        if let pick = (MLXModels.suggestions + [MLXModels.embeddingSuggestion]).first(where: { $0.id == model }) { return pick.name }
        if model.hasPrefix("/") { return (model as NSString).lastPathComponent }
        return model
    }

    private func chooseFolder(into selection: Binding<String>) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Choose a folder with an MLX model: its config.json and .safetensors weights."
        panel.prompt = "Use This Model"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        folderProblem = MLXModels.isModel(folder) ? nil : "“\(folder.lastPathComponent)” has no config.json and .safetensors weights."
        selection.wrappedValue = folder.path
    }
}
