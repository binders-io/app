import Foundation
import MLX
import MLXLLM
import MLXEmbedders
import MLXGuidedGeneration
import MLXLMCommon
import Tokenizers
import BindersKit

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

/// Keeps the models running in Binders in memory, loads each the first time it's needed, and frees each after a while
/// unused. Two may stay in memory together (the language model, and another chosen for Distill, lane DS3) when their
/// weights fit in `residentShare` of this Mac's memory; otherwise loading one frees the other, the one used longest ago
/// first, and it loads again when it's next needed.
actor MLXRuntime {
    static let shared = MLXRuntime()

    /// The most models kept in memory at once.
    static let maxResident = 2
    /// How much of this Mac's memory the models' weights may take together, leaving the rest for what they read and
    /// write (their caches) and everything else.
    static let residentShare = 0.6

    private struct Slot {
        let directory: URL
        let container: ModelContainer
        let bytes: Int64
        var lastUsed = Date()
        var unloadAt: Date?
        var unloadTask: Task<Void, Never>?
    }

    private var slots: [Slot] = []
    private var loading: (directory: URL, task: Task<ModelContainer, Error>)?

    init() {
        // The GPU keeps freed buffers around to reuse; a model's worth would stay held after it's gone.
        MLX.Memory.cacheLimit = 512 * 1024 * 1024
    }

    func container(for directory: URL) async throws -> ModelContainer {
        if let index = slots.firstIndex(where: { $0.directory == directory }) {
            slots[index].lastUsed = Date()
            return slots[index].container
        }
        if let loading, loading.directory == directory { return try await loading.task.value }
        // One load at a time: another model's finishes first.
        if let loading { _ = try? await loading.task.value }
        if let index = slots.firstIndex(where: { $0.directory == directory }) { return slots[index].container }
        let bytes = MLXModels.size(of: directory)
        makeRoom(for: bytes)
        let task = Task { try await loadModelContainer(from: directory, using: TransformersTokenizerLoader()) }
        loading = (directory, task)
        defer { loading = nil }
        let container = try await task.value
        slots.append(Slot(directory: directory, container: container, bytes: bytes))
        return container
    }

    /// Lane DS8: loads the model in `directory` ahead of its first request (Distill's, when a note with Distill on is
    /// opened), only when it isn't loaded or loading, nothing else is loading, and it fits beside the models in memory now
    /// without freeing any (the dictation model stays). Whether it loaded. Cancelling the task stops waiting for it.
    func warm(_ directory: URL) async -> Bool {
        guard !slots.contains(where: { $0.directory == directory }), loading == nil else { return false }
        let bytes = MLXModels.size(of: directory)
        guard bytes > 0, Self.fits(bytes, beside: slots.map(\.bytes)) else { return false }
        guard !Task.isCancelled else { return false }
        return (try? await container(for: directory)) != nil
    }

    /// Whether the model in `directory` is in memory now.
    func isLoaded(_ directory: URL) -> Bool { slots.contains { $0.directory == directory } }

    /// Whether a model of `bytes` may stay in memory beside models of `resident` bytes, on a Mac with `memory` bytes.
    static func fits(_ bytes: Int64, beside resident: [Int64], memory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> Bool {
        resident.count < maxResident && resident.reduce(bytes, +) <= Int64(Double(memory) * residentShare)
    }

    /// Frees models, the one used longest ago first, until one of `bytes` fits beside the rest.
    private func makeRoom(for bytes: Int64) {
        var freed = false
        while !slots.isEmpty, !Self.fits(bytes, beside: slots.map(\.bytes)) {
            let oldest = slots.indices.min { slots[$0].lastUsed < slots[$1].lastUsed }!
            free(slots.remove(at: oldest))
            freed = true
        }
        if freed { MLX.Memory.clearCache() }
    }

    private func free(_ slot: Slot) {
        slot.unloadTask?.cancel()
        MLXGuides.shared.forget(slot.directory)
    }

    /// Lets the model in `directory` go `minutes` after its last request; 0 keeps it.
    func used(_ directory: URL, keepFor minutes: Int) {
        guard let index = slots.firstIndex(where: { $0.directory == directory }) else { return }
        slots[index].lastUsed = Date()
        slots[index].unloadTask?.cancel()
        slots[index].unloadTask = nil
        guard minutes > 0 else {
            slots[index].unloadAt = nil
            return
        }
        slots[index].unloadAt = Date().addingTimeInterval(TimeInterval(minutes * 60))
        slots[index].unloadTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(TimeInterval(minutes * 60)))
            guard !Task.isCancelled else { return }
            await self?.release(directory)
        }
    }

    /// Frees one model.
    func release(_ directory: URL) {
        guard let index = slots.firstIndex(where: { $0.directory == directory }) else { return }
        free(slots.remove(at: index))
        MLX.Memory.clearCache()
    }

    /// Frees every model.
    func release() {
        slots.forEach(free)
        slots = []
        MLX.Memory.clearCache()
    }

    func residency(of directory: URL) -> ModelResidency? {
        guard let slot = slots.first(where: { $0.directory == directory }) else { return nil }
        return ModelResidency(bytes: slot.bytes, expiresAt: slot.unloadAt)
    }

    /// The models in memory now, for the self-test.
    var resident: [URL] { slots.map(\.directory) }
}

