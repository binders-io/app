import AppKit
import Darwin
import SwiftData
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
            # As a Claude Code an organization manages: it refuses a run limited to the servers it's given.
            if [ -f "$here/manager-managed" ]; then
              for a in "$@"; do
                if [ "$a" = "--strict-mcp-config" ]; then
                  touch "$here/manager-refused"
                  echo "Error: You cannot use --strict-mcp-config when an enterprise MCP config is present" >&2
                  exit 1
                fi
              done
            fi
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
        let scratch = NoteItem(text: "# Scratch\n\nold test words\n")
        scratch.binderID = binder.id
        store.insert(scratch)
        let probe = board.create(title: "QA probe: create_task still works", binderID: binder.id, column: .backlog, by: .you)
        probe.links = ["https://example.com/probe"]
        // Distill's proposal of the plan: three items waiting.
        let items = [DistillItem(title: "Write the release notes", section: nil), DistillItem(title: "Tag the build"), DistillItem(title: "Post it")]
        let proposal = DistillRecord(note: note.id, ranBy: "You", readBy: "test", items: items)
        DistillStore.shared.save(proposal)
        func receipts() -> Int { board.cards(in: binder.id).flatMap { board.timeline($0.id) }.filter { $0.kind == .woke }.count }
        let wokenBefore = receipts()

        // A request starts the Manager: Claude Code with Binders' tools alone, in its own empty folder.
        let request = manager.ask("Tidy my Personal board", from: .iphone)
        await until { !read("manager-env.txt").isEmpty }
        check(manager.runningID == request.id && manager.request(request.id)?.status == .running, "the request is running")
        check(read("manager-prompt.txt").hasPrefix(ManagerPrompt.marker) && read("manager-prompt.txt").contains(request.id.uuidString)
              && !read("manager-prompt.txt").contains("Tidy my Personal board"), "its prompt names the request, not your words")
        let args = read("manager-args.txt").split(separator: "\n").map(String.init)
        check(args.contains("dontAsk") && args.contains("--strict-mcp-config") && args.contains("mcp__binders_manager") && args.contains("Bash")
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
        check(await call("claim_task", ["id": held.id.uuidString]).text.contains("No tool named"), "it works no card itself")
        check(await call("get_request", [:]).text.contains("Tidy my Personal board"), "get_request has your words")

        let merged = await call("merge_tasks", ["into": dentist.id.uuidString, "ids": [again.id.uuidString], "why": "Same appointment"])
        check(merged.ok && dentist.details.contains("Merged from “Book the dentist”") && dentist.details.contains("Dr Lee")
              && dentist.links == ["https://example.com/dentist"] && again.column == .done, "merge_tasks: one card with both, the other in Done (\(merged.text))")
        let closed = await call("close_task", ["id": stale.id.uuidString, "why": "No change in 90 days"])
        check(closed.ok && stale.column == .done && board.timeline(stale.id).contains { $0.text.contains("No change in 90 days") }, "close_task, saying why")
        check(await call("close_task", ["id": stale.id.uuidString, "why": "x"]).text.contains("done already"), "not one that's done already")
        let edited = await call("edit_task", ["id": dentist.id.uuidString, "title": "Book the dentist for March", "why": "Clearer"])
        check(edited.ok && dentist.title == "Book the dentist for March", "edit_task")
        let moved = await call("move_item", ["id": note.id.uuidString, "to": "Health"])
        check(moved.ok && note.folderID != nil, "move_item into a folder it makes (\(moved.text))")
        let suggested = await call("propose_note_edit", ["id": note.id.uuidString, "find": "Ship the thing", "replace": "Ship 0.12", "why": "Say which release"])
        check(suggested.ok && note.text.contains("Ship the thing") && manager.waitingSuggestions.count == 1, "a suggested edit changes nothing yet")
        check(note.editedBy == nil, "and the note stays yours")
        check(await call("comment_task", ["id": held.id.uuidString, "text": "Looks close to done."]).ok, "it may comment")

        // Complete control: cards moved, given and deleted, notes written and deleted, Distill's proposals, binders.
        let movedCard = await call("move_task", ["id": waitedOn.id.uuidString, "column": "ready", "why": "Next up"])
        check(movedCard.ok && waitedOn.column == .ready, "move_task (\(movedCard.text))")
        let given = await call("assign_task", ["id": waitedOn.id.uuidString, "to": "Sam"])
        check(given.ok && waitedOn.meantFor == "Sam", "assign_task to a person (\(given.text))")
        let deleted = await call("delete_task", ["id": probe.id.uuidString, "why": "A test card"])
        check(deleted.ok && board.card(probe.id) == nil, "delete_task (\(deleted.text))")
        let listed = await call("list_proposals", ["id": note.id.uuidString])
        check(listed.ok && listed.text.contains("Write the release notes") && listed.text.contains(proposal.id.uuidString), "list_proposals shows the waiting items")
        let placed = await call("review_proposals", ["id": note.id.uuidString, "action": "place", "items": [items[0].id.uuidString]])
        let placedCard = board.cards(in: binder.id).first { $0.title == "Write the release notes" }
        check(placed.ok && placedCard?.column == .backlog && DistillStore.shared.distill(proposal.id, of: note.id)?.waiting.count == 2,
              "review_proposals places an item in Backlog (\(placed.text))")
        let dropped = await call("review_proposals", ["id": note.id.uuidString, "action": "dismiss", "items": [items[1].id.uuidString]])
        check(dropped.ok && DistillStore.shared.distill(proposal.id, of: note.id)?.waiting.map(\.title) == ["Post it"], "and drops one (\(dropped.text))")
        let aside = await call("review_proposals", ["id": note.id.uuidString, "action": "dismiss"])
        check(aside.ok && DistillStore.shared.distill(proposal.id, of: note.id)?.status == .dismissed, "and puts the rest aside (\(aside.text))")
        let written = await call("add_note", ["text": "# Weekly review\n\nAll calm.", "binder": binder.name])
        let madeNote = ((try? store.context.fetch(FetchDescriptor<NoteItem>())) ?? []).first { $0.title == "Weekly review" }
        check(written.ok && madeNote != nil, "add_note (\(written.text))")
        let changedNote = await call("update_note", ["id": note.id.uuidString, "find": "on Friday", "replace": "on Monday"])
        check(changedNote.ok && note.text.contains("on Monday"), "update_note changes the note itself")
        let gone = await call("delete_note", ["id": scratch.id.uuidString, "why": "Old test words"])
        check(gone.ok && store.note(scratch.id) == nil, "delete_note (\(gone.text))")
        let binderName = binder.name, binderColor = binder.colorIndex
        let renamed = await call("edit_binder", ["id": binder.id.uuidString, "name": "Home", "color": (binderColor + 1) % BinderRecord.paletteSize])
        check(renamed.ok && binder.name == "Home" && binder.colorIndex != binderColor, "edit_binder (\(renamed.text))")
        let madeBinder = await call("create_binder", ["name": "Garden"])
        check(madeBinder.ok && store.binders().contains { $0.name == "Garden" }, "create_binder")
        check(receipts() == wokenBefore, "nothing it did woke an agent")

        // Someone else, or a request that isn't running, gets nothing.
        let columnBefore = waitedOn.column
        let forged = await InboxCommands.perform(InboxRequest(action: "close_task", fields: ["id": waitedOn.id.uuidString, "why": "x", "actor": "Codex",
                                                                                              "actor_kind": "agent", "manager_request": request.id.uuidString]), controller: controller)
        check(!forged.ok && waitedOn.column == columnBefore, "another agent naming the request is refused")
        let wrong = await InboxCommands.perform(InboxRequest(action: "close_task", fields: ["id": waitedOn.id.uuidString, "why": "x", "actor": claude.name,
                                                                                             "actor_kind": "agent", "manager_request": second.id.uuidString]), controller: controller)
        check(!wrong.ok, "so is a request that isn't running")
        let notAllowed = await InboxCommands.perform(InboxRequest(action: "claim_task", fields: ["id": waiting.id.uuidString, "actor": claude.name,
                                                                                                  "actor_kind": "agent", "manager_request": request.id.uuidString]), controller: controller)
        check(!notAllowed.ok && waiting.assignee == nil, "and a write it isn't given")

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
        check(waitedOn.column == .backlog && waitedOn.meantFor == nil, "the moved card is back, meant for no one")
        let back = board.cards(in: binder.id).first { $0.title == "QA probe: create_task still works" }
        check(back?.links == ["https://example.com/probe"] && back?.column == .backlog, "the deleted card is made again")
        let again2 = DistillStore.shared.distill(proposal.id, of: note.id)
        check(again2?.status == .proposed && again2?.waiting.count == 3 && !board.cards(in: binder.id).contains { $0.title == "Write the release notes" },
              "the proposal waits again, all three items, the placed card gone: \(again2?.waiting.map(\.title) ?? [])")
        check(!((try? store.context.fetch(FetchDescriptor<NoteItem>())) ?? []).contains { $0.title == "Weekly review" } && note.text.contains("on Friday"), "the note it wrote is gone and its edit undone")
        check(store.note(scratch.id)?.text.contains("old test words") == true, "the deleted note is back, with its id")
        check(binder.name == binderName && binder.colorIndex == binderColor && !store.binders().contains { $0.name == "Garden" }, "the binder is as it was, the one it made gone")

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

        // A Claude Code an organization manages refuses a run limited to Binders' tools: the Manager starts again without
        // that, once, with a hook keeping it to the Manager's tools, and later requests start that way.
        AppDefaults.store.removeObject(forKey: AgentDispatcher.refusedOnlyBindersKey)
        files.createFile(atPath: folder.appendingPathComponent("manager-managed").path, contents: Data())
        try? files.removeItem(at: folder.appendingPathComponent("manager-args.txt"))
        let managed = manager.ask("What's blocked?", from: .mac)
        await until { files.fileExists(atPath: folder.appendingPathComponent("manager-refused").path) && read("manager-args.txt").contains("pre-tool-manager") }
        let managedArgs = read("manager-args.txt")
        check(manager.runningID == managed.id && manager.request(managed.id)?.status == .running, "refused once, it starts again (\(manager.request(managed.id)?.why ?? ""))")
        check(!managedArgs.contains("--strict-mcp-config") && managedArgs.contains("--agent-hook \(ClaudeCodeToolGuard.managerHook)"),
              "without the limit, with the Manager's tool guard")
        check(!AgentDispatcher.asksOnlyBinders, "later runs start without the limit")
        letItEnd()
        await until { manager.request(managed.id)?.isOver == true }
        check(manager.request(managed.id)?.status == .answered, "and it answers")
        try? files.removeItem(at: folder.appendingPathComponent("manager-managed"))
        AppDefaults.store.removeObject(forKey: AgentDispatcher.refusedOnlyBindersKey)

        // From the iPhone, asked of the Manager you were asked about: given to another agent since, it doesn't run there.
        let elsewhere = manager.ask("What's due?", from: .iphone, askedOf: "Claude Code · second")
        await until { manager.request(elsewhere.id)?.isOver == true }
        check(manager.request(elsewhere.id)?.status == .failed && manager.request(elsewhere.id)?.why?.contains("Ask again") == true,
              "asked of another Manager than the one with the role, it doesn't run")

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
