import XCTest
@testable import BindersKit

final class DistillAgainTests: XCTestCase {
    private let before = """
        # Offline mode

        ## Storage
        Keep the last 7 days of jobs on the device, encrypted.

        ## Sync
        Queue the changes made offline and send them in order.

        ## Interface
        Show a banner while offline.
        """

    /// The same note, its Sync section changed, Interface gone and Testing new.
    private let after = """
        # Offline mode

        ## Storage
        Keep the last 7 days of jobs on the device, encrypted.

        ## Sync
        Queue the changes made offline and send them in order. If a job changed on both sides, ask which to keep.

        ## Testing
        Test with the network cut for an hour.
        """

    private func earlier() -> [DistillAgain.Earlier] {
        let sections = DistillSections.sections(of: before)
        func hash(_ heading: String) -> String? { sections.first { $0.heading == heading }?.hash }
        return [
            DistillAgain.Earlier(item: UUID(), title: "Store 7 days of jobs, encrypted", section: "Storage", sectionHash: hash("Storage"), card: UUID()),
            DistillAgain.Earlier(item: UUID(), title: "Queue offline changes and send them in order", section: "Sync", sectionHash: hash("Sync"), card: UUID()),
            DistillAgain.Earlier(item: UUID(), title: "Show an offline banner", section: "Interface", sectionHash: hash("Interface"), card: UUID()),
        ]
    }

    func testSectionsAreNewChangedOrTheSame() {
        let plan = DistillAgain.plan(read: [], earlier: earlier(), sections: DistillSections.sections(of: after))
        XCTAssertEqual(plan.sections["Storage"], .same)
        XCTAssertEqual(plan.sections["Sync"], .changed)
        XCTAssertEqual(plan.sections["Testing"], .new)
        XCTAssertNil(plan.sections["Interface"], "it's gone")
    }

    func testItProposesOnlyTheNewAndTheChanged() {
        let sections = DistillSections.sections(of: after)
        let earlier = earlier()
        func item(_ title: String, _ section: String, brief: String = "") -> DistillItem {
            DistillItem(title: title, brief: brief, section: section, sectionHash: sections.first { $0.heading == section }?.hash)
        }
        let read = [
            item("Store the last 7 days of jobs, encrypted", "Storage"),
            item("Queue offline changes and send them in order", "Sync", brief: "Send in order; ask on a conflict."),
            item("Ask which version to keep on a conflict", "Sync", brief: "Keep both and ask."),
            item("Test an hour offline", "Testing"),
        ]
        let plan = DistillAgain.plan(read: read, earlier: earlier, sections: sections)
        XCTAssertEqual(plan.items.map(\.title), ["Ask which version to keep on a conflict", "Test an hour offline"],
                       "the storage item is the same as before, the queue item is on the board already")
        XCTAssertEqual(plan.updates.map(\.card), [earlier[1].card!], "the queue card's section changed: its brief is offered for update")
        XCTAssertEqual(plan.updates.first?.brief, "Send in order; ask on a conflict.")
        XCTAssertEqual(plan.updates.first?.sectionHash, sections.first { $0.heading == "Sync" }?.hash)
        XCTAssertEqual(plan.closes.map(\.card), [earlier[2].card!], "the banner card's section is gone")
        XCTAssertEqual(plan.leftOut, 2)
    }

    func testItNeverMakesTheSameItemTwice() {
        let sections = DistillSections.sections(of: before)
        let earlier = earlier()
        // Distilled again with nothing changed: the same items come back, and none is proposed.
        let read = earlier.map { DistillItem(title: $0.title, section: $0.section, sectionHash: $0.sectionHash) }
        let plan = DistillAgain.plan(read: read, earlier: earlier, sections: sections)
        XCTAssertTrue(plan.items.isEmpty)
        XCTAssertTrue(plan.updates.isEmpty)
        XCTAssertTrue(plan.closes.isEmpty)
        XCTAssertEqual(plan.leftOut, 3)
    }

