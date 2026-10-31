import XCTest
@testable import BindersKit

/// A linked binder's cards as the hub has them (shared/work.ts): read from /api/state, kept current by /api/live's
/// entries, and this Mac's changes as the hub's. Hubs, people and agents are made up.
final class HubCardsTests: XCTestCase {
    private func board() -> HubCards.Board {
        let state: [String: Any] = [
            "version": 7,
            "state": [
                "binders": [["id": "binder-g", "name": "Garden"]],
                "agents": [["id": "agent-1", "name": "Claude", "owner": "robin-h"], ["id": "agent-2", "name": "Codex", "owner": "sam-k"]],
                "cards": [
                    ["id": "card-1", "binderId": "binder-g", "title": "Buy stakes", "brief": "Bamboo", "doneWhen": "", "size": "M",
                     "stage": "ready", "createdAt": "2026-10-30T10:00:00.000Z", "createdBy": "robin-h", "updatedAt": "2026-10-30T10:00:00.000Z",
                     "waitsFor": [], "activity": [["at": "2026-10-30T10:00:00.000Z", "by": "robin-h", "kind": "created", "text": "Made it"]]],
                    ["id": "card-2", "binderId": "binder-g", "title": "Dig", "brief": "", "doneWhen": "Beds dug", "size": "S",
                     "stage": "shipping", "createdAt": "2026-10-30T10:00:00.000Z", "createdBy": "robin-h", "updatedAt": "2026-10-30T10:00:00.000Z",
                     "waitsFor": ["card-1"], "activity": [], "meantFor": "agent-2"],
                    ["id": "card-3", "binderId": "binder-other", "title": "Elsewhere", "stage": "ready", "waitsFor": [], "activity": []],
                ],
            ],
        ]
        return HubCards.Board(state: try! JSONSerialization.data(withJSONObject: state))!
    }

    private func entry(_ version: Int, _ change: [String: Any]) -> HubCards.Entry {
        HubCards.Entry(version: version, change: try! JSONDecoder().decode(JSONValue.self, from: JSONSerialization.data(withJSONObject: change)))
    }

    func testTheBoardComesFromTheHubsState() {
        let board = board()
        XCTAssertEqual(board.version, 7)
        XCTAssertEqual(board.cards(in: "binder-g").map(\.id).sorted(), ["card-1", "card-2"])
        XCTAssertEqual(board.cards["card-2"]?.stage, "live", "shipping reads as live")
        XCTAssertEqual(board.cards["card-2"]?.column, .done)
        XCTAssertEqual(board.cards["card-2"]?.waitsFor, ["card-1"])
        XCTAssertEqual(board.cards["card-1"]?.activity.first?.kind, "created")
        XCTAssertEqual(board.name(of: "agent-1"), "Claude")
        XCTAssertEqual(board.name(of: "robin-h"), "robin-h")
        XCTAssertNil(HubCards.Board(state: Data("{\"nope\":1}".utf8)))
    }

    func testTheFirstClaimAppliedGetsTheCardAndTheSecondDoesNothing() {
        var board = board()
        let touched = board.apply([
            entry(8, ["type": "card.claim", "id": "card-1", "agentId": "agent-1", "at": "2026-10-30T10:01:00.000Z"]),
            entry(9, ["type": "card.claim", "id": "card-1", "agentId": "agent-2", "at": "2026-10-30T10:01:00.001Z"]),
        ])
        XCTAssertEqual(touched, ["card-1"])
        let card = board.cards["card-1"]!
        XCTAssertEqual(card.agentId, "agent-1")
        XCTAssertEqual(card.stage, "working")
        XCTAssertEqual(card.column, .inProgress)
        XCTAssertEqual(card.activity.last, HubCards.Activity(at: "2026-10-30T10:01:00.000Z", by: "agent-1", kind: "claimed", text: "Claude took it"))
        XCTAssertEqual(card.activity.count, 2, "the refused claim writes nothing")
        XCTAssertEqual(board.version, 9)
    }

