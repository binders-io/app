import XCTest
@testable import BindersKit

/// Lane DS2: a long note read in parts, a second try for a reply with no list, and thinking left out of the reading.
final class DistillPartsTests: XCTestCase {
    private func headings(_ text: String) -> [String] { DistillSections.sections(of: text).compactMap(\.heading) }

    // MARK: Thinking

    func testThinkingBlocksAreNeverRead() {
        // Gemma 4's thought channel, with a draft list inside it, then the answer.
        let gemma = "<|channel>thought\nThe note has two sections. Draft: [{\"title\": \"Draft item\"}]<channel|>[{\"title\": \"Add the form\", \"section\": \"A\"}]<turn|>"
        let read = DistillReading.read(gemma, headings: ["A"])
        XCTAssertEqual(read.items.map(\.title), ["Add the form"], "the draft in the thought isn't an item")
        XCTAssertTrue(read.thought)
        XCTAssertFalse(read.onlyThinking)
        // <think> with prose and a fenced list after it.
        let qwen = "<think>Maybe [{\"title\": \"Wrong\"}]</think>\nHere are the work items I found:\n\n```json\n[{\"title\": \"Right\"}]\n```"
        XCTAssertEqual(DistillReading.read(qwen, headings: []).items.map(\.title), ["Right"])
        // Opened by the chat template: only the closing marker is in the reply.
        XCTAssertEqual(DistillReading.read("I should list the work first.</think>\n[{\"title\": \"Right\"}]", headings: []).items.map(\.title), ["Right"])
        // gpt-oss's analysis channel, and Mistral's [THINK].
        let harmony = "<|channel|>analysis<|message|>Draft [{\"title\": \"X\"}]<|end|><|start|>assistant<|channel|>final<|message|>[{\"title\": \"Y\"}]<|return|>"
        XCTAssertEqual(DistillReading.read(harmony, headings: []).items.map(\.title), ["Y"])
        XCTAssertEqual(DistillReading.read("[THINK]Draft [{\"title\": \"X\"}][/THINK][{\"title\": \"Z\"}]", headings: []).items.map(\.title), ["Z"])
    }

    func testAReplyThatOnlyThoughtHasNoList() {
        // It ran out of tokens while drafting its list inside the thought.
        let reply = "<|channel>thought\nLet me go through it. [{\"title\": \"Draft one\"}, {\"title\": \"Draft two\""
        let read = DistillReading.read(reply, headings: [])
        XCTAssertTrue(read.noList)
        XCTAssertTrue(read.onlyThinking)
        XCTAssertTrue(read.items.isEmpty, "nothing from the thinking is an item")
        XCTAssertNil(read.firstLines, "thinking isn't shown as what it wrote")
        XCTAssertTrue(ModelThinking.split("<think>never closed").stillThinking)
    }

    func testAListAfterProseIsRead() {
        let reply = """
            I read the note. Here are the work items it asks for, in order:

            1. The form
            2. The retry

            [{"title": "Build the form", "section": "Form"}, {"title": "Add retry", "section": "Retry", "waits_for": [1]}]

            Let me know if you want more detail.
            """
        let read = DistillReading.read(reply, headings: ["Form", "Retry"])
        XCTAssertEqual(read.items.map(\.title), ["Build the form", "Add retry"])
        XCTAssertEqual(read.items[1].waitsFor, [0])
    }

    func testThinkingNeverStopsTheReplyOrCountsAgainstIt() {
        let draft = String(repeating: "\"title\": \"Same draft\",\n", count: 4)
        XCTAssertFalse(DistillReading.isLooping("<think>\n" + draft + "</think>\n["), "drafting in the thought isn't looping")
        XCTAssertFalse(DistillReading.isLooping("<|channel>thought\n" + draft), "nor in a thought still going")
        XCTAssertTrue(DistillReading.isLooping("<think>ok</think>[\n" + draft), "in the answer it is")
        let stop = DistillReading.stopWhen(replyTokens: 100)
        XCTAssertFalse(stop("<think>" + String(repeating: "thinking a while\n", count: 200) + "</think>[{\"title\": \"A\"}"),
                       "a long thought doesn't use up the answer's room")
        XCTAssertTrue(stop(String(repeating: "a long answer in prose\n", count: 40)), "a long answer is stopped")
    }