/// A model running in Binders with MLX.
struct MLXClient: LLMClient {
    /// The Hugging Face name, or a folder's path.
    let model: String
    /// Minutes unused before the model's memory is freed; 0 keeps it loaded.
    let idleMinutes: Int

    var place: ModelPlace { .inApp }

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
        try await stream(system: system, user: user, maxTokens: maxTokens, temperature: temperature, timeout: timeout,
                         stopWhen: stopWhen, onText: { _ in })
    }

    func stream(system: String, user: String, maxTokens: Int, temperature: Double, timeout: TimeInterval,
                stopWhen: @escaping @Sendable (String) -> Bool, onText: @escaping @Sendable (String) -> Void) async throws -> String {
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
                onText(text)
                if chunk.contains("\n"), stopWhen(text) { break }
            }
            await MLXRuntime.shared.used(directory, keepFor: idle)
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

    /// The reply held to `schema` token by token (xgrammar, lane DS3), so the model can only write JSON that fits it: no
    /// prose, no thinking, and the JSON brought to a close before `schema.answerTokens`. Sampling is greedy while it's held.
    /// If holding it can't be set up for this model (a tokenizer xgrammar can't read, a schema it can't compile), the reply
    /// comes as `stream` writes it, and the log says why.
    func stream(system: String, user: String, maxTokens: Int, temperature: Double, timeout: TimeInterval, schema: ReplySchema,
                stopWhen: @escaping @Sendable (String) -> Bool, onText: @escaping @Sendable (String) -> Void) async throws -> SchemaReply {
        let directory = try directory
        let idle = idleMinutes
        let model = model
        let limit = max(1, min(maxTokens, schema.answerTokens))
        let prefix = MLXPrefixCache.isOn ? schema.userPrefix : nil
        let itemTokens = schema.itemTokens
        let work: @Sendable () async throws -> MLXGuides.Outcome = {
            let container = try await MLXRuntime.shared.container(for: directory)
            let input = UserInput(chat: [.system(system), .user(user)], additionalContext: ["enable_thinking": false])
            let prepared = try await container.prepare(input: input)
            // Lane DS8: where the question's start is shared with the asks before (Distill's parts), how many of its tokens
            // that is: the tokens the same in this question and in one with something else after the start.
            var probe: LMInput?
            if let prefix {
                probe = try await container.prepare(input: UserInput(chat: [.system(system), .user(prefix + "#")],
                                                                     additionalContext: ["enable_thinking": false]))
            }
            let outcome = try await container.perform(nonSendable: (prepared, probe)) { context, inputs in
                let (input, probe) = inputs
                // Read inside the container, as everything on its arrays is.
                let shared = probe.map { MLXPrefixCache.sharedCount(input.text.tokens.asArray(Int.self), $0.text.tokens.asArray(Int.self)) }
                return try MLXGuides.shared.run(input: input, context: context, directory: directory, schema: schema.bounded, maxTokens: limit,
                                                shared: shared, itemTokens: itemTokens, stopWhen: stopWhen, onText: onText)
            }
            await MLXRuntime.shared.used(directory, keepFor: idle)
            return outcome
        }
        let outcome = try await withThrowingTaskGroup(of: MLXGuides.Outcome.self) { group in
            group.addTask(operation: work)
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw MLXError.timedOut
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw LLMError.emptyResponse }
            return first
        }
        switch outcome {
        case .held(let text, let note, let tokens):
            if let note { Log.llm.notice("\(model, privacy: .public), held to the schema: \(note, privacy: .public)") }
            Log.llm.info("\(model, privacy: .public): \(tokens.line, privacy: .public)")
            let reply = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !reply.isEmpty else { throw LLMError.emptyResponse }
            return SchemaReply(text: reply, held: true, why: note, tokens: tokens)
        case .notSetUp(let why):
            Log.llm.notice("\(model, privacy: .public) couldn't be held to the schema, so it answers without it: \(why, privacy: .public)")
            let text = try await stream(system: system, user: user, maxTokens: maxTokens, temperature: temperature, timeout: timeout,
                                        stopWhen: schema.stopWhenNotHeld ?? stopWhen, onText: onText)
            return SchemaReply(text: text, held: false, why: why)
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

    /// Lane DS8: loads the model if it fits beside the ones in memory without freeing any (`MLXRuntime.warm`); keeps it for
    /// the usual idle time. Whether it's loaded now.
    func warmBeside() async -> Bool {
        guard let directory = try? directory else { return false }
        if await MLXRuntime.shared.isLoaded(directory) { return true }
        guard await MLXRuntime.shared.warm(directory) else { return false }
        await MLXRuntime.shared.used(directory, keepFor: idleMinutes)
        return true
    }

    func residency() async -> ModelResidency? {
        guard let directory = try? directory else { return nil }
        return await MLXRuntime.shared.residency(of: directory)
    }

    /// The model's own context, from its config.json (`max_position_embeddings`, in `text_config` for a model like Gemma
    /// 4): MLX keeps the whole prompt in its cache, so that, and the Mac's memory, is the limit.
    func contextTokens() async -> Int? {
        guard let directory = try? directory else { return nil }
        return Self.contextTokens(in: directory)
    }

    static func contextTokens(in directory: URL) -> Int? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("config.json")),
              let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let keys = ["max_position_embeddings", "max_sequence_length", "seq_length", "n_positions", "max_seq_len"]
        for scope in [config["text_config"] as? [String: Any], config].compactMap({ $0 }) {
            for key in keys {
                if let tokens = (scope[key] as? NSNumber)?.intValue, tokens > 0, tokens < 100_000_000 { return tokens }
            }
        }
        return nil
    }
}

