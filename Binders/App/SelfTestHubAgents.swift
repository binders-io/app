import Foundation
import SwiftData
import BindersKit

/// Agents and binders linked to a hub, in a throwaway folder (BINDERS_DATA_DIR). This Mac's MCP server leaves a linked
/// binder's notes and cards out for an agent and refuses to change them, saying where they are (the hub's /mcp, and the
/// hub's id), while its meetings stay, the other binders are as before and the iPhone (you) reads everything; the app
/// refuses an agent's write there too, and Binders wakes no agent of yours for its cards. Setting a tool up for the hub
/// (HubAgentSetup), with a stand-in hub: an agent of its own there taking work from the linked projects, the hub's server
/// in the tool's configuration with its token, set up again with the old agent revoked, a newly linked project added to
/// it, and Remove taking both away.
///
/// With BINDERS_TEST_HUB (a hub's address) and BINDERS_TEST_HUB_TOKEN (a bnp_ token there), it links a binder with a
/// ready card to a new project on that hub, sets a tool up for it, and has that agent claim and complete the card through
/// the hub's /mcp, with its own token. No tool's configuration is changed.
///
///     BINDERS_DATA_DIR=$(mktemp -d) Binders --selftest-hub-agents
extension SelfTest {
    @MainActor
    static func hubAgentsSelfTest() async -> Int32 {
        guard AppPaths.isDemo else {
            print("ERROR: set BINDERS_DATA_DIR to an empty folder; this test makes binders and links them to a hub")
            return 1
        }
        var failures = 0
        func check(_ condition: Bool, _ label: String) {
            print("\(condition ? "PASS" : "FAIL"): \(label)")
            if !condition { failures += 1 }
        }
        // The Keychain is this Mac's own: whatever token was there is put back at the end.
        let kept = Keychain.read(HubAccount.tokenKey)
        defer { Keychain.write(kept ?? "", for: HubAccount.tokenKey) }
        Keychain.write("", for: HubAccount.tokenKey)

        let controller = DictationController()
        let store = Store.shared
        let account = HubAccount.shared
        let setup = HubAgentSetup.shared
        account.openPage = { _ in }

        // A stand-in hub: its agents, and every request.
        var agents: [String: [String: Any]] = [:]
        var asked: [(method: String, path: String, space: String, body: [String: Any])] = []
        var issued = 0
        account.send = { request in
            let path = request.url?.path ?? ""
            let method = request.httpMethod ?? "GET"
            let space = request.value(forHTTPHeaderField: "x-binders-space") ?? ""
            let body = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            asked.append((method, path, space, body))
            func answer(_ status: Int, _ json: Any) -> (Data, URLResponse) {
                (try! JSONSerialization.data(withJSONObject: json), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
            }
            guard request.value(forHTTPHeaderField: "Authorization") == "Bearer bnp_robin00001" else { return answer(401, ["error": "Sign in again."]) }
            switch (method, path) {
            case ("GET", "/api/me"):
                return answer(200, ["user": ["login": "robin-h", "name": "Robin Hale"], "space": "team", "spaces": [["id": "team", "name": "Team", "role": "owner"]]])
            case ("POST", "/api/agents"):
                issued += 1
                var agent = body
                agent["id"] = "agent-\(issued)"
                agents["agent-\(issued)"] = agent
                return answer(200, ["agent": agent, "token": "bnd_token\(issued)"])
            case ("PATCH", _) where path.hasPrefix("/api/agents/"):
                let id = String(path.dropFirst("/api/agents/".count))
                guard agents[id] != nil else { return answer(400, ["error": "No such agent."]) }
                agents[id]?.merge(body) { _, new in new }
                return answer(200, agents[id] ?? [:])
            case ("DELETE", _) where path.hasPrefix("/api/agents/"):
                agents[String(path.dropFirst("/api/agents/".count))] = nil
                return answer(200, ["ok": true])
            default:
                return answer(404, ["error": "Not here."])
            }
        }
        account.signIn(to: "hub.example.com")
        await account.finish(URL(string: "binders://auth?token=bnp_robin00001&state=\(account.pending?.state ?? "")")!)
        guard let hub = account.address, account.isSignedIn else {
            check(false, "signed in to the stand-in hub")
            return 1
        }

        // MARK: Garden, linked to the hub; Work, not.
        let garden = BinderRecord(name: "Garden", colorIndex: 2)
        let work = BinderRecord(name: "Work", colorIndex: 1)
        store.insert(garden)
        store.insert(work)
        garden.hubLink = HubLink.Place(hub: hub, space: "team", spaceName: "Team", binder: "binder-garden", binderName: "Garden on the hub",
                                       client: "mac-test", uploaded: true).json
        func note(_ text: String, in binder: BinderRecord) -> NoteItem {
            let note = NoteItem(text: text)
            note.binderID = binder.id
            store.insert(note)
            return note
        }
        let tomatoes = note("# Tomatoes\n\nStake them in May.", in: garden)
        let budget = note("# Budget\n\nQ4 numbers.", in: work)
        let stakes = TaskCard(title: "Buy stakes", binderID: garden.id, column: .ready)
        let report = TaskCard(title: "Write the report", binderID: work.id, column: .ready)
        store.insert(stakes)
        store.insert(report)
        let walk = MeetingRecord(title: "Garden walk", appName: "Zoom", templateID: "general")
        walk.status = "ready"
        walk.summary = "## Decisions\n- Raised beds"
        walk.binderID = garden.id
        store.insert(walk)
        store.save()

        // MARK: This Mac's server, as an agent sees it.
        let write = MCPServer.writeInApp(controller: controller)
        func call(_ tool: String, _ arguments: [String: Any], as actor: BoardActor = BoardActor(name: "Claude Code", kind: .agent)) async -> (ok: Bool, text: String) {
            do { return (true, try await MCPServer.call(tool, arguments, knowledge: controller.knowledge, write: write, actor: actor, host: "Claude Code")) }
            catch { return (false, (error as? MCPCore.ToolFailure)?.message ?? error.localizedDescription) }
        }
        func list(_ text: String) -> [[String: Any]] { (try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]]) ?? [] }
        let mcp = HubAgents.mcpURL(hub: hub).absoluteString

