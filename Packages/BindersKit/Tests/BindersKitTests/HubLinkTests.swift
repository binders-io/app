import XCTest
@testable import BindersKit

/// Linking a binder to a hub's project: the first upload as the hub's changes (shared/notes.ts and shared/work.ts), in
/// batches it takes, and what /api/me and /api/state say. Hubs, people and binders are made up.
final class HubLinkTests: XCTestCase {
    private let top = UUID(), inner = UUID(), stray = UUID(), loopA = UUID(), loopB = UUID()
    private let note1 = UUID(), note2 = UUID(), card1 = UUID(), card2 = UUID()
    private let day = Date(timeIntervalSince1970: 1_793_000_000)

    private func upload(newName: String? = "Garden") -> [HubLink.Outgoing] {
        HubLink.firstUpload(
            binder: "binder-g", newName: newName, person: "robin-h",
            folders: [
                .init(id: inner, parent: top, name: "Beds"),
                .init(id: top, parent: nil, name: "Plans"),
                .init(id: stray, parent: UUID(), name: "Orphan"),
                .init(id: loopA, parent: loopB, name: "A"),
                .init(id: loopB, parent: loopA, name: "B"),
            ],
            notes: [
                .init(id: note1, title: "Tomatoes", text: "# Tomatoes\n\nStake them.", folder: inner, editedAt: day),
                .init(id: note2, title: "Ideas", text: "Ideas", folder: UUID(), editedAt: day),
            ],
            cards: [
                .init(id: card1, title: "Buy stakes", details: "Bamboo", column: .backlog, links: ["https://example.com/stakes"],
                      createdAt: day, updatedAt: day, waitsFor: [card2.uuidString, UUID().uuidString], note: note1,
                      events: [.init(kind: "comment", author: "Claude Code", text: "Found some", at: day),
                               .init(kind: "progress", author: "Claude Code", text: "50%", at: day)]),
                .init(id: card2, title: "Dig", details: "", column: .inProgress, createdBy: "Pennant", createdAt: day, updatedAt: day),
            ])
    }

