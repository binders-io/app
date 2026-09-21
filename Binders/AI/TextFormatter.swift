import Foundation
import BindersKit

/// Binds the pure pipelines to the user's settings, dictionary, snippets and model server.
@MainActor
enum TextFormatter {
    static func format(raw: String, context: AppContext, vocabulary: [VocabularyTerm]? = nil) async -> PipelineResult {
        let settings = AppSettings.shared
        let vocabulary = vocabulary ?? Store.shared.vocabulary()
        let category = StyleResolver.category(for: context, overrides: settings.styles.appOverrides)
        let config = PipelineConfig(aiFormatting: settings.aiFormatting, category: category, tone: settings.styles.tone(for: category),
                                    customInstructions: settings.styles.instructions(for: category), vocabulary: vocabulary,
                                    snippets: Store.shared.snippets(), voiceCommands: settings.voiceCommands)
        var llm: LLMCompletion?
        if settings.aiFormatting, let client = settings.makeLLMClient() {
            let maxTokens = max(256, raw.count / 2 + 256)
            llm = { system, user in
                try await client.complete(system: system, user: user, maxTokens: maxTokens, temperature: 0.1, timeout: 30)
            }
        }
        return await DictationPipeline.process(raw: raw, context: context, config: config, llm: llm)
    }

    static func command(instruction: String, context: AppContext, vocabulary: [VocabularyTerm]? = nil) async -> CommandOutcome {
        let vocabulary = vocabulary ?? Store.shared.vocabulary()
        let llm: LLMCompletion? = AppSettings.shared.makeLLMClient().map { client in
            { system, user in try await client.complete(system: system, user: user, maxTokens: 2048, temperature: 0.4, timeout: 120) }
        }
        return await CommandPipeline.process(instruction: instruction, context: context, dictionary: vocabulary.map(\.term), llm: llm)
    }
}