    func testAChangedSectionsNewItemMatchesItsCardByTitle() {
        let sections = DistillSections.sections(of: after)
        let earlier = earlier()
        let read = [DistillItem(title: "Queue the offline changes and send in order", brief: "New brief.", section: "Sync")]
        let plan = DistillAgain.plan(read: read, earlier: earlier, sections: sections)
        XCTAssertTrue(plan.items.isEmpty, "close enough to the card that's there: an update, not a new item")
        XCTAssertEqual(plan.updates.first?.brief, "New brief.")
    }

    func testFinishedCardsAreLeftAlone() {
        var earlier = earlier()
        earlier[2].finished = true
        earlier[1].finished = true
        let sections = DistillSections.sections(of: after)
        let plan = DistillAgain.plan(read: [DistillItem(title: "Queue offline changes and send them in order", section: "Sync")], earlier: earlier,
                                     sections: sections)
        XCTAssertTrue(plan.closes.isEmpty, "a done card isn't closed")
        XCTAssertTrue(plan.updates.isEmpty, "nor brought up to date")
    }

    func testWaitsOnItemsLeftOutGo() {
        let sections = DistillSections.sections(of: after)
        let storage = DistillItem(title: "Store 7 days of jobs, encrypted", section: "Storage")
        var testing = DistillItem(title: "Test an hour offline", section: "Testing")
        testing.waitsFor = [storage.id]
        let plan = DistillAgain.plan(read: [storage, testing], earlier: earlier(), sections: sections)
        XCTAssertEqual(plan.items.map(\.title), ["Test an hour offline"])
        XCTAssertEqual(plan.items[0].waitsFor, [], "what it waited for is on the board from before, not in this proposal")
    }

    func testAnAgentsOwnProposalLeavesOutOnlyRepeats() {
        let earlier = earlier()
        let read = [DistillItem(title: "Show an offline banner", section: "Interface"),
                    DistillItem(title: "Write the help page", section: "Storage"),
                    DistillItem(title: "Show an offline banner", section: "Storage")]
        let added = DistillAgain.additions(read: read, earlier: earlier)
        XCTAssertEqual(added.items.map(\.title), ["Write the help page"],
                       "a new item in a section that's the same stays; the same item goes, in its own section or another")
        XCTAssertEqual(added.leftOut, 2)
    }

    func testASectionTheLastReadingCutShortOffersWhatItHeldBack() {
        // 0.11.0 kept a long note's first 25 items: Storage had one proposed and two held back. Read again, unchanged,
        // the two come now; one like the item proposed doesn't, and without the cut the section offers nothing.
        let sections = DistillSections.sections(of: before)
        let hash = sections.first { $0.heading == "Storage" }?.hash
        func read() -> [DistillItem] {
            ["Store 7 days of jobs, encrypted", "Rotate the device key monthly", "Wipe jobs older than 7 days",
             "Store the last 7 days of jobs encrypted"].map { DistillItem(title: $0, brief: "", section: "Storage", sectionHash: hash) }
        }
        let proposed = DistillAgain.Earlier(item: UUID(), title: "Store 7 days of jobs, encrypted", section: "Storage", sectionHash: hash,
                                            card: nil, heldBack: true)
        let cut = DistillAgain.plan(read: read(), earlier: [proposed], sections: sections)
        XCTAssertEqual(cut.items.map(\.title), ["Rotate the device key monthly", "Wipe jobs older than 7 days"])
        var whole = proposed
        whole.heldBack = false
        XCTAssertEqual(DistillAgain.plan(read: read(), earlier: [whole], sections: sections).items, [])
    }

