import XCTest
@testable import BindersKit

final class DictionaryMatcherTests: XCTestCase {
    func testAliasReplacement() {
        let terms = [VocabularyTerm(term: "Binders", aliases: ["whispering", "wisp ring"])]
        let result = DictionaryMatcher.apply(terms, to: "I'm building whispering and wisp ring today.")
        XCTAssertEqual(result.text, "I'm building Binders and Binders today.")
        XCTAssertEqual(result.replacements, 2)
    }

    func testCaseFixAndCamelCaseSplit() {
        let terms = [VocabularyTerm(term: "FluidAudio")]
        XCTAssertEqual(DictionaryMatcher.apply(terms, to: "we use fluid audio and fluidaudio").text,
                       "we use FluidAudio and FluidAudio")
    }

    func testDoesNotClobberCommonWordsOrSubstrings() {
        let terms = [VocabularyTerm(term: "Linear"), VocabularyTerm(term: "Ghostty")]
        let result = DictionaryMatcher.apply(terms, to: "a linear regression in ghosttyish")
        XCTAssertEqual(result.text, "a linear regression in ghosttyish")
        XCTAssertEqual(result.replacements, 0)
    }

    func testAlreadyCorrectCountsNothing() {
        let result = DictionaryMatcher.apply([VocabularyTerm(term: "Ollama")], to: "Run Ollama now")
        XCTAssertEqual(result.replacements, 0)
    }
}

final class SnippetTests: XCTestCase {
    let snippets = [
        SnippetDefinition(trigger: "my calendar link", expansion: "https://cal.com/maya"),
        SnippetDefinition(trigger: "intro blurb", expansion: "Hi! I'm Maya."),
    ]

    func testWholeMatch() {
        let result = SnippetExpander.placeholderize("My calendar link.", snippets: snippets)
        XCTAssertTrue(result.isWholeMatch)
    }

    func testInlinePlaceholderRoundTrip() {
        let result = SnippetExpander.placeholderize("here is my calendar link, thanks", snippets: snippets)
        XCTAssertFalse(result.isWholeMatch)
        XCTAssertEqual(result.text, "here is ⟦1⟧, thanks")
        let expanded = SnippetExpander.expand("Here is ⟦1⟧. Thanks!", placeholders: result.placeholders)
        XCTAssertEqual(expanded.text, "Here is https://cal.com/maya. Thanks!")
        XCTAssertTrue(expanded.missing.isEmpty)
    }

    func testMissingPlaceholderReported() {
        let result = SnippetExpander.placeholderize("send the intro blurb please", snippets: snippets)
        XCTAssertEqual(SnippetExpander.expand("Send it please", placeholders: result.placeholders).missing, ["⟦1⟧"])
    }
}

final class FillerAndCommandTests: XCTestCase {
    func testFillerRemoval() {
        XCTAssertEqual(FillerCleaner.clean("So, um, I think uh we should go."), "So, I think we should go.")
        XCTAssertEqual(FillerCleaner.clean("Um, the the plan is ready."), "The plan is ready.")
        XCTAssertEqual(FillerCleaner.clean("I know that that is umbrella weather"), "I know that that is umbrella weather")
    }

    func testTrailingEnter() {
        let result = VoiceCommands.extractTrailingEnter("Ship it to prod, press enter.")
        XCTAssertEqual(result.text, "Ship it to prod")
        XCTAssertTrue(result.pressEnter)
        XCTAssertFalse(VoiceCommands.extractTrailingEnter("Don't press enter yet, I'm typing").pressEnter)
    }

    func testWebSearchParsing() {
        XCTAssertEqual(VoiceCommands.parseWebSearch("Search Google for best ramen in Lisbon.")?.absoluteString,
                       "https://www.google.com/search?q=best%20ramen%20in%20Lisbon")
        XCTAssertEqual(VoiceCommands.parseWebSearch("ask Perplexity what is FluidAudio")?.host, "www.perplexity.ai")
        XCTAssertEqual(VoiceCommands.parseWebSearch("Ask ChatGPT about swift actors")?.host, "chatgpt.com")
        XCTAssertNil(VoiceCommands.parseWebSearch("make this more concise"))
    }

    func testTodoParsing() {
        XCTAssertEqual(VoiceCommands.parseTodo("Add to do call Sam tomorrow."), "call Sam tomorrow")
        XCTAssertEqual(VoiceCommands.parseTodo("add a to-do: send the deck by Friday"), "send the deck by Friday")
        XCTAssertEqual(VoiceCommands.parseTodo("Add task to book the hotel"), "book the hotel")
        XCTAssertEqual(VoiceCommands.parseTodo("remind me to water the plants tonight"), "water the plants tonight")
        XCTAssertEqual(VoiceCommands.parseTodo("add buy milk to my to-do list"), "buy milk")
        XCTAssertEqual(VoiceCommands.parseTodo("New reminder call the dentist"), "call the dentist")
        XCTAssertNil(VoiceCommands.parseTodo("add it to my calendar"))
        XCTAssertNil(VoiceCommands.parseTodo("make this more concise"))
        XCTAssertNil(VoiceCommands.parseTodo("add to do"))
    }

