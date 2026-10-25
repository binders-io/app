import XCTest
@testable import BindersKit

/// Lane DS7: a slow model reads a long note without "The model took too long to answer": the stall rule, parts sized from
/// the model's speed, a part cut short kept up to its last whole item, a reading that goes on after a failed first part,
/// and the progress line.
final class DistillPaceTests: XCTestCase {
    // MARK: The stall rule

    func testAReplyIsStoppedOnAStallNotOnAStopwatch() {
        let pace = StreamPace.distill
        XCTAssertEqual(pace.firstWords, 300)
        XCTAssertEqual(pace.idle, 90)
        XCTAssertEqual(pace.ceiling, 1_200)
        // Before its first words: the longer allowance, for loading the model and reading a long part.
        XCTAssertNil(pace.stop(elapsed: 299, sinceWords: nil))
        XCTAssertEqual(pace.stop(elapsed: 300, sinceWords: nil), .noStart)
        // Writing steadily: never stopped, however long, up to the ceiling.
        XCTAssertNil(pace.stop(elapsed: 900, sinceWords: 2))
        XCTAssertNil(pace.stop(elapsed: 1_100, sinceWords: 89))
        XCTAssertEqual(pace.stop(elapsed: 400, sinceWords: 90), .stalled)
        XCTAssertEqual(pace.stop(elapsed: 1_200, sinceWords: 1), .ceiling)
        XCTAssertEqual(pace.stop(elapsed: 1_250, sinceWords: nil), .ceiling)
        XCTAssertEqual(pace.tick, 1)
        XCTAssertEqual(StreamPace(firstWords: 1, idle: 0.4, ceiling: 5).tick, 0.1, accuracy: 0.0001)
    }

    func testWhyItStoppedInWords() {
        let pace = StreamPace.distill
        XCTAssertEqual(StreamStop.stalled.words(pace), "the model stopped writing for 90 seconds")
        XCTAssertEqual(StreamStop.noStart.words(pace), "the model wrote nothing for 5 minutes")
        XCTAssertEqual(StreamStop.ceiling.words(pace), "it was still writing after 20 minutes")
        XCTAssertEqual(StreamStop.stopped.words(pace), "you stopped the reading")
        XCTAssertEqual(StreamStop.duration(0.4), "1 second")
        XCTAssertEqual(StreamStop.duration(119), "119 seconds")
        XCTAssertEqual(StreamStop.duration(420), "7 minutes")
        XCTAssertEqual(StreamStop.duration(60 * 1.4 + 60), "2 minutes")
    }

    // MARK: Parts sized from the model's speed

    /// A dense 27B on a Mac with 48 GB, about: reads 600 characters a second, writes 70.
    private let slow = DistillSpeed(readsPerSecond: 600, writesPerSecond: 70)
    private let fast = DistillSpeed(readsPerSecond: 8_000, writesPerSecond: 600)

    func testAModelInBindersNotYetMeasuredStartsWithSmallerParts() {
        let wide = DistillBudget.forContext(262_144)
        XCTAssertEqual(wide.partCharacters, DistillBudget.readsWell)
        let paced = wide.paced(nil, place: .inApp)
        XCTAssertEqual(paced.partCharacters, 6_000)
        XCTAssertEqual(paced.maxItems, 15, "items in proportion, with room for a dense part")
        XCTAssertEqual(paced.replyTokens, 15 * 120)
        XCTAssertEqual(paced.thinkingTokens, wide.thinkingTokens)
        XCTAssertTrue(paced.paced)
        // A server on this Mac, or elsewhere, keeps today's sizes until it's measured slow (elsewhere: always).
        XCTAssertEqual(wide.paced(nil, place: .thisMac), wide)
        XCTAssertEqual(wide.paced(nil, place: .elsewhere), wide)
        XCTAssertEqual(wide.paced(slow, place: .elsewhere), wide)
    }

