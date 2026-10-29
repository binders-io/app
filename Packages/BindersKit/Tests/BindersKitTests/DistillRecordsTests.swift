import XCTest
@testable import BindersKit

final class DistillRecordsTests: XCTestCase {
    // MARK: Turning it on

    func testDistillTravelsInTheMarkdownCopyAsAYAMLBoolean() {
        var note = TeamNote(id: "N1", body: "# Spec\n\nText", properties: NoteProperties(status: "Draft", distill: true))
        let markdown = TeamFiles.noteMarkdown(note)
        XCTAssertTrue(markdown.contains("\nbinders_distill: true\n"), markdown)
        XCTAssertFalse(markdown.contains("binders_distill: \"true\""), "not a quoted string")
        let parsed = TeamFiles.parseNote(markdown)
        XCTAssertTrue(parsed.properties.distill)
        XCTAssertEqual(parsed.properties.status, "Draft")
        XCTAssertFalse(parsed.extraFrontmatter.contains { $0.hasPrefix("binders_distill") }, "it isn't kept twice")
        // Off: no line at all.
        note.properties.distill = false
        XCTAssertFalse(TeamFiles.noteMarkdown(note).contains("binders_distill"))
        // Obsidian may write it other ways.
        XCTAssertTrue(TeamFiles.parseNote("---\nbinders_distill: yes\n---\n# A").properties.distill)
        XCTAssertFalse(TeamFiles.parseNote("---\nbinders_distill: false\n---\n# A").properties.distill)
    }

    func testAnOlderMacKeepsTheLineAsItsOwnExtraFrontMatter() {
        // A Mac before Distill reads the line as front matter it doesn't know and writes it back as it was.
        let fromOlder = "---\nbinders_id: \"N1\"\nbinders_distill: true\nstatus: \"Draft\"\n---\n# Spec"
        let parsed = TeamFiles.parseNote(fromOlder)
        XCTAssertTrue(parsed.properties.distill)
        let written = TeamFiles.noteMarkdown(parsed)
        XCTAssertEqual(written.components(separatedBy: "binders_distill").count, 2, "once")
    }

    func testTheHashIsUnchangedWithDistillOff() {
        XCTAssertEqual(TeamFiles.noteHash("# A", NoteProperties()), TeamFiles.noteHash("# A"))
        XCTAssertEqual(TeamFiles.noteHash("# A", NoteProperties(status: "Draft")),
                       TeamFiles.noteHash("# A", NoteProperties(status: "Draft", distill: false)))
        XCTAssertNotEqual(TeamFiles.noteHash("# A", NoteProperties(distill: true)), TeamFiles.noteHash("# A"), "turning it on is a change to sync")
        XCTAssertFalse(NoteProperties(distill: true).isEmpty)
    }

    func testTheSpecTemplateTurnsDistillOn() {
        let spec = NoteTemplate.builtIn.first { $0.name == "Spec" }
        XCTAssertEqual(spec?.distill, true)
        XCTAssertTrue(spec?.body.hasPrefix("# ") ?? false)
        XCTAssertFalse(NoteTemplate.builtIn.filter { $0.name != "Spec" }.contains { $0.distill })
        XCTAssertEqual(NoteTemplate.sections(of: spec?.body ?? ""), ["Goal", "Scope", "Requirements", "Design", "Rollout", "Open questions"])
        // One of yours, from its file.
        let file = NoteTemplate(name: "RFC", file: "---\nbinders_distill: true\n---\n# RFC: \n\n## Proposal\n")
        XCTAssertTrue(file.distill)
        XCTAssertEqual(file.body, "# RFC: \n\n## Proposal\n")
        XCTAssertFalse(NoteTemplate(name: "Plain", file: "# Plain\n").distill)
        XCTAssertEqual(NoteTemplate(name: "Plain", file: "# Plain\n").body, "# Plain\n")
        XCTAssertEqual(NoteTemplate.file(body: "# RFC", distill: true), "---\nbinders_distill: true\n---\n# RFC")
        XCTAssertEqual(NoteTemplate.file(body: "# RFC", distill: false), "# RFC")
    }

    // MARK: Old records

