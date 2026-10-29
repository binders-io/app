import XCTest
@testable import BindersKit

/// Folders inside a binder: their names, paths, and what may move where.
final class FolderTreeTests: XCTestCase {
    private let ops = FolderNode(name: "Ops")
    private lazy var devOps = FolderNode(parentID: ops.id, name: "DevOps")
    private lazy var pipelines = FolderNode(parentID: devOps.id, name: "Pipelines")
    private let social = FolderNode(name: "Social posts")
    private lazy var all = [ops, devOps, pipelines, social]

    func testNamesAreCleanedAndASlashIsNoName() {
        XCTAssertEqual(FolderTree.cleanName("  Social   posts "), "Social posts")
        XCTAssertEqual(FolderTree.cleanName("Q3/Q4 plans"), "Q3-Q4 plans", "a slash separates a path, so it can't be in a name")
        XCTAssertNil(FolderTree.cleanName("   "))
        XCTAssertNil(FolderTree.cleanName(""))
        XCTAssertEqual(FolderTree.cleanName(String(repeating: "a", count: 200))?.count, FolderTree.maxNameLength)
        XCTAssertEqual(FolderTree.key("Dev  Ops"), FolderTree.key("dev ops"))
        XCTAssertNotEqual(FolderTree.key("DevOps"), FolderTree.key("Dev Ops"))
    }

    func testPathsAsWritten() {
        XCTAssertEqual(FolderTree.components("DevOps / Pipelines"), ["DevOps", "Pipelines"])
        XCTAssertEqual(FolderTree.components("/DevOps//Pipelines/"), ["DevOps", "Pipelines"])
        XCTAssertEqual(FolderTree.components("/"), [], "the top")
        XCTAssertEqual(FolderTree.components(""), [])
    }

    func testAFoldersPathFromTheTop() {
        XCTAssertEqual(FolderTree.path(of: pipelines.id, in: all), "Ops/DevOps/Pipelines")
        XCTAssertEqual(FolderTree.path(of: ops.id, in: all), "Ops")
        XCTAssertEqual(FolderTree.path(of: nil, in: all), "", "the top of the binder")
        XCTAssertEqual(FolderTree.path(of: UUID(), in: all), "", "a folder that isn't there reads as the top")
        XCTAssertEqual(FolderTree.chain(to: pipelines.id, in: FolderTree.index(all)).map(\.name), ["Ops", "DevOps", "Pipelines"])
    }

    func testALoopFromTwoMacsStillHasAPath() {
        let a = UUID(), b = UUID()
        let looped = [FolderNode(id: a, parentID: b, name: "A"), FolderNode(id: b, parentID: a, name: "B")]
        XCTAssertEqual(FolderTree.path(of: a, in: FolderTree.index(looped)), "B/A", "read as it is, each folder once")
        let c = FolderNode(parentID: a, name: "C")
        XCTAssertEqual(FolderTree.path(of: c.id, in: looped + [c]), "A/C", "and as it's shown")
        let shown = FolderTree.flattened(looped + [c])
        XCTAssertEqual(shown.map(\.node.name), ["A", "C", "B"], "the two in the loop show at the top, rather than hidden, with what's in them")
        XCTAssertEqual(shown.map(\.depth), [0, 1, 0])
    }

    func testAFolderNeverGoesIntoItselfOrOneOfItsOwnFolders() {
        XCTAssertFalse(FolderTree.canMove(ops.id, into: ops.id, in: all), "into itself")
        XCTAssertFalse(FolderTree.canMove(ops.id, into: devOps.id, in: all), "into its own folder")
        XCTAssertFalse(FolderTree.canMove(ops.id, into: pipelines.id, in: all), "into a folder two levels down")
        XCTAssertTrue(FolderTree.canMove(pipelines.id, into: ops.id, in: all), "up is fine")
        XCTAssertTrue(FolderTree.canMove(devOps.id, into: social.id, in: all), "across is fine")
        XCTAssertTrue(FolderTree.canMove(pipelines.id, into: nil, in: all), "to the top is fine")
        XCTAssertEqual(FolderTree.subtree(of: ops.id, in: all), [ops.id, devOps.id, pipelines.id])
    }