    func testASlowModelsPartsAreReadInAboutTwoMinutes() {
        let wide = DistillBudget.forContext(262_144)
        let paced = wide.paced(slow, place: .inApp)
        XCTAssertLessThan(paced.partCharacters, DistillBudget.readsWell)
        XCTAssertGreaterThanOrEqual(paced.partCharacters, DistillBudget.smallest)
        XCTAssertLessThanOrEqual(slow.seconds(part: paced.partCharacters, overhead: DistillBudget.overhead), DistillBudget.partSeconds + 0.5)
        XCTAssertGreaterThan(slow.seconds(part: paced.partCharacters + 500, overhead: DistillBudget.overhead), DistillBudget.partSeconds,
                             "as big as fits the two minutes")
        XCTAssertEqual(paced.maxItems, DistillBudget.items(forPart: paced.partCharacters))
        XCTAssertEqual(paced.replyTokens, min(DistillPrompt.maxTokens, paced.maxItems * 120))
        // Measured slow on this Mac's server too.
        XCTAssertEqual(wide.paced(slow, place: .thisMac).partCharacters, paced.partCharacters)
        // A fast model keeps today's sizes, measured or not.
        XCTAssertEqual(wide.paced(fast, place: .inApp), wide)
        // Never below the smallest part, however slow.
        let crawl = DistillSpeed(readsPerSecond: 20, writesPerSecond: 2)
        XCTAssertEqual(wide.paced(crawl, place: .inApp).partCharacters, DistillBudget.smallest)
        XCTAssertEqual(wide.paced(crawl, place: .inApp).maxItems, 8)
    }

    func testASpeedIsMeasuredFromAnAskAndBlended() {
        let timing = StreamTiming(firstWords: 20, lastWords: 80, characters: 4_200, total: 80)
        let measured = DistillSpeed.measured(prompt: 12_000, timing: timing)
        XCTAssertEqual(measured?.readsPerSecond ?? 0, 600, accuracy: 0.01)
        XCTAssertEqual(measured?.writesPerSecond ?? 0, 70, accuracy: 0.01)
        XCTAssertNil(DistillSpeed.measured(prompt: 12_000, timing: StreamTiming(firstWords: nil, lastWords: nil, characters: 0, total: 300)),
                     "no words: nothing to measure")
        XCTAssertNil(DistillSpeed.measured(prompt: 12_000, timing: StreamTiming(firstWords: 2, lastWords: 2.5, characters: 120, total: 3)),
                     "too little to say")
        let blended = DistillSpeed(readsPerSecond: 100, writesPerSecond: 10).blended(DistillSpeed(readsPerSecond: 300, writesPerSecond: 30))
        XCTAssertEqual(blended.readsPerSecond, 200, accuracy: 0.01)
        XCTAssertEqual(blended.samples, 2)
        var many = DistillSpeed(readsPerSecond: 100, writesPerSecond: 10, samples: 9)
        many = many.blended(DistillSpeed(readsPerSecond: 500, writesPerSecond: 50))
        XCTAssertEqual(many.readsPerSecond, 200, accuracy: 0.01, "a new measure counts for a quarter at least")
        // Kept in defaults as JSON.
        let again = try? JSONDecoder().decode(DistillSpeed.self, from: JSONEncoder().encode(blended))
        XCTAssertEqual(again, blended)
    }

    func testAPacedBudgetAsksForFewerItemsAPart() async throws {
        let spec = DistillBench.longStatus
        let budget = DistillBudget.forContext(262_144).paced(nil, place: .inApp)
        let model = Model { _ in "[]" }
        let outcome = try await DistillRun.read(title: spec.name, text: spec.text, budget: budget) { try model.ask($0) }
        XCTAssertGreaterThan(outcome.parts.count, DistillParts.plan(spec.text, capacity: DistillBudget.readsWell).count)
        XCTAssertTrue(model.asked.allSatisfy { $0.maxItems == 15 && $0.replyTokens == 1_800 })
        XCTAssertTrue(model.asked.allSatisfy { $0.user.contains("List only the work this part asks for, at most 15 items.") })
        XCTAssertTrue(DistillPrompt.user(title: "N", sections: [], text: "x", items: 10).contains("List at most 10 work items."))
        XCTAssertEqual(DistillPrompt.user(title: "N", sections: [], text: "x"), DistillPrompt.user(title: "N", sections: [], text: "x", items: 25),
                       "today's question unchanged")
    }

    // MARK: A part cut short

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

    /// Three parts: "A", "B", "C", each about 5,000 characters, with a part's items as the model would list them.
    private let threeParts: String = {
        let body = String(repeating: "Some words about the work here. ", count: 150)
        return "# Plan\n\n## A\n\n\(body)\n\n## B\n\n\(body)\n\n## C\n\n\(body)"
    }()

    private func items(_ section: String, _ count: Int) -> String {
        "[" + (1...count).map { "{\"title\": \"Do \(section) \($0)\", \"section\": \"\(section)\"}" }.joined(separator: ", ") + "]"
    }

    private func section(of ask: DistillRun.Ask) -> String {
        ask.user.components(separatedBy: "\n").first { $0.hasPrefix("## ") }.map { String($0.dropFirst(3)) } ?? ""
    }

