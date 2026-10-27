import AppKit
import Darwin
import SwiftUI
import BindersKit

extension SelfTest {
    /// The Manager (lane MG1), with a stand-in for claude that takes its prompt and waits: the role only through Settings'
    /// yes, one request at a time, the run started with Binders' tools alone in its own folder, and, as its server would
    /// offer them, the Manager's tools in this process (its BINDERS_* set as the run's server has them): merge, close and
    /// edit cards, folders and moves, a suggested note edit, its reply; refused for a card an agent holds, one waiting on
    /// you, another agent or a request not running; nothing it does wakes an agent. Undo puts a whole request back, an
    /// accepted suggestion is your edit, and a run that ends without reply answers with what it said last. In a throwaway
    /// folder (BINDERS_DATA_DIR) only; no real agent runs.
    ///
    ///     BINDERS_DATA_DIR=$(mktemp -d) Binders --selftest-manager -notesShowMarkdown NO
    @MainActor
    static func managerSelfTest() async -> Int32 {
        guard AppPaths.isDemo else {
            print("ERROR: set BINDERS_DATA_DIR to an empty folder; this test writes cards, notes, agents and the Manager's file")
            return 1
        }
        var failures = 0
        func check(_ condition: Bool, _ label: String) {
            print("\(condition ? "PASS" : "FAIL"): \(label)")
            if !condition { failures += 1 }
        }
        let folder = AppPaths.support
        let files = FileManager.default
        let controller = DictationController()
        let board = controller.board
        let registry = AgentRegistry.shared
        let manager = controller.manager
        let write = MCPServer.writeInApp(controller: controller)
        func until(seconds: Double = 10, _ done: () -> Bool) async {
            let end = Date().addingTimeInterval(seconds)
            while !done(), Date() < end { try? await Task.sleep(for: .milliseconds(100)) }
        }
        let store = Store.shared
        let binder = BinderRecord(name: "Personal", colorIndex: 3)
        store.insert(binder)

        // A stand-in for claude: keeps its arguments, prompt and environment, then waits for the test to let it end, and
        // says something last, as a run's result line.
        let bin = folder.appendingPathComponent("bin")
        try? files.createDirectory(at: bin, withIntermediateDirectories: true)
        let fake = bin.appendingPathComponent("claude")
        try? """
            #!/bin/sh
            here="$(cd "$(dirname "$0")/.." && pwd)"
            cat > "$here/manager-prompt.txt"
            printf '%s\\n' "$@" > "$here/manager-args.txt"
            pwd > "$here/manager-pwd.txt"
            printf '%s' "$BINDERS_MANAGER" > "$here/manager-env.txt"
            n=0
            while [ ! -f "$here/manager-go" ] && [ $n -lt 300 ]; do sleep 0.1; n=$((n+1)); done
            rm -f "$here/manager-go"
            printf '{"type":"result","result":"What it said last"}\\n'
            """.write(to: fake, atomically: true, encoding: .utf8)
        try? files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        func letItEnd() { files.createFile(atPath: folder.appendingPathComponent("manager-go").path, contents: Data()) }
        func read(_ name: String) -> String { (try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)) ?? "" }

        // No agent has the role yet: a request fails, saying where to give it.
        let early = manager.ask("What's on my plate?", from: .mac)
        check(manager.request(early.id)?.status == .failed && manager.request(early.id)?.why?.contains("Settings → Agents") == true,
              "with no Manager, a request fails and says where to give the role")

        let repository = folder.appendingPathComponent("repo")
        try? files.createDirectory(at: repository.appendingPathComponent(".git"), withIntermediateDirectories: true)
        var claude = AgentProfile(name: "Claude Code · manager", wake: .claudeCode(ClaudeCodeWake(repository: repository.path, permissionMode: "auto", executable: fake.path)),
                                  preset: "claude-code", manager: true)
        // In the file but without Settings' yes: nothing.
        registry.upsert(claude)
        check(!registry.isManager(claude) && manager.agent == nil, "manager: true written without the turn-on alert's yes gives no role")
        registry.upsert(claude, isManager: true)
        check(registry.isManager(claude) && manager.agent?.id == claude.id, "Save with the alert's yes makes it the Manager")
        // A second one given the role takes it from the first.
        let other = AgentProfile(name: "Claude Code · second", wake: .claudeCode(ClaudeCodeWake(repository: repository.path, executable: fake.path)),
                                 preset: "claude-code", manager: true)
        registry.upsert(other, isManager: true)
        check(registry.isManager(other) && !registry.agents.contains { $0.id == claude.id && $0.manager == true }, "one Manager at a time")
        registry.upsert(claude, isManager: true)
        claude = registry.agents.first { $0.id == claude.id } ?? claude
        check(registry.isManager(claude) && manager.agent?.id == claude.id, "and back")
        let codex = AgentProfile(name: "Codex", wake: .command(command: "true"))
        registry.upsert(codex)