        let binders = list((await call("list_binders", [:])).text)
        let gardenEntry = binders.first { $0["name"] as? String == "Garden" }
        let gardenHub = gardenEntry?["hub"] as? [String: Any]
        check(gardenHub?["mcp"] as? String == mcp && gardenHub?["binder"] as? String == "binder-garden" && gardenEntry?["notes"] as? Int == 0
                && gardenEntry?["meetings"] as? Int == 1, "list_binders says Garden's notes and cards are on the hub, and its meeting here: \(gardenEntry ?? [:])")
        check(binders.first { $0["name"] as? String == "Work" }?["hub"] == nil, "Work isn't linked")

        let notes = list((await call("list_notes", [:])).text).compactMap { $0["id"] as? String }
        check(notes.contains(budget.id.uuidString) && !notes.contains(tomatoes.id.uuidString), "list_notes leaves Garden's notes out")
        let gardenNotes = await call("list_notes", ["binder": "Garden"])
        check(!gardenNotes.ok && gardenNotes.text.contains(mcp) && gardenNotes.text.contains("meetings"),
              "asked for Garden's notes, it says they're on the hub and what stays here: \(gardenNotes.text)")
        let read = await call("get_note", ["id": tomatoes.id.uuidString])
        check(!read.ok && read.text.contains(HubLink.hubID(tomatoes.id)), "get_note on Garden's note gives the hub's id for it: \(read.text)")
        let appended = await call("append_to_note", ["id": tomatoes.id.uuidString, "text": "And water them."])
        let updated = await call("update_note", ["id": tomatoes.id.uuidString, "text": "# Tomatoes\n\nGone."])
        check(!appended.ok && !updated.ok && store.note(tomatoes.id)?.text == "# Tomatoes\n\nStake them in May.", "Garden's note isn't changed here")
        let added = await call("add_note", ["text": "Compost", "binder": "Garden"])
        check(!added.ok && added.text.contains(mcp), "nor is a note added to Garden: \(added.text)")
        let moved = await call("move_item", ["id": tomatoes.id.uuidString, "to": "Later"])
        check(!moved.ok && store.note(tomatoes.id)?.folderID == nil, "nor moved")
        check((await call("get_note", ["id": budget.id.uuidString])).ok, "Work's notes are as before")

