import XCTest
@testable import BindersKit

/// Lane DS5: a note's cards as one group on the board, the card's parent in its distilled part, and acting on many.
final class BoardGroupsTests: XCTestCase {
    let spec = UUID(), plan = UUID()
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func card(_ column: BoardColumn, _ note: UUID?, at minutes: Double, closed: Bool = false) -> BoardGroups.Card {
        BoardGroups.Card(id: UUID(), column: column, note: note, created: t0.addingTimeInterval(minutes * 60), closed: closed)
    }

    // MARK: Grouping

    func testEachColumnShowsTheNotesInTheSameOrderNewestFirstAndLooseCardsLast() {
        let a = card(.ready, spec, at: 1), b = card(.ready, nil, at: 9), c = card(.ready, plan, at: 5), d = card(.ready, spec, at: 2)
        let e = card(.inProgress, spec, at: 3), f = card(.inProgress, plan, at: 4)
        let board = [a, b, c, d, e, f]
        let titles = [spec: "Checkout redesign", plan: "Launch plan"]
        XCTAssertEqual(BoardGroups.order(board, titles: titles), [plan, spec], "the plan's newest card is newer than the spec's")
        let ready = BoardGroups.groups(in: .ready, cards: board, titles: titles)
        XCTAssertEqual(ready.map(\.title), ["Launch plan", "Checkout redesign", "Not from a note"])
        XCTAssertEqual(ready[1].cards, [a.id, d.id], "within a group the column's own order holds")
        XCTAssertEqual(ready[2].cards, [b.id])
        XCTAssertNil(ready[2].progress, "cards from no note have no progress")
        let doing = BoardGroups.groups(in: .inProgress, cards: board, titles: titles)
        XCTAssertEqual(doing.map(\.note), [plan, spec], "the same order in every column")
        XCTAssertTrue(BoardGroups.groups(in: .done, cards: board, titles: titles).isEmpty, "a column with no cards has no groups")
    }

    func testCountsAreThisColumnsAndProgressIsTheWholeGroupsOnTheBoard() {
        let board = [card(.ready, spec, at: 1), card(.ready, spec, at: 2), card(.inProgress, spec, at: 3), card(.done, spec, at: 4),
                     card(.done, spec, at: 5), card(.done, spec, at: 6, closed: true), card(.backlog, spec, at: 7, closed: true)]
        let ready = BoardGroups.groups(in: .ready, cards: board, titles: [spec: "Spec"])
        XCTAssertEqual(ready.first?.cards.count, 2, "2 in Ready")
        XCTAssertEqual(ready.first?.progress, .init(done: 2, total: 5), "closed cards count as neither done nor open")
        XCTAssertEqual(ready.first?.progress?.line, "2 of 5 done")
        XCTAssertEqual(BoardGroups.spoken(ready[0]), "Spec, 2 cards here, 2 of 5 done")
        XCTAssertEqual(BoardGroups.progress(of: plan, in: board), .init(done: 0, total: 0))
    }

    func testAGroupsSelectAllTakesItsCardsInEveryColumn() {
        let a = card(.ready, spec, at: 1), b = card(.done, spec, at: 2), c = card(.ready, plan, at: 3), d = card(.backlog, nil, at: 4)
        XCTAssertEqual(BoardGroups.cards(of: spec, in: [a, b, c, d]), [a.id, b.id])
        XCTAssertEqual(BoardGroups.cards(of: nil, in: [a, b, c, d]), [d.id])
    }

    func testANoteWithoutATitleIsStillNamedAndTiesGoByTitle() {
        let a = card(.ready, spec, at: 1), b = card(.ready, plan, at: 1)
        XCTAssertEqual(BoardGroups.order([a, b], titles: [spec: "Zebra", plan: "Apple"]), [plan, spec])
        XCTAssertEqual(BoardGroups.groups(in: .ready, cards: [a], titles: [:]).first?.title, "A note")
    }

    // MARK: Selecting

    func testCommandClickTogglesShiftClickTakesARunInTheColumnAndAPlainClickClears() {
        let ids = (0..<5).map { _ in UUID() }
        var selection = BoardSelection()
        XCTAssertTrue(selection.click(ids[1], command: true, shift: false, column: ids))
        XCTAssertTrue(selection.click(ids[3], command: false, shift: true, column: ids))
        XCTAssertEqual(selection.ids, Set(ids[1...3]), "⇧-click: the run from the last one clicked")
        selection.click(ids[2], command: true, shift: false, column: ids)
        XCTAssertEqual(selection.ids, [ids[1], ids[3]], "⌘-click takes one away")
        let other = [UUID(), UUID()]
        selection.click(other[1], command: false, shift: true, column: other)
        XCTAssertTrue(selection.contains(other[1]), "⇧-click in another column adds that card alone")
        XCTAssertEqual(selection.count, 3)
        XCTAssertFalse(selection.click(ids[0], command: false, shift: false, column: ids), "a plain click opens the card")
        XCTAssertTrue(selection.isEmpty, "and clears the selection")
    }