    func testTheFirstLinesShowWhatTheModelWrote() {
        let reply = "<think>hmm</think>\n## Status summary<turn|>\n\nThe checkout work is mostly done.\nThe booth is booked.\nOffline mode is next.\nMore."
        XCTAssertEqual(DistillReading.firstLines(reply), "## Status summary The checkout work is mostly done. The booth is booked. …")
        let long = String(repeating: "word ", count: 100)
        let lines = DistillReading.firstLines(long)!
        XCTAssertTrue(lines.hasSuffix("…") && lines.count <= 241, lines)
        let read = DistillReading.read("I couldn't find a list.", headings: [])
        XCTAssertEqual(read.firstLines, "I couldn't find a list.")
    }

    // MARK: The budget

    func testTheBudgetComesFromTheModelsContext() {
        let unknown = DistillBudget.forContext(nil)
        XCTAssertEqual(unknown.partCharacters, DistillBudget.unknown)
        XCTAssertEqual(unknown.replyTokens, DistillPrompt.maxTokens)
        XCTAssertEqual(unknown.thinkingTokens, DistillBudget.thinkingRoom)
        let gemma = DistillBudget.forContext(262_144)
        XCTAssertEqual(gemma.partCharacters, DistillBudget.readsWell, "however big the context, a part is what reads well")
        XCTAssertEqual(gemma.streamTokens, DistillPrompt.maxTokens + DistillBudget.thinkingRoom)
        let small = DistillBudget.forContext(8_192)
        XCTAssertTrue(small.contextBound)
        XCTAssertLessThan(small.partCharacters, DistillBudget.unknown)
        XCTAssertGreaterThanOrEqual(small.partCharacters, 4_000)
        XCTAssertEqual(small.thinkingTokens, 0)
        // Ollama's own default: a shorter answer, so a part still holds something, and it all fits.
        let ollama = DistillBudget.forContext(4_096)
        XCTAssertLessThan(ollama.replyTokens, DistillPrompt.maxTokens)
        XCTAssertGreaterThanOrEqual(ollama.partCharacters, 2_000)
        XCTAssertLessThanOrEqual(ollama.replyTokens + ollama.partCharacters / 3 + DistillBudget.promptTokens, 4_096)
        XCTAssertLessThanOrEqual(DistillBudget.forContext(6_000).replyTokens, DistillPrompt.maxTokens)
        XCTAssertEqual(unknown.halved.partCharacters, DistillBudget.unknown / 2)
    }

    func testATooLongErrorSaysTheContext() {
        let llama = #"{"error":{"code":400,"message":"the request exceeds the available context size, try increasing it","type":"exceed_context_size_error","n_prompt_tokens":9120,"n_ctx":4096}}"#
        XCTAssertTrue(DistillBudget.isTooLong(llama))
        XCTAssertEqual(DistillBudget.context(fromError: llama), 4_096)
        let vllm = "This model's maximum context length is 8192 tokens. However, you requested 12000 tokens. Please reduce the length of the messages."
        XCTAssertTrue(DistillBudget.isTooLong(vllm))
        XCTAssertEqual(DistillBudget.context(fromError: vllm), 8_192)
        let studio = "Trying to keep the first 9000 tokens when context the overflows. However, the model is loaded with context length of only 4096 tokens"
        XCTAssertEqual(DistillBudget.context(fromError: studio), 4_096)
        XCTAssertFalse(DistillBudget.isTooLong("model not found"))
        XCTAssertNil(DistillBudget.context(fromError: "prompt is too long"))
    }

    // MARK: Parts

    func testANoteThatFitsIsOnePartAsItIs() {
        let spec = DistillBench.specs[0]
        let parts = DistillParts.plan(spec.text, capacity: DistillBudget.unknown)
        XCTAssertEqual(parts.count, 1)
        XCTAssertEqual(parts[0].text, spec.text, "read whole, as before")
    }