/// What holding a reply to a JSON schema needs from the loaded model, made once and kept while it's loaded (lane DS3): its
/// vocabulary as xgrammar reads it, the biases that bring a reply to a close near its limit and keep it from running on in
/// whitespace, and each schema's compiled grammar, kept for the next reply (a note's schema is the same for every part and
/// for a second try). Used inside the model container's `perform`, off the main actor.
final class MLXGuides: @unchecked Sendable {
    static let shared = MLXGuides()

    enum Outcome: Sendable {
        /// The reply as it was held; `note` says why it stopped short, when it did; its tokens (lane DS8).
        case held(String, note: String?, tokens: ReplyTokens)
        /// Holding it couldn't be set up: why.
        case notSetUp(String)
    }

    private struct Guide {
        let directory: URL
        let tokenizer: GrammarTokenizer
        let closing: MLXArray
        let whitespace: MLXArray
        let whitespaceIDs: Set<Int>
        var grammars: [String: GrammarConstraint] = [:]
        var reserves: [String: Int] = [:]
    }

    private let lock = NSLock()
    /// By model folder: the models in memory.
    private var guides: [URL: Guide] = [:]
    /// Grammars kept for one model: a note's schema differs by its headings.
    private static let grammarsKept = 8

    /// Lets one model's go, or every model's.
    func forget(_ directory: URL? = nil) {
        lock.withLock {
            if let directory { guides[directory] = nil } else { guides = [:] }
        }
        // What it read of a shared start goes with it (lane DS8).
        MLXPrefixCache.shared.forget(directory)
    }

