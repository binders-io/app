import XCTest
@testable import BindersKit

final class HubSyncTests: XCTestCase {
    private func json(_ object: Any) -> Data { try! JSONSerialization.data(withJSONObject: object) }

    func testReadsTheHubsStateAndSkipsWhatItCantRead() throws {
        let data = json(["version": 12, "state": [
            "binders": [["id": "p1", "name": "Roadmap", "repo": "a/b"]],
            "folders": [["id": "f1", "binderId": "p1", "name": "Plans"], ["id": "broken"]],
            "notes": [["id": "n1", "title": "Hello", "binderId": "p1", "folderId": "f1", "editedAt": "2026-10-30T10:00:00.000Z",
                       "editors": ["robin"], "text": "# Hello", "commit": "abc", "path": "roadmap/hello.md"]],
            "cards": [["id": "c1"]], "agents": []]])
        let state = try XCTUnwrap(HubSync.State(hubState: data))
        XCTAssertEqual(state.version, 12)
        XCTAssertEqual(state.binders, [HubSync.Binder(id: "p1", name: "Roadmap")])
        XCTAssertEqual(state.folders.keys.sorted(), ["f1"])
        XCTAssertEqual(state.notes["n1"]?.folderId, "f1")
        XCTAssertNil(HubSync.State(hubState: json(["error": "no"])))
    }

    func testReadsLiveEntriesOfEveryKind() throws {
        let data = json(["type": "entries", "entries": [
            ["version": 3, "id": "a", "client": "user:robin:tab1", "at": "x",
             "change": ["type": "note.edit", "id": "n1", "text": "Hi", "title": "Hi", "by": "robin", "at": "t", "changes": ["AAAA"]]],
            ["version": 4, "id": "b", "client": "agent:1", "at": "x", "change": ["type": "card.update", "id": "c1", "fields": [:]]],
            ["version": 5, "id": "c", "client": "user:robin:tab1", "at": "x", "change": ["type": "folder.delete", "id": "f1"]],
        ]])
        let entries = try XCTUnwrap(HubSync.entries(fromLive: data))
        XCTAssertEqual(entries.map(\.version), [3, 4, 5])
        XCTAssertEqual(entries[0].change, .noteEdit(.init(id: "n1", text: "Hi", title: "Hi", by: "robin", at: "t", changes: ["AAAA"])))
        XCTAssertEqual(entries[1].change, .other("card.update"))
        XCTAssertEqual(entries[2].change, .folderDelete("f1"))
        XCTAssertNil(HubSync.entries(fromLive: json(["type": "presence", "presence": [:]])))
    }

    func testChangesGoAsSharedNotesTSWritesThem() throws {
        let move = HubSync.Change.noteMove("n1", binderId: "p1", folderId: nil)
        let moved = try JSONSerialization.jsonObject(with: JSONEncoder.hub.encode(move)) as! [String: Any]
        XCTAssertEqual(moved["type"] as? String, "note.move")
        XCTAssertNil(moved["folderId"])
        let edit = HubSync.Change.noteEdit(.init(id: "n1", text: "Hi", title: "Hi", by: "robin", at: "t", changes: ["AAAA"]))
        let edited = try JSONSerialization.jsonObject(with: JSONEncoder.hub.encode(edit)) as! [String: Any]
        XCTAssertEqual(edited["type"] as? String, "note.edit")
        XCTAssertEqual(edited["changes"] as? [String], ["AAAA"])
        XCTAssertEqual(try JSONDecoder().decode(HubSync.Change.self, from: JSONEncoder.hub.encode(edit)), edit)
        // What's waiting keeps through quitting.
        let pending = HubSync.Pending(client: "mac-1", change: edit, base: "H")
        XCTAssertEqual(try JSONDecoder().decode(HubSync.Pending.self, from: JSONEncoder.hub.encode(pending)), pending)
    }

    func testAppliesChangesAsTheHubDoes() {
        var state = HubSync.State()
        state.apply(.folderPut(.init(id: "f1", binderId: "p1", name: "Plans")))
        state.apply(.folderPut(.init(id: "f2", binderId: "p1", name: "Later", parentId: "f1")))
        state.apply(.notePut(.init(id: "n1", title: "A", binderId: "p1", folderId: "f2", editedAt: "t", editors: ["dana"], text: "A")))
        state.apply(.noteEdit(.init(id: "n1", text: "# B", title: "B", by: "robin", at: "t2", changes: nil)))
        XCTAssertEqual(state.notes["n1"]?.text, "# B")
        XCTAssertEqual(state.notes["n1"]?.editors, ["dana", "robin"])
        state.shared = ["f2", "n1"]
        // A folder goes with what's inside it moved up to where it was.
        state.apply(.folderDelete("f2"))
        XCTAssertEqual(state.notes["n1"]?.folderId, "f1")
        XCTAssertFalse(state.shared.contains("f2"))
        state.apply(.noteMove("n1", binderId: "p2", folderId: nil))
        XCTAssertEqual(state.notes["n1"]?.binderId, "p2")
        state.apply(.noteDelete("n1"))
        XCTAssertNil(state.notes["n1"])
        XCTAssertTrue(state.shared.isEmpty)
    }