    func testItemsInOtherWordsAreRepeats() {
        // Lane BF2: the same work, worded again by the model, anywhere in the note.
        XCTAssertTrue(DistillAgain.alike(("Rate-limit the login endpoint", "Cap login attempts per IP", nil),
                                         ("Add login rate limiting", "Cap login attempts per IP address", nil)))
        XCTAssertTrue(DistillAgain.alike(("Store the last 7 days of jobs encrypted", nil, nil), ("Store 7 days of jobs, encrypted", nil, nil)))
        XCTAssertTrue(DistillAgain.alike(("Ship the export button", nil, "the export button goes in the toolbar"),
                                         ("Add the export button", nil, "The export button goes in the toolbar.")), "the same words of the note")
        XCTAssertFalse(DistillAgain.alike(("Write tests for login", "Cover the sign-in form", nil), ("Write tests for signup", "Cover account creation", nil)))
        XCTAssertFalse(DistillAgain.alike(("Write docs", nil, nil), ("Build the demo", nil, nil)))
    }

    func testDistillingAgainAndAgainAddsNothingNew() {
        // A note read three times, the model wording its items a little differently each time: the second and third
        // readings propose nothing.
        let sections = DistillSections.sections(of: before)
        let hash = sections.first { $0.heading == "Storage" }?.hash
        func items(_ titles: [String], section: String? = "Storage", hash: String? = nil) -> [DistillItem] {
            titles.map { DistillItem(title: $0, brief: "", section: section, sectionHash: hash) }
        }
        let first = items(["Store 7 days of jobs, encrypted", "Rotate the device key monthly"], hash: hash)
        let earlier = first.map { DistillAgain.Earlier(item: $0.id, title: $0.title, section: $0.section, sectionHash: $0.sectionHash, card: nil,
                                                       heldBack: true, brief: $0.brief, quote: $0.quote) }
        let again = DistillAgain.plan(read: items(["Store the last 7 days of jobs encrypted", "Rotate device keys monthly"], hash: hash),
                                      earlier: earlier, sections: sections)
        XCTAssertEqual(again.items, [], "even where the last reading held items back")
        // A new section's item much like one from another section is a repeat too, and so is one twice in the same reading.
        let elsewhere = DistillAgain.plan(read: items(["Rotate the device keys every month", "Add a status page", "Add the status page"], section: nil),
                                          earlier: earlier, sections: sections)
        XCTAssertEqual(elsewhere.items.map(\.title), ["Add a status page"])
    }

    func testRepeatsWaitingInProposalsAreFound() {
        let placed = DistillItem(title: "Store 7 days of jobs, encrypted", brief: "", section: "Storage", card: UUID())
        let first = DistillRecord(note: UUID(), ranBy: "You", readBy: "Binders", status: .placed, items: [placed])
        let repeatItem = DistillItem(title: "Store the last 7 days of jobs encrypted", brief: "", section: "Storage")
        let fresh = DistillItem(title: "Rotate the device key monthly", brief: "", section: "Storage")
        let again = DistillItem(title: "Rotate device keys monthly", brief: "", section: "Storage")
        let second = DistillRecord(note: first.note, ranBy: "You", readBy: "Binders", items: [repeatItem, fresh])
        let third = DistillRecord(note: first.note, ranBy: "You", readBy: "Binders", items: [again])
        let found = DistillAgain.repeats(in: [first, second, third])
        XCTAssertEqual(found.map(\.item), [repeatItem.id, again.id], "the first of each stays")
        var dismissed = third
        dismissed.status = .dismissed
        XCTAssertEqual(DistillAgain.repeats(in: [first, second, dismissed]).map(\.item), [repeatItem.id], "only what's still waiting")
    }

    func testSimilarity() {
        XCTAssertEqual(DistillAgain.similarity("Show an offline banner", "show the offline banner."), 1)
        XCTAssertEqual(DistillAgain.similarity("Write docs", "Build the demo"), 0)
        XCTAssertGreaterThan(DistillAgain.similarity("Queue offline changes", "Queue the offline changes in order"), 0.5)
    }
}