    func testChildrenSortLikeFinder() {
        let week2 = FolderNode(name: "Week 2"), week10 = FolderNode(name: "Week 10"), alpha = FolderNode(name: "alpha")
        XCTAssertEqual(FolderTree.children(of: nil, in: [week10, week2, alpha]).map(\.name), ["alpha", "Week 2", "Week 10"])
    }

    func testFlattenedForAMenu() {
        let flat = FolderTree.flattened(all)
        XCTAssertEqual(flat.map(\.node.name), ["Ops", "DevOps", "Pipelines", "Social posts"])
        XCTAssertEqual(flat.map(\.depth), [0, 1, 2, 0])
        XCTAssertEqual(FolderTree.flattened(all, excluding: [devOps.id]).map(\.node.name), ["Ops", "Social posts"],
                       "a folder left out takes what's inside it")
        XCTAssertEqual(FolderTree.flattened(all, under: ops.id).map(\.node.name), ["DevOps", "Pipelines"])
        let orphan = FolderNode(parentID: UUID(), name: "Arrived early")
        XCTAssertEqual(FolderTree.flattened([orphan]).map(\.node.name), ["Arrived early"], "a parent not here yet counts as the top")
    }

    func testFindingAFolderByItsPath() {
        XCTAssertEqual(FolderTree.resolve(["ops", "DEVOPS"], in: all), devOps.id, "case doesn't count")
        XCTAssertEqual(FolderTree.resolve(["Ops", "Dev  Ops"], in: all), nil, "but spacing between words is a different name")
        XCTAssertEqual(FolderTree.resolve([], in: all), nil, "the top")
        XCTAssertEqual(FolderTree.resolve(["Pipelines"], in: all, from: devOps.id), pipelines.id)
        let partial = FolderTree.resolvePartially(["Ops", "DevOps", "Releases", "2026"], in: all)
        XCTAssertEqual(partial.deepest, devOps.id)
        XCTAssertEqual(partial.missing, ["Releases", "2026"])
        XCTAssertEqual(FolderTree.resolvePartially(["Nothing"], in: all).deepest, nil)
    }

    func testTheListAsATree() {
        let top = UUID(), inOps = UUID(), deep = UUID(), lost = UUID(), inSocial = UUID()
        let items: [(id: UUID, folder: UUID?)] = [(top, nil), (deep, pipelines.id), (inOps, ops.id), (lost, UUID()), (inSocial, social.id)]
        // All closed: the folders at the top, then what's at the top, in the order given; one whose folder isn't here too.
        XCTAssertEqual(FolderTree.outline(all, items: items, open: []), [.folder(ops.id, depth: 0), .folder(social.id, depth: 0),
                                                                        .item(top, depth: 0), .item(lost, depth: 0)])
        // Ops open: its folder, then its items, under it.
        XCTAssertEqual(FolderTree.outline(all, items: items, open: [ops.id]),
                       [.folder(ops.id, depth: 0), .folder(devOps.id, depth: 1), .item(inOps, depth: 1), .folder(social.id, depth: 0),
                        .item(top, depth: 0), .item(lost, depth: 0)])
        // A folder open inside a closed one stays hidden.
        XCTAssertFalse(FolderTree.outline(all, items: items, open: [devOps.id, pipelines.id]).contains(.item(deep, depth: 3)))
        let everything = FolderTree.outline(all, items: items, open: [ops.id, devOps.id, pipelines.id, social.id])
        XCTAssertEqual(everything.count, 9)
        XCTAssertTrue(everything.contains(.item(deep, depth: 3)))
        XCTAssertEqual(everything.map(\.depth), [0, 1, 2, 3, 1, 0, 1, 0, 0])
    }

    func testCountsTakeTheWholeFolder() {
        let counts = FolderTree.counts(all, items: [pipelines.id, pipelines.id, ops.id, nil, UUID()])
        XCTAssertEqual(counts[ops.id], 3, "its own and those in the folders inside it")
        XCTAssertEqual(counts[devOps.id], 2)
        XCTAssertEqual(counts[pipelines.id], 2)
        XCTAssertNil(counts[social.id])
        XCTAssertEqual(FolderTree.ancestors(of: pipelines.id, in: all), [ops.id, devOps.id])
        XCTAssertEqual(FolderTree.ancestors(of: ops.id, in: all), [])
        XCTAssertEqual(FolderTree.ancestors(of: nil, in: all), [])
    }
}

