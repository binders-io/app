import XCTest
@testable import BindersKit

/// Binders' model hears what's captured from a note already, by any reader, and the merge after its reply leaves out
/// what it repeats anyway: an agent's items, put aside or waiting, in other words or under a section it named loosely.
final class DistillCapturedTests: XCTestCase {
    private func headings(_ text: String) -> [String] { DistillSections.sections(of: text).compactMap(\.heading) }

    private let note = """
        # Checkout redesign

        ## Payment form
        Put address, delivery and card on one page.
        Check card numbers as they're typed.

        ## Retry
        When the bank declines, keep what was typed and offer Retry.
        """

    // MARK: The prompt

    func testThePromptListsWhatsCapturedAlready() {
        let captured = [DistillPrompt.Captured(title: "Combine checkout into one page", section: "Payment form"),
                        DistillPrompt.Captured(title: "Offer Retry after a decline", section: "Retry"),
                        DistillPrompt.Captured(title: "Write the help page")]
        let line = DistillPrompt.capturedLine(captured) ?? ""
        XCTAssertTrue(line.hasPrefix("Already captured from this note, so don't propose these again"))
        XCTAssertTrue(line.contains("\"Combine checkout into one page\" (Payment form)") && line.contains("\"Write the help page\""))
        let user = DistillPrompt.user(title: "Checkout redesign", sections: headings(note), text: note, captured: captured)
        XCTAssertTrue(user.contains(line) && user.hasSuffix(note), "v1, the whole note: the list, then the note")
        XCTAssertEqual(DistillPrompt.user(title: "N", sections: [], text: "x", captured: []), DistillPrompt.user(title: "N", sections: [], text: "x"),
                       "with nothing captured, the question is as it always was")
        let part = DistillParts.Part(number: 1, count: 2, pieces: [DistillParts.Piece(heading: "Payment form")], text: "## Payment form\nPut it on one page.")
        XCTAssertTrue(DistillPrompt.part(title: "Checkout redesign", sections: headings(note), part: part, earlier: [], captured: captured).contains(line),
                      "v1, a part")
        let prefix = DistillPrompt.prefix(title: "Checkout redesign", sections: headings(note), captured: captured)
        XCTAssertTrue(prefix.contains(line), "v2: in the start every part shares")
        XCTAssertTrue(DistillPrompt.partV2(title: "Checkout redesign", sections: headings(note), part: part, lines: DistillLines(part.text),
                                           captured: captured).hasPrefix(prefix))
        XCTAssertNil(DistillPrompt.capturedLine([]))
    }

    func testTheCapturedListStaysShort() {
        let many = (1...120).map { DistillPrompt.Captured(title: "Do the thing number \($0) with a fairly long title to see the cut", section: "Section \($0 % 7)") }
        let line = DistillPrompt.capturedLine(many) ?? ""
        XCTAssertLessThanOrEqual(line.count, DistillPrompt.capturedCharacters + 40, "bounded, the rest counted")
        XCTAssertTrue(line.hasSuffix("more."))
        XCTAssertLessThanOrEqual(line.components(separatedBy: "\"; ").count, DistillPrompt.capturedLimit)
        let twice = DistillPrompt.capturedLine([DistillPrompt.Captured(title: "Add Retry"), DistillPrompt.Captured(title: "add retry")]) ?? ""
        XCTAssertEqual(twice.components(separatedBy: "Retry").count, 2, "the same title once")
    }

    func testEveryPartIsAskedWithTheListAndAnEightThousandTokenModelStillFits() async throws {
        let spec = DistillBench.long(characters: 30_000)
        let captured = (1...DistillPrompt.capturedLimit).map { DistillPrompt.Captured(title: "Captured work item number \($0) from before", section: "Section \($0)") }
        let line = DistillPrompt.capturedLine(captured)!
        for format in [DistillFormat.v1, .v2] {
            let asked = AskedHere()
            let budget = DistillBudget.forContext(8_192, format: format)
            _ = try await DistillRun.read(title: spec.name, text: spec.text, budget: budget, format: format, captured: captured) { ask in
                asked.add(ask)
                return "[]"
            }
            let asks = asked.all
            XCTAssertGreaterThan(asks.count, 1)
            XCTAssertTrue(asks.allSatisfy { $0.user.contains(line) }, "\(format): every part hears it")
            if format == .v2 { XCTAssertTrue(asks.allSatisfy { $0.prefix.contains(line) }, "in the shared start") }
            // Counted as the budget counts (3 characters a token), the question, its instructions and its answer fit.
            let most = asks.map { ($0.system.count + $0.user.count) / 3 + $0.maxTokens }.max() ?? 0
            XCTAssertLessThanOrEqual(most, 8_192, "\(format): \(most) tokens")
        }
    }

    // MARK: The merge after the reply

    private func sections(_ text: String) -> [DistillSections.Section] { DistillSections.sections(of: text) }
    private func hash(_ heading: String, in text: String) -> String? { sections(text).first { $0.heading == heading }?.hash }