    /// What one reply held to a schema starts from.
    struct Prepared {
        let constraint: GrammarConstraint
        let vocabSize: Int
        /// The fewest tokens a whole reply takes (`CompletionReserve`).
        let reserve: Int
        let closing: MLXArray
        let whitespace: MLXArray
        let whitespaceIDs: Set<Int>
    }

    private var compiled = 0
    /// How many grammars were compiled, for the self-test: a schema asked for again reuses the one kept.
    var compiles: Int { lock.withLock { compiled } }

    /// A matcher for `schema` on this model at its start, compiled the first time and kept after (`keep`); with the biases.
    func prepare(directory: URL, tokenizer: any MLXLMCommon.Tokenizer, schema: String) throws -> Prepared {
        try lock.withLock {
            if guides[directory] == nil {
                let vocabulary = TokenizerVocabExtractor.extractForGrammar(from: tokenizer)
                let grammarTokenizer = try GrammarTokenizer(vocab: vocabulary.vocab, vocabType: vocabulary.vocabType,
                                                            eosTokenId: Int32(tokenizer.eosTokenId ?? 0))
                let closing = ClosingTokenBias.compute(tokenizer: tokenizer, eosTokenId: tokenizer.eosTokenId)
                let (whitespace, whitespaceIDs) = WhitespaceTokenBias.compute(tokenizer: tokenizer)
                guides[directory] = Guide(directory: directory, tokenizer: grammarTokenizer, closing: closing, whitespace: whitespace, whitespaceIDs: whitespaceIDs)
            }
            guard var current = guides[directory] else { throw GrammarError.constraintCompilationFailed("no grammar tokenizer") }
            let constraint: GrammarConstraint
            // A grammar kept from an earlier reply is taken out while it's in use and wound back to its start (the
            // xgrammar Binders' mlx-swift-lm carries can't fork a matcher); one that's in use, or new, is compiled.
            if let kept = current.grammars.removeValue(forKey: schema) {
                Self.rewind(kept)
                constraint = kept
            } else {
                constraint = try GrammarConstraint(tokenizer: current.tokenizer, jsonSchema: schema, fastForward: true, hostTokenizer: tokenizer)
                compiled += 1
            }
            let reserve = current.reserves[schema] ?? CompletionReserve.estimate(schemaJSON: schema, tokenizer: tokenizer)
            current.reserves[schema] = reserve
            guides[directory] = current
            return Prepared(constraint: constraint, vocabSize: current.tokenizer.vocabSize, reserve: reserve, closing: current.closing,
                            whitespace: current.whitespace, whitespaceIDs: current.whitespaceIDs)
        }
    }

    /// Keeps a grammar a reply is done with, for the next reply held to the same schema on this model.
    func keep(_ constraint: GrammarConstraint, schema: String, directory: URL) {
        lock.withLock {
            guard guides[directory] != nil else { return }
            if guides[directory]?.grammars.count ?? 0 >= Self.grammarsKept { guides[directory]?.grammars = [:] }
            guides[directory]?.grammars[schema] = constraint
        }
    }

