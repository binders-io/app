import XCTest
@testable import BindersKit

/// Distill finished for 0.10.0 (lane RF2): what of a section's change reaches an agent, editing sessions, the Work panel's
/// column and last update, whom a card waits on, a confident "nobody", the Work bar's section line, and a proposal that
/// only offers to update or close cards.
final class DistillFinishTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let line = """
        The Payment form section of “Checkout” changed after this card was made: by Sam, 1 line added.
        + - Show the card's brand as it's typed.
        """

    // MARK: What reaches an agent

    func testYourChangeReachesTheAgentWithItsLines() {
        let mark = SectionChangeMark(.you, added: 1, removed: 0)
        XCTAssertEqual(mark.kind, .person)
        XCTAssertNil(mark.held)
        XCTAssertEqual(DistilledFrom.forAgent(line, mark: mark, readsTeam: false), line, "your own words, whatever it may read")
        // Binders itself (a ticked to-do, a link following a rename) is on your side too.
        XCTAssertEqual(DistilledFrom.forAgent(line, mark: SectionChangeMark(.binders, added: 1, removed: 0), readsTeam: false), line)
    }

    func testATeammatesLinesReachOnlyAnAgentThatMayReadTeammatesItems() {
        let mark = SectionChangeMark(.teammate("Sam"), added: 1, removed: 0)
        XCTAssertEqual(DistilledFrom.forAgent(line, mark: mark, readsTeam: true), line)
        let kept = DistilledFrom.forAgent(line, mark: mark, readsTeam: false) ?? ""
        XCTAssertFalse(kept.contains("brand"), "never the teammate's words: \(kept)")
        XCTAssertTrue(kept.hasPrefix("The Payment form section of “Checkout” changed after this card was made: by Sam, 1 line added."), "who, which section, how much")
        XCTAssertTrue(kept.contains("get_note_version"), "and where to read it")
    }

    func testAnotherAgentsLinesNeverReachAnAgent() {
        var mark = SectionChangeMark(.agent("Scribe"), added: 1, removed: 0)
        XCTAssertEqual(mark.held, true)
        XCTAssertEqual(mark.by, "Scribe (your agent)")
        XCTAssertNil(DistilledFrom.forAgent(line, mark: mark, readsTeam: true), "nothing until a person has looked")
        mark.held = false
        let after = DistilledFrom.forAgent(line, mark: mark, readsTeam: true) ?? ""
        XCTAssertFalse(after.contains("brand"), "nor after: \(after)")
        XCTAssertTrue(after.contains("get_note_version"))
        // A teammate's agent is an agent too.
        XCTAssertNil(DistilledFrom.forAgent(line, mark: SectionChangeMark(.agent("Pennant", owner: "Sam"), added: 1, removed: 0), readsTeam: true))
    }

    func testAMarkThatDoesntReadGetsTheShortForm() {
        XCTAssertNil(SectionChangeMark(json: #"{"kind":"robot","by":"R2","added":1,"removed":0}"#), "a kind a later build adds")
        XCTAssertNil(SectionChangeMark(json: nil))
        XCTAssertNil(SectionChangeMark(json: ""))
        let short = DistilledFrom.forAgent(line, mark: nil, readsTeam: true) ?? ""
        XCTAssertFalse(short.contains("brand"))
        let mark = SectionChangeMark(.agent("Scribe"), added: 2, removed: 1)
        XCTAssertEqual(SectionChangeMark(json: mark.json), mark, "it reads back as written")
    }

    func testWhatTheHoldingAgentHearsOnceYouLookedSaysHowMuch() {
        let told = DistilledFrom.passedOn(section: "Retry", note: "Checkout", by: "Scribe (your agent)", added: 1, removed: 1)
        XCTAssertTrue(told.contains("by Scribe (your agent): 1 line added, 1 removed, and the user has looked at it."), told)
        XCTAssertTrue(told.contains("get_note_version"))
        XCTAssertFalse(DistilledFrom.passedOn(section: nil, note: "Checkout", by: "Scribe").contains(":  "), "no counts, no stray colon")
    }

    func testACardFromBeforeReadsWithoutWhatItSaw() throws {
        let note = UUID(), distill = UUID(), item = UUID()
        let old = #"{"note":"\#(note.uuidString)","distill":"\#(distill.uuidString)","item":"\#(item.uuidString)","section":"Retry","noticedHash":"abc"}"#
        let from = try XCTUnwrap(DistilledFrom(json: old))
        XCTAssertNil(from.seenText)
        XCTAssertEqual(from.noticedHash, "abc")
        var seen = from
        seen.seenText = "Keep what was typed."
        XCTAssertEqual(DistilledFrom(json: seen.json)?.seenText, "Keep what was typed.")
    }

    // MARK: A proposal that only updates or closes cards

    func testAProposalOfOnlyChangesToCardsStaysReviewable() {
        let note = UUID()
        let updates = [DistillUpdate(kind: .brief, card: UUID(), brief: "New"), DistillUpdate(kind: .close, card: UUID())]
        var record = DistillRecord(note: note, ranBy: "You", readBy: "stand-in", items: [], updates: updates)
        XCTAssertTrue(record.waiting.isEmpty)
        XCTAssertTrue(record.waitsForReview)
        XCTAssertEqual(DistillFile(note: note, distills: [record]).proposal?.id, record.id, "Review stays after Not Now")
        record.updates[0].taken = true
        XCTAssertEqual(DistillFile(note: note, distills: [record]).proposal?.id, record.id, "one offer still open")
        record.updates[1].taken = false
        XCTAssertFalse(record.waitsForReview)
        XCTAssertNil(DistillFile(note: note, distills: [record]).proposal, "every offer taken or let be")
        record.updates[1].taken = nil
        record.status = .dismissed
        XCTAssertNil(DistillFile(note: note, distills: [record]).proposal, "put aside")
    }

    // MARK: Editing sessions

    func testAVersionIsOneEditingSession() {
        let typing = NoteVersions.Session(author: .you, last: now)
        XCTAssertTrue(NoteVersions.beginsSession(after: nil, by: .you, at: now), "none going on: left, closed, or Binders started since")
        XCTAssertFalse(NoteVersions.beginsSession(after: typing, by: .you, at: now.addingTimeInterval(5 * 60)), "five minutes of typing is still one")
        XCTAssertFalse(NoteVersions.beginsSession(after: typing, by: .you, at: now.addingTimeInterval(9 * 60 + 59)))
        XCTAssertTrue(NoteVersions.beginsSession(after: typing, by: .you, at: now.addingTimeInterval(10 * 60)), "ten minutes without a change ends it")
        XCTAssertTrue(NoteVersions.beginsSession(after: typing, by: .teammate("Sam"), at: now.addingTimeInterval(1)), "someone else edits")
        XCTAssertTrue(NoteVersions.beginsSession(after: typing, by: .agent("Scribe"), at: now.addingTimeInterval(1)))
        XCTAssertTrue(NoteVersions.beginsSession(after: typing, by: .you, at: now.addingTimeInterval(1), always: true), "a change that's a session of its own")
    }

    func testASessionsVersionIsDatedAtItsLastChange() {
        let session = NoteVersions.Session(author: .you, last: now)
        XCTAssertEqual(NoteVersions.versionDate(of: session, now: now.addingTimeInterval(3_600), after: now.addingTimeInterval(-60)), now)
        XCTAssertEqual(NoteVersions.versionDate(of: nil, now: now, after: nil), now)
        XCTAssertEqual(NoteVersions.versionDate(of: session, now: now.addingTimeInterval(10), after: now), now.addingTimeInterval(0.001),
                       "never at or before the version kept before it")
        XCTAssertEqual(NoteVersions.versionDate(of: session, now: now.addingTimeInterval(-5), after: nil), now.addingTimeInterval(-5), "nor after now")
        XCTAssertEqual(NoteVersions.versionDate(of: nil, now: now, after: now), now.addingTimeInterval(0.001), "within the same millisecond, the next one")
        let kept = Date(timeIntervalSince1970: 1_800_000_000.0009)
        let next = NoteVersions.versionDate(of: NoteVersions.Session(author: .you, last: kept), now: kept, after: kept)
        XCTAssertNotEqual(Int64(next.timeIntervalSince1970 * 1000), Int64(kept.timeIntervalSince1970 * 1000), "its own file name")
    }

    func testEachVersionCountsItsOwnChangeAndTheSectionsItTouched() {
        let a = "# Spec\n\n## Auth flow\nPasswords."
        let b = "# Spec\n\n## Auth flow\nPasswords.\n\n## Billing\nCards.\nInvoices."
        let c = "# Spec\n\n## Auth flow\nPasskeys.\n\n## Billing\nCards.\nInvoices."
        let entries = NoteVersions.entries(texts: [("a", now, a), ("b", now.addingTimeInterval(60), b), ("c", now.addingTimeInterval(120), c)],
                                           now: c, index: NoteVersionIndex())
        XCTAssertEqual(entries.map(\.id), ["c", "b", "a"])
        XCTAssertEqual(entries[0].added, 1, "from the version before it, not from now")
        XCTAssertEqual(entries[0].removed, 1)
        XCTAssertEqual(entries[0].sections, ["Auth flow"])
        XCTAssertEqual(entries[1].added, 4)
        XCTAssertEqual(entries[1].removed, 0)
        XCTAssertEqual(entries[1].sections, ["Billing"])
        XCTAssertEqual(entries[2].sections, [], "the earliest has nothing before it")
    }

    // MARK: The Work panel and the report

    func testTheWorkPanelSaysEachCardsColumnAndWhenItsLastUpdateWas() throws {
        var reported = DistillProgress.Card(id: "1", title: "A", column: .inProgress, assignee: "Echo", assigneeIsAgent: true,
                                            claimExpires: now.addingTimeInterval(600), lastReport: "Halfway", lastReportBy: "Echo", updated: now,
                                            lastReportAt: now.addingTimeInterval(-300))
        reported.doing = "Running the tests"
        let ready = DistillProgress.Card(id: "2", title: "B", column: .ready, updated: now)
        let items = DistillProgress.items([reported, ready], at: now)
        XCTAssertEqual(items.map(\.columnTitle), ["In progress", "Ready"])
        XCTAssertEqual(items[0].doing, "Running the tests")
        XCTAssertEqual(items[0].lastUpdate, "Halfway", "beside what its agent says it's doing")
        XCTAssertEqual(items[0].lastUpdateAt, AutomationPayload.iso(now.addingTimeInterval(-300)))
        XCTAssertNil(items[1].lastUpdateAt)
        // A Mac before it sends neither: an iPhone reads its reply as it did.
        let old = #"{"card":"1","title":"A","column":"ready","state":"not_started","who_is_agent":false,"meant":false,"updated":"2027-01-15T08:00:00Z","waits_for":[],"section_changed":false}"#
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let item = try decoder.decode(DistillProgress.Item.self, from: Data(old.utf8))
        XCTAssertNil(item.lastUpdateAt)
        XCTAssertNil(item.waitsOn)
        let counts = try decoder.decode(DistillProgress.Counts.self,
                                        from: Data(#"{"total":2,"done":1,"in_progress":0,"waits_on_you":1,"held_up":0,"not_started":0}"#.utf8))
        XCTAssertEqual(counts.line, "1 of 2 done · 1 waits on you")
    }

    func testTheReportNamesWhoACardWaitsOn() {
        var asked = DistillProgress.Card(id: "1", title: "Pricing", column: .blocked, assignee: "Pennant (Sam's)", assigneeIsAgent: true, updated: now)
        asked.question = "send the price list"
        asked.asker = "Pennant (Sam's)"
        asked.approval = true
        asked.waitsOn = "Sam"
        var review = DistillProgress.Card(id: "2", title: "Copy", column: .review, assignee: "Echo", assigneeIsAgent: true, updated: now)
        review.waitsOn = "Dana"
        var yours = DistillProgress.Card(id: "3", title: "Legal", column: .blocked, updated: now)
        yours.blockedReason = "Needs a signature."
        let report = DistillProgress.report(note: "Launch", cards: [asked, review, yours], since: nil, now: now)
        XCTAssertEqual(report.waiting.map(\.who), ["Sam", "Dana", "you"])
        XCTAssertEqual(report.waiting.map(\.detail), ["Pennant (Sam's) asks Sam's approval to: send the price list", "ready for Dana to check, from Echo",
                                                      "blocked: Needs a signature."])
        XCTAssertTrue(report.summary.contains("“Pricing” waits on Sam: Pennant (Sam's) asks Sam's approval to: send the price list."), report.summary)
        XCTAssertTrue(report.markdown.contains("- “Copy”: waits on Dana. Ready for Dana to check, from Echo"), report.markdown)
        XCTAssertTrue(report.markdown.contains("- “Legal”: waits on you. Blocked: Needs a signature."), report.markdown)
        XCTAssertEqual(report.counts.line, "0 of 3 done · 1 waits on you · 2 wait on teammates")
        XCTAssertEqual(DistillProgress.items([asked, review, yours], at: now).map(\.waitsOn), ["Sam", "Dana", nil])
        XCTAssertEqual(DistillProgress.Counts(total: 2, waitsOnYou: 1, waitsOnTeammates: 1).line, "0 of 2 done · 1 waits on a teammate")
    }

    // MARK: The Work bar's section line

    func testTheWorkBarSaysWhoChangedASectionWhenAndHowMuch() {
        var entry = DistillProgress.SectionEntry(section: "Auth flow", by: "Sam", at: "", added: 3, removed: 1, gone: false, caughtUp: [], behind: ["A"])
        XCTAssertEqual(entry.barLine(when: "5 minutes ago"), "The Auth flow section changed by Sam, 5 minutes ago: 3 lines added, 1 removed. 1 card hasn't caught up.")
        entry.behind = []
        entry.caughtUp = ["A"]
        XCTAssertEqual(entry.barLine(when: nil), "The Auth flow section changed by Sam: 3 lines added, 1 removed. Its cards caught up.")
        entry.gone = true
        entry.behind = ["A", "B"]
        XCTAssertEqual(entry.barLine(when: "yesterday"), "The Auth flow section is gone, taken out by Sam, yesterday. 2 cards haven't caught up.")
    }

    // MARK: Who an item is meant for

    func testANameInForMatchesYourAgentsAndTheTeamsPeople() {
        let names = ["Echo", "You", "Sam Lee", "Dana", "Pennant (Sam Lee)"]
        XCTAssertEqual(DistillWho.match("dana", among: names), "Dana")
        XCTAssertEqual(DistillWho.match("Sam", among: names), "Sam Lee", "a first name that's only one person's")
        XCTAssertEqual(DistillWho.match("Pennant (Sam Lee)", among: names), "Pennant (Sam Lee)")
        XCTAssertNil(DistillWho.match("Robin", among: names), "someone not in the team")
        XCTAssertNil(DistillWho.match("Sam", among: names + ["Sam Ortiz"]), "two people of that name")
        XCTAssertNil(DistillWho.match(" ", among: names))
    }

    func testANobodyTheModelIsSureOfIsMeantForYou() {
        let bands = RouterBands(start: 0.97, suggest: 0.5, generalBelow: 0.5, generalBelowTitlesOnly: 0.5)
        let sure = [RankedOption(key: "Echo", p: 0.1), RankedOption(key: RouterQuestions.nobody, p: 0.9)]
        let unsure = [RankedOption(key: "Echo", p: 0.35), RankedOption(key: RouterQuestions.nobody, p: 0.45), RankedOption(key: "Scribe", p: 0.2)]
        XCTAssertTrue(RouterRules.saysNobody(sure, bands: bands))
        XCTAssertFalse(RouterRules.saysNobody(unsure, bands: bands), "unsure: nobody, as before")
        XCTAssertFalse(RouterRules.saysNobody(nil, bands: bands), "no decision model")
        XCTAssertFalse(RouterRules.saysNobody([RankedOption(key: "Echo", p: 0.9), RankedOption(key: RouterQuestions.nobody, p: 0.1)], bands: bands))
        XCTAssertFalse(RouterRules.saysNobody(sure, bands: RouterBands(start: nil, suggest: RouterBands.never, generalBelow: 0.5, generalBelowTitlesOnly: 0.5)),
                       "a model whose measure names no one")
    }
}