/// Tidy into folders: the prefix rule, case by case, and what's proposed.
final class FolderTidyTests: XCTestCase {
    private func split(_ title: String) -> FolderTidy.Split? { FolderTidy.split(title) }

    func testTheFoundersTitles() {
        XCTAssertEqual(split("DevOps | Pipeline cleanup"), .init(prefix: "DevOps", rest: "Pipeline cleanup"))
        XCTAssertEqual(split("Social post · Launch week"), .init(prefix: "Social post", rest: "Launch week"))
        XCTAssertEqual(split("SRE report · March"), .init(prefix: "SRE report", rest: "March"), "a date after the separator is fine")
        XCTAssertNil(split("Q3 - plan"), "a quarter is a date")
        XCTAssertNil(split("2026-10-02 - standup"), "a date isn't a prefix, and its own hyphens don't split it")
    }

    func testSeparators() {
        XCTAssertEqual(split("DevOps|Pipeline")?.prefix, "DevOps", "a bar splits without spaces")
        XCTAssertEqual(split("DevOps   |   Pipeline")?.rest, "Pipeline")
        XCTAssertEqual(split("Social post ·Launch")?.prefix, "Social post", "a dot with a space on one side")
        XCTAssertNil(split("Col·lecció privada"), "a dot inside a word isn't a separator")
        XCTAssertEqual(split("Board – minutes")?.prefix, "Board", "an en dash")
        XCTAssertEqual(split("Board — minutes")?.prefix, "Board", "an em dash")
        XCTAssertNil(split("Follow-up with Sam"), "a hyphen inside a word")
        XCTAssertNil(split("Follow -up"), "a hyphen needs a space on both sides")
        XCTAssertEqual(split("DevOps | Pipeline - cleanup"), .init(prefix: "DevOps", rest: "Pipeline - cleanup"), "the first separator")
        XCTAssertEqual(split("Ops - Incidents | May"), .init(prefix: "Ops", rest: "Incidents | May"))
        XCTAssertNil(split("Pipeline cleanup"), "no separator")
    }

    func testWhatIsntAPrefix() {
        XCTAssertNil(split("12 | items"), "a number")
        XCTAssertNil(split("1:1 · Tuesday"), "no letter in it")
        XCTAssertNil(split("March · budget"), "a month")
        XCTAssertNil(split("Oct 2 - offsite"), "a month and a day")
        XCTAssertNil(split("2 Oct 2026 - offsite"))
        XCTAssertNil(split("Monday | standup"), "a weekday")
        XCTAssertNil(split("Today · errands"))
        XCTAssertNil(split("Q3 2026 | goals"), "a quarter and a year")
        XCTAssertNil(split("FY26 | budget"), "a fiscal year")
        XCTAssertNil(split("H1 - review"), "a half")
        XCTAssertNil(split("Week 42 · retro"), "a week")
        XCTAssertNil(split("W42 · retro"))
        XCTAssertNil(split("Week of Oct · plan"), "words that only go with a date")
        XCTAssertNil(split("Customer success team sync | notes"), "more than three words")
        XCTAssertNil(split("Supercalifragilisticexpialidociousness | x"), "more than 32 characters")
        XCTAssertNil(split("DevOps | "), "nothing after it")
        XCTAssertNil(split("DevOps | …"), "nothing that reads after it")
        XCTAssertNil(split(" | Pipeline"), "nothing before it")
        XCTAssertNil(split("[[DevOps]] | Pipeline"), "a link isn't a folder")
        XCTAssertEqual(split("Sprint 12 - retro")?.prefix, "Sprint 12", "a word with a number is a prefix")
        XCTAssertEqual(split("March madness · bracket")?.prefix, "March madness", "a month among other words is a prefix")
        XCTAssertEqual(split("Board meeting notes | Q3")?.prefix, "Board meeting notes", "three words")
    }