    /// Winds a matcher back to its start: every token it took is rolled back, until there are none left.
    static func rewind(_ constraint: GrammarConstraint) {
        var steps = 0
        while steps < 1_000_000, (try? constraint.rollback(1)) != nil { steps += 1 }
    }

    /// Writes one reply held to `schema`. Blocks while it writes, so only from inside the container's `perform`. Its
    /// last tokens are pushed to close the JSON (`completionReserve`), and the very last forced to (`hardReserve`), so
    /// the reply ends a whole object before `maxTokens`; one that still runs out is returned as it is, and the reader
    /// keeps the items before the cut. `stopWhen` is asked as each item or line ends.
    /// Lane DS8: `shared`, the tokens of the question's start that the asks of one reading share: read once and kept
    /// (`MLXPrefixCache`), each ask reading only what comes after it (`MLXHeldLoop`). `itemTokens`: about how long an item
    /// of the reply is (Distill v2's 30), which sizes the zones that close the reply in place of its last third.
    func run(input: LMInput, context: ModelContext, directory: URL, schema: String, maxTokens: Int, shared: Int? = nil, itemTokens: Int? = nil,
             stopWhen: @Sendable (String) -> Bool, onText: @Sendable (String) -> Void) throws -> Outcome {
        let set: Prepared
        do {
            set = try prepare(directory: directory, tokenizer: context.tokenizer, schema: schema)
        } catch {
            return .notSetUp(Self.words(error))
        }
        let (soft, hard) = Self.zones(maxTokens: maxTokens, reserve: set.reserve, itemTokens: itemTokens)
        var text = ""
        var note: String?
        let started = Date()
        var prefillSeconds: Double?
        var written = 0
        let tokens = input.text.tokens.asArray(Int.self)
        var reused = 0
        func emit(_ delta: String) -> Bool {
            if prefillSeconds == nil { prefillSeconds = Date().timeIntervalSince(started) }
            text += delta
            onText(text)
            // Stopped (a Distill reading at a pace, or you, lane DS7): what came is kept, and the GPU is freed for the next.
            if Task.isCancelled {
                note = "stopped part way"
                return false
            }
            if delta.contains("}") || delta.contains("\n"), stopWhen(text) {
                note = "stopped early: the reply was repeating itself"
                return false
            }
            return true
        }
        /// The package's own loop, which reads the whole question.
        func whole() throws -> Int {
            try GuidedGenerationLoop.run(input: input, context: context, constraint: set.constraint, maxTokens: maxTokens,
                                         vocabSize: set.vocabSize, completionReserve: soft, hardReserve: hard,
                                         closingBias: set.closing, whitespaceBias: set.whitespace, whitespaceTokenIDs: set.whitespaceIDs,
                                         emit: emit)
        }
        do {
            if let shared, shared >= MLXPrefixCache.leastTokens, shared < tokens.count, MLXPrefixCache.shared.allows(directory) {
                do {
                let cache: [KVCache]
                let feed: [Int]
                if let kept = MLXPrefixCache.shared.take(directory, prompt: tokens) {
                    cache = kept.cache
                    feed = Array(tokens[kept.count...])
                    reused = kept.count
                } else {
                    // The start read once, kept, then the rest.
                    cache = try context.model.newCache(parameters: GenerateParameters(kvCache: nil, kvBits: nil, kvGroupSize: 64, quantizedKVStart: 0))
                    try Self.prefill(Array(tokens[..<shared]), into: cache, context: context)
                    MLXPrefixCache.shared.keep(directory, tokens: Array(tokens[..<shared]), cache: cache.map { $0.copy() })
                    feed = Array(tokens[shared...])
                }
                written = try MLXHeldLoop.run(tokens: feed, cache: cache, context: context, constraint: set.constraint, maxTokens: maxTokens,
                                              vocabSize: set.vocabSize, completionReserve: soft, hardReserve: hard, closingBias: set.closing,
                                              whitespaceBias: set.whitespace, whitespaceTokenIDs: set.whitespaceIDs,
                                              prefilled: { _ in prefillSeconds = Date().timeIntervalSince(started) }, emit: emit)
                } catch let error where text.isEmpty && !(error is GuidedGenerationError) && !(error is GrammarError) && !(error is CancellationError) {
                // Reading on from a kept start failed for this model before it wrote anything: the whole question is read,
                // and this model isn't asked that way again until it's loaded again.
                Log.llm.notice("Couldn't read on from the kept start of the question, so it's read whole: \(String(describing: error), privacy: .public)")
                MLXPrefixCache.shared.refuse(directory)
                Self.rewind(set.constraint)
                reused = 0
                prefillSeconds = nil
                written = try whole()
                }
            } else {
                written = try whole()
            }
        } catch GuidedGenerationError.incompleteOutput {
            note = "the reply ran out of tokens before its JSON closed"
        } catch GuidedGenerationError.prematureEOS {
            note = "the model ended its reply before its JSON closed"
        } catch let error as GrammarError {
            // The grammar failed part way: what came is kept, or the reply is written without it. Its matcher isn't kept.
            guard !text.isEmpty else { return .notSetUp(Self.words(error)) }
            let total = Date().timeIntervalSince(started)
            return .held(text, note: "the grammar stopped part way: \(Self.words(error))",
                         tokens: ReplyTokens(prefill: tokens.count, reused: reused, decode: written, prefillSeconds: prefillSeconds ?? total,
                                             decodeSeconds: max(0, total - (prefillSeconds ?? total))))
        }
        keep(set.constraint, schema: schema, directory: directory)
        let total = Date().timeIntervalSince(started)
        let reading = prefillSeconds ?? total
        if written == 0 { written = max(0, (context.tokenizer.encode(text: text, addSpecialTokens: false)).count) }
        return .held(text, note: note, tokens: ReplyTokens(prefill: tokens.count, reused: reused, decode: written, prefillSeconds: reading,
                                                           decodeSeconds: max(0, total - reading)))
    }