    func testCalendarParsing() {
        XCTAssertEqual(VoiceCommands.parseCalendarAdd("Add it to my calendar."), .fromContext)
        XCTAssertEqual(VoiceCommands.parseCalendarAdd("put that on the calendar"), .fromContext)
        XCTAssertEqual(VoiceCommands.parseCalendarAdd("add to my calendar lunch with Sam tomorrow at noon"), .described("lunch with Sam tomorrow at noon"))
        XCTAssertEqual(VoiceCommands.parseCalendarAdd("put dentist Friday at 9 am on my calendar"), .described("dentist Friday at 9 am"))
        XCTAssertEqual(VoiceCommands.parseCalendarAdd("schedule a call with Noah Friday at 2 pm"), .described("a call with Noah Friday at 2 pm"))
        XCTAssertEqual(VoiceCommands.parseCalendarAdd("Add to my calendar."), .fromContext)
        XCTAssertNil(VoiceCommands.parseCalendarAdd("add to do call Sam"))
        XCTAssertNil(VoiceCommands.parseCalendarAdd("what's on my calendar"))
    }

    func testOnlyExplicitFormsCountInPlainDictation() {
        XCTAssertEqual(VoiceCommands.parseTodo("Add to do call Sam tomorrow.", explicitOnly: true), "call Sam tomorrow")
        XCTAssertNil(VoiceCommands.parseTodo("remind me to water the plants tonight", explicitOnly: true))
        XCTAssertNil(VoiceCommands.parseTodo("note to self: breathe", explicitOnly: true))
        XCTAssertEqual(VoiceCommands.parseCalendarAdd("Add it to my calendar.", explicitOnly: true), .fromContext)
        XCTAssertEqual(VoiceCommands.parseCalendarAdd("add dentist Friday at 9 to my calendar", explicitOnly: true), .described("dentist Friday at 9"))
        XCTAssertNil(VoiceCommands.parseCalendarAdd("schedule a call with Noah Friday", explicitOnly: true))
    }
}

final class OutputGuardTests: XCTestCase {
    func testSanitizeStripsWrappers() {
        XCTAssertEqual(OutputGuard.sanitize("<think>hmm</think>\nHere is the cleaned text:\n\"Hello there.\""), "Hello there.")
        XCTAssertEqual(OutputGuard.sanitize("```\nls -la\n```"), "ls -la")
    }

    func testRejectsAnswers() {
        let raw = "um what is the capital of france"
        XCTAssertTrue(OutputGuard.isPlausibleCleanup(raw: raw, output: "What is the capital of France?"))
        XCTAssertFalse(OutputGuard.isPlausibleCleanup(
            raw: "can you write me a short poem about the ocean and waves",
            output: "The ocean breathes in silver light, waves that whisper through the night, endless blue beyond our sight, a song of salt and foam and might."))
    }

    func testAcceptsCorrections() {
        XCTAssertTrue(OutputGuard.isPlausibleCleanup(
            raw: "hey sarah um just wanted to follow up on the the q3 roadmap i think we should push the launch to october no wait november",
            output: "Hey Sarah, I just wanted to follow up on the Q3 roadmap. I think we should push the launch to November."))
    }
}

final class PipelineTests: XCTestCase {
    func testLLMPathWithSnippetsAndDictionary() async {
        let config = PipelineConfig(vocabulary: [VocabularyTerm(term: "Binders", aliases: ["whispering"])],
                                    snippets: [SnippetDefinition(trigger: "my calendar link", expansion: "https://cal.com/x")])
        let result = await DictationPipeline.process(
            raw: "um try whispering and book time with my calendar link press enter",
            context: AppContext(appName: "Slack"), config: config,
            llm: { system, user in
                XCTAssertTrue(system.contains("Binders"))
                XCTAssertTrue(user.contains("⟦1⟧"))
                return "Try Binders and book time with ⟦1⟧."
            })
        XCTAssertEqual(result.text, "Try Binders and book time with https://cal.com/x.")
        XCTAssertTrue(result.pressEnter)
        XCTAssertTrue(result.usedLLM)
        XCTAssertNil(result.fallbackReason)
    }

    func testFallsBackWhenLLMFails() async {
        struct Boom: Error {}
        let result = await DictationPipeline.process(raw: "um hello there", context: AppContext(),
                                                     config: PipelineConfig(), llm: { _, _ in throw Boom() })
        XCTAssertEqual(result.text, "hello there")
        XCTAssertFalse(result.usedLLM)
        XCTAssertNotNil(result.fallbackReason)
    }

    func testFallsBackWhenLLMAnswers() async {
        let result = await DictationPipeline.process(
            raw: "write a haiku about autumn leaves falling", context: AppContext(), config: PipelineConfig(),
            llm: { _, _ in "Crimson leaves descend, whispering to the cold earth, the year exhales slow. Nature rests again under skies of grey." })
        XCTAssertEqual(result.text, "write a haiku about autumn leaves falling")
        XCTAssertNotNil(result.fallbackReason)
    }

    func testCommandModeRoutes() async {
        let search = await CommandPipeline.process(instruction: "search google for swift", context: AppContext(), dictionary: [], llm: nil)
        XCTAssertEqual(search, .openURL(URL(string: "https://www.google.com/search?q=swift")!))

        let rewrite = await CommandPipeline.process(instruction: "make it shorter", context: AppContext(selectedText: "A long sentence here."),
                                                    dictionary: [], llm: { _, user in
                                                        XCTAssertTrue(user.contains("A long sentence here."))
                                                        return "Short."
                                                    })
        XCTAssertEqual(rewrite, .replaceSelection("Short."))
    }
}