    func testAnUnmatchedSectionIsFoundFromTheQuote() {
        let reply = #"[{"title": "Offer Retry", "section": "Payments that fail", "quote": "keep what was typed and offer Retry"},"#
            + #"{"title": "Plan the launch", "section": "", "quote": "Something the note doesn't say"},"#
            + #"{"title": "Check numbers", "quote": "check card numbers as they’re typed."}]"#
        var read = DistillReading.read(reply, headings: headings(note))
        XCTAssertNil(read.items[0].section)
        XCTAssertEqual(read.items[0].unknownSection, "Payments that fail")
        read.recoverSections(from: note)
        XCTAssertEqual(read.items.map(\.section), ["Retry", nil, "Payment form"], "found as written, or loosely; nothing for words the note hasn't")
        XCTAssertNil(read.items[0].unknownSection)
        XCTAssertEqual(DistillQuote.section(of: "offer Retry", in: note), "Retry")
    }

    func testAnAgentsProposalInOtherWordsIsARepeat() {
        // The model proposed these before; the agent words one again, and repeats one of its own.
        let earlier = [DistillAgain.Earlier(item: UUID(), title: "Combine checkout into one page", section: "Payment form",
                                            sectionHash: hash("Payment form", in: note), card: nil, waiting: true)]
        let read = [DistillItem(title: "Put checkout on one page", section: "Payment form", quote: "Put address, delivery and card on one page."),
                    DistillItem(title: "Combine the checkout into one page", section: nil),
                    DistillItem(title: "Offer Retry after a decline", section: "Retry"),
                    DistillItem(title: "Offer a Retry after a decline", section: "Retry")]
        var withQuote = earlier
        withQuote[0].quote = "Put address, delivery and card on one page"
        let added = DistillAgain.additions(read: read, earlier: withQuote)
        XCTAssertEqual(added.items.map(\.title), ["Offer Retry after a decline"], "the same quote, the same title anywhere, the same twice")
        XCTAssertEqual(added.leftOut, 3)
    }

    func testAModelReadingLeavesOutWhatAnAgentProposed() {
        // Both ways: the model reads after the agent, and the agent's items are in `earlier` as any reader's are.
        let agents = [DistillAgain.Earlier(item: UUID(), title: "Offer Retry when the bank declines", section: "Retry",
                                           sectionHash: hash("Retry", in: note), card: nil, waiting: true)]
        let read = [DistillItem(title: "Keep entered details and offer Retry", section: "Retry", sectionHash: hash("Retry", in: note)),
                    DistillItem(title: "Validate card numbers while typing", section: "Payment form", sectionHash: hash("Payment form", in: note))]
        let plan = DistillAgain.plan(read: read, earlier: agents, sections: sections(note))
        XCTAssertEqual(plan.sections["Retry"], .same)
        XCTAssertEqual(plan.items.map(\.title), ["Validate card numbers while typing"], "a section the agent read, unchanged, gives nothing")
    }

    func testAnAgentsPickOfItemsLeavesTheRestOfItsSectionToRead() {
        // Its own propose_work_items, one item from Payment form: a repeat of it goes, the rest of the section is read.
        let picked = DistillAgain.Earlier(item: UUID(), title: "Combine checkout into one page", section: "Payment form",
                                          sectionHash: hash("Payment form", in: note), card: nil, waiting: true, whole: false)
        let read = [DistillItem(title: "Combine the checkout into one page", section: "Payment form", sectionHash: hash("Payment form", in: note)),
                    DistillItem(title: "Check card numbers as they're typed", section: "Payment form", sectionHash: hash("Payment form", in: note))]
        let plan = DistillAgain.plan(read: read, earlier: [picked], sections: sections(note))
        XCTAssertEqual(plan.sections["Payment form"], .new)
        XCTAssertEqual(plan.items.map(\.title), ["Check card numbers as they're typed"])
    }

    func testAProposalPutAsideIsNeverProposedAgain() {
        // An agent's proposal put aside whole (its items not dropped one by one) still counts.
        let putAside = DistillAgain.Earlier(item: UUID(), title: "Offer Retry when the bank declines", section: "Retry",
                                            sectionHash: hash("Retry", in: note), card: nil, waiting: false)
        let read = [DistillItem(title: "Offer Retry when the bank declines", section: "Retry", sectionHash: hash("Retry", in: note))]
        XCTAssertEqual(DistillAgain.plan(read: read, earlier: [putAside], sections: sections(note)).items, [])
        // In a changed section, the same work in other words stays out too, and isn't refreshed.
        let edited = note.replacingOccurrences(of: "offer Retry.", with: "offer Retry. Say why it failed.")
        let again = DistillAgain.plan(read: [DistillItem(title: "Offer Retry when a bank declines", section: "Retry", sectionHash: hash("Retry", in: edited))],
                                      earlier: [putAside], sections: sections(edited))
        XCTAssertEqual(again.sections["Retry"], .changed)
        XCTAssertEqual(again.items, [])
        XCTAssertEqual(again.refreshes, [])
    }