    func testSelectAllKeepAndClear() {
        let ids = (0..<4).map { _ in UUID() }
        var selection = BoardSelection()
        selection.select(ids)
        XCTAssertEqual(selection.count, 4)
        selection.select([ids[0]])
        XCTAssertEqual(selection.ids, [ids[0]], "a group's Select All chooses its cards alone")
        selection.select([ids[1]], adding: true)
        XCTAssertEqual(selection.ids, [ids[0], ids[1]])
        selection.keep([ids[1], ids[2]])
        XCTAssertEqual(selection.ids, [ids[1]], "a deleted card leaves the selection")
        selection.clear()
        XCTAssertTrue(selection.isEmpty)
    }

    // MARK: What it says

    func testTheLinesSayWhatWasDoneAndWhatStayed() {
        XCTAssertEqual(BoardBulkWords.selected(5), "5 cards selected")
        XCTAssertEqual(BoardBulkWords.moved(5, to: .inProgress), "Moved 5 cards to In progress.")
        XCTAssertEqual(BoardBulkWords.moved(4, to: .done, stays: [.working("Claude Code")]),
                       "Moved 4 cards to Done. 1 stayed: Claude Code is working on it.")
        XCTAssertEqual(BoardBulkWords.moved(1, to: .ready, already: 2, stays: [.working("Echo"), .working("Echo"), .refused("The team's database is out of reach")]),
                       "Moved 1 card to Ready. 2 were in Ready already. 2 stayed: Echo is working on them. 1 stayed: The team's database is out of reach.")
        XCTAssertEqual(BoardBulkWords.assigned(5, to: "Claude Code", agent: true), "Gave 5 cards to Claude Code.")
        XCTAssertEqual(BoardBulkWords.assigned(2, to: "You", agent: false, stays: [.done]), "2 cards are for you now. 1 stayed: it's done.")
        XCTAssertEqual(BoardBulkWords.assigned(1, to: nil, agent: false), "1 card is for anyone now.")
        XCTAssertEqual(BoardBulkWords.deleted(3), "Deleted 3 cards.")
        XCTAssertEqual(BoardBulkWords.grouped(2, into: "Spec", stays: [.distilled("Plan")]),
                       "Put 2 cards in “Spec”. 1 stayed: Distill made it from “Plan”, so it stays in that note's group.")
        XCTAssertEqual(BoardBulkWords.grouped(2, into: nil), "Took 2 cards out of their notes' groups.")
        XCTAssertEqual(BoardBulkWords.deleteQuestion(5), "Delete 5 cards?")
        XCTAssertEqual(BoardBulkWords.deleteMessage, "You can undo this.")
        XCTAssertEqual(BoardBulkWords.giveQuestion(5, to: "Claude Code"), "Give 5 cards to Claude Code?")
        XCTAssertEqual(BoardBulkWords.notHandedOver(["Agents are paused.", "Agents are paused.", "It isn't in Ready for an agent that takes it"]),
                       "2 weren't handed over yet: Agents are paused. 1 wasn't handed over yet: It isn't in Ready for an agent that takes it.")
        XCTAssertNil(BoardBulkWords.notHandedOver([]))
        XCTAssertFalse(BoardBulkWords.moved(2, to: .ready).contains("successfully"))
    }

    // MARK: The card's parent, in its distilled part

    func testAHandAddedCardNamesItsNoteAndNothingOfDistill() throws {
        let from = DistilledFrom.byHand(note: spec)
        XCTAssertEqual(from.groupNote, spec)
        XCTAssertFalse(from.isDistilled)
        let kept = try XCTUnwrap(DistilledFrom(json: from.json), "it keeps on the card as JSON")
        XCTAssertEqual(kept.byHand, true)
        XCTAssertEqual(kept.groupNote, spec)
    }

    func testACardDistillMadeIsInItsNotesGroupAndARequestIsInNone() {
        let made = DistilledFrom(note: spec, distill: UUID(), item: UUID(), section: "Payment form")
        XCTAssertTrue(made.isDistilled)
        XCTAssertEqual(made.groupNote, spec)
        let asking = DistilledFrom(note: spec, distill: plan, item: plan, request: true)
        XCTAssertNil(asking.groupNote, "a card asking an agent to distill the note is about it, not part of its work")
        XCTAssertFalse(asking.isDistilled)
    }

    func testAnOldRecordWithoutTheParentStillReads() throws {
        // As a card made before this lane keeps it.
        let note = UUID(), distill = UUID(), item = UUID()
        let old = #"{"note":"\#(note.uuidString)","distill":"\#(distill.uuidString)","item":"\#(item.uuidString)","section":"Rollout","sectionHash":"abc"}"#
        let from = try XCTUnwrap(DistilledFrom(json: old))
        XCTAssertNil(from.byHand)
        XCTAssertTrue(from.isDistilled)
        XCTAssertEqual(from.groupNote, note)
    }
}
