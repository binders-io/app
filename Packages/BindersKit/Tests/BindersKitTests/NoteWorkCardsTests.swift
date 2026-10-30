import XCTest
@testable import BindersKit

/// Lane DS6: one rule for a note's cards (Distill's, by hand, Put on Board's, and Put on Board's from before), and the
/// cards Put on Board makes from words selected in a note.
final class NoteWorkCardsTests: XCTestCase {
    let spec = UUID(), other = UUID()

    private func member(_ from: DistilledFrom?, kind: String? = "note", source: UUID? = nil, todo: String? = nil) -> NoteWorkCards.Membership? {
        NoteWorkCards.membership(distilled: from?.json ?? "", sourceKind: kind, sourceID: (source ?? spec).uuidString, todo: todo)
    }

    // MARK: A note's cards

    func testDistillsCardsAreTheNotes() {
        let made = DistilledFrom(note: spec, distill: UUID(), item: UUID(), section: "Auth", quote: "Sign in with a passkey")
        let found = member(made)
        XCTAssertEqual(found?.note, spec)
        XCTAssertEqual(found?.tie, .distilled)
        XCTAssertEqual(found?.staysInGroup, true, "Distill's card stays in its note's group")
        XCTAssertEqual(found?.quote, "Sign in with a passkey")
        XCTAssertEqual(found?.section, "Auth")
    }

    func testCardsPutInByHandAreTheNotesAndCanLeave() {
        // A card from a meeting, put in the spec's group by hand.
        let found = NoteWorkCards.membership(distilled: DistilledFrom.byHand(note: spec).json, sourceKind: "meeting",
                                             sourceID: UUID().uuidString, todo: nil)
        XCTAssertEqual(found?.note, spec)
        XCTAssertEqual(found?.tie, .byHand)
        XCTAssertEqual(found?.staysInGroup, false, "one put in by hand can be taken out")
        XCTAssertNil(found?.quote)
    }

    func testPutOnBoardsCardsAreTheNotesWithTheirWordsAndSection() {
        let put = DistilledFrom.put(note: spec, section: "Auth", sectionText: "- Sign in with a passkey\n- Recover", quote: "Sign in with a passkey")
        let found = member(put)
        XCTAssertEqual(found?.tie, .put)
        XCTAssertEqual(found?.note, spec)
        XCTAssertEqual(found?.staysInGroup, true, "made from the note: it stays in its group")
        XCTAssertEqual(found?.quote, "Sign in with a passkey")
        XCTAssertEqual(put.sectionHash, DistillSections.hash("- Sign in with a passkey\n- Recover"))
        XCTAssertEqual(put.seenText, "- Sign in with a passkey\n- Recover", "its section's changes are told from the text it was made from")
        XCTAssertFalse(put.isDistilled, "not Distill's")
        XCTAssertFalse(put.opensNote, "gives an agent no way into the note")
        XCTAssertTrue(put.followsSection, "its section's changes are said on it")
        let whole = DistilledFrom.put(note: spec)
        XCTAssertNil(whole.section)
        XCTAssertNil(whole.sectionHash)
        XCTAssertFalse(whole.followsSection, "a whole note's card follows no section")
        XCTAssertEqual(member(whole)?.tie, .put)
        // Made in the note's opening, before any "## ": no section, so no section's changes.
        XCTAssertFalse(DistilledFrom.put(note: spec, section: nil, sectionText: "Intro", quote: "Intro").followsSection)
    }

    func testPutOnBoardsCardsFromBeforeAreAdoptedAsTheyAre() {
        let found = member(nil)
        XCTAssertEqual(found?.note, spec, "source kind note with the note's id")
        XCTAssertEqual(found?.tie, .put)
        XCTAssertNil(found?.from, "nothing of Distill on it, and nothing written")
        XCTAssertEqual(NoteWorkCards.note(distilled: "", sourceKind: "note", sourceID: spec.uuidString.lowercased(), todo: nil), spec,
                       "a team database's copy names the note in lower case")
    }