    func testOldDistillFilesRead() throws {
        // A file with only what the first build wrote, and one item a later build added a kind to.
        let json = """
            {"note": "6F1C2D3E-0000-4000-8000-000000000001", "distills": [
              {"id": "6F1C2D3E-0000-4000-8000-000000000002", "note": "6F1C2D3E-0000-4000-8000-000000000001", "readBy": "gemma",
               "status": "proposed", "items": [{"id": "6F1C2D3E-0000-4000-8000-000000000003", "title": "Add retry"},
                                                {"id": "6F1C2D3E-0000-4000-8000-000000000004", "title": "Odd", "size": "gigantic", "hint": "robot"}]},
              {"id": "not a uuid"},
              {"id": "6F1C2D3E-0000-4000-8000-000000000005", "note": "6F1C2D3E-0000-4000-8000-000000000001", "status": "someday", "items": []}
            ]}
            """
        let file = try DistillFile.decoder().decode(DistillFile.self, from: Data(json.utf8))
        XCTAssertEqual(file.version, 1)
        XCTAssertEqual(file.distills.count, 2, "the one that doesn't read is left out")
        let first = file.distills[0]
        XCTAssertEqual(first.ranBy, "You")
        XCTAssertFalse(first.readByAgent)
        XCTAssertEqual(first.items.count, 2)
        XCTAssertEqual(first.items[0].brief, "")
        XCTAssertEqual(first.items[0].waitsFor, [])
        XCTAssertFalse(first.items[0].dropped)
        XCTAssertNil(first.items[1].size, "a size this build doesn't know")
        XCTAssertNil(first.items[1].hint)
        XCTAssertEqual(first.updates, [])
        XCTAssertEqual(file.distills[1].status, .proposed, "a status this build doesn't know stays in front of a person")
        XCTAssertEqual(file.proposal?.id, first.id)
        // And it goes back out as it came in, give or take what was filled in.
        let again = try DistillFile.decoder().decode(DistillFile.self, from: DistillFile.encoder().encode(file))
        XCTAssertEqual(again, file)
    }

    func testDistilledFromOnACard() {
        let from = DistilledFrom(note: UUID(), distill: UUID(), item: UUID(), section: "Sync", sectionHash: "abc", version: "1700000000000")
        XCTAssertEqual(DistilledFrom(json: from.json), from)
        XCTAssertNil(DistilledFrom(json: ""), "a card Distill didn't make")
        XCTAssertNil(DistilledFrom(json: "{\"note\": 1}"))
        // One written before noticedHash and held existed.
        let old = #"{"note":"6F1C2D3E-0000-4000-8000-000000000001","distill":"6F1C2D3E-0000-4000-8000-000000000002","item":"6F1C2D3E-0000-4000-8000-000000000003","section":"Sync","sectionHash":"abc"}"#
        let read = DistilledFrom(json: old)
        XCTAssertEqual(read?.seenHash, "abc")
        XCTAssertNil(read?.held)
    }

    func testOldVersionIndexesRead() throws {
        let json = #"{"versions": {"1700000000000": {"by": {"name": "Claude Code", "kind": "agent"}}, "1700000000001": {}}, "current": {"by": {"name": "Sam", "kind": "android"}, "since": 1}}"#
        let index = try JSONDecoder().decode(NoteVersionIndex.self, from: Data(json.utf8))
        XCTAssertEqual(index.versions["1700000000000"]?.by, NoteAuthor.agent("Claude Code"))
        XCTAssertEqual(index.versions["1700000000000"]?.by.owner, "You", "an agent with no owner said is yours")
        XCTAssertEqual(index.versions["1700000000001"]?.by, .you)
        XCTAssertEqual(index.versions["1700000000001"]?.distills, [])
        XCTAssertEqual(index.current?.by.kind, .person, "a kind this build doesn't know reads as a person's")
        XCTAssertEqual(index.sections, [:])
    }

    // MARK: Sections

    func testSectionsAndTheirVersions() {
        let text = """
            # Checkout

            Intro line.

            ## Payment form
            - One page.

            ### Details
            Inside the form section.

            ```
            ## Not a heading
            ```

            ## Retry
            Keep what was typed.
            """
        let sections = DistillSections.sections(of: text)
        XCTAssertEqual(sections.map(\.heading), [nil, "Payment form", "Retry"])
        XCTAssertEqual(sections[0].text, "Intro line.")
        XCTAssertTrue(sections[1].text.contains("### Details"), "a ### heading stays inside its section")
        XCTAssertTrue(sections[1].text.contains("## Not a heading"), "a heading in code doesn't count")
        XCTAssertEqual(sections[2].text, "Keep what was typed.")
        // Its version doesn't change with the space at line ends or blank lines around it.
        XCTAssertEqual(DistillSections.hash("A\nB  \n\n"), DistillSections.hash("\nA\nB"))
        XCTAssertNotEqual(DistillSections.hash("A\nB"), DistillSections.hash("A\nC"))
        XCTAssertEqual(DistillSections.section("retry", in: text)?.heading, "Retry")
        XCTAssertEqual(DistillSections.section(nil, in: text)?.text, "Intro line.")
        XCTAssertEqual(DistillSections.touched(from: text, to: text.replacingOccurrences(of: "Keep what was typed.", with: "Keep it.")), ["Retry"])
        let change = DistillSections.change(from: "A\nB", to: "A\nC\nD")
        XCTAssertEqual(change.added, 2)
        XCTAssertEqual(change.removed, 1)
        XCTAssertEqual(change.lines, [.removed("B"), .added("C"), .added("D")])
    }

