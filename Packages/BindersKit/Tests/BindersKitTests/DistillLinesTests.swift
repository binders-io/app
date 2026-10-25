import XCTest
@testable import BindersKit

/// Lane DS8: Distill reads fast. Numbered lines, v2's short replies and what the app takes from their lines, parts read
/// without hearing each other, readings kept by section, the pace with v2's smaller answers, and briefs written later.
final class DistillLinesTests: XCTestCase {
    private func headings(_ text: String) -> [String] { DistillSections.sections(of: text).compactMap(\.heading) }

    // MARK: Numbered lines

    func testLinesAreNumberedHeadingsAndBlankLinesAreNot() {
        let text = "# Launch\n\nWhy we do it.\n\n## Form\n- Add the form.\n- Check the card.\n\n### Details\nUse the brand colours.\n\n## Retry\nOffer Retry."
        let lines = DistillLines(text)
        XCTAssertEqual(lines.numbered.map(\.id), [1, 2, 3, 4, 5])
        XCTAssertEqual(lines.numbered.map(\.text), ["Why we do it.", "- Add the form.", "- Check the card.", "Use the brand colours.", "Offer Retry."])
        XCTAssertEqual(lines.numbered.map(\.section), [nil, "Form", "Form", "Form", "Retry"], "a ### heading stays inside its ## section")
        XCTAssertEqual(lines.rendered, "# Launch\n1| Why we do it.\n## Form\n2| - Add the form.\n3| - Check the card.\n### Details\n4| Use the brand colours.\n## Retry\n5| Offer Retry.")
        XCTAssertEqual(DistillLines(text), lines, "the same text numbers the same way")
        XCTAssertEqual(lines.last, 5)
    }

    func testALongParagraphIsCutAtItsSentences() {
        let paragraph = "When the bank declines a card or the connection drops, keep everything the customer typed and offer Retry. "
            + "Log each failure with its reason code, e.g. a timeout, so support can look it up later. "
            + "Show it. Then send a short email to the customer within 3.5 hours saying what happened and what to do next."
        XCTAssertGreaterThan(paragraph.count, DistillLines.longLine)
        let lines = DistillLines("## Retry\n" + paragraph)
        let texts = lines.numbered.map(\.text)
        XCTAssertEqual(texts.count, 3, "three sentences, the short one with the next: \(texts)")
        XCTAssertTrue(texts[0].hasSuffix("offer Retry."))
        XCTAssertTrue(texts[1].contains("e.g. a timeout"), "an abbreviation isn't a sentence's end")
        XCTAssertTrue(texts[2].hasPrefix("Show it. Then send"), "a short sentence goes with the next")
        XCTAssertTrue(texts[2].contains("3.5 hours"))
        for text in texts { XCTAssertTrue(paragraph.contains(text), "each piece is the note's own words: \(text)") }
        XCTAssertEqual(DistillLines("A short line.").numbered.count, 1)
    }

    func testCodeBlocksAndMermaidStayWhole() {
        let text = "## Flow\nThe flow:\n```mermaid\ngraph TD\n## not a heading\nA --> B\n```\nThen ship it.\n```swift\nlet x = 1\n```"
        let lines = DistillLines(text)
        XCTAssertEqual(lines.numbered.count, 4)
        XCTAssertEqual(lines.line(2)?.text, "```mermaid\ngraph TD\n## not a heading\nA --> B\n```", "a Mermaid block is one line")
        XCTAssertEqual(lines.line(3)?.section, "Flow", "a heading in a code block isn't one")
        XCTAssertEqual(lines.line(4)?.text, "```swift\nlet x = 1\n```")
        XCTAssertEqual(lines.resolve([2]).quote, "graph TD", "a block's quote is its first line of code")
        XCTAssertEqual(DistillLines("```\nnever closed\nstill code").numbered.count, 1)
    }