    func testALongNoteIsReadInTheFewestEvenPartsSectionBySection() {
        let note = DistillBench.longStatus.text
        XCTAssertGreaterThan(note.count, 58_000)
        XCTAssertLessThan(note.count, 62_000)
        let capacity = 12_000
        let parts = DistillParts.plan(note, capacity: capacity)
        let sections = DistillSections.sections(of: note)
        // The fewest: what packing the sections as full as they go makes; and at least what the length needs.
        let sizes = sections.map { ($0.heading.map { "## \($0)\n\n" } ?? "").count + $0.text.count }
        XCTAssertEqual(parts.count, DistillParts.pack(sizes, limit: capacity).count)
        XCTAssertGreaterThanOrEqual(parts.count, Int((Double(note.count) / Double(capacity)).rounded(.up)))
        XCTAssertTrue(parts.allSatisfy { $0.text.count <= capacity }, parts.map(\.text.count).description)
        // As even as they go: no part is less than half the biggest.
        let biggest = parts.map(\.text.count).max()!
        XCTAssertTrue(parts.dropLast().allSatisfy { $0.text.count * 2 >= biggest }, parts.map(\.text.count).description)
        // Every section once, in order, under its heading, and no other heading in its part.
        XCTAssertEqual(parts.flatMap { $0.pieces.map(\.heading) }, sections.map(\.heading))
        for part in parts {
            XCTAssertEqual(headings(part.text), part.pieces.compactMap(\.heading))
            XCTAssertEqual(part.count, parts.count)
        }
        XCTAssertEqual(parts.map(\.number), Array(1...parts.count))
    }

    func testASectionLongerThanAPartIsCutBetweenParagraphs() {
        let paragraphs = (1...30).map { "Paragraph \($0): " + String(repeating: "status words ", count: 30) }
        let note = "# Long\n\n## Small\n\nShip the thing.\n\n## Huge\n\n" + paragraphs.joined(separator: "\n\n") + "\n\n## After\n\nWrite it up."
        let parts = DistillParts.plan(note, capacity: 3_000)
        let huge = parts.flatMap(\.pieces).filter { $0.heading == "Huge" }
        XCTAssertGreaterThan(huge.count, 1)
        XCTAssertEqual(huge.map(\.piece), Array(1...huge.count).map(Optional.init))
        XCTAssertTrue(huge.allSatisfy { $0.pieces == huge.count })
        XCTAssertTrue(parts.allSatisfy { $0.text.count <= 3_000 })
        // Each piece under the heading; every paragraph read, whole, once.
        let all = parts.map(\.text).joined(separator: "\n\n")
        for paragraph in paragraphs { XCTAssertEqual(all.components(separatedBy: paragraph).count, 2, paragraph.prefix(14).description) }
        let withHuge = parts.filter { $0.pieces.contains { $0.heading == "Huge" } }
        XCTAssertTrue(withHuge.allSatisfy { $0.text.contains("## Huge\n\n") })
        XCTAssertTrue(withHuge[1].holds.contains("\"Huge\" (piece 2 of \(huge.count), cut from a longer section)"), withHuge[1].holds)
        // A paragraph longer than a part: between lines, then words.
        let one = DistillParts.cut(String(repeating: "word ", count: 2_000), limit: 1_000)
        XCTAssertTrue(one.count >= 10 && one.allSatisfy { $0.count <= 1_000 })
    }

    func testThePartPromptHasEveryHeadingWhatThePartHoldsAndTheItemsBefore() {
        let note = DistillBench.longStatus.text
        let parts = DistillParts.plan(note, capacity: 12_000)
        let all = headings(note)
        let prompt = DistillPrompt.part(title: "Spring programme status", sections: all, part: parts[1], earlier: ["One page form", "Card number check"])
        XCTAssertTrue(prompt.contains(DistillPrompt.headingsLine(all)), "the whole list of headings")
        XCTAssertTrue(prompt.contains("you read it in \(parts.count) parts. This is part 2 of \(parts.count): the sections \""))
        XCTAssertTrue(prompt.contains("Work items from the parts before: \"One page form\"; \"Card number check\"."))
        XCTAssertTrue(prompt.contains("by that item's title or by its section's heading"))
        XCTAssertTrue(prompt.hasSuffix(parts[1].text))
        XCTAssertTrue(DistillPrompt.again(prompt).hasSuffix(DistillPrompt.reminder))
        XCTAssertTrue(DistillPrompt.reminder.contains("only the JSON list"))
        let opening = DistillParts.Part(number: 1, count: 2, pieces: [.init(heading: nil), .init(heading: "A"), .init(heading: "B")], text: "")
        XCTAssertEqual(opening.holds, "the note's opening and the sections \"A\" and \"B\"")
        XCTAssertEqual(opening.span, "the opening to “B”")
    }