        let tasks = list((await call("list_tasks", [:])).text).compactMap { $0["id"] as? String }
        check(tasks.contains(report.id.uuidString) && !tasks.contains(stakes.id.uuidString), "list_tasks leaves Garden's cards out")
        check(!(await call("list_tasks", ["binder": "Garden"])).ok, "and refuses Garden's board")
        let streams = await call("work_streams", [:])
        check(streams.ok && !streams.text.contains("Buy stakes"), "work_streams leaves them out")
        let getTask = await call("get_task", ["id": stakes.id.uuidString])
        check(!getTask.ok && getTask.text.contains(HubLink.hubID(stakes.id)), "get_task on Garden's card points at the hub: \(getTask.text)")
        for tool in ["claim_task", "comment_task", "complete_task"] {
            let tried = await call(tool, ["id": stakes.id.uuidString, "text": "x", "summary": "x"])
            check(!tried.ok && tried.text.contains(mcp), "\(tool) on Garden's card is refused")
        }
        check(stakes.assignee == nil && stakes.column == .ready, "Garden's card is as it was")
        let made = await call("create_task", ["title": "Plant beans", "binder": "Garden"])
        check(!made.ok && BoardService().cards(in: garden.id).count == 1, "no card is made on Garden's board")
        let claimed = await call("claim_task", ["id": report.id.uuidString])
        check(claimed.ok && report.assignee == "Claude Code", "Work's card is claimed as before: \(claimed.text)")

        // What stays here: Garden's meeting.
        let meetings = list((await call("list_meetings", ["binder": "Garden"])).text)
        check(meetings.first?["title"] as? String == "Garden walk", "Garden's meeting is still here")
        let instructions = MCPServer.offeredInstructions
        check(instructions.contains(mcp) && instructions.contains("linked to a hub"), "the server tells agents where linked binders' notes and cards are")

        // The app refuses an agent's write there itself; you (the iPhone) aren't an agent.
        let direct = await InboxCommands.perform(InboxRequest(action: "claim_task", fields: ["id": stakes.id.uuidString, "actor": "Codex",
                                                                                             "actor_kind": BoardActor.Kind.agent.rawValue]), controller: controller)
        check(!direct.ok && stakes.assignee == nil, "the app refuses an agent's claim on Garden's card: \(direct.error ?? "")")
        let directNote = await InboxCommands.perform(InboxRequest(action: "add_note", fields: ["text": "Weeds", "binder": "Garden", "actor": "Codex",
                                                                                               "actor_kind": BoardActor.Kind.agent.rawValue]), controller: controller)
        check(!directNote.ok, "and an agent's note in Garden")
        let phoneNotes = list((await call("list_notes", ["binder": "Garden"], as: .you)).text)
        check(phoneNotes.contains { $0["id"] as? String == tomatoes.id.uuidString }, "the iPhone (you) reads Garden's notes as before")
        check((await call("get_task", ["id": stakes.id.uuidString], as: .you)).ok, "and its cards")

        // Binders wakes none of your agents for Garden's cards.
        stakes.meantFor = "Claude Code"
        store.save()
        let reach = controller.agents.commentReach(for: stakes, events: [])
        if case .held(_, let why) = reach {
            check(why == AgentDispatcher.onHubWhy, "a comment on Garden's card wakes no agent here")
        } else if case .nobody = reach {
            check(true, "a comment on Garden's card wakes no agent here (none set up)")
        } else {
            check(false, "a comment on Garden's card wakes no agent here: \(reach)")
        }

        // MARK: Setting a tool up for the hub.
        var servers: [String: (url: URL, token: String)] = [:]
        var failAdding = false
        setup.addServer = { host, name, url, token in
            if failAdding { throw MCPHost.Failure.command("Claude Code's file is locked.") }
            servers["\(host.rawValue)/\(name)"] = (url, token)
        }
        setup.removeServer = { host, name in servers["\(host.rawValue)/\(name)"] = nil }