    func testAnItemsLinesGiveItsQuoteSectionAndBrief() {
        let lines = DistillLines("Intro line.\n## Payment form\n- [ ] One page instead of three.\n- Card numbers are checked as they're typed.\n## Rollout\n1. Ship behind a flag.")
        let one = lines.resolve([2, 3, 2, 99, 0])
        XCTAssertEqual(one.ids, [2, 3], "repeats once, numbers that aren't lines left out")
        XCTAssertEqual(one.dropped, 2)
        XCTAssertEqual(one.quote, "One page instead of three.", "the first line's words, its marker off")
        XCTAssertEqual(one.section, "Payment form")
        XCTAssertEqual(one.source, "One page instead of three.\nCard numbers are checked as they're typed.")
        XCTAssertEqual(lines.resolve([4]).quote, "Ship behind a flag.")
        XCTAssertNil(lines.resolve([1]).section, "the opening has no section")
        XCTAssertEqual(lines.resolve([1, 2, 3, 4]).ids.count, 4)
        XCTAssertEqual(DistillLines("a\nb\nc\nd\ne").resolve([1, 2, 3, 4, 5]).ids, [1, 2, 3, 4], "at most four")
    }

    // MARK: Reading a v2 reply

    func testAV2ReplyIsReadFromItsLines() {
        let note = "# Checkout\n\n## Payment form\n- One page instead of three.\n- Card numbers are checked as they're typed.\n\n## Rollout\nShip behind a flag once the form is done."
        let lines = DistillLines(note)
        let reply = #"{"items":[{"title":"Combine checkout into one page","lines":[1],"for":"agent","size":"medium"},"#
            + #"{"title":"Check card numbers","lines":"2","for":"agent","size":"small","after":1},"#
            + #"{"title":"Ship behind a flag","lines":[3, 40],"for":"person","size":"small","after":1},"#
            + #"{"title":"Something from nowhere","lines":[77],"for":"agent","size":"small"}]}"#
        var read = DistillReading.read(reply, headings: headings(note))
        read.resolve(lines: lines, headings: headings(note))
        XCTAssertEqual(read.items.map(\.title), ["Combine checkout into one page", "Check card numbers", "Ship behind a flag", "Something from nowhere"])
        XCTAssertEqual(read.items.map(\.quote), ["One page instead of three.", "Card numbers are checked as they're typed.", "Ship behind a flag once the form is done.", nil])
        XCTAssertEqual(read.items.map(\.section), ["Payment form", "Payment form", "Rollout", nil])
        XCTAssertEqual(read.items[0].brief, "One page instead of three.", "a first brief: the lines themselves")
        XCTAssertTrue(read.items[0].briefPending)
        XCTAssertEqual(read.items[1].waitsFor, [0], "after names an earlier item")
        XCTAssertEqual(read.items[2].lines, [3])
        XCTAssertEqual(read.droppedLines, 2)
        XCTAssertEqual(read.items[3].lines, [], "an item with no line that's here keeps its title and has no quote")
        XCTAssertEqual(read.items[0].hint, .agent)
        XCTAssertEqual(read.items[2].hint, .person)
        let items = read.items(sections: DistillSections.sections(of: note))
        XCTAssertEqual(items[0].briefPending, true)
        XCTAssertEqual(items[0].sectionHash, DistillSections.section("Payment form", in: note)?.hash)
    }

