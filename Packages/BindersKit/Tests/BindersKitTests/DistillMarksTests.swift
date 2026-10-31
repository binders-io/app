import XCTest
@testable import BindersKit

/// Lane DS4: each work item's quote, from the schema and the reply to the card and the team, and finding it in the note
/// as it is now.
final class DistillMarksTests: XCTestCase {
    static let note = """
        # Checkout redesign

        We want one checkout page instead of three.

        ## Payment form
        - Put address, delivery and card on **one page** instead of three.
        - [ ] Check card numbers as they're typed and show the error under the field.
        - Add Apple Pay and Google Pay buttons above the form.

        ## Retry after a failed payment
        When the bank declines or the connection drops, keep what was typed and offer “Retry”.
        Log each failure with its reason code.

        ## Rollout
        Ship behind a flag to 10% of visitors. Add Apple Pay and Google Pay buttons above the form.
        """

    func range(_ words: String, in text: String = note, from: Int = 0) -> NSRange {
        let string = text as NSString
        return string.range(of: words, options: [], range: NSRange(location: from, length: string.length - from))
    }

    // MARK: The schema and the prompt

    func testTheSchemaAsksForTheQuoteAfterTheSection() throws {
        let text = DistillSchema.json(headings: ["A"])
        let order = ["\"section\":{", "\"quote\":{", "\"waits_for\":{"].compactMap { text.range(of: $0)?.lowerBound }
        XCTAssertEqual(order.count, 3)
        XCTAssertEqual(order, order.sorted(), "quote comes right after section, as the prompt lists it")
        let schema = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let item = try XCTUnwrap(((schema["properties"] as? [String: Any])?["items"] as? [String: Any])?["items"] as? [String: Any])
        XCTAssertEqual(((item["properties"] as? [String: Any])?["quote"] as? [String: Any])?["type"] as? String, "string")
        XCTAssertTrue((item["required"] as? [String])?.contains("quote") == true)
        XCTAssertFalse(text.contains("maxLength"), "no lengths, as before")
        // The portable form too.
        XCTAssertTrue(DistillSchema.json(headings: [], bounded: false).contains("\"quote\":{\"type\":\"string\"}"))
    }

    func testThePromptAsksForTheNotesOwnWords() {
        XCTAssertTrue(DistillPrompt.system.contains("- quote: the words of the note the item comes from, copied exactly"))
        XCTAssertTrue(DistillPrompt.system.contains("\"quote\": \"Once someone signs up, send them a welcome email\""))
        let section = DistillPrompt.system.range(of: "- section:")!.lowerBound
        let quote = DistillPrompt.system.range(of: "- quote:")!.lowerBound
        let waits = DistillPrompt.system.range(of: "- waits_for:")!.lowerBound
        XCTAssertTrue(section < quote && quote < waits)
    }

    // MARK: Reading replies

    func testANewReplyIsReadWithItsQuotes() {
        let reply = """
            {"items": [
              {"title": "Combine checkout into one page", "brief": "", "done_when": "", "section": "Payment form", "quote": "Put address, delivery and card on one page instead of three.", "waits_for": [], "size": "medium", "for": "agent"},
              {"title": "Offer Retry", "brief": "", "done_when": "", "section": "Retry after a failed payment", "quote": "  “keep what was typed and offer Retry”  ", "waits_for": [], "size": "small", "for": "agent"},
              {"title": "Decide", "brief": "", "done_when": "", "section": "Rollout", "quote": "", "waits_for": [], "size": "small", "for": "person"}
            ]}
            """
        let headings = DistillSections.sections(of: Self.note).compactMap(\.heading)
        let read = DistillReading.read(reply, headings: headings)
        XCTAssertEqual(read.items.map(\.quote), ["Put address, delivery and card on one page instead of three.", "keep what was typed and offer Retry", nil],
                       "trimmed, the reader's own quotation marks taken off; an empty one is none")
        let items = read.items(sections: DistillSections.sections(of: Self.note))
        XCTAssertEqual(items.map(\.quote), read.items.map(\.quote), "the items keep them")
    }