    func testAClaimOnACardMeantForAnotherAgentOrNotReadyDoesNothing() {
        var board = board()
        board.apply([entry(8, ["type": "card.update", "id": "card-2", "fields": ["stage": "ready"]]),
                     entry(9, ["type": "card.claim", "id": "card-2", "agentId": "agent-1", "at": "2026-10-30T10:01:00.000Z"])])
        XCTAssertNil(board.cards["card-2"]?.agentId, "meant for agent-2")
        board.apply([entry(10, ["type": "card.update", "id": "card-1", "fields": ["stage": "proposed"]]),
                     entry(11, ["type": "card.claim", "id": "card-1", "agentId": "agent-1", "at": "2026-10-30T10:01:00.000Z"])])
        XCTAssertNil(board.cards["card-1"]?.agentId, "proposed isn't ready")
    }

    func testAnUpdateMergesClearsWithNullAndAddsItsLine() {
        var board = board()
        board.apply([entry(8, ["type": "card.claim", "id": "card-1", "agentId": "agent-1", "at": "2026-10-30T10:01:00.000Z"]),
                     entry(9, ["type": "card.update", "id": "card-1", "fields": ["stage": "ready", "agentId": NSNull(), "title": "Buy long stakes"],
                               "activity": ["at": "2026-10-30T10:02:00.000Z", "by": "robin-h", "kind": "moved", "text": "Moved it to Ready"]])])
        let card = board.cards["card-1"]!
        XCTAssertNil(card.agentId)
        XCTAssertEqual(card.title, "Buy long stakes")
        XCTAssertEqual(card.column, .ready)
        XCTAssertEqual(card.activity.last?.text, "Moved it to Ready")
        XCTAssertEqual(card.updatedAt, HubCards.date("2026-10-30T10:02:00.000Z"))
    }

    func testEntriesAlreadyAppliedAreLeftAndReleasesActivityAndDeletesApply() {
        var board = board()
        board.apply([entry(8, ["type": "card.claim", "id": "card-1", "agentId": "agent-1", "at": "2026-10-30T10:01:00.000Z"])])
        // Sent again after a reconnect: applied once.
        XCTAssertTrue(board.apply([entry(8, ["type": "card.claim", "id": "card-1", "agentId": "agent-1", "at": "2026-10-30T10:01:00.000Z"])]).isEmpty)
        board.apply([entry(9, ["type": "card.release", "id": "card-1", "agentId": "agent-2", "at": "2026-10-30T10:02:00.000Z", "why": "Not mine"])])
        XCTAssertEqual(board.cards["card-1"]?.agentId, "agent-1", "only its holder lets it go")
        board.apply([entry(10, ["type": "card.release", "id": "card-1", "agentId": "agent-1", "at": "2026-10-30T10:02:00.000Z", "why": "Stuck"]),
                     entry(11, ["type": "card.activity", "id": "card-1", "activity": ["at": "2026-10-30T10:03:00.000Z", "by": "sam-k", "kind": "comment", "text": "Try again"]])])
        XCTAssertEqual(board.cards["card-1"]?.column, .ready)
        XCTAssertEqual(board.cards["card-1"]?.activity.suffix(2).map(\.kind), ["released", "comment"])
        XCTAssertEqual(board.apply([entry(12, ["type": "card.delete", "id": "card-2"]), entry(13, ["type": "note.put", "note": ["id": "n"]])]), ["card-2"])
        XCTAssertNil(board.cards["card-2"])
    }

    func testARevokedAgentsCardsGoBackToTheBoard() {
        var board = board()
        board.apply([entry(8, ["type": "card.claim", "id": "card-1", "agentId": "agent-1", "at": "2026-10-30T10:01:00.000Z"]),
                     entry(9, ["type": "agent.revoke", "id": "agent-1"])])
        XCTAssertNil(board.cards["card-1"]?.agentId)
        XCTAssertEqual(board.cards["card-1"]?.column, .ready)
        XCTAssertNil(board.agentID(named: "Claude"), "a revoked agent isn't anyone's")
    }