        let spaces = setup.spaces()
        check(spaces.map(\.id) == ["team"] && spaces.first?.projects == ["binder-garden"] && spaces.first?.name == "Team",
              "the hub's Team has Garden's project linked here: \(spaces)")
        guard let team = spaces.first else { return 1 }
        asked = []
        let first = await setup.add(.claudeCode, in: team)
        let made1 = asked.first { $0.method == "POST" && $0.path == "/api/agents" }
        check(first && made1?.space == "team" && made1?.body["binders"] as? [String] == ["binder-garden"] && made1?.body["provider"] as? String == "claude"
                && (made1?.body["name"] as? String ?? "").hasPrefix("Claude Code"), "Set Up asks the hub for a Claude Code agent taking Garden's project's work: \(made1?.body ?? [:])")
        check(servers["claudeCode/binders-team"]?.url.absoluteString == mcp && servers["claudeCode/binders-team"]?.token == "bnd_token1",
              "and adds the hub's server to Claude Code as binders-team, with that agent's token")
        let record = setup.record(.claudeCode, in: "team")
        check(record?.agent == "agent-1" && record?.server == "binders-team", "Binders keeps which agent it is")
        let saved = AppDefaults.store.data(forKey: HubAgentSetup.recordsKey).map { String(decoding: $0, as: UTF8.self) } ?? ""
        check(saved.contains("agent-1") && !saved.contains("bnd_"), "and never its token")

        let again = await setup.add(.claudeCode, in: team)
        check(again && setup.record(.claudeCode, in: "team")?.agent == "agent-2" && agents["agent-1"] == nil && agents["agent-2"] != nil
                && servers["claudeCode/binders-team"]?.token == "bnd_token2", "Set Up Again makes a new agent and revokes the old one")

        failAdding = true
        let failed = await setup.add(.cursor, in: team)
        failAdding = false
        check(!failed && agents.count == 1 && setup.record(.cursor, in: "team") == nil && setup.problems[HubAgentSetup.key(.cursor, "team")]?.contains("locked") == true,
              "a tool that can't be changed leaves no agent on the hub, and says why")

        // Another binder linked in Team: the agent takes its work too; unlinked, not.
        let shed = BinderRecord(name: "Shed", colorIndex: 3)
        shed.hubLink = HubLink.Place(hub: hub, space: "team", spaceName: "Team", binder: "binder-shed", binderName: "Shed", client: "mac-test-2", uploaded: true).json
        store.insert(shed)
        store.save()
        await setup.refresh()
        check(agents["agent-2"]?["binders"] as? [String] == ["binder-garden", "binder-shed"], "linking Shed adds its project to the agent")
        HubLinks.shared.unlink(shed)
        await setup.refresh()
        check(agents["agent-2"]?["binders"] as? [String] == ["binder-garden"], "unlinking it takes it away")

        await setup.remove(.claudeCode, in: team)
        check(servers.isEmpty && agents.isEmpty && setup.record(.claudeCode, in: "team") == nil, "Remove takes the server out of Claude Code and the agent off the hub")

        // MARK: A real hub, when one is given.
        if let realHub = ProcessInfo.processInfo.environment["BINDERS_TEST_HUB"], let token = ProcessInfo.processInfo.environment["BINDERS_TEST_HUB_TOKEN"] {
            failures += await realHubAgentChecks(hub: realHub, token: token)
        } else {
            print("SKIP: a real hub (set BINDERS_TEST_HUB and BINDERS_TEST_HUB_TOKEN)")
        }