    func testTheNoteEditedAfterTheAgentReadItRefreshesItsWaitingItem() {
        let waiting = DistillAgain.Earlier(item: UUID(), title: "Offer Retry when the bank declines", section: "Retry",
                                           sectionHash: hash("Retry", in: note), card: nil, quote: "offer Retry", waiting: true)
        let edited = note.replacingOccurrences(of: "offer Retry.", with: "offer Retry. Say why the payment failed.")
        let read = [DistillItem(title: "Offer Retry when the bank declines, saying why", brief: "Keep the form, say why, offer Retry.", section: "Retry",
                                sectionHash: hash("Retry", in: edited), quote: "Say why the payment failed.")]
        let plan = DistillAgain.plan(read: read, earlier: [waiting], sections: sections(edited))
        XCTAssertEqual(plan.items, [], "not a second item next to the one waiting")
        XCTAssertEqual(plan.refreshes.map(\.item), [waiting.item], "the waiting item is brought up to date")
        XCTAssertEqual(plan.refreshes.first?.brief, "Keep the form, say why, offer Retry.")
        XCTAssertEqual(plan.refreshes.first?.sectionHash, hash("Retry", in: edited))
        XCTAssertEqual(plan.updates, [], "it has no card to update")
    }

    func testTheNotesOtherCardsAreRepeatsButSayNothingOfTheirSection() {
        // A card made with Put on Board from one line of Payment form, its section as it is.
        let put = DistillAgain.Earlier(item: UUID(), title: "Check card numbers as they're typed", section: "Payment form",
                                       sectionHash: hash("Payment form", in: note), card: UUID(), other: true)
        let read = [DistillItem(title: "Combine checkout into one page", section: "Payment form", sectionHash: hash("Payment form", in: note)),
                    DistillItem(title: "Check the card numbers as they're typed", section: "Payment form", sectionHash: hash("Payment form", in: note))]
        let plan = DistillAgain.plan(read: read, earlier: [put], sections: sections(note))
        XCTAssertEqual(plan.sections["Payment form"], .new, "the rest of the section is still to read")
        XCTAssertEqual(plan.items.map(\.title), ["Combine checkout into one page"])
        let gone = DistillAgain.plan(read: [], earlier: [put], sections: sections("# Checkout redesign\n\n## Retry\nOffer Retry."))
        XCTAssertEqual(gone.closes, [], "never closed by Distill")
    }

    // MARK: An agent's reading

    func testAnAgentsReadingCountsForTheSectionsThatReadTheSame() {
        let then = note
        let now = note.replacingOccurrences(of: "offer Retry.", with: "offer Retry. Say why.")
        var read = DistillReading.read(#"[{"title": "Combine checkout into one page", "section": "Payment form"}, {"title": "Offer Retry", "section": "Retry"}]"#,
                                       headings: headings(now))
        read.recoverSections(from: now)
        let readings = DistillKeep.agentReadings(read.items, read: then, sections: sections(now), agent: "Scribe")
        XCTAssertEqual(readings.map(\.section), ["Payment form"], "Retry changed after the agent read it: Binders' model reads it")
        XCTAssertEqual(readings.first?.items.map(\.title), ["Combine checkout into one page"])
        let key = DistillKeep.Key(format: .v2, model: "some-model", takers: "abc")
        let split = DistillKeep.split(sections(now), kept: readings, key: key)
        XCTAssertEqual(split.read.map(\.heading), ["Retry"], "whatever model reads next")
        XCTAssertEqual(split.kept.map(\.section), ["Payment form"])
    }

    // MARK: The note's marks

    func testAChipSaysWhatsProposed() {
        let proposed = DistillMarks.ChipCard.proposal(id: "a", title: "Offer Retry")
        let card = DistillMarks.ChipCard(id: "b", title: "Combine checkout", column: BoardColumn.ready.rawValue, state: .notStarted, who: "Echo")
        XCTAssertEqual(DistillMarks.chip([proposed]), "Proposed")
        XCTAssertEqual(DistillMarks.chip([proposed, proposed]), "2 proposed")
        XCTAssertEqual(DistillMarks.chip([card, proposed]), "Ready · Echo · 1 proposed")
        XCTAssertFalse(proposed.finished)
        XCTAssertEqual(DistillMarks.headingChip(0, proposed: 2), "2 proposed")
        XCTAssertEqual(DistillMarks.headingChip(1, proposed: 1), "1 card · 1 proposed")
        XCTAssertEqual(DistillMarks.headingChip(3), "3 cards")
    }
}

private final class AskedHere: @unchecked Sendable {
    private let lock = NSLock()
    private var asks: [DistillRun.Ask] = []
    func add(_ ask: DistillRun.Ask) { lock.withLock { asks.append(ask) } }
    var all: [DistillRun.Ask] { lock.withLock { asks } }
}