    func testOtherCardsAreNotTheNotes() {
        XCTAssertNil(member(nil, kind: "meeting"), "a card from a meeting")
        XCTAssertNil(member(nil, todo: UUID().uuidString), "a card made from a to-do the note holds")
        XCTAssertNil(NoteWorkCards.membership(distilled: "", sourceKind: "note", sourceID: "not an id", todo: nil))
        XCTAssertNil(NoteWorkCards.membership(distilled: "", sourceKind: nil, sourceID: nil, todo: nil), "a card from nowhere")
        let request = DistilledFrom(note: spec, distill: UUID(), item: UUID(), request: true)
        XCTAssertNil(member(request), "a card asking an agent to distill the note isn't part of its work")
        XCTAssertNil(member(nil, kind: "note", source: other).flatMap { $0.note == spec ? $0 : nil }, "another note's card")
        XCTAssertEqual(member(DistilledFrom.byHand(note: other))?.note, other, "put in another note's group, it's that note's")
        XCTAssertNil(NoteWorkCards.membership(distilled: "{\"later\":1}", sourceKind: "note", sourceID: spec.uuidString, todo: nil),
                     "a Distill part a later build wrote says nothing")
    }

    func testAnOldPartWithoutPutReadsAsBefore() throws {
        let old = #"{"note":"\#(spec.uuidString)","distill":"\#(spec.uuidString)","item":"\#(spec.uuidString)","byHand":true}"#
        let from = try XCTUnwrap(DistilledFrom(json: old))
        XCTAssertNil(from.put)
        XCTAssertEqual(from.byHand, true)
        let mark = try XCTUnwrap(SectionChangeMark(json: #"{"kind":"person","by":"you","added":1,"removed":0}"#))
        XCTAssertNil(mark.withoutNote, "a section's change written before this build")
    }

    // MARK: What an agent hears of a Put on Board card's section

    func testAnAgentHearsOnlyWhoAndHowMuchOfAPutCardsSection() {
        let line = "The Auth section of “Spec” changed after this card was made: by you, 1 line added.\n+ Recover with email"
        let mine = SectionChangeMark(.you, added: 1, removed: 0, withoutNote: true)
        XCTAssertEqual(DistilledFrom.forAgent(line, mark: mine, readsTeam: true),
                       "The Auth section of “Spec” changed after this card was made: by you, 1 line added.", "never its lines, nor a way into the note")
        let agents = SectionChangeMark(kind: .agent, by: "Scribe (your agent)", added: 1, held: true, withoutNote: true)
        XCTAssertNil(DistilledFrom.forAgent(line, mark: agents, readsTeam: true), "an agent's change: nothing until a person looks")
        // Distill's cards hear as before.
        XCTAssertEqual(DistilledFrom.forAgent(line, mark: SectionChangeMark(.you, added: 1, removed: 0), readsTeam: true), line)
        XCTAssertFalse(DistilledFrom.passedOn(section: "Auth", note: "Spec", by: "Scribe", opensNote: false).contains("get_note_version"))
        XCTAssertTrue(DistilledFrom.passedOn(section: "Auth", note: "Spec", by: "Scribe").contains("get_note_version"))
    }

    // MARK: Put on Board from a selection

    let note = """
        # Checkout

        Opening words.

        ## Auth
        - [ ] Sign in with a **passkey**
        - Recover the account by [email](https://example.com)
        * Lock after five tries

        ## Billing
        Charge the card once.
        """

    private func range(of words: String, through end: String? = nil) -> NSRange {
        let string = note as NSString
        let start = string.range(of: words)
        guard let end else { return start }
        let last = string.range(of: end)
        return NSRange(location: start.location, length: NSMaxRange(last) - start.location)
    }

    func testOneCardForASelectionTitledFromItsFirstLine() throws {
        let selection = range(of: "- [ ] Sign in", through: "five tries")
        let pieces = NoteSelectionCards.pieces(text: note, selection: selection, noteID: spec, eachLine: false)
        let piece = try XCTUnwrap(pieces.first)
        XCTAssertEqual(pieces.count, 1)
        XCTAssertEqual(piece.title, "Sign in with a passkey", "list marker, checkbox and bold taken off")
        XCTAssertEqual(piece.section, "Auth")
        XCTAssertEqual(piece.sectionText, DistillSections.section("Auth", in: note)?.text)
        XCTAssertTrue(piece.details.hasPrefix("- [ ] Sign in with a **passkey**\n- Recover"), "the selection, as written: \(piece.details)")
        XCTAssertTrue(piece.details.hasSuffix("From the note, “Auth”: [open it](\(DistillLinks.section(note: spec, heading: "Auth")))"))
        // Short enough to be its quote whole, and found in the note.
        XCTAssertEqual(piece.quote, "Sign in with a **passkey** Recover the account by [email](https://example.com) Lock after five tries")
        let found = try XCTUnwrap(DistillQuote.find(piece.quote ?? "", section: piece.section, in: note))
        XCTAssertEqual(found.how, .loose)
        XCTAssertTrue((note as NSString).substring(with: found.range).hasSuffix("five tries"))
    }

    func testEachLineIsACardWithItsOwnQuote() {
        let selection = range(of: "## Auth", through: "five tries")
        XCTAssertEqual(NoteSelectionCards.lines(in: note, selection: selection).count, 3, "the heading isn't a line of work")
        let pieces = NoteSelectionCards.pieces(text: note, selection: selection, noteID: spec, eachLine: true)
        XCTAssertEqual(pieces.map(\.title), ["Sign in with a passkey", "Recover the account by email", "Lock after five tries"])
        XCTAssertEqual(pieces.map(\.quote), ["Sign in with a **passkey**", "Recover the account by [email](https://example.com)", "Lock after five tries"])
        XCTAssertEqual(Set(pieces.map(\.section)), ["Auth"])
        for piece in pieces {
            XCTAssertEqual(DistillQuote.find(piece.quote ?? "", section: piece.section, in: note)?.how, .exact, "found as it is: \(piece.title)")
        }
    }

    func testASelectionInTheOpeningHasNoSection() {
        let piece = NoteSelectionCards.pieces(text: note, selection: range(of: "Opening words."), noteID: spec, eachLine: false).first
        XCTAssertEqual(piece?.title, "Opening words.")
        XCTAssertNil(piece?.section)
        XCTAssertNil(piece?.sectionText)
        XCTAssertEqual(piece?.quote, "Opening words.")
        XCTAssertTrue(piece?.details.hasSuffix("From the note: [open it](binders://note/\(spec.uuidString))") == true)
        XCTAssertEqual(NoteSelectionCards.section(at: (note as NSString).range(of: "Charge").location, in: note), "Billing")
    }

    func testALongFirstLineMakesALongTitleShortAndALongSelectionQuotesItsFirstLine() {
        let words = (1...40).map { "word\($0)" }.joined(separator: " ")
        let title = NoteSelectionCards.title("- " + words)
        XCTAssertLessThanOrEqual(title.count, NoteSelectionCards.titleLength + 1)
        XCTAssertTrue(title.hasSuffix("…"))
        XCTAssertFalse(title.contains("- "))
        let text = "# Note\n\n\(words)\nsecond line here\n"
        let selection = NSRange(location: 8, length: (text as NSString).length - 8)
        let piece = NoteSelectionCards.pieces(text: text, selection: selection, noteID: spec, eachLine: false).first
        XCTAssertEqual(piece?.quote, words, "more than 25 words: its first line")
    }

    func testANoteWithAnAgentsWordsCopiesNoneOfThem() {
        let agent = AgentMark(madeBy: "Scribe")
        let piece = NoteSelectionCards.pieces(text: note, selection: range(of: "Charge the card once."), noteID: spec, eachLine: false, agent: agent).first
        XCTAssertNotNil(agent.label)
        XCTAssertFalse(piece?.details.contains("Charge the card") ?? true, "the words stay in the note: \(piece?.details ?? "")")
        XCTAssertTrue(piece?.details.contains("[open it]") ?? false)
    }

    func testNothingSelectedOrNoWordsMakesNoCard() {
        XCTAssertTrue(NoteSelectionCards.pieces(text: note, selection: NSRange(location: 3, length: 0), noteID: spec, eachLine: false).isEmpty)
        XCTAssertTrue(NoteSelectionCards.pieces(text: "a\n\n---\n", selection: NSRange(location: 2, length: 4), noteID: spec, eachLine: true).isEmpty)
        XCTAssertEqual(NoteSelectionCards.title("- [ ]"), "")
        XCTAssertEqual(NoteSelectionCards.title("> *Ship* the `beta` ~~soon~~ [[Launch plan|launch]]"), "Ship the beta soon launch")
        XCTAssertEqual(NoteSelectionCards.title("Keep snake_case_names as they are"), "Keep snake_case_names as they are")
    }

    func testStayingInTheGroupIsSaidForPutCards() {
        XCTAssertEqual(BoardBulkWords.stayed([.put("Checkout")]), "1 stayed: it was put on the board from “Checkout”, so it stays in that note's group.")
        XCTAssertEqual(BoardBulkWords.stayed([.put("Checkout"), .put("Checkout")]),
                       "2 stayed: they were put on the board from “Checkout”, so they stay in that note's group.")
    }
}