        // The boards: two cards that are the same work, one long untouched, one an agent holds, one waiting on you.
        let dentist = board.create(title: "Book dentist", binderID: binder.id, column: .backlog, by: .you)
        let again = board.create(title: "Book the dentist", details: "Dr Lee, after 3pm", binderID: binder.id, column: .backlog, by: .you)
        again.links = ["https://example.com/dentist"]
        let stale = board.create(title: "Old idea", binderID: binder.id, column: .ready, by: .you)
        let held = board.create(title: "Fix the footer", binderID: binder.id, column: .ready, by: .you)
        try? board.claim(held, by: BoardActor(name: "Codex", kind: .agent))
        let waiting = board.create(title: "Pick a venue", binderID: binder.id, column: .ready, by: .you)
        try? board.move(waiting, to: .blocked, by: .you)
        let waitedOn = board.create(title: "Get the quote", binderID: binder.id, column: .backlog, by: .you)
        let after = board.create(title: "Sign the contract", binderID: binder.id, column: .backlog, by: .you)
        try? board.setWaits(after, to: [waitedOn.id], by: .you)
        let note = NoteItem(text: "# Plan\n\nShip the thing on Friday.\n")
        note.binderID = binder.id
        store.insert(note)
        func receipts() -> Int { board.cards(in: binder.id).flatMap { board.timeline($0.id) }.filter { $0.kind == .woke }.count }
        let wokenBefore = receipts()

        // A request starts the Manager: Claude Code with Binders' tools alone, in its own empty folder.
        let request = manager.ask("Tidy my Personal board", from: .iphone)
        await until { !read("manager-env.txt").isEmpty }
        check(manager.runningID == request.id && manager.request(request.id)?.status == .running, "the request is running")
        check(read("manager-prompt.txt").hasPrefix(ManagerPrompt.marker) && read("manager-prompt.txt").contains(request.id.uuidString)
              && !read("manager-prompt.txt").contains("Tidy my Personal board"), "its prompt names the request, not your words")
        let args = read("manager-args.txt").split(separator: "\n").map(String.init)
        check(args.contains("dontAsk") && args.contains("--strict-mcp-config") && args.contains("mcp__binders") && args.contains("Bash")
              && !args.contains("--worktree"), "Binders' tools alone, nothing of its own, no worktree")
        check(read("manager-pwd.txt").trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("/manager")
              && read("manager-env.txt") == request.id.uuidString, "in the Manager's own folder, for this request")
        let second = manager.ask("And what's due this week?", thread: request.id, from: .iphone)
        check(manager.request(second.id)?.status == .waiting && second.thread == request.thread, "a second one waits its turn, in the same conversation")

        // Its tools, as its server offers them for this request.
        let run = ["BINDERS_RUN": "1", "BINDERS_TOOLS": "board", "BINDERS_AGENT": claude.name, "BINDERS_CARD": request.id.uuidString,
                   "BINDERS_MANAGER": request.id.uuidString]
        for (key, value) in run { setenv(key, value, 1) }
        defer { for key in run.keys { unsetenv(key) } }
        func call(_ tool: String, _ arguments: [String: Any]) async -> (ok: Bool, text: String) {
            do { return (true, try await MCPServer.call(tool, arguments, knowledge: controller.knowledge, write: write, actor: BoardActor(name: "claude-code", kind: .agent))) }
            catch { return (false, (error as? MCPCore.ToolFailure)?.message ?? error.localizedDescription) }
        }
        let offered = Set(MCPServer.offered.map(\.name))
        check(offered == ManagerTools.offered, "its server offers the Manager's tools: \(offered.symmetricDifference(ManagerTools.offered).sorted())")
        check(await call("update_note", ["id": note.id.uuidString, "text": "x"]).text.contains("No tool named"), "no note edits of its own")
        check(await call("get_request", [:]).text.contains("Tidy my Personal board"), "get_request has your words")

        let merged = await call("merge_tasks", ["into": dentist.id.uuidString, "ids": [again.id.uuidString], "why": "Same appointment"])
        check(merged.ok && dentist.details.contains("Merged from “Book the dentist”") && dentist.details.contains("Dr Lee")
              && dentist.links == ["https://example.com/dentist"] && again.column == .done, "merge_tasks: one card with both, the other in Done (\(merged.text))")
        let closed = await call("close_task", ["id": stale.id.uuidString, "why": "No change in 90 days"])
        check(closed.ok && stale.column == .done && board.timeline(stale.id).contains { $0.text.contains("No change in 90 days") }, "close_task, saying why")
        check(await call("close_task", ["id": held.id.uuidString, "why": "x"]).text.contains("holds"), "not a card an agent holds")
        check(await call("close_task", ["id": waiting.id.uuidString, "why": "x"]).text.contains("waits on the user"), "not one waiting on you")
        check(await call("close_task", ["id": waitedOn.id.uuidString, "why": "x"]).text.contains("wait for"), "not one other cards wait for")
        let edited = await call("edit_task", ["id": dentist.id.uuidString, "title": "Book the dentist for March", "why": "Clearer"])
        check(edited.ok && dentist.title == "Book the dentist for March", "edit_task")
        let moved = await call("move_item", ["id": note.id.uuidString, "to": "Health"])
        check(moved.ok && note.folderID != nil, "move_item into a folder it makes (\(moved.text))")
        let suggested = await call("propose_note_edit", ["id": note.id.uuidString, "find": "Ship the thing", "replace": "Ship 0.12", "why": "Say which release"])
        check(suggested.ok && note.text.contains("Ship the thing") && manager.waitingSuggestions.count == 1, "a suggested edit changes nothing yet")
        check(note.editedBy == nil, "and the note stays yours")
        check(await call("comment_task", ["id": held.id.uuidString, "text": "Looks close to done."]).ok, "it may comment")
        check(receipts() == wokenBefore, "nothing it did woke an agent")

