import Foundation
import SwiftData
import BindersKit

/// A linked binder's board through the hub (HubBoard), in a throwaway folder (BINDERS_DATA_DIR), with a stand-in hub that
/// keeps a log as binders-server does, applies it (`HubCards.Board`), answers /api/state, feeds /api/live, and takes from a
/// person only what the hub does: a hub agent's claim shows on the board, as do a card made on the hub, a question and a
/// deletion; a move, a comment, an answer, an approval of what's in review, an edit, a new card and a deletion made here
/// reach the hub, each line once on both sides; a claim made here is refused here, as the hub takes none from a person's
/// app; a new card the hub didn't get is kept and goes again; a dropped feed catches up; an unlinked binder stops
/// following.
///
/// With BINDERS_TEST_HUB (a hub's address), BINDERS_TEST_HUB_TOKEN (a bnp_ token there) and BINDERS_TEST_HUB_AGENT_TOKEN
/// (an agent's bnd_ token in the same Binder), it links a binder to a new project on that hub, has the agent claim its card
/// over the hub's /mcp, and waits for the board here to show it; then moves and comments on it here and reads the hub's
/// state back, as the web app does.
///
///     BINDERS_DATA_DIR=$(mktemp -d) Binders --selftest-hub-board
extension SelfTest {
    @MainActor
    static func hubBoardSelfTest() async -> Int32 {
        guard AppPaths.isDemo else {
            print("ERROR: set BINDERS_DATA_DIR to an empty folder; this test makes binders and links them to a hub")
            return 1
        }
        var failures = 0
        func check(_ condition: Bool, _ label: String) {
            print("\(condition ? "PASS" : "FAIL"): \(label)")
            if !condition { failures += 1 }
        }
        let kept = Keychain.read(HubAccount.tokenKey)
        defer { Keychain.write(kept ?? "", for: HubAccount.tokenKey) }
        Keychain.write("", for: HubAccount.tokenKey)

        let controller = DictationController()
        let store = Store.shared
        let account = HubAccount.shared
        let links = HubLinks.shared
        let hubBoard = HubBoard.shared
        let board = controller.board
        account.openPage = { _ in }
        hubBoard.retry = .milliseconds(100)

        // MARK: The stand-in hub: its log, the state it makes, and its live feed.
        var log: [HubCards.Entry] = []
        var hub = HubCards.Board()
        var projects: [[String: Any]] = [["id": "binder-old", "name": "Roadmap"]]
        var kept_: Set<String> = []
        var live: AsyncThrowingStream<Data, Error>.Continuation?
        var liveOpened = 0
        /// POST /api/changes fails, as a hub out of reach does (its state still reads).
        var unreachable = false
        func value(_ object: Any) -> JSONValue { try! JSONDecoder().decode(JSONValue.self, from: JSONSerialization.data(withJSONObject: object)) }
        func json(_ value: JSONValue) -> Any { try! JSONSerialization.jsonObject(with: JSONEncoder().encode(value), options: .fragmentsAllowed) }
        func message(_ entries: [HubCards.Entry]) -> Data {
            let list = entries.map { ["version": $0.version, "id": "e\($0.version)", "client": "x", "at": "t", "change": json($0.change)] as [String: Any] }
            return try! JSONSerialization.data(withJSONObject: ["type": "entries", "entries": list])
        }
        /// A change in the log, as the hub's own or an agent's: applied, and sent to whoever's listening.
        @discardableResult
        func append(_ change: [String: Any]) -> Int {
            let entry = HubCards.Entry(version: log.count + 1, change: value(change))
            log.append(entry)
            hub.apply([entry])
            if case .object(let body) = entry.change, body["type"] == .string("binder.put"), case .object(let project)? = body["binder"] {
                projects.append(["id": json(project["id"] ?? .null), "name": json(project["name"] ?? .null)])
            }
            live?.yield(message([entry]))
            return entry.version
        }
        append(["type": "agent.put", "agent": ["id": "agent-claude", "name": "Claude", "owner": "robin-h", "provider": "claude"]])
        append(["type": "agent.put", "agent": ["id": "agent-codex", "name": "Codex", "owner": "sam-k", "provider": "openai"]])
        append(["type": "agent.put", "agent": ["id": "agent-pennant", "name": "Pennant", "owner": "robin-h", "provider": "other"]])

        let fromPeople: Set<String> = ["binder.put", "folder.put", "note.put", "card.put", "card.update", "card.activity", "card.delete"]
        var posted: [String] = []
        account.send = { request in
            let path = request.url?.path ?? ""
            let method = request.httpMethod ?? "GET"
            func answer(_ status: Int, _ object: Any) -> (Data, URLResponse) {
                (try! JSONSerialization.data(withJSONObject: object), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
            }
            guard request.value(forHTTPHeaderField: "Authorization") == "Bearer bnp_robin00001" else { return answer(401, ["error": "Sign in again."]) }
            switch (method, path) {
            case ("GET", "/api/me"):
                return answer(200, ["user": ["login": "robin-h", "name": "Robin Hale"], "space": "team", "spaces": [["id": "team", "name": "Team", "role": "owner"]]])
            case ("GET", "/api/state"):
                let cards = hub.cards.values.map { json(.object($0.fields)) }
                let agents = [["id": "agent-claude", "name": "Claude", "owner": "robin-h"], ["id": "agent-codex", "name": "Codex", "owner": "sam-k"],
                              ["id": "agent-pennant", "name": "Pennant", "owner": "robin-h"]]
                return answer(200, ["version": log.count, "state": ["binders": projects, "folders": [], "notes": [], "cards": cards, "agents": agents]])
            case ("POST", "/api/changes"):
                if unreachable { throw URLError(.notConnectedToInternet) }
                guard let body = request.httpBody.flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }),
                      let client = body["client"] as? String, let changes = body["changes"] as? [[String: Any]] else { return answer(400, ["error": "?"]) }
                // A person sends only what the web app may, as binders-server's hub.ts: a card.claim isn't one of them.
                for outgoing in changes {
                    let type = (outgoing["change"] as? [String: Any])?["type"] as? String ?? ""
                    if !fromPeople.contains(type) {
                        return answer(422, ["error": "That can’t be sent from the web app (\(type))."])
                    }
                }
                var versions: [Int] = []
                for outgoing in changes {
                    guard let id = outgoing["id"] as? String, let change = outgoing["change"] as? [String: Any], let type = change["type"] as? String else { continue }
                    guard kept_.insert("\(client):\(id)").inserted else {
                        versions.append(0)
                        continue
                    }
                    posted.append(type)
                    versions.append(append(change))
                }
                return answer(200, ["versions": versions, "version": log.count])
            default:
                return answer(404, ["error": "Not here."])
            }
        }
        hubBoard.openLive = { request in
            liveOpened += 1
            let since = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "since" }?.value.flatMap(Int.init) ?? 0
            return AsyncThrowingStream { continuation in
                live = continuation
                let missed = log.filter { $0.version > since }
                if !missed.isEmpty { continuation.yield(message(missed)) }
            }
        }

        func until(_ seconds: Double = 3, _ condition: () -> Bool) async -> Bool {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end {
                if condition() { return true }
                try? await Task.sleep(for: .milliseconds(25))
            }
            return condition()
        }
        /// Changes sent from here, answered.
        func sent() async -> Bool { await until { hubBoard.sending == 0 } }
        func timeline(_ card: TaskCard) -> [TaskEvent] { board.timeline(card.id) }

        // MARK: A linked binder.
        let garden = BinderRecord(name: "Garden", colorIndex: 2)
        store.insert(garden)
        let stakes = TaskCard(title: "Buy stakes", binderID: garden.id, column: .ready)
        stakes.details = "Bamboo, 2 m."
        let seeds = TaskCard(title: "Order seeds", binderID: garden.id, column: .ready)
        for card in [stakes, seeds] { store.insert(card) }
        store.insert(TaskEvent(taskID: stakes.id, kind: .created, author: .you))
        store.insert(TaskEvent(taskID: stakes.id, kind: .comment, author: .you, text: "The long ones"))
        store.save()
        account.signIn(to: "hub.example.com")
        await account.finish(URL(string: "binders://auth?token=bnp_robin00001&state=\(account.pending?.state ?? "")")!)
        let linked = await links.link(garden, space: HubLink.Space(id: "team", name: "Team"), to: nil)
        let project = HubLinks.place(of: garden)?.binder ?? ""
        check(linked && hubBoard.covers(stakes), "Garden is linked, and its board follows the hub: \(links.problems[garden.id] ?? "")")
        check(await until { hubBoard.live.contains("team") }, "the hub's Binder is followed live")
        let stakesID = HubLink.hubID(stakes.id)
        check(stakes.hubCard == stakesID && timeline(stakes).filter { $0.kind == .comment }.count == 1 && timeline(stakes).filter { $0.kind == .created }.count == 1,
              "a card that went up keeps its lines once: \(timeline(stakes).map(\.kindRaw))")

        // MARK: A hub agent claims a card: the board here shows it.
        let claimedAt = Date()
        append(["type": "card.claim", "id": stakesID, "agentId": "agent-claude", "at": HubCards.iso(Date())])
        check(await until(2) { stakes.column == .inProgress && stakes.assignee == "Claude" && stakes.assigneeIsAgent },
              "Claude claims Buy stakes on the hub, and it's In progress with Claude here in \(String(format: "%.2f", Date().timeIntervalSince(claimedAt)))s")
        check(timeline(stakes).filter { $0.kind == .claimed }.map(\.text) == ["Claude took it"] && stakes.claimExpiresAt == nil,
              "with the hub's line, once, and no lease here: the hub keeps it")

        // MARK: A card made on the hub, then a question on it.
        append(["type": "card.put", "card": ["id": "card-hub1", "binderId": project, "title": "Fix the gate", "brief": "It sticks.", "doneWhen": "It swings",
                                             "size": "S", "stage": "ready", "createdAt": HubCards.iso(Date()), "createdBy": "sam-k", "updatedAt": HubCards.iso(Date()),
                                             "waitsFor": [stakesID], "activity": [["at": HubCards.iso(Date()), "by": "sam-k", "kind": "created", "text": "Made it"]]]])
        let gateID = HubCards.localID("card-hub1")
        check(await until { board.card(gateID) != nil }, "a card made on the hub shows here")
        let gate = board.card(gateID)
        check(gate?.binderID == garden.id && gate?.details == "It sticks.\n\n**Done when:** It swings" && gate?.waitsFor == [stakes.id.uuidString]
                && gate?.createdBy == "sam-k" && gate?.hubCard == "card-hub1", "in Garden, with its brief, what done looks like, what it waits for and who made it")
        append(["type": "card.claim", "id": "card-hub1", "agentId": "agent-codex", "at": HubCards.iso(Date())])
        append(["type": "card.update", "id": "card-hub1", "fields": ["needsYou": "Paint it too?", "stage": "blocked"],
                "activity": ["at": HubCards.iso(Date()), "by": "agent-codex", "kind": "question", "text": "Paint it too?"]])
        check(await until { gate?.column == .blocked }, "Codex asks on the hub, and the card waits on you here")
        check(gate.map { BoardRules.waitingQuestion(in: timeline($0).map { (kind: $0.kindRaw, to: $0.toColumn ?? "") }) != nil } == true,
              "with its question waiting for an answer")

        // MARK: Answered here: on the hub it's back at work, the question answered.
        if let gate { board.comment(gate, text: "Yes, green.", by: .you) }
        check(await sent() && hub.cards["card-hub1"]?.stage == "working" && hub.cards["card-hub1"]?.needsYou == nil && hub.cards["card-hub1"]?.agentId == "agent-codex",
              "an answer here puts it back to work on the hub with Codex: \(hub.cards["card-hub1"]?.stage ?? "")")
        check(hub.cards["card-hub1"]?.activity.last.map { [$0.kind, $0.by, $0.text] } == ["answer", "robin-h", "Yes, green."],
              "with the answer, by robin-h")
        check(gate.map { timeline($0).filter { $0.kind == .answer }.count } == 1 && gate?.column == .inProgress, "and the answer here once, after the hub's echo")

        // MARK: Moved and commented on here: the hub has it, each line once.
        try? board.move(stakes, to: .ready, by: .you)
        check(await sent() && hub.cards[stakesID]?.stage == "ready" && hub.cards[stakesID]?.agentId == nil,
              "moving Buy stakes back to Ready here takes it out of Claude's hands on the hub")
        check(hub.cards[stakesID]?.activity.last?.kind == "moved" && hub.cards[stakesID]?.activity.last?.by == "robin-h", "with a moved line by robin-h")
        board.comment(stakes, text: "Get twenty", by: .you)
        check(await sent() && hub.cards[stakesID]?.activity.last.map { [$0.kind, $0.text] } == ["comment", "Get twenty"], "a comment here is on the hub's card")
        _ = await until(0.3) { false }
        check(timeline(stakes).filter { $0.kind == .moved }.count == 1 && timeline(stakes).filter { $0.text == "Get twenty" }.count == 1,
              "and each line once here after the hub's echo: \(timeline(stakes).map(\.kindRaw))")

        // MARK: Approved: what's in review goes to Done.
        append(["type": "card.update", "id": "card-hub1", "fields": ["stage": "review", "doing": NSNull()],
                "activity": ["at": HubCards.iso(Date()), "by": "agent-codex", "kind": "completed", "text": "Painted green"]])
        check(await until { gate?.column == .review }, "Codex hands it over for review")
        if let gate { try? board.move(gate, to: .done, by: .you) }
        check(await sent() && hub.cards["card-hub1"]?.stage == "live" && hub.cards["card-hub1"]?.agentId == "agent-codex",
              "approved here, it's live on the hub, still Codex's work")

        // MARK: Claims: the hub takes none from this Mac.
        let before = posted.count
        for actor in [BoardActor.you, BoardActor(name: "Claude", kind: .agent), BoardActor(name: "Pennant", kind: .agent)] {
            var claimRefused = false
            do { try board.claim(seeds, by: actor) } catch { claimRefused = error.localizedDescription.contains("claim_task on the hub's /mcp") }
            check(claimRefused, "a claim here by \(actor.name) is refused, saying cards are taken on the hub")
        }
        _ = await sent()
        check(posted.count == before && seeds.column == .ready && seeds.assignee == nil && !timeline(seeds).contains { $0.kind == .claimed },
              "nothing goes to the hub, and the card is in Ready with no one, as the hub has it")
        append(["type": "card.claim", "id": HubLink.hubID(seeds.id), "agentId": "agent-pennant", "at": HubCards.iso(Date())])
        check(await until { seeds.assignee == "Pennant" && seeds.column == .inProgress }, "Pennant takes it on the hub, and it's Pennant's here")

        // MARK: Edited, made and deleted here.
        board.edit(seeds, title: "Order seeds and bulbs", by: .you)
        check(await sent() && hub.cards[HubLink.hubID(seeds.id)]?.title == "Order seeds and bulbs", "a new title here is the hub's")
        try? board.setWaits(seeds, to: [stakes.id], by: .you)
        check(await sent() && hub.cards[HubLink.hubID(seeds.id)]?.waitsFor == [stakesID], "what a card waits for here is what it waits for on the hub")
        let elsewhere = BinderRecord(name: "Elsewhere", colorIndex: 1)
        store.insert(elsewhere)
        var moveRefused = false
        do { try board.moveBinder(stakes, to: elsewhere, by: .you) } catch { moveRefused = true }
        check(moveRefused && stakes.binderID == garden.id, "a card doesn't move off a linked binder's board, where the hub would put it back")
        let shed = board.create(title: "Clear the shed", details: "Before winter", binderID: garden.id, column: .ready, by: .you)
        check(await sent() && hub.cards[HubLink.hubID(shed.id)]?.title == "Clear the shed" && hub.cards[HubLink.hubID(shed.id)]?.binderId == project,
              "a card made here goes up to the project")
        _ = await until(0.3) { false }
        check(timeline(shed).filter { $0.kind == .created }.count == 1, "with its created line once here")
        board.delete(shed)
        check(await sent() && hub.cards[HubLink.hubID(shed.id)] == nil, "a card deleted here goes from the hub")

        // MARK: A new card the hub didn't get: kept, and sent again.
        unreachable = true
        let fence = board.create(title: "Mend the fence", details: "", binderID: garden.id, column: .ready, by: .you)
        board.comment(fence, text: "The east side", by: .you)
        _ = await sent()
        _ = await until(0.3) { false }
        check(board.card(fence.id) != nil && fence.hubCard.isEmpty && hub.cards[HubLink.hubID(fence.id)] == nil,
              "a card made while the hub is out of reach stays here, not marked as the hub's: \(timeline(fence).last?.text ?? "")")
        check(timeline(fence).contains { $0.text == "The east side" }, "with its comment")
        unreachable = false
        let reopened = liveOpened
        live?.finish(throwing: URLError(.networkConnectionLost))
        live = nil
        check(await until { liveOpened > reopened && hub.cards[HubLink.hubID(fence.id)] != nil && fence.hubCard == HubLink.hubID(fence.id) },
              "connected again, it goes up, and is the hub's")
        check(hub.cards[HubLink.hubID(fence.id)]?.activity.contains { $0.text == "The east side" } == true
                && hub.cards[HubLink.hubID(fence.id)]?.activity.contains { $0.text.hasPrefix("Not done on the hub") } == false,
              "with its comment, and not the line saying it didn't get there")

        // MARK: Deleted on the hub.
        append(["type": "card.delete", "id": "card-hub1"])
        check(await until { board.card(gateID) == nil }, "a card deleted on the hub goes from here")

        // MARK: The feed drops: what happened meanwhile arrives.
        let opened = liveOpened
        live?.finish(throwing: URLError(.networkConnectionLost))
        live = nil
        append(["type": "card.update", "id": stakesID, "fields": ["title": "Buy long stakes"]])
        check(await until { liveOpened > opened && stakes.title == "Buy long stakes" }, "after a drop the feed opens again and catches up")

        // MARK: Unlinked, it stops following.
        links.unlink(garden)
        check(!hubBoard.covers(stakes) && hubBoard.live.isEmpty, "unlinked, Garden's board is its own again")
        append(["type": "card.update", "id": stakesID, "fields": ["title": "Not here"]])
        _ = await until(0.3) { false }
        check(stakes.title == "Buy long stakes", "and what the hub does no longer reaches it")

        // MARK: A real hub, when one is given.
        let environment = ProcessInfo.processInfo.environment
        if let address = environment["BINDERS_TEST_HUB"], let token = environment["BINDERS_TEST_HUB_TOKEN"], let agent = environment["BINDERS_TEST_HUB_AGENT_TOKEN"] {
            failures += await realHubBoardChecks(hub: address, token: token, agentToken: agent, board: board)
        } else {
            print("SKIP: a real hub (set BINDERS_TEST_HUB, BINDERS_TEST_HUB_TOKEN and BINDERS_TEST_HUB_AGENT_TOKEN)")
        }

        print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
        return failures == 0 ? 0 : 1
    }

    /// Links a binder to a new project on a running hub, has an agent claim its card through the hub's /mcp, and waits for
    /// the board here to show it; then moves it and comments here, and reads the hub's state back.
    @MainActor
    private static func realHubBoardChecks(hub: String, token: String, agentToken: String, board: BoardService) async -> Int {
        var failed = 0
        func check(_ condition: Bool, _ label: String) {
            print("\(condition ? "PASS" : "FAIL"): real hub: \(label)")
            if !condition { failed += 1 }
        }
        let account = HubAccount.shared
        let links = HubLinks.shared
        let hubBoard = HubBoard.shared
        let store = Store.shared
        account.send = { try await URLSession.shared.data(for: $0) }
        hubBoard.openLive = HubBoard.webSocket
        account.signIn(to: hub)
        await account.finish(URL(string: "binders://auth?token=\(token)&state=\(account.pending?.state ?? "")")!)
        check(account.isSignedIn, "signed in as \(account.person?.login ?? account.problem ?? "no one")")

        let stamp = Int(Date().timeIntervalSince1970)
        let binder = BinderRecord(name: "Board from a Mac \(stamp)", colorIndex: 5)
        store.insert(binder)
        let card = TaskCard(title: "Claim me \(stamp)", binderID: binder.id, column: .ready)
        store.insert(card)
        store.save()
        guard let found = try? await links.spaces(), let space = found.spaces.first(where: { $0.id == found.current }) ?? found.spaces.first else {
            check(false, "the hub says which Binders you're in")
            return failed
        }
        let linked = await links.link(binder, space: space, to: nil)
        check(linked, "linked to a new project in \(space.name): \(links.done[binder.id] ?? links.problems[binder.id] ?? "")")
        func until(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end {
                if condition() { return true }
                try? await Task.sleep(for: .milliseconds(50))
            }
            return condition()
        }
        check(await until(5) { hubBoard.live.contains(space.id) }, "following the hub live: \(hubBoard.problems[space.id] ?? "")")

        // The agent claims it over MCP, as a runner's agent does.
        var request = URLRequest(url: URL(string: hub)!.appendingPathComponent("mcp"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(agentToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        let call: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/call",
                                   "params": ["name": "claim_task", "arguments": ["id": HubLink.hubID(card.id)]]]
        request.httpBody = try? JSONSerialization.data(withJSONObject: call)
        let asked = Date()
        let answer = try? await URLSession.shared.data(for: request)
        let said = answer.flatMap { String(data: $0.0, encoding: .utf8) } ?? "no answer"
        check(!said.contains("\"isError\":true"), "the agent claimed the card over /mcp: \(said.prefix(200))")
        let shown = await until(5) { card.column == .inProgress && card.assigneeIsAgent }
        check(shown && Date().timeIntervalSince(asked) < 3,
              "the board here shows \(card.assignee ?? "no one") holding it in \(String(format: "%.2f", Date().timeIntervalSince(asked)))s")

        // Moved and commented on here: the hub's state has them.
        try? board.move(card, to: .ready, by: .you)
        board.comment(card, text: "Commented on a Mac at \(stamp)", by: .you)
        _ = await until(5) { hubBoard.sending == 0 }
        guard let place = HubLinks.place(of: binder), var read = account.authorized("api/state") else { return failed + 1 }
        read.setValue(place.space, forHTTPHeaderField: "x-binders-space")
        let state = (try? await URLSession.shared.data(for: read).0).flatMap { HubCards.Board(state: $0) }
        let there = state?.cards[HubLink.hubID(card.id)]
        check(there?.stage == "ready" && there?.agentId == nil, "on the hub it's back in Ready, out of the agent's hands: \(there?.stage ?? "?")")
        check(there?.activity.contains { $0.kind == "comment" && $0.text == "Commented on a Mac at \(stamp)" } == true, "with the comment made here")
        print("NOTE: real hub: open \(hub) and the project “\(binder.name)” in \(space.name) to see it in the web app")
        return failed
    }
}