    func testHeadingsMatchLoosely() {
        let headings = ["Payment form", "Retry after a failed payment", "Rollout"]
        XCTAssertEqual(DistillSections.match("Payment form", in: headings), "Payment form")
        XCTAssertEqual(DistillSections.match("## payment Form", in: headings), "Payment form")
        XCTAssertEqual(DistillSections.match("2. Rollout", in: headings), "Rollout")
        XCTAssertEqual(DistillSections.match("Retry", in: headings), "Retry after a failed payment", "the only heading it starts")
        XCTAssertNil(DistillSections.match("Pricing", in: headings))
        XCTAssertNil(DistillSections.match("", in: headings))
        XCTAssertNil(DistillSections.match("Pay", in: ["Payment form", "Payout"]), "two it could be: neither")
    }

    func testLinksToASection() {
        let note = UUID()
        let link = DistillLinks.section(note: note, heading: "Retry after a failed payment")
        XCTAssertTrue(link.hasPrefix("binders://note/\(note.uuidString)?section="), link)
        let url = URL(string: link)!
        XCTAssertEqual(NoteCards.noteID(in: url), note, "it still opens the note")
        XCTAssertEqual(DistillLinks.heading(in: url), "Retry after a failed payment")
        XCTAssertEqual(DistillLinks.section(note: note, heading: nil), NoteCards.link(noteID: note.uuidString))
    }

    func testTheCardsDistillMakes() {
        let note = UUID()
        let item = DistillItem(title: "Add the retry button", brief: "Keep what was typed.", doneWhen: "Retry sends it again.", section: "Retry", size: .small)
        let details = DistillCards.details(item, note: note, noteTitle: "Checkout")
        XCTAssertTrue(details.hasPrefix("Keep what was typed.\n\n**Done when:** Retry sends it again.\n\nDistilled from [Checkout](binders://note/"))
        XCTAssertTrue(details.hasSuffix(" · section “Retry” · small"))
        XCTAssertTrue(DistillCards.details(item, note: note, noteTitle: "Checkout", placedByAgent: "Claude Code").hasPrefix("Placed by Claude Code"))
        let updated = DistillCards.updating(details, brief: "New brief.", doneWhen: "")
        XCTAssertTrue(updated.hasPrefix("New brief.\n\nDistilled from [Checkout]"))
        let request = DistillCards.requestDetails(noteText: "# Checkout\n\nText", note: note)
        XCTAssertTrue(request.contains("propose_work_items"))
        XCTAssertTrue(request.hasSuffix("# Checkout\n\nText"))
        XCTAssertEqual(DistillCards.requestTitle("Checkout"), "Distill “Checkout” into work items")
        let long = String(repeating: "x", count: DistillCards.noteLimit + 100)
        XCTAssertTrue(DistillCards.requestDetails(noteText: long, note: note).hasSuffix("\n\n…\n\n" + DistillCards.cutLine))
        XCTAssertFalse(request.contains(DistillCards.cutLine), "a note that fits isn't said to go on")
        // A card whose tie to its note didn't come with it is still known by its title and source.
        let title = DistillCards.requestTitle("V0.18")
        XCTAssertTrue(DistillCards.asksToDistill(title: title, sourceKind: "note", sourceTitle: "V0.18"))
        XCTAssertFalse(DistillCards.asksToDistill(title: title, sourceKind: "capture", sourceTitle: "V0.18"))
        XCTAssertFalse(DistillCards.asksToDistill(title: "Fix the login", sourceKind: "note", sourceTitle: "V0.18"))
        XCTAssertFalse(DistillCards.asksToDistill(title: title, sourceKind: "note", sourceTitle: nil))
    }
}
