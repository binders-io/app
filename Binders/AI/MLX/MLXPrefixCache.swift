import Foundation
import MLX
import MLXGuidedGeneration
import MLXLMCommon

// Lane DS8: a Distill reading asks the model in Binders about each part of a note with the same instructions, the same
// list of who can take work and the same headings, and only the part's own lines differ. What the model read of that
// shared start (its KV cache) is kept, and each ask reads only its own lines after it, within one reading and across
// readings while the model, the instructions and the note's headings stay the same.
//
// mlx-swift-lm's GuidedGenerationLoop makes a fresh cache for every reply and takes none from its caller, so a reply held
// to a schema with a kept prefix is written by `MLXHeldLoop` here: the same steps as that loop, through the package's
// public API (the model's `prepare` and forward pass, xgrammar's `computeMask` and `commitToken`), with the cache given.

/// The KV cache of the last shared start each model read (`ReplySchema.userPrefix`), kept while the model is loaded.
/// Used only inside a model container's `perform`, which answers one request at a time.
final class MLXPrefixCache: @unchecked Sendable {
    static let shared = MLXPrefixCache()

    /// A kept start: its tokens, and the cache that holds them (a copy is taken for each ask, which writes after it).
    private struct Entry {
        let tokens: [Int]
        let cache: [KVCache]
        let bytes: Int
    }

    /// The most a kept start may take in memory; a bigger one isn't kept.
    static let maxBytes = 1_500_000_000
    /// A start shorter than this isn't worth keeping.
    static let leastTokens = 64

    private let lock = NSLock()
    private var entries: [URL: Entry] = [:]
    private var counts = (asks: 0, reused: 0, tokensReused: 0)

    /// On unless `defaults write io.binders.mac distillReusePrefix -bool NO` (the bench has `--prefix-cache on|off`).
    static var enabled: Bool { AppDefaults.store.object(forKey: "distillReusePrefix") as? Bool ?? true }
    /// The bench's own choice, over the setting, while it runs.
    nonisolated(unsafe) static var override: Bool?
    static var isOn: Bool { override ?? enabled }

    /// Models that failed to read on from a kept start, asked the whole question until they're loaded again.
    private var refused: Set<URL> = []

    /// Lets one model's go, or every model's: it unloaded, or memory is wanted.
    func forget(_ directory: URL? = nil) {
        lock.withLock {
            if let directory {
                entries[directory] = nil
                refused.remove(directory)
            } else {
                entries = [:]
                refused = []
            }
        }
    }

    /// Whether this model reads on from a kept start.
    func allows(_ directory: URL) -> Bool { lock.withLock { !refused.contains(directory) } }

    /// This model failed to read on from a kept start: it reads every question whole while it's loaded.
    func refuse(_ directory: URL) {
        lock.withLock {
            refused.insert(directory)
            entries[directory] = nil
        }
    }

    /// For the bench and the log: asks that could reuse, those that did, and the tokens they didn't read again.
    var stats: (asks: Int, reused: Int, tokensReused: Int) { lock.withLock { counts } }

    /// A copy of the kept cache when its tokens start `prompt` and leave at least one token after them.
    func take(_ directory: URL, prompt: [Int]) -> (count: Int, cache: [KVCache])? {
        lock.withLock {
            counts.asks += 1
            guard let entry = entries[directory], entry.tokens.count < prompt.count,
                  Array(prompt.prefix(entry.tokens.count)) == entry.tokens else { return nil }
            counts.reused += 1
            counts.tokensReused += entry.tokens.count
            return (entry.tokens.count, entry.cache.map { $0.copy() })
        }
    }

    /// Keeps `cache`, which holds `tokens`, for the next ask on this model, in place of the last one. Not when it's too big.
    func keep(_ directory: URL, tokens: [Int], cache: [KVCache]) {
        let bytes = cache.flatMap { $0.innerState() }.reduce(0) { $0 + $1.nbytes }
        lock.withLock {
            guard bytes <= Self.maxBytes else {
                entries[directory] = nil
                return
            }
            entries[directory] = Entry(tokens: tokens, cache: cache, bytes: bytes)
        }
    }

    /// The tokens of the shared start of a question: the first `prefix` tokens are the same in `prompt` and in the
    /// question with something else after the start (`probe`), as a chat template renders both.
    static func sharedCount(_ prompt: [Int], _ probe: [Int]) -> Int {
        var count = 0
        while count < prompt.count, count < probe.count, prompt[count] == probe[count] { count += 1 }
        return count
    }
}