        print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
        return failures == 0 ? 0 : 1
    }

    /// Links a binder with a ready card to a new project on a running hub, sets a tool up for it, and has that agent claim
    /// and complete the card through the hub's /mcp with its own token, while this Mac's server refuses it.
    @MainActor
    private static func realHubAgentChecks(hub: String, token: String) async -> Int {
        var failed = 0
        func check(_ condition: Bool, _ label: String) {
            print("\(condition ? "PASS" : "FAIL"): real hub: \(label)")
            if !condition { failed += 1 }
        }
        let account = HubAccount.shared
        let links = HubLinks.shared
        let setup = HubAgentSetup.shared
        let store = Store.shared
        let controller = DictationController()
        account.send = { try await URLSession.shared.data(for: $0) }
        account.signIn(to: hub)
        await account.finish(URL(string: "binders://auth?token=\(token)&state=\(account.pending?.state ?? "")")!)
        check(account.isSignedIn && account.person != nil, "signed in as \(account.person?.line ?? account.problem ?? "no one")")

        let stamp = Int(Date().timeIntervalSince1970)
        let binder = BinderRecord(name: "Agents from a Mac \(stamp)", colorIndex: 5)
        store.insert(binder)
        let card = TaskCard(title: "Water the tomatoes", binderID: binder.id, column: .ready)
        card.details = "Made at \(stamp)."
        store.insert(card)
        store.save()
        guard let found = try? await links.spaces(), let space = found.spaces.first(where: { $0.id == found.current }) ?? found.spaces.first else {
            check(false, "the hub says which Binders you're in")
            return failed
        }
        let linked = await links.link(binder, space: space, to: nil)
        check(linked, "linked to a new project in \(space.name): \(links.done[binder.id] ?? links.problems[binder.id] ?? "")")

        // This Mac's server refuses the card to an agent.
        let local = try? await MCPServer.call("claim_task", ["id": card.id.uuidString], knowledge: controller.knowledge, write: MCPServer.writeInApp(controller: controller),
                                              actor: BoardActor(name: "Claude Code", kind: .agent), host: "Claude Code")
        check(local == nil && card.assignee == nil, "this Mac's server won't let an agent claim it")

        // Set up, keeping the token instead of writing any tool's configuration.
        var given: (url: URL, token: String)?
        setup.addServer = { _, _, url, token in given = (url, token) }
        setup.removeServer = { _, _ in }
        guard let hubSpace = setup.spaces().first(where: { $0.id == space.id }) else {
            check(false, "the linked project is offered for setting up")
            return failed
        }
        let added = await setup.add(.claudeCode, in: hubSpace)
        check(added && given?.token.hasPrefix("bnd_") == true, "a Claude Code agent set up on the hub: \(setup.done[HubAgentSetup.key(.claudeCode, space.id)] ?? setup.problems[HubAgentSetup.key(.claudeCode, space.id)] ?? "")")
        guard let given else { return failed }

        /// One tool call on the hub's /mcp, as the agent.
        func tool(_ name: String, _ arguments: [String: Any]) async -> (ok: Bool, text: String) {
            var request = URLRequest(url: given.url)
            request.httpMethod = "POST"
            request.setValue("Bearer \(given.token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": "tools/call",
                                                                            "params": ["name": name, "arguments": arguments]] as [String: Any])
            guard let (data, _) = try? await URLSession.shared.data(for: request),
                  let reply = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return (false, "no answer") }
            let result = reply["result"] as? [String: Any]
            let text = ((result?["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String } ?? []).joined(separator: "\n")
            return (result != nil && result?["isError"] as? Bool != true, text.isEmpty ? "\(reply)" : text)
        }
        let hubCard = HubLink.hubID(card.id)
        let claim = await tool("claim_task", ["id": hubCard])
        check(claim.ok, "the agent claims the card through the hub's /mcp: \(claim.text.prefix(200))")
        let complete = await tool("complete_task", ["id": hubCard, "summary": "Watered, from a self-test on a Mac."])
        check(complete.ok, "and completes it: \(complete.text.prefix(200))")

        guard let place = HubLinks.place(of: binder), var request = account.authorized("api/state") else { return failed + 1 }
        request.setValue(place.space, forHTTPHeaderField: "x-binders-space")
        let state = (try? await URLSession.shared.data(for: request).0).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["state"] as? [String: Any]
        let onHub = (state?["cards"] as? [[String: Any]])?.first { $0["id"] as? String == hubCard }
        let kinds = (onHub?["activity"] as? [[String: Any]])?.compactMap { $0["kind"] as? String } ?? []
        check(onHub?["stage"] as? String != "ready" && kinds.contains("claimed") && kinds.contains("completed"),
              "the hub has it claimed and completed by the agent: \(onHub?["stage"] ?? "?"), \(kinds)")

        await setup.remove(.claudeCode, in: hubSpace)
        let after = await tool("list_binders", [:])
        check(!after.ok, "removed, the agent's token no longer works on the hub")
        return failed
    }
}