    // MARK: Merging the parts

    private func item(_ title: String, _ section: String?, waits: [Int] = [], elsewhere: [String] = []) -> DistillReading.Item {
        var item = DistillReading.Item(title: title, brief: "", doneWhen: "", section: section, unknownSection: nil, waitsFor: waits, size: nil, hint: nil, forName: nil)
        item.waitsElsewhere = elsewhere
        return item
    }

    func testMergingLeavesOutRepeatsAndKeepsWaitsAcrossParts() {
        let headings = ["Form", "Retry", "Rollout", "Docs"]
        let one = DistillReading.Result(items: [item("Build the form", "Form"), item("Add retry", "Retry", waits: [0])])
        let two = DistillReading.Result(items: [item("Build the form.", "Rollout"), item("Ship to 10%", "Rollout", elsewhere: ["Build the form", "Retry"]),
                                                item("Decide on 100%", "Rollout", waits: [1]), item("Write the notes", "Docs", elsewhere: ["Nothing like this"])])
        let merged = DistillParts.merge([one, two], headings: headings)
        XCTAssertEqual(merged.items.map(\.title), ["Build the form", "Add retry", "Ship to 10%", "Decide on 100%", "Write the notes"])
        XCTAssertEqual(merged.repeats, 1, "the second part's form is a repeat")
        XCTAssertEqual(merged.items[1].waitsFor, [0])
        XCTAssertEqual(merged.items[2].waitsFor, [0, 1], "by an earlier part's title, and by a heading: every item from it")
        XCTAssertEqual(merged.items[3].waitsFor, [2], "a wait inside its own part, by number")
        XCTAssertEqual(merged.items[4].waitsFor, [])
        XCTAssertEqual(merged.droppedWaits, 1, "a wait on nothing goes")
        XCTAssertTrue(merged.items.allSatisfy(\.waitsElsewhere.isEmpty))
    }

    func testMergingKeepsTheNotesOrderAndAtMostTheItemCap() {
        let headings = (1...6).map { "S\($0)" }
        // A later part's item for an earlier section goes with that section.
        let early = DistillParts.merge([DistillReading.Result(items: [item("A", "S2")]), DistillReading.Result(items: [item("B", "S3"), item("C", "S1")])],
                                       headings: headings)
        XCTAssertEqual(early.items.map(\.title), ["C", "A", "B"])
        // Three parts of ten items: the first 25 in the note's order; a wait on one past them goes.
        let reads = (0..<3).map { part in
            DistillReading.Result(items: (0..<10).map { index in
                item("Item \(part)-\(index)", "S\(part * 2 + 1)", waits: index == 9 ? [8] : [])
            })
        }
        var withWait = reads
        withWait[0].items[0].waitsElsewhere = ["Item 2-9"]
        let merged = DistillParts.merge(withWait, headings: headings)
        XCTAssertEqual(merged.items.count, DistillPrompt.maxItems)
        XCTAssertEqual(merged.over, 5)
        XCTAssertEqual(merged.items.first?.title, "Item 0-0")
        XCTAssertEqual(merged.items.last?.title, "Item 2-4")
        XCTAssertEqual(merged.items[0].waitsFor, [], "its wait was on an item past the cap")
        XCTAssertEqual(merged.droppedWaits, 1)
        XCTAssertEqual(merged.items[9].waitsFor, [8])
        XCTAssertEqual(merged.note, "5 items more than the model was asked for were left out; 1 wait that went in a circle was left out.")
    }

    func testALongNotesPartsAreAllKept() {
        // A note read in parts: every part's items, however many, as the reading merges them (0.11.0 kept the first 25).
        let headings = (1...6).map { "S\($0)" }
        let reads = (0..<3).map { part in
            DistillReading.Result(items: (0..<20).map { item("Item \(part)-\($0)", "S\(part * 2 + 1)") })
        }
        let merged = DistillParts.merge(reads, headings: headings, limit: .max)
        XCTAssertEqual(merged.items.count, 60)
        XCTAssertEqual(merged.over, 0)
        XCTAssertNil(merged.note)
        XCTAssertEqual(merged.items.last?.title, "Item 2-19")
    }

