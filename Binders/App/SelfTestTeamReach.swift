import AppKit
import SwiftUI
import BindersKit

/// Lane DB8's self-test, on TeamDBTestBed's throwaway Postgres: board writes over MCP, from the iPhone (a person's) and on
/// this Mac while the team database is stopped, frozen (connected, and answering nothing) and turned off on this Mac.
/// Each kind of write answers within its time with the right words; what's kept here arrives once the database is back,
/// once each; what's refused changed nothing, here or there. A folder after the flag gets the board drawn in each state.
///
///     Binders --selftest-teamdb-reach [folder]
extension SelfTest {
    @MainActor
    static func teamReachChecks(_ bed: TeamDBTestBed) async throws {
        let agentA = AgentProfile(id: bed.agentA, name: "Agent A", wake: .webhook(url: "https://example.invalid/agent-a"), report: .mcp)
        let mac = try await TeamMac.start(bed, agents: [agentA])
        let alex = try await bed.teammate()
        let agent = BoardActor(name: "Agent A", kind: .agent)
        let team = mac.team
        // As the app does at launch: it hears the team database's default from now on.
        team.watchFeature()
        let shared = try required(Store.shared.binder(bed.shared), "the shared binder")

        /// A tool call, and how long its answer took.
        func timed(_ tool: String, _ arguments: [String: Any], as actor: BoardActor = agent) async -> (ok: Bool, text: String, seconds: Double) {
            let started = Date()
            let answer = await mac.mcp(tool, arguments, as: actor)
            return (answer.ok, answer.text, Date().timeIntervalSince(started))
        }
        func message(_ text: String) -> String { TeamMac.object(text)["message"] as? String ?? text }
        func secs(_ seconds: Double) -> String { String(format: "%.2f s", seconds) }
        func events(_ card: UUID) async throws -> [TeamRow] {
            try await alex.rows(.cardEvents, binder: bed.shared).filter { $0["card_id"]?.uuid == card }
        }
        func row(_ card: UUID) async throws -> TeamRow? {
            let rows = try await alex.rows(.cards, ids: [card])
            return rows.first
        }
        func queued() -> [String] { (team.database ?? team.parked?.outbox)?.queued.map(\.call.function) ?? [] }
        func refused(_ work: () throws -> Void) -> String {
            do { try work() } catch { return error.localizedDescription }
            return ""
        }

        // Every connection ends a transaction left open, and checks its peer is still there (TeamQueries.sessionSetup).
        let settings = try await team.database?.json("SELECT json_build_array(current_setting('idle_in_transaction_session_timeout'), current_setting('tcp_keepalives_idle'))::text")
        bed.check(settings?.array?.compactMap(\.string) == ["30s", "30"], "every connection ends a transaction left open for 30 s, and checks its peer after 30 s: \(settings?.text ?? "-")")

        // The cards: one nobody holds, one Agent A works on, one that waits for Sam's approval.
        let free = try await bed.made("Write the intro", by: alex)
        let held = try await bed.made("Check the figures", by: alex)
        let asking = try await bed.made("Pick the venue", by: alex)
        _ = await bed.eventually(5) { [free, held, asking].allSatisfy { mac.card($0) != nil } }
        _ = await mac.claim(held, as: "Agent A")
        _ = await mac.claim(asking, as: "Agent A")
        let approval = await mac.mcp("request_approval", ["id": asking.uuidString, "action": "Book the hall", "text": "Book the main hall for the 12th."], as: agent)
        bed.check(approval.ok && mac.card(held)?.assignee == "Agent A" && mac.card(asking)?.column == .blocked, "Agent A has a card, and one waits for Sam's approval: \(approval.text.prefix(60))")
        let menu = mac.board.create(title: "Draft the menu", binderID: bed.shared, column: .backlog, by: .you)
        _ = await mac.drained()
        let tile = { (id: UUID) -> String in
            guard let card = mac.card(id) else { return "-" }
            return "\(card.column.rawValue) \(card.assignee ?? "nobody")"
        }

        // The Manager tidies the team's board as you would: a free card it may close while the database answers.
        let manager = BoardActor(name: "Manager", kind: .agent)
        if let card = mac.card(free) {
            bed.check(ManagerCommands.refusal(card, board: mac.board, closing: true) == nil && ManagerCommands.refusal(card, board: mac.board, closing: false) == nil,
                      "the Manager may close and edit a free card on the team's board")
        }
        if let card = mac.card(held) {
            bed.check(ManagerCommands.refusal(card, board: mac.board, closing: true) == nil, "and one an agent holds, when you ask it to")
        }

        // MARK: The server stops.
        bed.check(await bed.postgres.pause(), "the team's server stops")
        let away = await bed.eventually(10) { team.outboxReach == .unreachable }
        bed.check(away, "this Mac knows it can't reach it: \(team.status)")
        let before = [free: tile(free), held: tile(held), asking: tile(asking)]
        let refusals: [(String, [String: Any], TeamBoardWrite, String)] = [
            ("claim_task", ["id": free.uuidString], .claim, "claim_task"),
            ("update_task", ["id": free.uuidString, "column": "in_progress"], .move(.inProgress), "update_task to In progress"),
            ("update_task", ["id": held.uuidString, "column": "review"], .move(.review), "update_task to Review"),
            ("complete_task", ["id": held.uuidString, "summary": "Checked."], .finish, "complete_task"),
            ("release_task", ["id": held.uuidString], .release, "release_task"),
        ]
        if let card = mac.card(free) {
            let refusal = ManagerCommands.refusal(card, board: mac.board, closing: true)
            bed.check(refusal == TeamBoardWrites.refusal(.move(.done), .unreachable, agent: true) && mac.board.teamRefusal(.move(.done), on: card, by: manager) == refusal,
                      "stopped: the Manager hears why it can't close a team card now: \(refusal?.prefix(60) ?? "-")")
        }
        for (tool, arguments, write, name) in refusals {
            let answer = await timed(tool, arguments)
            bed.check(!answer.ok && answer.text == TeamBoardWrites.refusal(write, .unreachable, agent: true) && answer.seconds < 3,
                      "stopped: \(name) is refused in \(secs(answer.seconds)), saying why: \(answer.text.prefix(70))")
        }
        let comment = await timed("comment_task", ["id": asking.uuidString, "text": "Approved"], as: .you)
        bed.check(!comment.ok && comment.text == TeamBoardWrites.refusal(.answerApproval, .unreachable, agent: false) && comment.seconds < 3,
                  "stopped: your “Approved” from the iPhone, which would decide the approval, is refused in \(secs(comment.seconds))")
        if let card = mac.card(asking) {
            let decided = refused { try mac.board.decide(card, approve: true, by: .you, on: "Mac") }
            bed.check(decided == TeamBoardWrites.refusal(.decide, .unreachable, agent: false), "stopped: Approve on this Mac is refused at once: \(decided.prefix(70))")
        }
        if let card = mac.card(held) {
            let lines = mac.board.timeline(held).count
            let accepted = refused { try CardActions.accept(card, words: "Looks right.", board: mac.board) }
            bed.check(accepted == TeamBoardWrites.refusal(.move(.done), .unreachable, agent: false) && mac.board.timeline(held).count == lines,
                      "stopped: Accept on this Mac is refused before your words go on their own")
        }
        let given = mac.board.give(menu, to: "Agent A", by: .you)
        bed.check(given == .notWoken(TeamBoardWrites.kept(.unreachable) + " Give it to Agent A again then to hand it over.")
                    && menu.column == .backlog && menu.meantFor == "Agent A" && queued() == ["assign_card"] && mac.wakes(of: menu.id).isEmpty,
                  "stopped: Give to keeps who it's for, moves nothing, wakes no one, and says so")
        if let card = mac.card(free) {
            let taken = refused { try mac.board.claim(card, by: .you) }
            bed.check(taken == TeamBoardWrites.refusal(.claim, .unreachable, agent: false), "stopped: Take It on this Mac is refused at once")
            bed.check(mac.board.delete(card) == TeamBoardWrites.refusal(.delete, .unreachable, agent: false) && mac.card(free) != nil,
                      "stopped: Delete on this Mac is refused, and the card stays")
        }
        let kept: [(String, [String: Any], String)] = [
            ("comment_task", ["id": held.uuidString, "text": "Halfway through the figures."], "comment_task"),
            ("update_task", ["id": held.uuidString, "progress": "Checked March", "links": "https://example.com/figures"], "update_task with progress and links"),
            ("create_task", ["title": "Order the posters", "binder": "Shared", "column": "ready"], "create_task"),
            ("update_task", ["id": free.uuidString, "for": "Agent B"], "update_task for Agent B"),
        ]
        for (tool, arguments, name) in kept {
            let answer = await timed(tool, arguments)
            bed.check(answer.ok && message(answer.text).hasSuffix(TeamBoardWrites.kept(.unreachable)) && answer.seconds < 3,
                      "stopped: \(name) is kept here in \(secs(answer.seconds)), and says so: \(message(answer.text).prefix(60))…")
        }
        let after = [free: tile(free), held: tile(held), asking: tile(asking)]
        bed.check(after == before, "what was refused changed nothing here: \(after.values.sorted())")
        bed.check(queued() == ["assign_card", "answer", "report", "create_card", "assign_card"], "only what can wait waits, in order: \(queued())")
        bed.check(team.database?.queued.first { $0.call.function == "report" }?.call.argument("p_renewing") == "false",
                  "the report goes without keeping Agent A's claim alive from when it arrives")
        if let folder = teamDrawings { _ = await drawBoard(shared, controller: mac.controller, name: "reach-board-unreachable", directory: folder) }
        bed.check(await drawBoard(shared, controller: mac.controller, name: nil, directory: nil).contains("board.teamReach.unreachable"),
                  "the board says it can't reach the team's database, what waits and what to check")

        // Back: what was kept arrives once each; what was refused never does.
        bed.check(await bed.postgres.resume(), "the server starts again")
        let back = await bed.eventually(20) { team.isConnected && (team.database?.waiting ?? 1) == 0 }
        bed.check(back, "this Mac is back on it, and its outbox is empty")
        var lines = try await events(held)
        bed.check(lines.filter { $0["kind"]?.string == "comment" && $0["text"]?.string == "Halfway through the figures." && $0["author_name"]?.string == "Agent A (Sam)" }.count == 1,
                  "the comment arrived once, by Agent A (Sam)")
        bed.check(lines.filter { $0["kind"]?.string == "progress" && $0["text"]?.string == "Checked March\n→ https://example.com/figures" }.count == 1,
                  "the report and its link arrived once")
        bed.check(!lines.contains { ["moved", "completed", "released"].contains($0["kind"]?.string ?? "") }, "nothing moved, finished or let go of it")
        let posters = try await alex.rows(.cards, binder: bed.shared).filter { $0["title"]?.string == "Order the posters" }
        bed.check(posters.count == 1, "the new card arrived once: \(posters.count)")
        let freeRow = try await row(free)
        bed.check(freeRow?["meant_for"]?.string?.hasPrefix("Agent B") == true && freeRow?["meant_for_by_agent"]?.bool == true
                    && freeRow?["board_column"]?.string == "ready" && freeRow?["holder_kind"]?.string == nil,
                  "who it's meant for arrived as Agent A's suggestion; the card is still free, in Ready")
        let menuRow = try await row(menu.id)
        bed.check(menuRow?["meant_for"]?.string?.hasPrefix("Agent A") == true && menuRow?["meant_for_by_agent"]?.bool == false
                    && menuRow?["board_column"]?.string == "backlog",
                  "your Give to arrived as who it's for, and the card is still in Backlog: \(menuRow?["meant_for"]?.string ?? "-")")
        let askingRow = try await row(asking)
        let askingLines = try await events(asking)
        bed.check(askingRow?["board_column"]?.string == "blocked" && !askingLines.contains { $0["kind"]?.string == "decision" },
                  "the approval still waits: no decision reached the team")
        let heldRow = try await row(held)
        bed.check(heldRow?["board_column"]?.string == "in_progress" && heldRow?["holder_agent_id"]?.uuid == bed.agentA, "Agent A still has its card, in progress")

        // MARK: The server freezes: still connected, answering nothing. A claim first asks whether it answers.
        await bed.postgres.freeze()
        let claim = await timed("claim_task", ["id": free.uuidString])
        bed.check(!claim.ok && claim.text == TeamBoardWrites.refusal(.claim, .unreachable, agent: true) && claim.seconds < 3,
                  "frozen: a claim asks first, and is refused within \(secs(claim.seconds))")
        let again = await timed("update_task", ["id": held.uuidString, "column": "review"])
        bed.check(!again.ok && again.text == TeamBoardWrites.refusal(.move(.review), .unreachable, agent: true) && again.seconds < 1,
                  "frozen: then at once (\(secs(again.seconds)))")
        let kept1 = await timed("comment_task", ["id": held.uuidString, "text": "Still on it."])
        bed.check(kept1.ok && message(kept1.text).hasSuffix(TeamBoardWrites.kept(.unreachable)) && kept1.seconds < 1,
                  "frozen: a comment is kept here at once (\(secs(kept1.seconds)))")
        if let card = mac.card(free) {
            bed.check(refused { try mac.board.claim(card, by: .you) } == TeamBoardWrites.refusal(.claim, .unreachable, agent: false) && card.assignee == nil,
                      "frozen: Take It on this Mac is refused at once, and the card stays free")
        }
        await bed.postgres.thaw()
        var thawed = await bed.eventually(20) { team.database?.isAnswering == true && (team.database?.waiting ?? 1) == 0 }
        bed.check(thawed, "thawed: it answers again, and what waited went")

        // Frozen again, a comment first: it waits 5 s at most for the answer, then it's kept, and what follows doesn't wait.
        await bed.postgres.freeze()
        let first = await timed("comment_task", ["id": held.uuidString, "text": "Nearly there."])
        bed.check(first.ok && message(first.text).hasSuffix(TeamBoardWrites.notAnsweredYet) && first.seconds < 6.5,
                  "frozen: the first comment waits 5 s at most, then is kept here, and says so (\(secs(first.seconds)))")
        let after5 = await timed("complete_task", ["id": held.uuidString, "summary": "Checked."])
        bed.check(!after5.ok && after5.text == TeamBoardWrites.refusal(.finish, .unreachable, agent: true) && after5.seconds < 1,
                  "frozen: then a finish is refused at once (\(secs(after5.seconds)))")
        await bed.postgres.thaw()
        thawed = await bed.eventually(20) { team.database?.isAnswering == true && (team.database?.waiting ?? 1) == 0 }
        bed.check(thawed, "thawed again: what waited went")
        lines = try await events(held)
        bed.check(["Still on it.", "Nearly there."].allSatisfy { text in lines.filter { $0["text"]?.string == text }.count == 1 }, "each comment arrived once")
        let freeNow = try await row(free)
        let freeLines = try await events(free)
        let heldNow = try await row(held)
        bed.check(freeNow?["holder_kind"]?.string == nil && !freeLines.contains { $0["kind"]?.string == "claimed" }
                    && heldNow?["board_column"]?.string == "in_progress",
                  "the claims, the move and the finish never reached the team")

        // MARK: Slow to take a claim: it's taken back unsent, and the card put back.
        team.database?.testHooks.holdBeforeSending = { $0.call.function == "claim_card" }
        let slow = await timed("claim_task", ["id": free.uuidString])
        bed.check(!slow.ok && slow.text.hasPrefix("The team's database didn't answer within 5 seconds, so this Mac took back the claim: nothing changed.") && slow.seconds < 6.5,
                  "slow: a claim whose answer doesn't come in 5 s is taken back (\(secs(slow.seconds))): \(slow.text.prefix(80))")
        let restored = mac.card(free)
        bed.check(restored?.column == .ready && restored?.assignee == nil && !queued().contains("claim_card")
                    && mac.board.timeline(free).last?.text.hasPrefix("Agent A's claim didn't go through on the team's board: The team's database didn't answer within 5 seconds") == true,
                  "the card is as it was here, with a line that says why, and nothing waits: \(tile(free))")
        team.database?.testHooks.holdBeforeSending = nil
        _ = await mac.drained()
        bed.check(try await row(free)?["holder_kind"]?.string == nil, "and the team never had it")

        // MARK: Left in the outbox past its time: it goes again only if the database already has it.
        let notes = try await bed.made("Write the notes", by: alex)
        let agenda = try await bed.made("Print the agenda", by: alex)
        _ = await bed.eventually(5) { mac.card(notes) != nil && mac.card(agenda) != nil }
        team.database?.send(.claimCard(notes, agent: bed.agentA), sendBy: Date().addingTimeInterval(-1))
        let late = await bed.eventually(10) {
            mac.board.timeline(notes).contains { $0.text == "Agent A's claim didn't go through on the team's board: \(TeamBoardWrites.notSentLate)" }
        }
        bed.check(late, "a claim past its time the database doesn't have isn't sent: the card says so")
        bed.check(try await row(notes)?["holder_kind"]?.string == nil && mac.card(notes)?.assignee == nil, "and nobody has the card, there or here")
        let operation = UUID()
        let samLink = try await bed.link(bed.sam)
        _ = try await samLink.call(.claimCard(agenda, agent: bed.agentA, operation: operation))
        team.database?.send(.claimCard(agenda, agent: bed.agentA, operation: operation), sendBy: Date().addingTimeInterval(-1))
        let replayed = await bed.eventually(10) { mac.card(agenda)?.assignee == "Agent A" && (team.database?.waiting ?? 1) == 0 }
        let claims = try await events(agenda).filter { $0["kind"]?.string == "claimed" }.count
        bed.check(replayed && claims == 1, "one the database has goes again, gets its first answer back, and lands once (\(claims) claim)")

        // MARK: Team databases turned off on this Mac.
        AppDefaults.store.removeObject(forKey: TeamDatabaseFeature.key)
        let parked = await bed.eventually(10) { team.database == nil && team.parked != nil }
        bed.check(parked && team.outboxReach == .off && team.covers(bed.shared) == false && team.isShared(binder: bed.shared),
                  "turned off: disconnected, and its board is still shared through it, as off")
        for (tool, arguments, write, name) in [("claim_task", ["id": free.uuidString], TeamBoardWrite.claim, "claim_task"),
                                               ("complete_task", ["id": held.uuidString, "summary": "Checked."], .finish, "complete_task"),
                                               ("update_task", ["id": held.uuidString, "column": "done"], .move(.done), "update_task to Done")] as [(String, [String: Any], TeamBoardWrite, String)] {
            let answer = await timed(tool, arguments)
            bed.check(!answer.ok && answer.text == TeamBoardWrites.refusal(write, .off, agent: true) && answer.seconds < 1,
                      "off: \(name) is refused in \(secs(answer.seconds)): \(answer.text.prefix(80))")
        }
        for (tool, arguments, name) in [("comment_task", ["id": held.uuidString, "text": "Written while it was off."], "comment_task"),
                                        ("update_task", ["id": held.uuidString, "progress": "April checked too"], "update_task with progress"),
                                        ("create_task", ["title": "Book the photographer", "binder": "Shared"], "create_task")] as [(String, [String: Any], String)] {
            let answer = await timed(tool, arguments)
            bed.check(answer.ok && message(answer.text).hasSuffix(TeamBoardWrites.kept(.off)) && answer.seconds < 1,
                      "off: \(name) is kept here in \(secs(answer.seconds)), and says so")
        }
        if let card = mac.card(free) {
            bed.check(refused { try mac.board.claim(card, by: .you) } == TeamBoardWrites.refusal(.claim, .off, agent: false), "off: Take It on this Mac is refused at once")
        }
        let read = TeamMac.list((await mac.mcp("list_tasks", ["binder": "Shared"], as: agent)).text)
        bed.check(read.contains { $0["title"] as? String == "Check the figures" }, "off: agents still read the board")
        bed.check(queued() == ["answer", "report", "create_card"], "off: what can wait waits in the outbox on disk: \(queued())")
        bed.check(!(try await events(held)).contains { $0["text"]?.string == "Written while it was off." }, "off: nothing reached the team")
        if let folder = teamDrawings { _ = await drawBoard(shared, controller: mac.controller, name: "reach-board-off", directory: folder) }
        let shownOff = await drawBoard(shared, controller: mac.controller, name: nil, directory: nil)
        bed.check(shownOff.contains("board.teamReach.off") && shownOff.contains("board.teamReach.turnOn"),
                  "off: the board says team databases are off on this Mac, what waits, and offers Turn On")

        // On again: what was kept goes, once each.
        AppDefaults.store.set(true, forKey: TeamDatabaseFeature.key)
        let on = await bed.eventually(20) { team.parked == nil && team.isConnected && (team.database?.waiting ?? 1) == 0 }
        bed.check(on, "on again: connected, and the outbox is empty")
        lines = try await events(held)
        bed.check(lines.filter { $0["text"]?.string == "Written while it was off." }.count == 1 && lines.filter { $0["text"]?.string == "April checked too" }.count == 1,
                  "what was kept while it was off arrived, once each")
        bed.check(try await alex.rows(.cards, binder: bed.shared).filter { $0["title"]?.string == "Book the photographer" }.count == 1, "the new card arrived once")
        let heldAfter = try await row(held)
        let heldLines = try await events(held)
        bed.check(heldAfter?["board_column"]?.string == "in_progress" && heldAfter?["holder_agent_id"]?.uuid == bed.agentA
                    && !heldLines.contains { $0["kind"]?.string == "completed" },
                  "what was refused never happened: Agent A's card is still in progress")
        let shownOn = await drawBoard(shared, controller: mac.controller, name: nil, directory: nil)
        bed.check(!shownOn.contains { $0.hasPrefix("board.teamReach") }, "on and answering: the board has no such line")
        await mac.stop()
    }

    /// The board drawn in a window as the Binders window shows it: the names of the probes it drew (FitProbe), and a
    /// drawing in `directory` when one is given.
    @MainActor
    static func drawBoard(_ binder: BinderRecord, controller: DictationController, name: String?, directory: URL?) async -> Set<String> {
        let wasOn = FitProbe.isOn
        FitProbe.isOn = true
        defer { FitProbe.isOn = wasOn }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700), styleMask: [.titled, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        let hosting = NSHostingView(rootView: BoardView(binder: binder).pageGround()
            .environment(controller).environment(controller.knowledge).environment(HubNavigation()).environment(AppSettings.shared)
            .modelContainer(Store.shared.container))
        hosting.wantsLayer = true
        window.contentView = hosting
        window.orderFrontRegardless()
        try? await Task.sleep(for: .milliseconds(1_200))
        let shown = Set(FitProbe.all(in: window).map(\.name))
        if let directory, let name {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            capture(hosting, name: name, directory: directory)
        }
        window.close()
        return shown
    }

    /// A value the test can't go on without.
    private static func required<T>(_ value: T?, _ what: String) throws -> T {
        guard let value else { throw TeamDatabase.Problem.refused("no \(what)") }
        return value
    }
}