    private func json(_ outgoing: HubLink.Outgoing) -> [String: Any] {
        let data = try! JSONEncoder.hub.encode(outgoing)
        return try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    func testANewProjectGoesFirstThenFoldersParentsFirstThenNotesThenCards() {
        let changes = upload()
        let types = changes.map { (json($0)["change"] as! [String: Any])["type"] as! String }
        XCTAssertEqual(types, ["binder.put"] + Array(repeating: "folder.put", count: 5) + ["note.put", "note.put", "card.put", "card.put"])
        let binder = (json(changes[0])["change"] as! [String: Any])["binder"] as! [String: Any]
        XCTAssertEqual(binder as NSDictionary, ["id": "binder-g", "name": "Garden", "createdBy": "robin-h"])
        XCTAssertEqual(changes[0].id, "binder-binder-g")

        let folders = changes.compactMap { if case .folder(let f) = $0.change { f } else { nil } }
        let plans = folders.firstIndex { $0.name == "Plans" }!, beds = folders.firstIndex { $0.name == "Beds" }!
        XCTAssertLessThan(plans, beds, "a parent goes before what's in it")
        XCTAssertEqual(folders[beds].parentId, HubLink.hubID(top))
        XCTAssertNil(folders.first { $0.name == "Orphan" }?.parentId, "a folder whose parent isn't here goes at the top")
        XCTAssertNil(folders.first { $0.name == "A" }?.parentId, "folders in a loop go at the top")
        XCTAssertTrue(folders.allSatisfy { $0.binderId == "binder-g" })
        XCTAssertEqual(changes.first { $0.id == "folder-\(HubLink.hubID(top))" }.map { _ in true }, true, "a change's id is what it puts")
    }

    func testAnExistingProjectIsntPut() {
        let changes = upload(newName: nil)
        XCTAssertFalse(changes.contains { if case .binder = $0.change { true } else { false } })
        XCTAssertEqual(HubLink.counted(changes), "2 notes, 5 folders and 2 cards")
    }

    func testNotes() {
        let notes = upload().compactMap { if case .note(let n) = $0.change { n } else { nil } }
        XCTAssertEqual(notes[0].id, note1.uuidString.lowercased())
        XCTAssertEqual(notes[0].folderId, HubLink.hubID(inner))
        XCTAssertEqual(notes[0].editors, ["robin-h"])
        XCTAssertEqual(notes[0].text, "# Tomatoes\n\nStake them.")
        XCTAssertEqual(notes[0].editedAt, "2026-10-26T07:33:20.000Z", "as JavaScript's toISOString writes it")
        XCTAssertNil(notes[1].folderId, "a note in a folder that isn't here goes at the top")
        let wire = json(upload().first { $0.id == "note-\(HubLink.hubID(note2))" }!)["change"] as! [String: Any]
        XCTAssertNil((wire["note"] as! [String: Any])["folderId"], "nothing is sent for no folder")
    }

    func testCards() {
        let cards = upload().compactMap { if case .card(let c) = $0.change { c } else { nil } }
        let stakes = cards[0], dig = cards[1]
        XCTAssertEqual(stakes.stage, "proposed", "the hub's agents don't take a Backlog card")
        XCTAssertEqual(dig.stage, "working")
        XCTAssertEqual(stakes.brief, "Bamboo\n\n- https://example.com/stakes", "links go in the brief")
        XCTAssertEqual(stakes.waitsFor, [HubLink.hubID(card2)], "only cards that go up with it")
        XCTAssertEqual(stakes.noteId, HubLink.hubID(note1))
        XCTAssertEqual(stakes.createdBy, "robin-h", "You is who's signed in")
        XCTAssertEqual(dig.createdBy, "Pennant")
        XCTAssertEqual(stakes.activity.map(\.kind), ["created", "comment"], "what people and agents said, not progress")
        XCTAssertEqual(stakes.activity[1].by, "Claude Code")
        XCTAssertEqual(stakes.size, "M")
        XCTAssertEqual(BoardColumn.allCases.map(HubLink.stage), ["proposed", "ready", "working", "blocked", "review", "live"])
    }

    func testBatches() {
        let changes = upload()
        XCTAssertEqual(HubLink.batches(changes).count, 1)
        XCTAssertEqual(HubLink.batches(changes, maxCount: 4).map(\.count), [4, 4, 2])
        XCTAssertEqual(HubLink.batches(changes, maxBytes: 1).count, changes.count, "one each when each is too big, never none")
        XCTAssertEqual(HubLink.batches([]).count, 0)
        let body = try! JSONSerialization.jsonObject(with: HubLink.body(client: "mac-abc123", changes: Array(changes.prefix(1)))) as! [String: Any]
        XCTAssertEqual(body["client"] as? String, "mac-abc123")
        XCTAssertEqual((body["changes"] as? [Any])?.count, 1)
    }

    func testClient() {
        let client = HubLink.newClient()
        XCTAssertNotNil(client.range(of: #"^[A-Za-z0-9_-]{6,64}$"#, options: .regularExpression), "the hub's clientPattern")
        XCTAssertNotEqual(client, HubLink.newClient())
        XCTAssertTrue(HubLink.newProjectID().hasPrefix("binder-"))
    }

    func testMovedProjectIsTheSameOnEveryMac() {
        let binder = UUID(uuidString: "6B0E8F52-3C1A-4D2B-9E7F-0A1B2C3D4E5F")!
        XCTAssertEqual(HubLink.movedProjectID(binder), "binder-6b0e8f52-3c1a-4d2b-9e7f-0a1b2c3d4e5f")
        XCTAssertEqual(HubLink.movedProjectID(binder), HubLink.movedProjectID(binder))
        XCTAssertNotEqual(HubLink.movedProjectID(binder), HubLink.movedProjectID(UUID()))
    }

    func testWhatTheHubSays() {
        let me = Data(#"{"user":{"login":"robin-h","name":"Robin"},"space":"team","spaces":[{"id":"team","name":"Team","role":"owner"},{"id":"lab","name":"Lab","role":"member"}]}"#.utf8)
        let spaces = HubLink.spaces(fromMe: me)
        XCTAssertEqual(spaces.current, "team")
        XCTAssertEqual(spaces.spaces.map(\.name), ["Team", "Lab"])

        let changes = upload()
        let state = Data("""
        {"version":9,"state":{"binders":[{"id":"zz","name":"zebra"},{"id":"binder-g","name":"Garden","repo":"a/b"}],
         "folders":[{"id":"\(HubLink.hubID(top))","binderId":"binder-g","name":"Plans"},{"id":"\(HubLink.hubID(inner))","binderId":"zz","name":"Beds"}],
         "notes":[{"id":"\(HubLink.hubID(note1))","binderId":"binder-g"}],"cards":[],"agents":[]}}
        """.utf8)
        XCTAssertEqual(HubLink.projects(fromState: state)?.map(\.name), ["Garden", "zebra"], "by name")
        let missing = HubLink.missing(changes, fromState: state, binder: "binder-g") ?? []
        XCTAssertFalse(missing.contains("binder-binder-g"))
        XCTAssertFalse(missing.contains("folder-\(HubLink.hubID(top))"))
        XCTAssertTrue(missing.contains("folder-\(HubLink.hubID(inner))"), "in another project isn't in this one")
        XCTAssertEqual(missing.count, changes.count - 3)
        XCTAssertNil(HubLink.projects(fromState: Data("{}".utf8)))
        XCTAssertEqual(HubLink.error(in: Data(#"{"error":"No."}"#.utf8)), "No.")
    }

    func testPlaceIsKept() {
        let place = HubLink.Place(hub: URL(string: "https://hub.example.com")!, space: "team", spaceName: "Team", binder: "binder-g",
                                  binderName: "Garden", client: "mac-abc123", linkedAt: day)
        XCTAssertEqual(HubLink.Place(json: place.json), place)
        XCTAssertNil(HubLink.Place(json: ""))
    }
}