    /// The zones that bring a reply to a close (`GuidedGenerationLoop`'s `completionReserve` and `hardReserve`): the soft
    /// one nudges each string and the item to their ends; the hard one leaves only what closes them. With items of about
    /// `itemTokens` (lane DS8: v2's are short), a few items' worth, at most a quarter of the reply; else as lane DS3 set
    /// them, up to its last third, as an item left open there needs a few tokens a field.
    static func zones(maxTokens: Int, reserve: Int, itemTokens: Int?) -> (soft: Int, hard: Int) {
        if let item = itemTokens, item > 0 {
            let hard = min(maxTokens / 6, max(reserve * 4, item * 2))
            return (min(maxTokens / 4, max(reserve * 3, hard + item * 3)), hard)
        }
        let hard = min(maxTokens / 4, max(reserve * 8, 80))
        return (min(maxTokens / 3, max(reserve * 3, hard + 160)), hard)
    }

    /// Reads `tokens` into `cache`, as a question's start is read, without writing anything.
    static func prefill(_ tokens: [Int], into cache: [KVCache], context: ModelContext) throws {
        let input = LMInput(tokens: MLXArray(tokens.map(Int32.init)))
        switch try context.model.prepare(input, cache: cache, state: nil, prefill: .init(stepSize: PrefillParameters.defaultStepSize)) {
        case .tokens(let rest):
            eval(context.model(rest[text: .newAxis], cache: cache, state: nil).logits)
        case .logits(let result):
            eval(result.logits)
        }
        eval(cache.flatMap { $0.innerState() })
    }

    static func words(_ error: Error) -> String {
        switch error {
        case GrammarError.tokenizerCreationFailed(let why): "xgrammar couldn't read the model's tokenizer: \(why)"
        case GrammarError.invalidJSONSchema(let why): "xgrammar turned the schema down: \(why)"
        case GrammarError.constraintCompilationFailed(let why): "xgrammar couldn't compile the schema: \(why)"
        default: String(describing: error)
        }
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