    private let budget = DistillBudget(contextTokens: nil, partCharacters: 6_000, replyTokens: 3_000, thinkingTokens: 0)

    private func stopped(_ why: StreamStop, _ text: String) -> StreamStopped {
        StreamStopped(why: why, pace: .distill, text: text, timing: StreamTiming(firstWords: 5, lastWords: 50, characters: text.count, total: 140))
    }

    func testAPartThatStallsKeepsItsWholeItemsAndTheReadingGoesOn() async throws {
        let model = Model { ask in
            let section = self.section(of: ask)
            if section == "B" {
                // Two whole items, the third cut part way, held to the schema's object.
                throw self.stopped(.stalled, "{\"items\": [{\"title\": \"Do B 1\", \"section\": \"B\"}, {\"title\": \"Do B 2\", \"section\": \"B\"}, {\"title\": \"Do B")
            }
            return self.items(section, 2)
        }
        let outcome = try await DistillRun.read(title: "Plan", text: threeParts, budget: budget) { try model.ask($0) }
        XCTAssertEqual(outcome.parts.count, 3)
        XCTAssertEqual(model.asked.count, 3, "the stalled part isn't asked again, and the last part is read")
        XCTAssertEqual(outcome.result.items.map(\.title), ["Do A 1", "Do A 2", "Do B 1", "Do B 2", "Do C 1", "Do C 2"])
        XCTAssertEqual(outcome.parts[1].stop, .stalled)
        XCTAssertEqual(outcome.parts[1].items, 2)
        XCTAssertFalse(outcome.result.cutOff, "the part's note says it, not the reading's")
        XCTAssertTrue(outcome.cutShort)
        XCTAssertFalse(outcome.stopped)
        XCTAssertEqual(outcome.partsNote, "Part 2 of 3 (“B”) was cut short: the model stopped writing for 90 seconds. The 2 items it had finished are here. "
                       + "Distill Again to read the rest: it proposes only what's new.")
        XCTAssertEqual(model.asked[2].itemsBefore, 4, "the items so far count what's kept")
    }

    func testAOnePartNoteCutShortSaysSo() async throws {
        let model = Model { _ in throw self.stopped(.ceiling, "[{\"title\": \"Do A 1\"}, {\"title\": \"Do A 2\"}, {\"title\": \"Do") }
        let outcome = try await DistillRun.read(title: "Plan", text: "## A\n\nShort.", budget: budget) { try model.ask($0) }
        XCTAssertEqual(outcome.result.items.count, 2)
        XCTAssertEqual(outcome.partsNote, "The reading was cut short: it was still writing after 20 minutes. The 2 items it had finished are here. "
                       + "Distill Again to read the rest: it proposes only what's new.")
        let nothing = Model { _ in throw self.stopped(.noStart, "") }
        let empty = try await DistillRun.read(title: "Plan", text: "## A\n\nShort.", budget: budget) { try nothing.ask($0) }
        XCTAssertTrue(empty.result.items.isEmpty)
        XCTAssertFalse(empty.noList, "cut short isn't a reply with no list")
        XCTAssertEqual(empty.partsNote, "The reading was cut short: the model wrote nothing for 5 minutes. It hadn't finished an item. "
                       + "Distill Again to read the rest: it proposes only what's new.")
    }

    func testStoppingKeepsWhatsDoneAndReadsNoMore() async throws {
        let model = Model { ask in
            let section = self.section(of: ask)
            if section == "B" { throw self.stopped(.stopped, "[{\"title\": \"Do B 1\", \"section\": \"B\"}, {\"title\": \"Do") }
            return self.items(section, 2)
        }
        let outcome = try await DistillRun.read(title: "Plan", text: threeParts, budget: budget) { try model.ask($0) }
        XCTAssertEqual(model.asked.count, 2, "part 3 isn't asked")
        XCTAssertEqual(outcome.result.items.map(\.title), ["Do A 1", "Do A 2", "Do B 1"])
        XCTAssertTrue(outcome.stopped)
        XCTAssertTrue(outcome.parts[2].notRead)
        XCTAssertEqual(outcome.partsNote, "You stopped the reading in part 2 of 3 (“B”). The 1 item it had finished is here. Part 3 of 3 wasn't read. "
                       + "Distill Again to read the rest: it proposes only what's new.")
    }