    func testMergingNeverKeepsACircleAcrossParts() {
        let one = DistillReading.Result(items: [item("A", "S1", elsewhere: ["C"])])
        let two = DistillReading.Result(items: [item("C", "S2", elsewhere: ["A"])])
        let merged = DistillParts.merge([one, two], headings: ["S1", "S2"])
        XCTAssertEqual(merged.items[0].waitsFor, [1])
        XCTAssertEqual(merged.items[1].waitsFor, [], "the wait that closes the circle goes")
        XCTAssertNotNil(CardWaits.order(merged.items.map(\.waitsFor)))
    }

    // MARK: The run

    /// A stand-in for the model: answers each question with `answer`, and keeps what it was asked.
    private final class Model: @unchecked Sendable {
        private let lock = NSLock()
        private var _asked: [DistillRun.Ask] = []
        var asked: [DistillRun.Ask] { lock.withLock { _asked } }
        let answer: (DistillRun.Ask) throws -> String
        init(_ answer: @escaping (DistillRun.Ask) throws -> String) { self.answer = answer }
        func ask(_ ask: DistillRun.Ask) throws -> String {
            lock.withLock { _asked.append(ask) }
            return try answer(ask)
        }
    }

    private func run(_ text: String, title: String = "Note", budget: DistillBudget = .forContext(nil), _ model: Model) async throws -> DistillRun.Outcome {
        try await DistillRun.read(title: title, text: text, budget: budget) { try model.ask($0) }
    }

    /// The long note's gold items for the sections a part holds, as a model that reads them right would write them: its
    /// rollout waits for the earlier parts' items by title and by heading.
    private func longReply(_ ask: DistillRun.Ask) -> String {
        let spec = DistillBench.longStatus
        let inPart = Set(ask.user.components(separatedBy: "\n").filter { $0.hasPrefix("## ") }.map { String($0.dropFirst(3)) })
        func title(_ gold: DistillBench.Gold) -> String { gold.words.joined(separator: " ").capitalized }
        let items: [[String: Any]] = spec.gold.compactMap { gold in
            guard let section = gold.section, inPart.contains(section) else { return nil }
            var item: [String: Any] = ["title": title(gold), "brief": gold.words.joined(separator: ", "), "section": section,
                                       "for": gold.person ? "person" : "agent"]
            if section == "Checkout: Rollout", gold.waits.count == 3 {
                item["waits_for"] = [title(spec.gold[gold.waits[0]]), "Checkout: Retry after a failed payment", title(spec.gold[gold.waits[2]])]
            } else if !gold.waits.isEmpty {
                item["waits_for"] = gold.waits.map { title(spec.gold[$0]) }
            }
            return item
        }
        return String(decoding: try! JSONSerialization.data(withJSONObject: items), as: UTF8.self)
    }

    func testANoteThatFitsIsAskedOnceAsBefore() async throws {
        let spec = DistillBench.specs[0]
        let model = Model { _ in DistillFixtures.checkoutClean }
        let outcome = try await run(spec.text, title: spec.name, model)
        XCTAssertEqual(model.asked.count, 1)
        XCTAssertEqual(model.asked[0].user, DistillPrompt.user(title: spec.name, sections: headings(spec.text), text: spec.text))
        XCTAssertEqual(outcome.result, DistillReading.read(DistillFixtures.checkoutClean, headings: headings(spec.text)))
        XCTAssertFalse(outcome.inParts)
        XCTAssertNil(outcome.partsLine)
        XCTAssertNil(outcome.partsNote)
        XCTAssertEqual(model.asked[0].maxTokens, DistillPrompt.maxTokens + DistillBudget.thinkingRoom)
        XCTAssertEqual(model.asked[0].replyTokens, DistillPrompt.maxTokens)
    }

    func testNoListTheFirstTimeAsksOnceMoreWithAReminder() async throws {
        let spec = DistillBench.specs[0]
        let model = Model { $0.attempt == 1 ? "Here is a summary of the checkout note: it is about a redesign." : DistillFixtures.checkoutClean }
        let outcome = try await run(spec.text, title: spec.name, model)
        XCTAssertEqual(model.asked.count, 2)
        XCTAssertTrue(model.asked[1].user.hasSuffix(DistillPrompt.reminder))
        XCTAssertEqual(model.asked[1].attempt, 2)
        XCTAssertEqual(outcome.result.items.count, 8)
        XCTAssertEqual(outcome.parts[0].tries, 2)
        XCTAssertFalse(outcome.noList)
        XCTAssertNil(outcome.firstLines, "a second try that read leaves nothing to show")
    }