/// A reply held to a schema, from a cache that may already hold the start of the question (`MLXPrefixCache`): what
/// `GuidedGenerationLoop.run` does, with the cache given. Blocks while it writes, so only from inside the container's
/// `perform`.
enum MLXHeldLoop {
    /// Feeds `tokens` into `cache` and writes the reply, held to `constraint`. Returns the tokens written. Throws as
    /// `GuidedGenerationLoop.run` does: `incompleteOutput` when `maxTokens` ran out before the grammar closed.
    @discardableResult
    static func run(tokens: [Int], cache: [KVCache], context: ModelContext, constraint: GrammarConstraint, maxTokens: Int, vocabSize: Int,
                    completionReserve: Int, hardReserve: Int, closingBias: MLXArray?, whitespaceBias: MLXArray?, whitespaceTokenIDs: Set<Int>,
                    prefilled: (Double) -> Void = { _ in }, emit: (String) -> Bool) throws -> Int {
        let model = context.model
        let start = Date()
        var stopIDs = Set(context.configuration.eosTokenIds)
        if let eos = context.tokenizer.eosTokenId { stopIDs.insert(eos) }
        for token in context.configuration.extraEOSTokens {
            if let id = context.tokenizer.convertTokenToId(token) { stopIDs.insert(id) }
        }
        var state: LMOutput.State?
        var logits: MLXArray
        let input = LMInput(tokens: MLXArray(tokens.map(Int32.init)))
        switch try model.prepare(input, cache: cache, state: nil, prefill: .init(stepSize: PrefillParameters.defaultStepSize)) {
        case .tokens(let rest):
            let result = model(rest[text: .newAxis], cache: cache, state: nil)
            state = result.state
            logits = result.logits
        case .logits(let result):
            state = result.state
            logits = result.logits
        }
        eval(logits)
        prefilled(Date().timeIntervalSince(start))

        let eosPenalty: MLXArray? = closingBias.map { bias in
            var penalty = [Float32](repeating: 0, count: bias.shape[0])
            for eos in stopIDs where eos >= 0 && eos < penalty.count { penalty[eos] = -10_000 }
            return MLXArray(penalty)
        }
        var detokenizer = NaiveStreamingDetokenizer(tokenizer: context.tokenizer)
        var whitespace = WhitespaceRunTracker(whitespaceTokenIDs: whitespaceTokenIDs)
        var count = 0
        var stopped = false
        let logitCount = logits.shape[logits.ndim - 1]
        var mask = try constraint.computeMask()
        var maskArray = Self.maskArray(mask, vocabSize: vocabSize, logits: logitCount)

        func step(_ token: Int32) {
            let result = model(LMInput.Text(tokens: MLXArray([token]))[text: .newAxis], cache: cache, state: state)
            state = result.state
            logits = result.logits
        }

        loop: while count < maxTokens {
            try Task.checkCancellation()
            if mask.isTerminated {
                stopped = true
                break
            }
            // The zones, as GuidedGenerationLoop has them: a nudge to close near the end, then only what closes.
            var bias: MLXArray?
            if mask.needsApply {
                if let closingBias {
                    if hardReserve > 0, count >= maxTokens - hardReserve {
                        var hard = which(closingBias .> 0, Float32(0), Float32(-10_000))
                        if let eosPenalty { hard = hard + eosPenalty }
                        bias = hard
                    } else if count >= maxTokens - completionReserve {
                        bias = closingBias
                    }
                }
                if let whitespaceBias, whitespace.isActive { bias = bias.map { $0 + whitespaceBias } ?? whitespaceBias }
            }
            let token = Self.sample(logits, mask: maskArray, bias: bias)
            let id = Int(token)
            if whitespaceBias != nil { _ = whitespace.record(tokenID: id) }
            if mask.needsApply, id == context.tokenizer.unknownTokenId || stopIDs.contains(id) {
                stopped = true
                break
            }
            let committed = try constraint.commitToken(Int32(token))
            detokenizer.append(token: id)
            if let text = detokenizer.next(), !emit(text) { break }
            count += 1
            if committed.isTerminated {
                stopped = true
                break
            }
            let forced = committed.tokens
            if !forced.isEmpty {
                for token in forced {
                    if count >= maxTokens { break loop }
                    detokenizer.append(token: Int(token))
                    if let text = detokenizer.next(), !emit(text) { break loop }
                    count += 1
                }
                // One at a time, as the package does: a batch on a full cache trips an attention mask on some models.
                for token in forced { step(token) }
            } else {
                step(Int32(token))
            }
            asyncEval(logits)
            mask = try constraint.computeMask()
            maskArray = Self.maskArray(mask, vocabSize: vocabSize, logits: logitCount)
            eval(logits)
        }
        if !stopped, count >= maxTokens { throw GuidedGenerationError.incompleteOutput }
        return count
    }

    /// The grammar's mask as logits to add: 0 allowed, -inf not; nil when the grammar forces every token.
    static func maskArray(_ mask: MaskResult, vocabSize: Int, logits: Int) -> MLXArray? {
        guard mask.needsApply else { return nil }
        return mask.mask.withUnsafeBufferPointer { buffer in
            let words = UnsafeRawPointer(buffer.baseAddress!).assumingMemoryBound(to: UInt32.self)
            var floats = [Float](repeating: -Float.infinity, count: logits)
            for index in 0..<min(vocabSize, logits) where (words[index / 32] >> (UInt32(index) % 32)) & 1 == 1 { floats[index] = 0 }
            return MLXArray(floats)
        }
    }

    /// The greedy pick, the mask and bias added (the bias padded or cut to the logits' size).
    static func sample(_ raw: MLXArray, mask: MLXArray?, bias: MLXArray?) -> UInt32 {
        var logits = raw[0..., -1, 0...]
        if let mask { logits = logits + mask }
        if let bias {
            let size = logits.shape[logits.ndim - 1], biasSize = bias.shape[0]
            if biasSize < size {
                logits = logits + concatenated([bias, MLXArray.zeros([size - biasSize])])
            } else if biasSize > size {
                logits = logits + bias[0..<size]
            } else {
                logits = logits + bias
            }
        }
        return argMax(logits, axis: -1).item(UInt32.self)
    }
}