    private func note(_ title: String) -> FolderTidy.Note { FolderTidy.Note(id: UUID(), title: title) }

    func testTheProposal() {
        let notes = [note("DevOps | Pipeline cleanup"), note("devops  | Alert rules"), note("DevOps | On-call rota"),
                     note("Social post · Launch week"), note("Social post · Hiring"), note("SRE report · March"),
                     note("Q3 - plan"), note("Q3 - review"), note("2026-10-02 - standup"), note("Pipeline cleanup notes")]
        let proposals = FolderTidy.proposals(for: notes)
        XCTAssertEqual(proposals.map(\.folderName), ["DevOps", "Social post"], "a prefix one note has stays, and dates never count")
        XCTAssertEqual(proposals[0].items.map(\.newTitle), ["Alert rules", "On-call rota", "Pipeline cleanup"])
        XCTAssertEqual(proposals[0].items.first?.title, "devops  | Alert rules")
        XCTAssertEqual(proposals[1].items.map(\.newTitle), ["Hiring", "Launch week"])
        XCTAssertTrue(proposals.allSatisfy { $0.existingFolder == nil })
    }

    func testTheSpellingMostNotesUse() {
        let proposals = FolderTidy.proposals(for: [note("devops | A"), note("DevOps | B"), note("DevOps | C")])
        XCTAssertEqual(proposals.first?.folderName, "DevOps")
        let tie = FolderTidy.proposals(for: [note("Devops | A"), note("DevOps | B")])
        XCTAssertEqual(tie.first?.folderName, "Devops", "a tie goes to the note given first (the newest)")
    }

    func testAFolderAlreadyThere() {
        let existing = FolderNode(name: "Social posts")
        let inside = FolderNode(parentID: existing.id, name: "DevOps")
        let proposals = FolderTidy.proposals(for: [note("Social post · Launch week"), note("DevOps | Alerts")], existing: [existing, inside])
        XCTAssertEqual(proposals.map(\.folderName), ["Social posts"], "one note is enough for a folder already at the top, plural and all")
        XCTAssertEqual(proposals.first?.existingFolder, existing.id)
        XCTAssertEqual(proposals.first?.items.map(\.newTitle), ["Launch week"])
        let both = FolderTidy.proposals(for: [note("Social post · A"), note("Social posts · B")], existing: [existing])
        XCTAssertEqual(both.count, 1, "two prefixes naming one folder go into it together")
        XCTAssertEqual(both.first?.items.count, 2)
    }

    func testTitlesThatWouldClashStay() {
        let items = FolderTidy.proposals(for: [note("DevOps | March"), note("DevOps | Alerts"), note("SRE report · March"), note("SRE report · Plan")])
            .flatMap(\.items)
        let kept = FolderTidy.keepingTitles(items, taken: [WikiLinks.key("Plan")])
        XCTAssertEqual(Set(items.filter { kept.contains($0.id) }.map(\.title)), ["DevOps | March", "SRE report · March", "SRE report · Plan"],
                       "two would be called March, and another note is already called Plan")
    }

    func testTakingThePrefixOffTheFirstLine() {
        XCTAssertEqual(FolderTidy.removingPrefix(from: "# DevOps | Pipeline cleanup\n\nThe body | stays"), "# Pipeline cleanup\n\nThe body | stays")
        XCTAssertEqual(FolderTidy.removingPrefix(from: "Social post · Launch week"), "Launch week", "a plain first line")
        XCTAssertEqual(FolderTidy.removingPrefix(from: "## **DevOps** | *Pipeline* cleanup\nBody"), "## *Pipeline* cleanup\nBody",
                       "markup after the prefix is kept")
        XCTAssertEqual(FolderTidy.removingPrefix(from: "- [ ] SRE report · March\nBody"), "- [ ] March\nBody")
        XCTAssertNil(FolderTidy.removingPrefix(from: "# Pipeline cleanup\nDevOps | in the body"), "only the title counts")
        XCTAssertNil(FolderTidy.removingPrefix(from: "# 2026-10-02 - standup"))
    }
}
