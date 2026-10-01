import Foundation
import Observation

/// Models that run inside Binders with MLX, on Apple silicon, for Macs where Ollama isn't allowed or wanted. They're
/// downloaded from Hugging Face (or a company mirror of it) into Binders' own folder, or used from a folder IT provides.
@MainActor
@Observable
final class MLXModels {
    static let shared = MLXModels()

    struct Suggestion: Identifiable {
        let id: String
        let name: String
        let detail: String
        let gigabytes: Double
        /// The least memory a Mac should have to run it alongside everything else.
        let memoryGB: Int
    }

    /// Models Binders knows run well for cleaning up dictation, digests and answers, smallest first.
    static let suggestions: [Suggestion] = [
        Suggestion(id: "mlx-community/gemma-4-e2b-it-4bit", name: "Gemma 4 E2B", detail: "Small and quick, for Macs with 8 GB or more.", gigabytes: 3.6, memoryGB: 8),
        Suggestion(id: "mlx-community/Qwen3.5-4B-MLX-4bit", name: "Qwen 3.5 4B", detail: "Small, another family, for 8 GB or more.", gigabytes: 3.1, memoryGB: 8),
        Suggestion(id: "mlx-community/gemma-4-e4b-it-4bit", name: "Gemma 4 E4B", detail: "Quick and good, for 16 GB or more.", gigabytes: 5.2, memoryGB: 16),
        Suggestion(id: "mlx-community/gemma-4-12B-it-qat-4bit", name: "Gemma 4 12B", detail: "Better writing, for 32 GB or more.", gigabytes: 11.0, memoryGB: 32),
        Suggestion(id: "mlx-community/gemma-4-26b-a4b-it-4bit", name: "Gemma 4 26B", detail: "The best of these, and still quick: for 48 GB or more.", gigabytes: 15.4, memoryGB: 48),
    ]

    /// For meaning-based search in Knowledge.
    static let embeddingSuggestion = Suggestion(id: "mlx-community/embeddinggemma-300m-4bit", name: "EmbeddingGemma 300M",
                                                detail: "For search by meaning in Knowledge.", gigabytes: 0.2, memoryGB: 8)