    func testProseEveryTimeSaysWhatHappenedInPlainWords() async throws {
        let spec = DistillBench.specs[0]
        let model = Model { _ in "## Summary\nThe note describes a checkout redesign.\nIt has five sections." }
        let outcome = try await run(spec.text, title: spec.name, model)
        XCTAssertEqual(model.asked.count, 2, "once more, then no further")
        XCTAssertTrue(outcome.noList)
        XCTAssertEqual(outcome.firstLines, "## Summary The note describes a checkout redesign. It has five sections.")
        let words = outcome.noListWords(model: "gemma", agents: true)
        XCTAssertTrue(words.hasPrefix("The model answered without a list of work items, even when asked again."), words)
        XCTAssertTrue(words.contains("Distill with one of your agents"))
        XCTAssertFalse(words.contains("too long"), "a short note isn't too long")
        XCTAssertFalse(outcome.noListWords(model: "gemma", agents: false).contains("agents"))
    }

    func testAModelThatOnlyThinksIsSaidSo() async throws {
        let model = Model { _ in "<|channel>thought\nThere is a lot here. Let me think about each section in turn" }
        let outcome = try await run(DistillBench.specs[0].text, model)
        XCTAssertTrue(outcome.noList)
        XCTAssertTrue(outcome.result.onlyThinking)
        XCTAssertNil(outcome.firstLines)
        XCTAssertTrue(outcome.noListWords(model: "gemma", agents: false).hasPrefix("gemma spent its whole reply thinking and never wrote the list"))
    }

    func testALongNoteIsReadInPartsAndMadeOne() async throws {
        let spec = DistillBench.longStatus
        let model = Model { self.longReply($0) }
        let outcome = try await run(spec.text, title: spec.name, model)
        let parts = DistillParts.plan(spec.text, capacity: DistillBudget.unknown)
        XCTAssertEqual(outcome.parts.count, parts.count)
        XCTAssertGreaterThanOrEqual(parts.count, 5)
        XCTAssertEqual(model.asked.count, parts.count, "each part once: every reply had a list")
        XCTAssertEqual(outcome.partsLine, "in \(parts.count) parts")
        XCTAssertNil(outcome.partsNote)
        for (index, ask) in model.asked.enumerated() {
            XCTAssertTrue(ask.user.contains(DistillPrompt.headingsLine(headings(spec.text))), "part \(index + 1) has every heading")
            XCTAssertTrue(ask.user.contains("This is part \(index + 1) of \(parts.count)"))
            XCTAssertTrue(ask.user.hasSuffix(parts[index].text))
            XCTAssertLessThanOrEqual(parts[index].text.count, DistillBudget.unknown)
        }
        // Lane DS8: no part hears the items found before it, so parts can be read at once; repeats go in the merge.
        XCTAssertFalse(model.asked.contains { $0.user.contains("Work items from the parts before") }, "no part hears the items before")
        let score = DistillBench.score(outcome.result, spec: spec)
        XCTAssertEqual(score.found, spec.gold.count, DistillBench.summary([score]).joined(separator: "\n"))
        XCTAssertEqual(score.rightSection, spec.gold.count)
        XCTAssertEqual(score.madeUp, 0)
        XCTAssertEqual(score.waitsFound, score.waitsPossible, "waits across parts kept")
        // The rollout, read last, waits for the form, both retry items (by its heading) and the summary, read parts before.
        let titles = outcome.result.items.map(\.title)
        let flag = outcome.result.items.first { $0.title == "Flag 10%" }!
        XCTAssertEqual(Set(flag.waitsFor.map { titles[$0] }), ["One Page Form", "Retry Keep Typed Details", "Log Failure Reason", "Order Summary Total"])
        XCTAssertEqual(titles.last, "Compare Abandonment Decide 100%", "in the note's order")
    }