    func testAFailedFirstPartNoLongerEndsTheReading() async throws {
        struct Down: LocalizedError { var errorDescription: String? { "The model took too long to answer." } }
        let model = Model { ask in
            if ask.part == 1 { throw Down() }
            return self.items(self.section(of: ask), 2)
        }
        let outcome = try await DistillRun.read(title: "Plan", text: threeParts, budget: budget) { try model.ask($0) }
        XCTAssertEqual(model.asked.count, 3)
        XCTAssertEqual(outcome.result.items.map(\.title), ["Do B 1", "Do B 2", "Do C 1", "Do C 2"])
        XCTAssertEqual(outcome.parts[0].error, "The model took too long to answer.")
        XCTAssertEqual(outcome.partsNote, "Part 1 of 3 (“A”) couldn't be read: The model took too long to answer. Distill Again to read the note again.")
    }

    func testAModelThatNeverStartsTwiceEndsTheReading() async throws {
        let model = Model { _ in throw self.stopped(.noStart, "") }
        let outcome = try await DistillRun.read(title: "Plan", text: threeParts, budget: budget) { try model.ask($0) }
        XCTAssertEqual(model.asked.count, 2)
        XCTAssertTrue(outcome.parts[2].notRead)
        XCTAssertTrue(outcome.partsNote?.contains("Part 3 of 3 wasn't read: the model didn't answer for two parts in a row.") == true, outcome.partsNote ?? "")
    }

    // MARK: Showing it move

    func testItemsSoFarAreCountedFromTheReplyAsItComes() {
        XCTAssertEqual(DistillReading.wholeItems(""), 0)
        XCTAssertEqual(DistillReading.wholeItems("[\n  {\"title\": \"A\", \"waits_for\": [1, 2]},\n  {\"title\": \"B\", \"brief\": \"a } in {a} string\"},\n  {\"title\": \"C"), 2)
        XCTAssertEqual(DistillReading.wholeItems("{\"items\": [{\"title\": \"A\"}, {\"title\": \"B\"}]}"), 2)
        XCTAssertEqual(DistillReading.wholeItems("<think>[{\"title\": \"draft\"}]</think>[{\"title\": \"A\"}"), 1, "the thinking isn't counted")
        XCTAssertEqual(DistillReading.wholeItems("Here is what I found:\n```json\n["), 0)
    }

    func testTheReadingLine() {
        XCTAssertEqual(DistillRun.readingLine(part: 2, of: 5, items: 9), "Reading part 2 of 5 · 9 items so far")
        XCTAssertEqual(DistillRun.readingLine(part: 1, of: 5, items: 0), "Reading part 1 of 5…")
        XCTAssertEqual(DistillRun.readingLine(part: 1, of: 1, items: 1), "Reading the note · 1 item so far")
        XCTAssertEqual(DistillRun.readingLine(part: 1, of: 1, items: 0), "Reading the note…")
    }

    // MARK: A quicker model

    func testAQuickerInstalledModelIsOfferedNeverATinyOne() {
        let qwen = DistillQuicker.Model(id: "mlx-community/Qwen3.8-27B-4bit", bytes: 16_100)
        let gemma = DistillQuicker.Model(id: "mlx-community/gemma-4-26b-a4b-it-4bit", bytes: 15_400)
        let small = DistillQuicker.Model(id: "mlx-community/gemma-4-e2b-it-4bit", bytes: 3_600)
        let twelve = DistillQuicker.Model(id: "mlx-community/gemma-4-12B-it-qat-4bit", bytes: 11_000)
        let embed = DistillQuicker.Model(id: "mlx-community/embeddinggemma-300m-4bit", bytes: 200)
        XCTAssertEqual(DistillQuicker.activeShare(gemma.id), 4.0 / 26.0, accuracy: 0.0001)
        XCTAssertEqual(DistillQuicker.activeShare(qwen.id), 1)
        XCTAssertEqual(DistillQuicker.pick(current: qwen, among: [qwen, gemma, small, twelve, embed]), gemma.id)
        XCTAssertNil(DistillQuicker.pick(current: qwen, among: [qwen, small, twelve, embed]), "a 12B dense isn't quick enough, a small one finds less")
        XCTAssertNil(DistillQuicker.pick(current: gemma, among: [qwen, gemma]), "the quick one has nothing quicker")
        // Measures, where both have them, decide.
        var measuredQwen = qwen, measuredTwelve = twelve
        measuredQwen.speed = slow
        measuredTwelve.speed = fast
        XCTAssertEqual(DistillQuicker.pick(current: measuredQwen, among: [measuredQwen, measuredTwelve]), twelve.id)
        XCTAssertEqual(DistillQuicker.tookLine(seconds: 420, model: "Qwen3.8-27B-4bit"), "Reading it took 7 minutes with Qwen3.8-27B-4bit.")
    }
}
