import Foundation
import MLX
import MLXLLM
import MLXEmbedders
import MLXLMCommon
import Tokenizers

enum MLXError: LocalizedError {
    case notInstalled(String)
    case timedOut

    var errorDescription: String? {
        switch self {
        case .notInstalled(let model): "“\(model)” isn't downloaded yet. Download it in Settings → AI."
        case .timedOut: "The model took too long to answer."
        }
    }
}

/// Keeps one model in memory, loads it the first time it's needed, and frees it after a while unused.
actor MLXRuntime {
    static let shared = MLXRuntime()

    private var loaded: (directory: URL, container: ModelContainer, bytes: Int64)?
    private var loading: (directory: URL, task: Task<ModelContainer, Error>)?
    private var unloadAt: Date?
    private var unloadTask: Task<Void, Never>?

    init() {
        // The GPU keeps freed buffers around to reuse; a model's worth would stay held after it's gone.
        MLX.Memory.cacheLimit = 512 * 1024 * 1024
    }

    func container(for directory: URL) async throws -> ModelContainer {
        if let loaded, loaded.directory == directory { return loaded.container }
        if let loading, loading.directory == directory { return try await loading.task.value }
        release()
        let task = Task { try await loadModelContainer(from: directory, using: TransformersTokenizerLoader()) }
        loading = (directory, task)
        defer { loading = nil }
        let container = try await task.value
        loaded = (directory, container, MLXModels.size(of: directory))
        return container
    }

    /// Lets the model go `minutes` after the last request; 0 keeps it.
    func used(keepFor minutes: Int) {
        unloadTask?.cancel()
        guard minutes > 0 else {
            unloadAt = nil
            return
        }
        let at = Date().addingTimeInterval(TimeInterval(minutes * 60))
        unloadAt = at
        unloadTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(TimeInterval(minutes * 60)))
            guard !Task.isCancelled else { return }
            await self?.release()
        }
    }

    func release() {
        unloadTask?.cancel()
        unloadTask = nil
        unloadAt = nil
        loaded = nil
        MLX.Memory.clearCache()
    }

    func residency(of directory: URL) -> ModelResidency? {
        guard let loaded, loaded.directory == directory else { return nil }
        return ModelResidency(bytes: loaded.bytes, expiresAt: unloadAt)
    }
}

/// A model running in Binders with MLX.
struct MLXClient: LLMClient {
    /// The Hugging Face name, or a folder's path.
    let model: String
    /// Minutes unused before the model's memory is freed; 0 keeps it loaded.
    let idleMinutes: Int

    private var directory: URL {
        get throws {
            guard let directory = MLXModels.directory(for: model) else { throw MLXError.notInstalled(model) }
            return directory
        }
    }

    func complete(system: String, user: String, maxTokens: Int, temperature: Double, timeout: TimeInterval) async throws -> String {
        try await stream(system: system, user: user, maxTokens: maxTokens, temperature: temperature, timeout: timeout) { _ in false }
    }

    func stream(system: String, user: String, maxTokens: Int, temperature: Double, timeout: TimeInterval,
                stopWhen: @escaping @Sendable (String) -> Bool) async throws -> String {
        let directory = try directory
        let idle = idleMinutes
        let work: @Sendable () async throws -> String = {
            let container = try await MLXRuntime.shared.container(for: directory)
            // Thinking off: cleaning up dictation wants the answer, not the reasoning.
            let input = UserInput(chat: [.system(system), .user(user)], additionalContext: ["enable_thinking": false])
            let prepared = try await container.prepare(input: input)
            let parameters = GenerateParameters(maxTokens: maxTokens, temperature: Float(temperature))
            var text = ""
            for await event in try await container.generate(input: prepared, parameters: parameters) {
                try Task.checkCancellation()
                guard case .chunk(let chunk) = event else { continue }
                text += chunk
                if chunk.contains("\n"), stopWhen(text) { break }
            }
            await MLXRuntime.shared.used(keepFor: idle)
            let reply = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !reply.isEmpty else { throw LLMError.emptyResponse }
            return reply
        }
        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask(operation: work)
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw MLXError.timedOut
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw LLMError.emptyResponse }
            return first
        }
    }

    func listModels() async throws -> [String] {
        await MainActor.run { MLXModels.shared.installed().map(\.id) }
    }

    func warmUp() async {
        guard (try? directory) != nil else { return }
        // One token, so the GPU's code for this model is built now rather than during the first dictation.
        _ = try? await complete(system: "Reply with OK.", user: "OK", maxTokens: 1, temperature: 0, timeout: 120)
    }

    func unload() async {
        await MLXRuntime.shared.release()
    }

    func residency() async -> ModelResidency? {
        guard let directory = try? directory else { return nil }
        return await MLXRuntime.shared.residency(of: directory)
    }
}

/// Reads a model's tokenizer with swift-transformers, for MLX.
struct TransformersTokenizerLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        TokenizerBridge(try await AutoTokenizer.from(modelFolder: directory))
    }
}

private struct TokenizerBridge: MLXLMCommon.Tokenizer {
    let upstream: any Tokenizers.Tokenizer

    init(_ upstream: any Tokenizers.Tokenizer) { self.upstream = upstream }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] { upstream.encode(text: text, addSpecialTokens: addSpecialTokens) }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens) }
    func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }
    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
                           additionalContext: [String: any Sendable]?) throws -> [Int] {
        do {
            return try upstream.applyChatTemplate(messages: messages, tools: tools, additionalContext: additionalContext)
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}

/// Embeddings for search by meaning, from an embedding model running in Binders.
actor MLXEmbedder {
    static let shared = MLXEmbedder()
    private var loaded: (directory: URL, container: EmbedderModelContainer)?

    func embed(_ texts: [String], model: String) async throws -> [[Float]] {
        guard let directory = MLXModels.directory(for: model) else { throw MLXError.notInstalled(model) }
        let container: EmbedderModelContainer
        if let loaded, loaded.directory == directory {
            container = loaded.container
        } else {
            container = try await EmbedderModelFactory.shared.loadContainer(from: directory, using: TransformersTokenizerLoader())
            loaded = (directory, container)
        }
        return await container.perform { context in
            let tokenizer = context.tokenizer
            // Long passages are cut where the model's attention would thin out anyway.
            let encoded = texts.map { Array(tokenizer.encode(text: $0, addSpecialTokens: true).prefix(1024)) }
            let longest = max(1, encoded.map(\.count).max() ?? 1)
            let pad = tokenizer.eosTokenId ?? 0
            let padded = stacked(encoded.map { MLXArray($0 + Array(repeating: pad, count: longest - $0.count)) })
            // Each text's own tokens count, the padding after them doesn't.
            let mask = MLXArray(encoded.flatMap { tokens in (0..<longest).map { $0 < tokens.count } }, [encoded.count, longest])
            let output = context.model(padded, positionIds: nil, tokenTypeIds: MLXArray.zeros(like: padded), attentionMask: mask)
            let result = context.pooling(output, normalize: true, applyLayerNorm: true)
            result.eval()
            return result.map { $0.asArray(Float.self) }
        }
    }

    func release() {
        loaded = nil
        MLX.Memory.clearCache()
    }
}