    /// The model suggested for this Mac's memory.
    static var suggested: Suggestion {
        let memory = Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824)
        return suggestions.last { $0.memoryGB <= memory } ?? suggestions[0]
    }

    /// MLX runs on Apple silicon only; on an Intel Mac the option isn't offered.
    nonisolated static var isSupported: Bool {
        #if arch(arm64)
        true
        #else
        false
        #endif
    }

    /// Where downloaded models live: Binders' own folder, not a cache shared with other apps.
    nonisolated static var folder: URL {
        if let path = ProcessInfo.processInfo.environment["BINDERS_MLX_MODELS"], !path.isEmpty { return URL(fileURLWithPath: path, isDirectory: true) }
        return AppPaths.support.appendingPathComponent("Models/MLX", isDirectory: true)
    }

    /// Download progress by model, 0…1, while one is downloading.
    private(set) var progress: [String: Double] = [:]
    /// Why a download didn't finish.
    private(set) var failures: [String: String] = [:]
    /// Bumped when models come or go, for views that list them.
    private(set) var revision = 0
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]

    // MARK: Finding models

    /// A model's folder name: "mlx-community/gemma-4-e4b-it-4bit" → "mlx-community--gemma-4-e4b-it-4bit".
    nonisolated static func folderName(_ id: String) -> String { id.replacingOccurrences(of: "/", with: "--") }

    /// Where a model is, if it's here: a downloaded model by its Hugging Face name, or a folder by its path.
    nonisolated static func directory(for model: String) -> URL? {
        let model = model.trimmingCharacters(in: .whitespaces)
        guard !model.isEmpty else { return nil }
        let candidate = model.hasPrefix("/") || model.hasPrefix("~")
            ? URL(fileURLWithPath: (model as NSString).expandingTildeInPath, isDirectory: true)
            : folder.appendingPathComponent(folderName(model), isDirectory: true)
        return isModel(candidate) ? candidate : nil
    }

    /// A folder with a model in it: its configuration and its weights.
    nonisolated static func isModel(_ folder: URL) -> Bool {
        let manager = FileManager.default
        guard manager.fileExists(atPath: folder.appendingPathComponent("config.json").path) else { return false }
        let files = (try? manager.contentsOfDirectory(atPath: folder.path)) ?? []
        return files.contains { $0.hasSuffix(".safetensors") }
    }

    struct Installed: Identifiable, Hashable {
        /// The Hugging Face name, as Settings keeps it.
        let id: String
        let bytes: Int64
    }

    /// The models downloaded into Binders' folder.
    func installed() -> [Installed] {
        _ = revision
        let manager = FileManager.default
        let folders = (try? manager.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: nil)) ?? []
        return folders.filter { !$0.lastPathComponent.hasPrefix(".") && Self.isModel($0) }.map { folder in
            Installed(id: folder.lastPathComponent.replacingOccurrences(of: "--", with: "/"), bytes: Self.size(of: folder))
        }.sorted { $0.id < $1.id }
    }

    nonisolated static func size(of folder: URL) -> Int64 {
        let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey])
        var total: Int64 = 0
        while let file = files?.nextObject() as? URL {
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return total
    }

    // MARK: Downloading

    /// Fetches a model's files: its weights, configuration and tokenizer, not its pictures and READMEs. Files already
    /// fetched in full are kept, so a download that stopped carries on where it was.
    func download(_ id: String) {
        guard tasks[id] == nil else { return }
        failures[id] = nil
        progress[id] = 0
        let settings = AppSettings.shared
        let endpoint = settings.mlxEndpoint.trimmingCharacters(in: .whitespaces).isEmpty ? "https://huggingface.co" : settings.mlxEndpoint
        let token = settings.mlxToken
        tasks[id] = Task { [weak self] in
            do {
                try await MLXDownload(id: id, endpoint: endpoint, token: token.isEmpty ? nil : token) { fraction in
                    Task { @MainActor in self?.progress[id] = fraction }
                }.run()
            } catch is CancellationError {
            } catch {
                await MainActor.run { self?.failures[id] = error.localizedDescription }
            }
            await MainActor.run {
                self?.progress[id] = nil
                self?.tasks[id] = nil
                self?.revision += 1
            }
        }
    }

    func cancel(_ id: String) {
        tasks[id]?.cancel()
    }

    func delete(_ id: String) {
        try? FileManager.default.trashItem(at: Self.folder.appendingPathComponent(Self.folderName(id)), resultingItemURL: nil)
        revision += 1
    }
}

enum MLXDownloadError: LocalizedError {
    case notFound(String)
    case refused(Int, String)
    case nothingToFetch(String)

    var errorDescription: String? {
        switch self {
        case .notFound(let id): "There's no model called “\(id)” there."
        case .refused(let status, let id): status == 401 || status == 403
            ? "“\(id)” needs a Hugging Face access token, or accepting its licence on huggingface.co."
            : "The download of “\(id)” failed (HTTP \(status))."
        case .nothingToFetch(let id): "“\(id)” has no MLX weights."
        }
    }
}

/// One model's download: the list of its files, then each file, into a folder that becomes the model once it's whole.
struct MLXDownload: Sendable {
    let id: String
    let endpoint: String
    let token: String?
    let onProgress: @Sendable (Double) -> Void

    /// What a model needs to run, by name.
    static func wanted(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent.lowercased()
        guard !path.contains("/") || path.hasPrefix("tokenizer") else { return false }
        return name.hasSuffix(".safetensors") || name.hasSuffix(".json") || name.hasSuffix(".jinja") || name.hasSuffix(".tiktoken")
            || name == "tokenizer.model" || name == "merges.txt" || name == "vocab.txt"
    }