    func testAPartWithNoListIsNotedAndTheRestKept() async throws {
        let spec = DistillBench.longStatus
        let model = Model { ask in ask.part == 3 ? "This part is all status updates." : self.longReply(ask) }
        let outcome = try await run(spec.text, title: spec.name, model)
        XCTAssertEqual(model.asked.filter { $0.part == 3 }.count, 2)
        XCTAssertFalse(outcome.noList)
        XCTAssertFalse(outcome.result.items.isEmpty)
        let note = outcome.partsNote ?? ""
        XCTAssertTrue(note.hasPrefix("Part 3 of \(outcome.parts.count) (“"), note)
        XCTAssertTrue(note.contains("had no list of work items, even when asked again, so its work isn't here. The model wrote: “This part is all status updates.”"), note)
        XCTAssertTrue(note.hasSuffix("Distill Again to read the note again."))
    }

    func testALongNoteWithNoListAnywhereMayBeTooLongForTheModel() async throws {
        let spec = DistillBench.longStatus
        let model = Model { _ in "Status: all projects are on track." }
        let outcome = try await run(spec.text, title: spec.name, model)
        XCTAssertEqual(model.asked.count, outcome.parts.count * 2)
        XCTAssertTrue(outcome.noList)
        let words = outcome.noListWords(model: "mlx-community/gemma-4-26b-a4b-it-4bit", agents: true)
        XCTAssertEqual(words, "The model answered without a list of work items for each of the \(outcome.parts.count) parts of this note, even when asked again, "
                       + "so the note may be too long for mlx-community/gemma-4-26b-a4b-it-4bit. Distill it with one of your agents instead, or choose another model in Settings → AI.")
        XCTAssertEqual(outcome.firstLines, "Status: all projects are on track.")
    }

    func testAModelThatSaysTheNoteIsTooLongIsAskedInSmallerParts() async throws {
        let spec = DistillBench.longStatus
        let model = Model { ask in
            if ask.user.count > 9_000 { throw DistillRun.TooLong(contextTokens: 6_000) }
            return self.longReply(ask)
        }
        let outcome = try await run(spec.text, title: spec.name, model)
        XCTAssertEqual(outcome.budget.contextTokens, 6_000)
        XCTAssertLessThan(outcome.capacity, DistillBudget.unknown)
        XCTAssertGreaterThan(outcome.parts.count, DistillParts.plan(spec.text, capacity: DistillBudget.unknown).count)
        XCTAssertEqual(DistillBench.score(outcome.result, spec: spec).found, spec.gold.count)
    }

    func testAnErrorOnEveryPartEndsItAndOnOnePartIsNoted() async throws {
        struct Down: Error {}
        let first = Model { _ in throw Down() }
        do {
            _ = try await run(DistillBench.longStatus.text, first)
            XCTFail("the reading can't be done")
        } catch {
            XCTAssertTrue(error is Down)
        }
        // Lane DS7: the first part's error no longer ends it; two parts in a row with nothing do.
        XCTAssertEqual(first.asked.count, 2)
        let later = Model { ask in if ask.part == 2 { throw Down() }; return self.longReply(ask) }
        let outcome = try await run(DistillBench.longStatus.text, later)
        XCTAssertNotNil(outcome.parts[1].error)
        XCTAssertEqual(later.asked.filter { $0.part == 2 }.count, 1, "an error isn't asked again")
        XCTAssertTrue(outcome.partsNote?.hasPrefix("Part 2 of") == true)
    }

    // MARK: Records

    func testADistillWrittenBeforeHasNoParts() throws {
        let old = #"{"id":"9F1C2B6E-6D53-4D69-9B47-1B3E8C1E3B11","note":"6A0B2C3D-1E2F-4A5B-8C9D-0E1F2A3B4C5D","ranBy":"You","readBy":"stand-in","status":"proposed","items":[]}"#
        let record = try JSONDecoder().decode(DistillRecord.self, from: Data(old.utf8))
        XCTAssertNil(record.parts)
        XCTAssertNil(record.readNote)
        var now = record
        now.parts = 4
        now.readNote = "Part 2 of 4 had no list."
        let again = try JSONDecoder().decode(DistillRecord.self, from: JSONEncoder().encode(now))
        XCTAssertEqual(again.parts, 4)
        XCTAssertEqual(again.readNote, "Part 2 of 4 had no list.")
    }
}