    func testAReplyWrittenAsV1IsReadAsItWas() {
        let note = "## Form\nAdd the form."
        var read = DistillReading.read(#"[{"title":"Add the form","brief":"So people can sign up.","section":"Form","quote":"Add the form"}]"#, headings: ["Form"])
        read.resolve(lines: DistillLines(note), headings: ["Form"])
        XCTAssertEqual(read.items.first?.brief, "So people can sign up.")
        XCTAssertEqual(read.items.first?.quote, "Add the form")
        XCTAssertEqual(read.items.first?.briefPending, false)
    }

    func testLineRangesAndRepeatsFromTheSameLines() {
        let lines = DistillLines("## A\none\ntwo\nthree\nfour")
        var read = DistillReading.read(#"[{"title":"Do the first two","lines":"1-2"},{"title":"Do the first two now","lines":[2]},{"title":"Do four","lines":["4"], "after": 2}]"#, headings: ["A"])
        read.resolve(lines: lines, headings: ["A"])
        XCTAssertEqual(read.items.map(\.title), ["Do the first two", "Do four"], "the same line with much the same title is a repeat")
        XCTAssertEqual(read.repeats, 1)
        XCTAssertEqual(read.items[0].lines, [1, 2])
        XCTAssertEqual(read.items[1].waitsFor, [0], "a wait on the repeat goes to the item it repeats")
    }

    func testRepeatsAcrossPartsByTheirLine() {
        func item(_ title: String, quote: String) -> DistillReading.Item {
            DistillReading.Item(title: title, brief: "", doneWhen: "", section: "A", unknownSection: nil, quote: quote, waitsFor: [], size: nil, hint: nil, forName: nil)
        }
        let merged = DistillParts.merge([DistillReading.Result(items: [item("Add the signup form", quote: "Add a form")]),
                                         DistillReading.Result(items: [item("Add signup form to footer", quote: "Add a form"), item("Send email", quote: "Email")])],
                                        headings: ["A"])
        XCTAssertEqual(merged.items.map(\.title), ["Add the signup form", "Send email"])
        XCTAssertEqual(merged.repeats, 1)
        let many = (1...30).map { DistillReading.Result(items: [item("Item \($0)", quote: "q\($0)")]) }
        XCTAssertEqual(DistillParts.merge(many, headings: ["A"]).items.count, DistillPrompt.maxItems)
        XCTAssertEqual(DistillParts.merge(many, headings: ["A"], limit: 40).items.count, 30)
    }

    // MARK: The v2 schema and prompt

    func testTheV2SchemaIsShortAndTheSameForEveryNote() throws {
        let schema = DistillSchema.jsonV2()
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(schema.utf8)) as? [String: Any])
        let item = try XCTUnwrap((((object["properties"] as? [String: Any])?["items"] as? [String: Any])?["items"]) as? [String: Any])
        XCTAssertEqual(item["required"] as? [String], ["title", "lines", "for", "size"], "after is left out when there's nothing to wait for")
        XCTAssertTrue(schema.contains(#""title":{"type":"string"},"lines":"#), "in the prompt's order")
        XCTAssertFalse(schema.contains("quote") || schema.contains("brief") || schema.contains("section"))
        let portable = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(DistillSchema.jsonV2(bounded: false).utf8)) as? [String: Any])
        let strict = try XCTUnwrap((((portable["properties"] as? [String: Any])?["items"] as? [String: Any])?["items"]) as? [String: Any])
        XCTAssertEqual(strict["required"] as? [String], ["title", "lines", "for", "size", "after"], "a strict server wants every key, after as null")
        XCTAssertTrue(DistillSchema.jsonV2(names: ["Echo"]).contains(#""enum":["Echo","agent","person","either"]"#))
        // The v1 schema differs with the headings; v2's doesn't, so its grammar is compiled once.
        let a = DistillRun.Ask(user: "", maxTokens: 1, replyTokens: 1, part: 1, parts: 1, attempt: 1, headings: ["A"], format: .v2)
        let b = DistillRun.Ask(user: "", maxTokens: 1, replyTokens: 1, part: 2, parts: 3, attempt: 1, headings: ["B", "C"], format: .v2)
        XCTAssertEqual(a.schema(bounded: true), b.schema(bounded: true))
    }

    func testTheV2PromptIsShorterAndListsWhoCanTakeWork() {
        XCTAssertLessThan(DistillPrompt.systemV2.count, DistillPrompt.system.count)
        XCTAssertTrue(DistillPrompt.systemV2.contains(DistillPrompt.forLine))
        let who = DistillTakers(agents: [DistillTakers.Agent(name: "Echo", whatFor: "the web pages", kinds: "coding")], people: [])
        let system = DistillPrompt.system(who: who, format: .v2)
        XCTAssertTrue(system.contains("\"Echo\", an AI agent") && system.contains(who.forLine) && !system.contains(DistillPrompt.forLine))
        XCTAssertEqual(DistillPrompt.system(who: nil, format: .v1), DistillPrompt.system)
    }

    func testEveryPartSharesItsStartAndHearsNothingOfTheOthers() async throws {
        let spec = DistillBench.long(characters: 30_000)
        let asked = Asked()
        let outcome = try await DistillRun.read(title: spec.name, text: spec.text, budget: .forContext(nil, format: .v2), format: .v2) { ask in
            asked.add(ask)
            return DistillBench.standInReply(ask, spec: spec)
        }
        let asks = asked.all
        XCTAssertGreaterThan(asks.count, 1)
        let prefix = DistillPrompt.prefix(title: spec.name, sections: headings(spec.text))
        XCTAssertTrue(asks.allSatisfy { $0.prefix == prefix && $0.user.hasPrefix(prefix) }, "the same start, first, for every part")
        XCTAssertTrue(asks.allSatisfy { $0.system == DistillPrompt.systemV2 })
        XCTAssertTrue(asks.allSatisfy { $0.user.contains("1| ") && $0.lines != nil }, "numbered lines")
        XCTAssertFalse(asks.contains { $0.user.contains("Work items from the parts before") })
        let score = DistillBench.score(outcome.result, spec: spec)
        XCTAssertEqual(score.found, spec.gold.count, DistillBench.summary([score]).joined(separator: "\n"))
        XCTAssertEqual(score.rightSection, spec.gold.count, "sections come from the lines")
        XCTAssertEqual(score.madeUp, 0)
        XCTAssertTrue(outcome.result.items.allSatisfy { $0.quote != nil && $0.briefPending })
        XCTAssertEqual(outcome.parts.compactMap(\.read).count, asks.count, "each part's own reading is kept")
    }

    func testPartsReadAtOnceComeBackInTheNotesOrder() async throws {
        let spec = DistillBench.long(characters: 40_000)
        let tracker = Overlap()
        let outcome = try await DistillRun.read(title: spec.name, text: spec.text, budget: .forContext(nil, format: .v2), format: .v2, concurrent: 2) { ask in
            await tracker.begin()
            // The first part takes longest, so the second finishes first.
            try await Task.sleep(for: .milliseconds(ask.part == 1 ? 120 : 20))
            await tracker.end()
            return DistillBench.standInReply(ask, spec: spec)
        }
        let most = await tracker.most
        XCTAssertEqual(most, 2, "two parts were asked at once")
        XCTAssertEqual(outcome.parts.map(\.number), Array(1...outcome.parts.count))
        let ordered = DistillBench.score(outcome.result, spec: spec)
        XCTAssertEqual(ordered.found, spec.gold.count)
        let sequential = try await DistillRun.read(title: spec.name, text: spec.text, budget: .forContext(nil, format: .v2), format: .v2) {
            DistillBench.standInReply($0, spec: spec)
        }
        XCTAssertEqual(outcome.result.items.map(\.title), sequential.result.items.map(\.title), "the same items in the same order as one at a time")
    }

    func testOnlyTheSectionsGivenAreRead() async throws {
        let spec = DistillBench.specs[0]
        let sections = DistillSections.sections(of: spec.text).filter { $0.heading == "Order summary" || $0.heading == "Rollout" }
        let asked = Asked()
        let outcome = try await DistillRun.read(title: spec.name, text: spec.text, budget: .forContext(nil, format: .v2), format: .v2, only: sections) { ask in
            asked.add(ask)
            return DistillBench.standInReply(ask, spec: spec)
        }
        XCTAssertEqual(asked.all.count, 1)
        let user = asked.all[0].user
        XCTAssertTrue(user.contains("## Order summary") && user.contains("## Rollout") && !user.contains("## Payment form"))
        XCTAssertTrue(user.contains("the rest of the note was read before"))
        XCTAssertTrue(user.contains(DistillPrompt.headingsLine(headings(spec.text))), "still with every heading")
        XCTAssertEqual(Set(outcome.result.items.compactMap(\.section)), ["Order summary", "Rollout"])
    }

    // MARK: How much it writes, and the pace

    func testV2WritesAQuarterOfV1() async throws {
        var tokens: [DistillFormat: (tokens: Int, items: Int)] = [:]
        for format in DistillFormat.allCases {
            let replies = Asked()
            var items = 0, total = 0
            for spec in DistillBench.specs where !spec.gold.isEmpty {
                let outcome = try await DistillRun.read(title: spec.name, text: spec.text, budget: .forContext(nil, format: format), format: format) { ask in
                    replies.add(ask)
                    return DistillBench.standInReply(ask, spec: spec)
                }
                total += replies.all.map { DistillBench.estimatedTokens(DistillBench.standInReply($0, spec: spec)) }.reduce(0, +)
                replies.clear()
                items += outcome.result.items.count
            }
            tokens[format] = (total, items)
        }
        let v1 = Double(tokens[.v1]!.tokens) / Double(tokens[.v1]!.items), v2 = Double(tokens[.v2]!.tokens) / Double(tokens[.v2]!.items)
        print("DS8 stand-in: v1 \(Int(v1)) tokens an item, v2 \(Int(v2)), over \(tokens[.v2]!.items) items")
        XCTAssertLessThanOrEqual(v2, Double(DistillFormat.v2.tokensPerItem), "v2 about 30 tokens an item or fewer")
        XCTAssertGreaterThan(v1 / v2, 2.5)
        XCTAssertEqual(tokens[.v1]!.items, tokens[.v2]!.items, "the same items either way")
    }

    func testTheV2BudgetAndPace() {
        XCTAssertEqual(DistillFormat(setting: nil), .v2)
        XCTAssertEqual(DistillFormat(setting: "V1"), .v1)
        XCTAssertEqual(DistillFormat(setting: "v9"), .v2)
        let v2 = DistillBudget.forContext(nil, format: .v2)
        XCTAssertEqual(v2.replyTokens, DistillFormat.v2.maxTokens)
        XCTAssertEqual(DistillFormat.v2.maxTokens, 1_200)
        XCTAssertEqual(DistillBudget.forContext(nil).replyTokens, DistillPrompt.maxTokens, "v1 as before")
        // A model in Binders not measured yet: twice as much a part as v1, as its answer is a quarter as long.
        let unmeasured = DistillBudget.forContext(262_144, format: .v2).paced(nil, place: .inApp, format: .v2)
        XCTAssertEqual(unmeasured.partCharacters, 12_000)
        XCTAssertEqual(DistillBudget.forContext(262_144).paced(nil, place: .inApp).partCharacters, DistillBudget.slowStart)
        // A dense model's speed: 500 characters of question a second, 60 of answer.
        let speed = DistillSpeed(readsPerSecond: 500, writesPerSecond: 60)
        let v1Fit = speed.fits(seconds: DistillBudget.partSeconds, overhead: DistillBudget.overhead(.v1), share: DistillFormat.v1.answerShare)
        let v2Fit = speed.fits(seconds: DistillBudget.partSeconds, overhead: DistillBudget.overhead(.v2), share: DistillFormat.v2.answerShare)
        XCTAssertGreaterThan(Double(v2Fit), Double(v1Fit) * 2.5, "v2 reads far more in two minutes: \(v1Fit) vs \(v2Fit)")
        let paced = DistillBudget.forContext(262_144, format: .v2).paced(DistillSpeed(readsPerSecond: 200, writesPerSecond: 20), place: .inApp, format: .v2)
        XCTAssertTrue(paced.paced)
        XCTAssertLessThan(Double(paced.seconds(DistillSpeed(readsPerSecond: 200, writesPerSecond: 20))), DistillBudget.partSeconds + 1)
        XCTAssertEqual(paced.replyTokens, max(DistillFormat.v2.maxTokens / 3, paced.maxItems * DistillFormat.v2.replyTokensPerItem))
    }

    func testPrefillSpeedsAreKeptAndAnOldMeasureReads() throws {
        let old = try JSONDecoder().decode(DistillSpeed.self, from: Data(#"{"readsPerSecond": 400, "writesPerSecond": 50, "samples": 2}"#.utf8))
        XCTAssertNil(old.prefillTokensPerSecond)
        let new = old.blended(DistillSpeed(readsPerSecond: 400, writesPerSecond: 50, prefillTokensPerSecond: 300, decodeTokensPerSecond: 16))
        XCTAssertEqual(new.prefillTokensPerSecond, 300)
        XCTAssertEqual(new.blended(DistillSpeed(readsPerSecond: 400, writesPerSecond: 50)).prefillTokensPerSecond, 300, "a measure without it keeps it")
    }

    // MARK: Readings kept by section

    func testReadingsAreKeptBySectionAndOnlyWhatChangedIsRead() async throws {
        let spec = DistillBench.specs[0]
        let key = DistillKeep.Key(format: .v2, model: "stand-in", takers: DistillTakers.none.fingerprint)
        let sections = DistillSections.sections(of: spec.text)
        let outcome = try await DistillRun.read(title: spec.name, text: spec.text, budget: .forContext(nil, format: .v2), format: .v2) {
            DistillBench.standInReply($0, spec: spec)
        }
        let readings = DistillKeep.readings(from: outcome, sections: sections, key: key)
        XCTAssertEqual(readings.map(\.section), sections.map(\.heading), "a reading for every section, those with no work too")
        XCTAssertEqual(readings.first { $0.section == "Payment form" }?.items.count, 3)
        XCTAssertEqual(readings.first { $0.section == "Goal" }?.items.count, 0)
        XCTAssertEqual(readings.first { $0.section == "Rollout" }?.items.last?.waits, [0], "a wait inside its section is kept")
        XCTAssertFalse(DistillKeep.hasChanged(spec.text, kept: readings, key: key), "nothing changed")
        XCTAssertTrue(DistillKeep.hasChanged(spec.text, kept: nil, key: key), "never read")
        XCTAssertTrue(DistillKeep.hasChanged(spec.text, kept: readings, key: DistillKeep.Key(format: .v1, model: "stand-in", takers: key.takers)), "read another way")
        XCTAssertTrue(DistillKeep.hasChanged(spec.text, kept: readings, key: DistillKeep.Key(format: .v2, model: "other", takers: key.takers)), "by another model")
        // The summary changes and a section is added: only those two are read.
        let changed = spec.text.replacingOccurrences(of: "the delivery cost and the total", with: "the delivery cost, the tax and the total")
            + "\n\n## Receipts\nShow a receipt page with the order number."
        let now = DistillSections.sections(of: changed)
        let split = DistillKeep.split(now, kept: readings, key: key)
        XCTAssertEqual(split.read.map(\.heading), ["Order summary", "Receipts"])
        XCTAssertEqual(split.kept.count, now.count - 2)
        let reused = DistillKeep.result(split.kept)
        XCTAssertEqual(reused.items.count, spec.gold.count - 1, "every kept item but the summary's")
        XCTAssertEqual(reused.items.first { $0.title.hasPrefix("Compare") }?.waitsFor.count, 1)
        XCTAssertTrue(reused.items.allSatisfy(\.briefPending))
        let merged = DistillKeep.kept(readings, adding: [DistillSectionReading(section: "Receipts", hash: now.last!.hash, format: "v2", model: "stand-in",
                                                                                takers: key.takers, items: [])], sections: now)
        XCTAssertEqual(merged.map(\.section), now.map(\.heading).filter { $0 != "Order summary" }, "the old summary's goes, the new section's comes, in order")
    }

    func testAPartCutShortIsntKept() async throws {
        let spec = DistillBench.long(characters: 30_000)
        let key = DistillKeep.Key(format: .v2, model: "m", takers: "t")
        let outcome = try await DistillRun.read(title: spec.name, text: spec.text, budget: .forContext(nil, format: .v2), format: .v2) { ask in
            if ask.part == 2 {
                throw StreamStopped(why: .stalled, pace: .distill, text: "", timing: StreamTiming(firstWords: nil, lastWords: nil, characters: 0, total: 1))
            }
            return DistillBench.standInReply(ask, spec: spec)
        }
        let readings = DistillKeep.readings(from: outcome, sections: DistillSections.sections(of: spec.text), key: key)
        let second = Set(outcome.parts[1].pieces.map(\.heading))
        XCTAssertFalse(readings.contains { second.contains($0.section) }, "a part cut short is read again next time")
        XCTAssertFalse(readings.isEmpty)
    }

    func testFilesFromBeforeRead() throws {
        let note = UUID()
        let old = #"{"version": 1, "note": "\#(note.uuidString)", "distills": [{"id": "\#(UUID().uuidString)", "note": "\#(note.uuidString)", "items": [{"id": "\#(UUID().uuidString)", "title": "Old item"}]}]}"#
        let file = try DistillFile.decoder().decode(DistillFile.self, from: Data(old.utf8))
        XCTAssertNil(file.readings)
        XCTAssertNil(file.distills.first?.items.first?.briefPending)
        var kept = file
        kept.readings = [DistillSectionReading(section: nil, hash: "h", format: "v2", model: "m", takers: "t", items: [.init(title: "A", waits: [])],
                                             at: Date(timeIntervalSince1970: 1_000))]
        let again = try DistillFile.decoder().decode(DistillFile.self, from: DistillFile.encoder().encode(kept))
        XCTAssertEqual(again.readings, kept.readings)
        let from = try JSONDecoder().decode(DistilledFrom.self, from: Data(#"{"note": "\#(note.uuidString)", "distill": "\#(note.uuidString)", "item": "\#(note.uuidString)"}"#.utf8))
        XCTAssertNil(from.briefFor)
        // A reading a later build writes another way is left out, not fatal.
        let odd = #"{"note": "\#(note.uuidString)", "distills": [], "readings": [{"section": 3}]}"#
        XCTAssertEqual(try DistillFile.decoder().decode(DistillFile.self, from: Data(odd.utf8)).readings, [])
    }

    // MARK: Briefs written later

    func testACardWaitsForItsBriefWithItsLines() {
        let note = UUID()
        let item = DistillItem(title: "Check card numbers", brief: "Card numbers are checked as they're typed.", section: "Payment form", size: .small, briefPending: true)
        let details = DistillCards.pendingDetails(item, note: note, noteTitle: "Checkout")
        XCTAssertTrue(details.hasPrefix("From “Checkout” › Payment form:\n> Card numbers are checked as they're typed."))
        XCTAssertTrue(details.contains("Distilled from [Checkout](binders://note/\(note.uuidString)?section=Payment%20form) · section “Payment form” · small"))
        XCTAssertFalse(details.contains("**Done when:**"))
        let written = DistillCards.updating(details, brief: "Validate the number while typing.", doneWhen: "A wrong number shows an error.")
        XCTAssertTrue(written.hasPrefix("Validate the number while typing.\n\n**Done when:** A wrong number shows an error.\n\nDistilled from "))
        XCTAssertFalse(written.contains("From “Checkout”"), "the lines go once the brief is written")
        XCTAssertEqual(DistillBriefs.read(#"{"brief": "Validate it.", "done_when": "Errors show."}"#)?.doneWhen, "Errors show.")
        XCTAssertNil(DistillBriefs.read("I can't."))
        XCTAssertTrue(DistillBriefs.user(title: "T", noteTitle: "N", section: nil, lines: "x").contains("its opening"))
    }
}

/// What a stand-in was asked, from any task.
private final class Asked: @unchecked Sendable {
    private let lock = NSLock()
    private var asks: [DistillRun.Ask] = []
    func add(_ ask: DistillRun.Ask) { lock.withLock { asks.append(ask) } }
    func clear() { lock.withLock { asks = [] } }
    var all: [DistillRun.Ask] { lock.withLock { asks } }
}

/// How many asks ran at once, at most.
private actor Overlap {
    private var now = 0
    private(set) var most = 0
    func begin() { now += 1; most = max(most, now) }
    func end() { now -= 1 }
}

private extension DistillBudget {
    /// Seconds a part this size takes at `speed`, with v2's answer.
    func seconds(_ speed: DistillSpeed) -> Double {
        speed.seconds(part: partCharacters, overhead: DistillBudget.overhead(.v2), share: DistillFormat.v2.answerShare)
    }
}