    func testAnOldReplyAndAStandInWithoutQuotesStillRead() {
        let old = #"[{"title": "Add retry", "section": "Retry after a failed payment", "waits_for": [], "size": "small", "for": "agent"}]"#
        let read = DistillReading.read(old, headings: ["Retry after a failed payment"])
        XCTAssertEqual(read.items.count, 1)
        XCTAssertNil(read.items[0].quote)
        XCTAssertNil(read.items(sections: []).first?.quote)
        // An agent's words under another name.
        let agent = DistillReading.read(#"[{"title": "Add retry", "excerpt": "offer Retry"}]"#, headings: [])
        XCTAssertEqual(agent.items.first?.quote, "offer Retry")
    }

    func testAQuoteIsCleaned() {
        XCTAssertNil(DistillQuote.clean(nil))
        XCTAssertNil(DistillQuote.clean("   "))
        XCTAssertNil(DistillQuote.clean("\"\""))
        XCTAssertEqual(DistillQuote.clean("\"Log each failure\""), "Log each failure")
        XCTAssertEqual(DistillQuote.clean("…keep what was typed…"), "keep what was typed")
        XCTAssertEqual(DistillQuote.clean("one\n  two\tthree"), "one two three")
        let long = (1...60).map { "w\($0)" }.joined(separator: " ")
        XCTAssertEqual(DistillQuote.clean(long)?.split(separator: " ").count, 40, "a quote that runs on is cut")
    }

    // MARK: Old and new records

    func testOldRecordsDecodeWithoutAQuote() throws {
        let item = try JSONDecoder().decode(DistillItem.self, from: Data(#"{"id": "6F1C2D3E-0000-4000-8000-000000000003", "title": "Add retry"}"#.utf8))
        XCTAssertNil(item.quote)
        var quoted = item
        quoted.quote = "offer Retry"
        XCTAssertEqual(try JSONDecoder().decode(DistillItem.self, from: JSONEncoder().encode(quoted)), quoted)
        // A quote that isn't a string doesn't lose the item.
        let odd = try JSONDecoder().decode(DistillItem.self, from: Data(#"{"id": "6F1C2D3E-0000-4000-8000-000000000003", "title": "A", "quote": 5}"#.utf8))
        XCTAssertNil(odd.quote)

        let old = #"{"note":"6F1C2D3E-0000-4000-8000-000000000001","distill":"6F1C2D3E-0000-4000-8000-000000000002","item":"6F1C2D3E-0000-4000-8000-000000000003","section":"Sync","sectionHash":"abc"}"#
        let from = try XCTUnwrap(DistilledFrom(json: old))
        XCTAssertNil(from.quote)
        var marked = from
        marked.quote = "Sync every hour"
        XCTAssertEqual(DistilledFrom(json: marked.json)?.quote, "Sync every hour")

        let update = try JSONDecoder().decode(DistillUpdate.self, from: Data(
            #"{"id":"6F1C2D3E-0000-4000-8000-000000000009","kind":"brief","card":"6F1C2D3E-0000-4000-8000-000000000008","brief":"b","doneWhen":"d"}"#.utf8))
        XCTAssertNil(update.quote)
    }

    // MARK: Finding the words

    func testExactWordsAreFoundInTheirSectionFirst() {
        let words = "Add Apple Pay and Google Pay buttons above the form."
        let payment = DistillQuote.find(words, section: "Payment form", in: Self.note)
        XCTAssertEqual(payment, DistillQuote.Found(range: range(words), how: .exact))
        let rollout = DistillQuote.find(words, section: "Rollout", in: Self.note)
        XCTAssertEqual(rollout?.range, range(words, from: range("## Rollout").location), "the same words in another section: the card's own section's")
        // Words that moved to another section are still found.
        let moved = DistillQuote.find("Ship behind a flag to 10% of visitors.", section: "Payment form", in: Self.note)
        XCTAssertEqual(moved?.range, range("Ship behind a flag to 10% of visitors."))
        // The opening.
        XCTAssertEqual(DistillQuote.find("one checkout page", section: nil, in: Self.note)?.range, range("one checkout page"))
    }

    func testWordsAreFoundLoosely() {
        // Case, the Markdown around "one page", and a model that left the list's dash in.
        let markup = DistillQuote.find("- put address, delivery and card on one page instead of three", section: "Payment form", in: Self.note)
        XCTAssertEqual(markup?.how, .loose)
        let start = range("Put address").location, end = NSMaxRange(range("instead of three", from: start))
        XCTAssertEqual(markup?.range, NSRange(location: start, length: end - start), "from its first word to its last, the bold's stars inside")
        // Straight quotes for curly ones, a line break for a space, and a checkbox.
        let curly = DistillQuote.find("keep what was typed and offer \"Retry\"", section: "Retry after a failed payment", in: Self.note)
        XCTAssertEqual(curly?.how, .loose)
        XCTAssertEqual(curly.map { (Self.note as NSString).substring(with: $0.range) }, "keep what was typed and offer “Retry")
        let checkbox = DistillQuote.find("[ ] Check card numbers  as they're typed", section: "Payment form", in: Self.note)
        XCTAssertEqual(checkbox.map { (Self.note as NSString).substring(with: $0.range) }, "Check card numbers as they're typed")
        let accents = DistillQuote.find("Log each failure with its réason code", section: nil, in: Self.note)
        XCTAssertEqual(accents?.how, .loose, "accents don't count either")
    }

    func testEditedWordsFallBackToTheLineWithTheMostOfThem() {
        let edited = Self.note.replacingOccurrences(of: "Log each failure with its reason code.", with: "Log every failure, with the bank's reason code.")
        let found = DistillQuote.find("Log each failure with its reason code.", section: "Retry after a failed payment", in: edited)
        XCTAssertEqual(found?.how, .words)
        XCTAssertEqual(found.map { (edited as NSString).substring(with: $0.range) }, "Log every failure, with the bank's reason code.")
        // Too little of it left: not found, so its heading shows it.
        let gone = Self.note.replacingOccurrences(of: "Log each failure with its reason code.", with: "Write it down.")
        XCTAssertNil(DistillQuote.find("Log each failure with its reason code.", section: "Retry after a failed payment", in: gone))
        // Words in a section that's gone are only found as written.
        XCTAssertNil(DistillQuote.find("Log every failure", section: "Errors", in: Self.note))
    }

    // MARK: Placing the cards

    func testCardsArePlacedAtTheirWordsOrTheirHeadings() {
        let cards = [
            DistillMarks.Card(id: "form", quote: "Put address, delivery and card on one page instead of three.", section: "Payment form"),
            DistillMarks.Card(id: "pay", quote: "Add Apple Pay and Google Pay buttons", section: "Payment form"),
            DistillMarks.Card(id: "wallets", quote: "Google Pay buttons above the form", section: "Payment form"),
            DistillMarks.Card(id: "old", quote: nil, section: "Retry after a failed payment"),
            DistillMarks.Card(id: "lost", quote: "Nothing like this is in the note at all", section: "Rollout"),
            DistillMarks.Card(id: "gone", quote: "Nothing like this either", section: "A section that went"),
            DistillMarks.Card(id: "opening", quote: nil, section: nil),
        ]
        let placed = DistillMarks.place(cards, in: Self.note)
        XCTAssertEqual(placed.lines.map(\.cards), [["form"], ["pay", "wallets"]], "two items on one line share it")
        XCTAssertEqual(placed.lines[1].line, NSRange(location: range("- Add Apple Pay").location, length: ("- Add Apple Pay and Google Pay buttons above the form." as NSString).length))
        XCTAssertEqual(placed.mark(of: "wallets")?.range, range("Google Pay buttons above the form"))
        XCTAssertEqual(placed.atHeading, ["old", "lost", "opening"], "no quote, or words no longer there: at the heading")
        XCTAssertEqual(placed.nowhere, ["gone"], "words and section both gone: nowhere")
        XCTAssertEqual(placed.headings.map(\.heading), [nil, "Payment form", "Retry after a failed payment", "Rollout"])
        XCTAssertEqual(placed.headings.map(\.cards), [["opening"], ["form", "pay", "wallets"], ["old"], ["lost"]], "each heading counts its section's cards")
        XCTAssertEqual(placed.headings[0].line, range("# Checkout redesign"), "the opening's cards go on the title")
        XCTAssertEqual(placed.headings[1].line, range("## Payment form"))
        XCTAssertFalse(placed.lines.contains { $0.isHeading })
        XCTAssertEqual(DistillMarks.place([], in: Self.note), .empty)
        // A heading renamed a little is still the section.
        let renamed = Self.note.replacingOccurrences(of: "## Rollout", with: "## 3. rollout")
        XCTAssertEqual(DistillMarks.place([DistillMarks.Card(id: "x", quote: nil, section: "Rollout")], in: renamed).headings.first?.heading, "3. rollout")
    }

    func testTypingMovesMarksAlongAndDropsTheEditedOnes() {
        let cards = [
            DistillMarks.Card(id: "form", quote: "Put address, delivery and card", section: "Payment form"),
            DistillMarks.Card(id: "retry", quote: "keep what was typed", section: "Retry after a failed payment"),
        ]
        let placed = DistillMarks.place(cards, in: Self.note)
        // Typing above both: they move with the text.
        let typed = "Hello. "
        let at = range("We want").location
        let above = (Self.note as NSString).replacingCharacters(in: NSRange(location: at, length: 0), with: typed)
        let moved = placed.shifted(edited: NSRange(location: at, length: 7), delta: 7, in: above)
        XCTAssertEqual(moved.mark(of: "form")?.range, NSRange(location: placed.mark(of: "form")!.range.location + 7, length: placed.mark(of: "form")!.range.length))
        XCTAssertEqual(moved.headings.map(\.line.location), placed.headings.map { $0.line.location + 7 })
        XCTAssertEqual(moved, DistillMarks.place(cards, in: above), "the same as finding them again")
        // Changing the quoted words: that mark drops to its heading until it's found again; the other stays put.
        let inside = range("delivery")
        let edited = (Self.note as NSString).replacingCharacters(in: inside, with: "shipping")
        let dropped = placed.shifted(edited: NSRange(location: inside.location, length: 8), delta: 0, in: edited)
        XCTAssertNil(dropped.mark(of: "form"))
        XCTAssertEqual(dropped.atHeading, ["form"])
        XCTAssertEqual(dropped.mark(of: "retry"), placed.mark(of: "retry"))
        // Found again: the line with most of its words.
        XCTAssertEqual(DistillMarks.place(cards, in: edited).mark(of: "form")?.how, .words)
        // Typing right after the words keeps them.
        let after = NSMaxRange(placed.mark(of: "retry")!.range)
        let appended = (Self.note as NSString).replacingCharacters(in: NSRange(location: after, length: 0), with: " now")
        XCTAssertEqual(placed.shifted(edited: NSRange(location: after, length: 4), delta: 4, in: appended).mark(of: "retry"), placed.mark(of: "retry"))
    }

    func testANoteWithoutHeadingsOrTitle() {
        let text = "call the dentist\nbook the car in for its service"
        let placed = DistillMarks.place([DistillMarks.Card(id: "car", quote: "book the car in", section: nil)], in: text)
        XCTAssertEqual(placed.mark(of: "car")?.range, (text as NSString).range(of: "book the car in"))
        XCTAssertEqual(placed.headings.first?.line, (text as NSString).range(of: "call the dentist"), "its first line is its title")
        let empty = DistillMarks.place([DistillMarks.Card(id: "a", quote: "x y z", section: nil)], in: "")
        XCTAssertEqual(empty.nowhere, ["a"])
    }

    // MARK: What the chips say

    func testWhatAChipSays() {
        func card(_ column: BoardColumn, who: String? = nil, closed: Bool = false) -> DistillMarks.ChipCard {
            DistillMarks.ChipCard(id: UUID().uuidString, title: "A", column: column.rawValue, state: nil, who: who, closed: closed)
        }
        XCTAssertEqual(DistillMarks.chip([card(.ready, who: "DevPlus")]), "Ready · DevPlus")
        XCTAssertEqual(DistillMarks.chip([card(.inProgress, who: "Claude Code")]), "In progress · Claude Code")
        XCTAssertEqual(DistillMarks.chip([card(.backlog)]), "Backlog")
        XCTAssertEqual(DistillMarks.chip([card(.done, who: "Echo")]), "Done")
        XCTAssertEqual(DistillMarks.chip([card(.done, closed: true)]), "Closed")
        XCTAssertEqual(DistillMarks.chip([card(.ready), card(.done), card(.review)]), "3 cards · 1 done")
        XCTAssertEqual(DistillMarks.chip([card(.done), card(.done)]), "2 cards · all done")
        XCTAssertEqual(DistillMarks.chip([card(.ready), card(.blocked)]), "2 cards")
        XCTAssertEqual(DistillMarks.headingChip(1), "1 card")
        XCTAssertEqual(DistillMarks.headingChip(2), "2 cards")
        XCTAssertTrue(card(.done).finished)
        XCTAssertTrue(card(.ready, closed: true).finished)
        XCTAssertFalse(card(.review).finished)
    }

    func testPlacingALongNoteIsQuick() {
        var text = "# Long\n\n"
        for section in 0..<40 {
            text += "## Part \(section)\n"
            for line in 0..<20 { text += "- Line \(line) of part \(section): something to do about the thing, with **bold** words.\n" }
        }
        let cards = (0..<25).map { DistillMarks.Card(id: "\($0)", quote: "line \($0 % 20) of part \($0): Something to do", section: "Part \($0)") }
        let start = Date()
        let placed = DistillMarks.place(cards, in: text)
        XCTAssertEqual(placed.lines.count, 25)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0, "a 25-card, 800-line note is placed well within a second")
    }
}