    private func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 60)
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return request
    }

    func run() async throws {
        let base = endpoint.hasSuffix("/") ? String(endpoint.dropLast()) : endpoint
        guard let listURL = URL(string: "\(base)/api/models/\(id)/tree/main?recursive=1") else { throw MLXDownloadError.notFound(id) }
        let (data, response) = try await URLSession.shared.data(for: request(listURL))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { throw MLXDownloadError.notFound(id) }
        guard (200..<300).contains(status) else { throw MLXDownloadError.refused(status, id) }
        let entries = (try JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
        let files: [(path: String, size: Int64)] = entries.compactMap { entry in
            guard entry["type"] as? String == "file", let path = entry["path"] as? String, Self.wanted(path) else { return nil }
            let size = ((entry["lfs"] as? [String: Any])?["size"] as? NSNumber)?.int64Value ?? (entry["size"] as? NSNumber)?.int64Value ?? 0
            return (path, size)
        }
        guard files.contains(where: { $0.path.hasSuffix(".safetensors") }) else { throw MLXDownloadError.nothingToFetch(id) }

        let manager = FileManager.default
        let destination = MLXModels.folder.appendingPathComponent(MLXModels.folderName(id), isDirectory: true)
        let partial = MLXModels.folder.appendingPathComponent(".partial/\(MLXModels.folderName(id))", isDirectory: true)
        try manager.createDirectory(at: partial, withIntermediateDirectories: true)
        let total = max(1, files.reduce(0) { $0 + $1.size })
        var done: Int64 = 0
        for file in files {
            try Task.checkCancellation()
            let target = partial.appendingPathComponent(file.path)
            try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let existing = (try? manager.attributesOfItem(atPath: target.path)[.size] as? NSNumber)?.int64Value
            if existing == file.size, file.size > 0 {
                done += file.size
                onProgress(Double(done) / Double(total))
                continue
            }
            guard let url = URL(string: "\(base)/\(id)/resolve/main/\(file.path)") else { continue }
            let before = done
            let (temporary, fileResponse) = try await Self.fetch(request(url)) { written in onProgress(Double(before + written) / Double(total)) }
            let fileStatus = (fileResponse as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(fileStatus) else { throw MLXDownloadError.refused(fileStatus, id) }
            try? manager.removeItem(at: target)
            try manager.moveItem(at: temporary, to: target)
            done += file.size
            onProgress(Double(done) / Double(total))
        }
        try? manager.removeItem(at: destination)
        try manager.moveItem(at: partial, to: destination)
    }
}

extension MLXDownload {
    /// One file, saying how much has arrived twice a second, and stopping when the download is cancelled.
    static func fetch(_ request: URLRequest, written: @escaping @Sendable (Int64) -> Void) async throws -> (URL, URLResponse) {
        let box = TaskBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = URLSession.shared.downloadTask(with: request) { location, response, error in
                    if let error { return continuation.resume(throwing: error) }
                    guard let location, let response else { return continuation.resume(throwing: URLError(.badServerResponse)) }
                    // The file goes when this returns: keep it first.
                    let kept = FileManager.default.temporaryDirectory.appendingPathComponent("binders-model-\(UUID().uuidString)")
                    do {
                        try FileManager.default.moveItem(at: location, to: kept)
                        continuation.resume(returning: (kept, response))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
                box.task = task
                task.resume()
                Task.detached {
                    while task.state == .running || task.state == .suspended {
                        written(task.countOfBytesReceived)
                        try? await Task.sleep(for: .milliseconds(500))
                    }
                }
            }
        } onCancel: {
            box.task?.cancel()
        }
    }
}

/// The download task, for cancelling it from outside.
private final class TaskBox: @unchecked Sendable {
    var task: URLSessionDownloadTask?
}