    func testPlansWhatGoesAndWhatComes() {
        var state = HubSync.State()
        state.folders = ["f1": .init(id: "f1", binderId: "p1", name: "Plans"),
                         "f2": .init(id: "f2", binderId: "p1", name: "Old", parentId: "f1"),
                         "f9": .init(id: "f9", binderId: "p1", name: "From the web")]
        state.notes = ["n1": .init(id: "n1", title: "A", binderId: "p1", folderId: "f1", editedAt: "t", editors: [], text: "A"),
                       "n2": .init(id: "n2", title: "B", binderId: "p1", editedAt: "t", editors: [], text: "B"),
                       "n3": .init(id: "n3", title: "C", binderId: "p1", editedAt: "t", editors: [], text: "C"),
                       "n4": .init(id: "n4", title: "D", binderId: "p1", editedAt: "t", editors: [], text: "D"),
                       "n9": .init(id: "n9", title: "W", binderId: "p1", editedAt: "t", editors: [], text: "W")]
        state.shared = ["f1", "f2", "n1", "n2", "n3", "n4"]
        let folders = [HubSync.LocalFolder(id: "f3", parent: "f1", name: "New"), .init(id: "f1", parent: nil, name: "Plans, renamed")]
        let notes = [HubSync.LocalNote(id: "n1", folder: "f3", text: "A"),        // moved
                     .init(id: "n2", folder: nil, text: "B, edited"),             // written
                     .init(id: "n5", folder: "f1", text: "# Fresh\nwords")]       // new
        let plan = HubSync.plan(project: "p1", state: state, folders: folders, notes: notes, person: "robin", elsewhere: ["n4"],
                                at: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(plan.changes, [
            .folderPut(.init(id: "f1", binderId: "p1", name: "Plans, renamed")),
            .folderPut(.init(id: "f3", binderId: "p1", name: "New", parentId: "f1")),
            .noteMove("n1", binderId: "p1", folderId: "f3"),
            .notePut(.init(id: "n5", title: "Fresh", binderId: "p1", folderId: "f1", editedAt: "1970-01-01T00:00:00.000Z", editors: ["robin"],
                           text: "# Fresh\nwords")),
            .noteDelete("n3"),                                                     // deleted here; n4 moved to another binder
            .folderDelete("f2"),
        ])
        XCTAssertEqual(plan.edited, ["n2"])
        XCTAssertEqual(plan.newNotes, ["n9"])
        XCTAssertEqual(plan.newFolders, ["f9"])
    }

    func testNothingGoesWhenBothAgree() {
        var state = HubSync.State()
        state.folders = ["f1": .init(id: "f1", binderId: "p1", name: "Plans")]
        state.notes = ["n1": .init(id: "n1", title: "A", binderId: "p1", folderId: "f1", editedAt: "t", editors: [], text: "A")]
        state.shared = ["f1", "n1"]
        let plan = HubSync.plan(project: "p1", state: state, folders: [.init(id: "f1", parent: nil, name: "Plans")],
                                notes: [.init(id: "n1", folder: "f1", text: "A")], person: "robin")
        XCTAssertEqual(plan, HubSync.Plan())
    }

    func testDeletedFoldersGoChildrenFirst() {
        var state = HubSync.State()
        state.folders = ["a": .init(id: "a", binderId: "p1", name: "A"), "b": .init(id: "b", binderId: "p1", name: "B", parentId: "a"),
                         "c": .init(id: "c", binderId: "p1", name: "C", parentId: "b")]
        state.shared = ["a", "b", "c"]
        let plan = HubSync.plan(project: "p1", state: state, folders: [], notes: [], person: "robin")
        XCTAssertEqual(plan.changes, [.folderDelete("c"), .folderDelete("b"), .folderDelete("a")])
    }

    func testIdsHereForTheHubsIds() {
        let uuid = UUID()
        XCTAssertEqual(HubSync.localID(uuid.uuidString.lowercased()), uuid)
        let web = HubSync.localID("note-lq2x9-5")
        XCTAssertEqual(web, HubSync.localID("note-lq2x9-5"))
        XCTAssertNotEqual(web, HubSync.localID("note-lq2x9-6"))
        var state = HubSync.State()
        state.notes["note-lq2x9-5"] = .init(id: "note-lq2x9-5", title: "", binderId: "p1", editedAt: "", editors: [], text: "")
        XCTAssertEqual(HubSync.hubIDs(in: state)[web], "note-lq2x9-5")
    }

    func testTitlesAsTheHubMakesThem() {
        XCTAssertEqual(HubSync.title(of: "intro\n# Plan for May ##\nmore"), "Plan for May")
        XCTAssertEqual(HubSync.title(of: "\n- [ ] **ship** it"), "ship it")
        XCTAssertEqual(HubSync.title(of: "  \n"), "Untitled")
    }

    func testBatchesARunOfOneClient() {
        let a = HubSync.Pending(client: "mac-a", change: .noteDelete("1"))
        let b = HubSync.Pending(client: "mac-b", change: .noteDelete("2"))
        XCTAssertEqual(HubSync.nextBatch([a, a, b, a]).count, 2)
        XCTAssertEqual(HubSync.nextBatch(Array(repeating: a, count: 150)).count, 100)
        XCTAssertEqual(HubSync.nextBatch([]), [])
        let body = try! JSONSerialization.jsonObject(with: HubSync.body([a])) as! [String: Any]
        XCTAssertEqual(body["client"] as? String, "mac-a")
        XCTAssertEqual((body["changes"] as? [[String: Any]])?.first?["id"] as? String, a.id)
    }

    func testLiveAddress() {
        XCTAssertEqual(HubSync.liveURL(hub: URL(string: "https://hub.binders.io")!, since: 41)?.absoluteString, "wss://hub.binders.io/api/live?since=41")
        XCTAssertEqual(HubSync.liveURL(hub: URL(string: "http://localhost:8787")!, since: -1)?.absoluteString, "ws://localhost:8787/api/live?since=0")
        XCTAssertEqual(HubSync.retryDelay(after: 1), 1)
        XCTAssertEqual(HubSync.retryDelay(after: 3), 4)
        XCTAssertEqual(HubSync.retryDelay(after: 20), 30)
    }
}