        // Someone else, or a request that isn't running, gets nothing.
        let forged = await InboxCommands.perform(InboxRequest(action: "close_task", fields: ["id": waitedOn.id.uuidString, "why": "x", "actor": "Codex",
                                                                                              "actor_kind": "agent", "manager_request": request.id.uuidString]), controller: controller)
        check(!forged.ok && waitedOn.column == .backlog, "another agent naming the request is refused")
        let wrong = await InboxCommands.perform(InboxRequest(action: "close_task", fields: ["id": waitedOn.id.uuidString, "why": "x", "actor": claude.name,
                                                                                             "actor_kind": "agent", "manager_request": second.id.uuidString]), controller: controller)
        check(!wrong.ok, "so is a request that isn't running")
        let notAllowed = await InboxCommands.perform(InboxRequest(action: "update_note", fields: ["id": note.id.uuidString, "text": "x", "actor": claude.name,
                                                                                                  "actor_kind": "agent", "manager_request": request.id.uuidString]), controller: controller)
        check(!notAllowed.ok && note.text.contains("Ship the thing"), "and a write it isn't given")

        let replied = await call("reply", ["text": "Merged the two dentist cards and closed one stale idea."])
        check(replied.ok && manager.request(request.id)?.status == .answered && manager.request(request.id)?.reply?.contains("dentist") == true, "reply answers the request")
        for key in run.keys { unsetenv(key) }
        letItEnd()
        await until { manager.runningID == second.id }
        check(manager.request(request.id)?.reply == "Merged the two dentist cards and closed one stale idea.", "its reply stands when the run ends")
        check(manager.runningID == second.id, "the next request starts when it ends")
        letItEnd()
        await until { manager.request(second.id)?.isOver == true }
        check(manager.request(second.id)?.status == .answered && manager.request(second.id)?.reply == "What it said last",
              "a run that ends without reply answers with what it said last")

        // Undo: the whole request, back as it was.
        let changes = manager.request(request.id)?.changes.map(\.kind) ?? []
        check(changes.contains(.mergedCards) && changes.contains(.closedCard) && changes.contains(.editedCard) && changes.contains(.madeFolder)
              && changes.contains(.movedItem) && changes.contains(.suggestedEdit), "each change is kept: \(changes.map(\.rawValue))")
        let undone = manager.undo(request.id)
        check(dentist.title == "Book dentist" && dentist.details.isEmpty && dentist.links.isEmpty, "Undo: the card's title and description are back (\(undone))")
        check(again.column == .backlog && stale.column == .ready, "and the merged and closed cards are where they were")
        check(note.folderID == nil && !store.allFolders().contains { $0.name == "Health" }, "and the note's back at the top, its empty folder gone")
        check(receipts() == wokenBefore, "Undo woke no one either")
        check(manager.request(request.id)?.undoable.isEmpty == true, "undone once")
        check(manager.waitingSuggestions.count == 1, "a suggestion still waits after Undo")

        // The suggestion, accepted: your edit.
        let accepted = manager.accept(manager.waitingSuggestions[0].id)
        check(note.text.contains("Ship 0.12") && note.editedBy == nil, "an accepted suggestion is your edit (\(String(describing: accepted)))")
        check(NoteHistory.entries(of: note).dropFirst().first?.by.name != claude.name, "its history says it was you")

        // Stopped before it starts, and stopped while it runs.
        let third = manager.ask("Distill the plan", from: .mac)
        await until { manager.runningID == third.id }
        manager.stop(third.id)
        await until { manager.request(third.id)?.isOver == true }
        check(manager.request(third.id)?.status == .stopped, "Stop ends a run")

        // What the phone reads.
        let object = manager.request(request.id)?.jsonObject ?? [:]
        check(object["status"] as? String == "answered" && (object["changes"] as? [Any])?.isEmpty == false && object["can_undo"] as? Bool == false,
              "the phone reads a request with its reply and changes")
        let reread = ManagerService.readFile()
        check(reread.requests.count == manager.requests.count, "the file keeps them")

        print(failures == 0 ? "MANAGER_OK" : "MANAGER_FAILED \(failures)")
        return failures == 0 ? 0 : 1
    }
}