    func testAnAgentIsFoundByNamePreferringYours() {
        var board = board()
        board.apply([entry(8, ["type": "agent.put", "agent": ["id": "agent-3", "name": "Claude", "owner": "sam-k"]])])
        XCTAssertEqual(board.agentID(named: "claude", owner: "robin-h"), "agent-1")
        XCTAssertEqual(board.agentID(named: "Claude", owner: "sam-k"), "agent-3")
        XCTAssertNil(board.agentID(named: "Pennant"))
    }

    func testTheLiveFeedsEntriesAreRead() {
        let live = Data(#"{"type":"entries","entries":[{"version":3,"id":"x","client":"agent:a","at":"t","change":{"type":"card.delete","id":"c"}}]}"#.utf8)
        XCTAssertEqual(HubCards.entries(fromLive: live)?.map(\.version), [3])
        XCTAssertNil(HubCards.entries(fromLive: Data(#"{"type":"presence","presence":{}}"#.utf8)))
    }

    func testStagesAndKindsReadAsThisMacsBoard() {
        XCTAssertEqual(["proposed", "ready", "working", "blocked", "review", "live", "shipping"].map(HubCards.column),
                       [.backlog, .ready, .inProgress, .blocked, .review, .done, .done])
        for column in BoardColumn.allCases { XCTAssertEqual(HubCards.column(HubLink.stage(column)), column) }
        XCTAssertEqual(HubCards.localKind("step"), "progress")
        XCTAssertEqual(HubCards.localKind("question"), "question")
        XCTAssertEqual(HubCards.hubKind("approval"), "question")
        XCTAssertEqual(HubCards.hubKind("assigned"), "moved")
        XCTAssertNil(HubCards.hubKind("woke"))
        XCTAssertNil(HubCards.hubKind("context"))
    }

    func testACardMadeOnTheHubHasTheSameIDOnEveryMac() {
        let mac = UUID()
        XCTAssertEqual(HubCards.localID(HubLink.hubID(mac)), mac)
        XCTAssertEqual(HubCards.localID("card-4aaf2cdd"), HubCards.localID("card-4aaf2cdd"))
        XCTAssertNotEqual(HubCards.localID("card-4aaf2cdd"), HubCards.localID("card-4aaf2cde"))
    }

    func testDoneWhenGoesAfterTheBriefAndComesOffAgain() {
        let details = HubCards.details(brief: "Bamboo", doneWhen: "Stakes in the shed")
        XCTAssertEqual(details, "Bamboo\n\n**Done when:** Stakes in the shed")
        XCTAssertEqual(HubCards.brief(details: details, doneWhen: "Stakes in the shed"), "Bamboo")
        XCTAssertEqual(HubCards.brief(details: "Bamboo, 2 m", doneWhen: "Stakes in the shed"), "Bamboo, 2 m")
        XCTAssertEqual(HubCards.details(brief: "Bamboo", doneWhen: ""), "Bamboo")
    }

    func testWhatGoesUp() throws {
        func object(_ value: JSONValue) throws -> [String: Any] {
            try JSONSerialization.jsonObject(with: JSONEncoder.hub.encode(value)) as! [String: Any]
        }
        let claim = try object(HubCards.claim("card-1", agent: "agent-1", at: "2026-10-30T10:01:00.000Z"))
        XCTAssertEqual(claim["type"] as? String, "card.claim")
        XCTAssertEqual(claim["agentId"] as? String, "agent-1")

        let move = try object(HubCards.update("card-1", fields: HubCards.moveFields(to: .ready),
                                               activity: .init(at: "t", by: "robin-h", kind: "moved", text: "Moved it to Ready")))
        let fields = move["fields"] as? [String: Any]
        XCTAssertEqual(fields?["stage"] as? String, "ready")
        XCTAssertTrue(fields?["agentId"] is NSNull, "back on the board, out of the agent's hands")
        XCTAssertTrue(fields?["needsYou"] is NSNull)
        XCTAssertEqual((move["activity"] as? [String: Any])?["kind"] as? String, "moved")
        XCTAssertNil(HubCards.moveFields(to: .review)["agentId"], "in review its agent keeps it")

        let day = Date(timeIntervalSince1970: 1_793_000_000)
        let local = HubLink.LocalCard(id: UUID(), title: "Paint", details: "Green", column: .backlog, createdAt: day, updatedAt: day,
                                      waitsFor: ["card-1", "card-gone"], note: UUID())
        let put = try object(XCTUnwrap(HubCards.put(local, binder: "binder-g", person: "robin-h", known: ["card-1"])))
        let card = put["card"] as? [String: Any]
        XCTAssertEqual(put["type"] as? String, "card.put")
        XCTAssertEqual(card?["stage"] as? String, "proposed")
        XCTAssertEqual(card?["binderId"] as? String, "binder-g")
        XCTAssertEqual(card?["waitsFor"] as? [String], ["card-1"])
        XCTAssertEqual(card?["noteId"] as? String, HubLink.hubID(local.note!))
        XCTAssertEqual(card?["createdBy"] as? String, "robin-h")

        let body = try JSONSerialization.jsonObject(with: HubCards.body(client: "mac-abc123", changes: [.init(id: "x", change: HubCards.delete("card-1"))])) as? [String: Any]
        XCTAssertEqual(body?["client"] as? String, "mac-abc123")
        XCTAssertEqual(HubCards.versions(fromChanges: Data(#"{"versions":[4,5],"version":5}"#.utf8)), [4, 5])
    }

    func testAChangeKeptUntilTheHubHasItComesBackTheSame() throws {
        let put = HubCards.Outgoing(id: "card-abc", change: HubCards.delete("card-1"))
        XCTAssertEqual(HubCards.Outgoing(json: put.json), put)
        XCTAssertNil(HubCards.Outgoing(json: ""))
        XCTAssertNil(HubCards.Outgoing(json: "{"))
    }

    func testACardPutBackIsTheHubsAsItWasByAChangeOfItsOwn() throws {
        var board = HubCards.Board()
        let line = HubCards.Activity(at: "2026-10-30T10:01:00.000Z", by: "agent-1", kind: "claimed", text: "Claude took it")
        _ = board.apply([HubCards.Entry(version: 1, change: .object(["type": .string("card.put"), "card": .object([
            "id": .string("card-hub1"), "binderId": .string("binder-g"), "title": .string("Gate"), "stage": .string("working"),
            "agentId": .string("agent-1"), "activity": .array([line.json])])]))])
        let was = try XCTUnwrap(board.cards["card-hub1"])
        _ = board.apply([HubCards.Entry(version: 2, change: HubCards.delete("card-hub1"))])
        XCTAssertNil(board.cards["card-hub1"])

        let back = HubCards.putBack(was)
        XCTAssertFalse(back.id == "card-card-hub1", "not the first put's id, which the hub has had already")
        XCTAssertNotEqual(back.id, HubCards.putBack(was).id, "each one a change of its own")
        _ = board.apply([HubCards.Entry(version: 3, change: back.change)])
        XCTAssertEqual(board.cards["card-hub1"], was, "the same id, stage, agent and lines")
        XCTAssertEqual(board.cards["card-hub1"]?.activity.map { $0.key(card: "card-hub1") }, [line.key(card: "card-hub1")])
    }

    func testALinesKeyIsTheSameWhereverItsRead() {
        let line = HubCards.Activity(at: "2026-10-30T10:01:00.000Z", by: "robin-h", kind: "comment", text: "Hi")
        XCTAssertEqual(line.key(card: "card-1"), HubCards.Activity(at: line.at, by: "robin-h", kind: "comment", text: "Hi").key(card: "card-1"))
        XCTAssertNotEqual(line.key(card: "card-1"), line.key(card: "card-2"))
        XCTAssertNotNil(line.date)
    }
}
