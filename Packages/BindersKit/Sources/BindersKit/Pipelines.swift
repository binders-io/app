import Foundation

public typealias LLMCompletion = @Sendable (_ system: String, _ user: String) async throws -> String

public struct PipelineConfig: Sendable {
    public var aiFormatting: Bool
    public var category: StyleCategory
    public var tone: Tone
    public var customInstructions: String?
    public var vocabulary: [VocabularyTerm]
    public var snippets: [SnippetDefinition]
    public var voiceCommands: Bool

    public init(aiFormatting: Bool = true, category: StyleCategory = .other, tone: Tone = .formal,
                customInstructions: String? = nil, vocabulary: [VocabularyTerm] = [], snippets: [SnippetDefinition] = [],
                voiceCommands: Bool = true) {
        self.aiFormatting = aiFormatting
        self.category = category
        self.tone = tone
        self.customInstructions = customInstructions
        self.vocabulary = vocabulary
        self.snippets = snippets
        self.voiceCommands = voiceCommands
    }
}

public struct PipelineResult: Sendable, Equatable {
    public var text: String
    public var pressEnter: Bool = false
    public var usedLLM: Bool = false
    /// Why the LLM result wasn't used, when formatting was requested.
    public var fallbackReason: String?
    public var dictionaryReplacements: Int = 0
    public var snippetsUsed: Int = 0
}

public enum DictationPipeline {
    public static func process(raw: String, context: AppContext, config: PipelineConfig, llm: LLMCompletion?) async -> PipelineResult {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return PipelineResult(text: "") }

        var pressEnter = false
        if config.voiceCommands {
            let extracted = VoiceCommands.extractTrailingEnter(text)
            text = extracted.text
            pressEnter = extracted.pressEnter
            if text.isEmpty { return PipelineResult(text: "", pressEnter: pressEnter) }
        }

        let snippets = SnippetExpander.placeholderize(text, snippets: config.snippets)
        if snippets.isWholeMatch, let expansion = snippets.placeholders.values.first {
            return PipelineResult(text: expansion, pressEnter: pressEnter, snippetsUsed: 1)
        }
        text = snippets.text

        let pre = DictionaryMatcher.apply(config.vocabulary, to: text)
        // "by Friday, actually make that Thursday" is settled here, so it holds with a small model or none.
        text = SelfCorrection.resolve(pre.text)

        let deterministic: () -> PipelineResult = {
            let cleaned = FillerCleaner.clean(text)
            let expanded = SnippetExpander.expand(cleaned, placeholders: snippets.placeholders).text
            let post = DictionaryMatcher.apply(config.vocabulary, to: expanded)
            return PipelineResult(text: post.text, pressEnter: pressEnter, usedLLM: false,
                                  dictionaryReplacements: pre.replacements + post.replacements,
                                  snippetsUsed: snippets.placeholders.count)
        }

        guard config.aiFormatting, let llm else { return deterministic() }

        let system = PromptBuilder.cleanupSystemPrompt(dictionary: config.vocabulary.map(\.term))
        let user = PromptBuilder.cleanupUserPrompt(transcript: text, context: context, category: config.category,
                                                   tone: config.tone, customInstructions: config.customInstructions)
        do {
            let output = OutputGuard.sanitize(try await llm(system, user))
            guard OutputGuard.isPlausibleCleanup(raw: text, output: output) else {
                var result = deterministic()
                result.fallbackReason = "Formatter output didn't match the dictation"
                return result
            }
            let expanded = SnippetExpander.expand(output, placeholders: snippets.placeholders)
            guard expanded.missing.isEmpty else {
                var result = deterministic()
                result.fallbackReason = "Formatter dropped a snippet"
                return result
            }
            let post = DictionaryMatcher.apply(config.vocabulary, to: expanded.text)
            return PipelineResult(text: post.text, pressEnter: pressEnter, usedLLM: true,
                                  dictionaryReplacements: pre.replacements + post.replacements,
                                  snippetsUsed: snippets.placeholders.count)
        } catch {
            var result = deterministic()
            result.fallbackReason = "Formatter unavailable: \(error.localizedDescription)"
            return result
        }
    }
}

public enum CommandOutcome: Equatable, Sendable {
    case openURL(URL)
    case replaceSelection(String)
    case insert(String)
    case failed(String)
}

public enum CommandPipeline {
    public static func process(instruction rawInstruction: String, context: AppContext, dictionary: [String],
                               llm: LLMCompletion?) async -> CommandOutcome {
        let instruction = rawInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty else { return .failed("No command heard") }
        if let url = VoiceCommands.parseWebSearch(instruction) {
            return .openURL(url)
        }
        guard let llm else { return .failed("Command Mode needs a language model") }
        do {
            let output = OutputGuard.sanitize(try await llm(
                PromptBuilder.commandSystemPrompt(dictionary: dictionary),
                PromptBuilder.commandUserPrompt(instruction: instruction, context: context)))
            guard !output.isEmpty else { return .failed("The model returned nothing") }
            if let selected = context.selectedText, !selected.isEmpty {
                return .replaceSelection(output)
            }
            return .insert(output)
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
