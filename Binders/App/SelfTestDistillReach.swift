import Foundation
import SwiftData
import BindersKit

extension SelfTest {
    /// Distill, finished (lane RF2), in a throwaway folder (BINDERS_DATA_DIR) with the stand-ins `--selftest-distill` has: what
    /// of a section's change reaches the agent holding a card, in its wake and in get_task (your change with its lines; a
    /// teammate's lines only to an agent that may read teammates' items, any other hearing who, where and how much; another
    /// agent's lines never, before or after you look), then Distill's smaller gaps (`distillFinishChecks`).
    ///
    ///     BINDERS_DATA_DIR=<new empty folder> Binders --selftest-distill-more -notesShowMarkdown NO
    @MainActor
    static func distillMoreSelfTest() async -> Int32 {
        guard AppPaths.isDemo else {
            print("ERROR: set BINDERS_DATA_DIR to an empty folder; this test writes notes, cards and agents")
            return 1
        }
        let controller = DictationController()
        let run = DistillTestRun(controller: controller)
        let store = Store.shared
        let service = controller.distill
        let registry = AgentRegistry.shared
        if registry.paused { registry.setPaused(false) }
        service.start()
        // Your typing is looked at when the test says, not 45 seconds later.
        service.settleDelay = .seconds(600)
        let folder = AppPaths.support

        // The stand-ins: the language model, the decision model, and Echo, which writes what each wake carried.
        let model = DistillModelStandIn()
        service.model = { model }
        let standIn = RouterStandIn()
        let standIns = RouterStandIns()
        standIns.byChoice[.tev1] = standIn
        controller.router.models = DecisionModels(choice: .tev1, measures: DecisionMeasureStore(url: folder.appendingPathComponent("distill-more-measures.json")),
                                                  fingerprints: FolderFingerprints(url: folder.appendingPathComponent("distill-more-fingerprints.json")),
                                                  makeBackend: { standIns.make($0) })
        controller.router.budget = .seconds(3)
        for title in ["Combine checkout into one page", "Check card numbers as they're typed", "Add Apple Pay and Google Pay buttons",
                      "Keep entered details and offer Retry", "Log each payment failure with its reason code", "Show a live order summary",
                      "Ship behind a flag to 10% of visitors"] {
            standIn.set(title, agent: ["Echo": 0.98])
        }
        let command = #"printf 'WAKE %s %s\n' "$BINDERS_EVENT" "$BINDERS_CARD" >> echo.txt; cat >> echo.txt; printf '\n' >> echo.txt"#
        let echo = AgentProfile(name: "Echo", wake: .command(command: command, folder: folder.path), wakesPerHour: 60,
                                purpose: "the checkout's web pages and payments")
        let scribe = AgentProfile(name: "Scribe", wake: .board, purpose: "writes and edits documents")
        for agent in [echo, scribe] { run.check(registry.upsert(agent) == nil, "\(agent.name) is saved") }

        let web = BinderRecord(name: "Web", colorIndex: 2)
        store.insert(web)
        let note = NoteItem(text: DistillBench.specs.first { $0.name == "Checkout redesign" }!.text)
        note.binderID = web.id
        store.insert(note)
        service.setDistill(true, for: note)
        guard case .success(var proposal) = await service.distill(note) else {
            run.check(false, "Binders' model reads the note")
            return 1
        }
        // Lane DS8: who each is for comes after the proposal.
        await service.suggestionsDone(proposal.id)
        proposal = DistillStore.shared.distill(proposal.id, of: note.id) ?? proposal
        let placed = service.place(proposal, items: Set(proposal.items.map(\.id)), column: .ready)
        run.check(placed.count == 8, "its 8 items are on the board: \(placed.count)")
        guard placed.count == 8 else { return 1 }

        await distillReachChecks(run, note: note, cards: placed)
        await distillFinishChecks(run, note: note, web: web, cards: placed, router: standIn)
        print(run.failures == 0 ? "DISTILL_MORE_OK" : "DISTILL_MORE_FAILED: \(run.failures)")
        return run.failures == 0 ? 0 : 1
    }

    /// What of a section's change reaches Echo, holding the form's card: in what its wakes carry, and in get_task's
    /// timeline from a tool that may or may not read teammates' items.
    @MainActor
    static func distillReachChecks(_ run: DistillTestRun, note: NoteItem, cards: [TaskCard]) async {
        let controller = run.controller
        let board = controller.board
        let service = controller.distill
        let echoActor = BoardActor(name: "Echo", kind: .agent), scribeActor = BoardActor(name: "Scribe", kind: .agent)
        let form = cards[0]
        let noTeam = MCPServer.Reads(captures: true, transcripts: true, team: false)
        /// The lines by Binders that say the card's section changed, oldest first.
        func lines(_ card: TaskCard) -> [TaskEvent] {
            board.timeline(card.id).filter { $0.author == BoardService.binders.name && $0.sectionChange != nil }
        }
        /// get_task's timeline, its texts, for `actor` from a tool that may read `reads`.
        func timeline(_ card: TaskCard, as actor: BoardActor, reads: MCPServer.Reads) async -> [String] {
            let reply = run.object((await run.call("get_task", ["id": card.id.uuidString], as: actor, reads: reads)).text)
            return (reply["timeline"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
        }
        /// What Echo's latest wake for the card carried.
        func told(_ card: TaskCard) -> String { run.wakes(card: card.id).last?.json["answer"] as? String ?? "" }
        /// You change the note, and it's looked at now rather than once your typing settles.
        func type(_ find: String, _ replace: String) {
            let before = note.text
            note.text = before.replacingOccurrences(of: find, with: replace)
            NoteHistory.changed(note.id, previous: before, by: .you)
            service.settleNow(note.id)
        }
        /// Sam's change arrives through the team folder, as the team's sync lands it.
        func teammate(_ find: String, _ replace: String) async {
            let changed = note.text.replacingOccurrences(of: find, with: replace)
            NoteHistory.willChange(note, to: changed, always: true, by: .teammate("Sam"))
            note.text = changed
            try? await Task.sleep(for: .milliseconds(300))
        }

        await run.waitFor(1, card: form.id)
        run.check((await run.call("claim_task", ["id": form.id.uuidString], as: echoActor)).ok, "Echo holds the form's card")

        // MARK: Your change: its lines reach the agent, in its wake and in get_task
        type("- Apple Pay and Google Pay buttons above the form.", "- Apple Pay and Google Pay buttons above the form.\n- Show the card's brand as it's typed.")
        let yours = lines(form).last
        run.check(yours?.text.contains("by you") == true && yours?.text.contains("\n+ - Show the card's brand as it's typed.") == true,
                  "the card says what you changed: \(yours?.text ?? "nothing")")
        run.check(SectionChangeMark(json: yours?.sectionChange)?.kind == .person, "and that the change was yours")
        await run.waitFor(2, card: form.id)
        run.check(run.wakes(card: form.id).last?.line == "commented \(form.id.uuidString)" && told(form).contains("Show the card's brand"),
                  "Echo is woken with your lines: \(told(form).prefix(160))")
        let yoursShown = await timeline(form, as: echoActor, reads: noTeam)
        run.check(yoursShown.contains { $0.contains("+ - Show the card's brand as it's typed.") }, "get_task gives Echo your lines, whatever it may read")

        // MARK: A teammate's change, teammates' items kept from the agent: who, where and how much, never the lines
        controller.agents.readsTeam = { _ in false }
        let samWords = "Show the delivery date beside the card field."
        await teammate("- Show the card's brand as it's typed.", "- Show the card's brand as it's typed.\n- \(samWords)")
        let sams = lines(form).last
        run.check(sams?.text.contains("by Sam, 1 line added") == true && sams?.text.contains(samWords) == true,
                  "the card shows people Sam's lines: \(sams?.text ?? "nothing")")
        run.check(sams?.text.contains("Show the card's brand") == false, "only Sam's change, not yours before it")
        run.check(SectionChangeMark(json: sams?.sectionChange)?.kind == .teammate, "and that the change was a teammate's")
        await run.waitFor(3, card: form.id)
        run.check(!told(form).contains(samWords), "Echo, which may not read teammates' items, isn't woken with Sam's lines: \(told(form).prefix(220))")
        run.check(told(form).contains("Payment form section") && told(form).contains("by Sam, 1 line added") && told(form).contains("get_note_version"),
                  "it hears who changed which section, how much, and where to read it")
        let samShown = await timeline(form, as: echoActor, reads: noTeam)
        run.check(!samShown.contains { $0.contains(samWords) }, "get_task doesn't give Sam's lines to a tool that may not read teammates' items")
        run.check(samShown.contains { $0.contains("by Sam, 1 line added") && $0.contains("get_note_version") }, "it says who, how much and where to read it")
        run.check(await timeline(form, as: .you, reads: noTeam).contains { $0.contains(samWords) }, "your iPhone, which is you, shows you every line")

        // MARK: Teammates' items allowed: the lines
        controller.agents.readsTeam = { _ in true }
        let samMore = "Keep the Pay button in sight while scrolling."
        await teammate("- \(samWords)", "- \(samWords)\n- \(samMore)")
        await run.waitFor(4, card: form.id)
        run.check(told(form).contains(samMore), "an agent that may read teammates' items is woken with their lines")
        run.check(await timeline(form, as: echoActor, reads: .everything).contains { $0.contains(samMore) }, "and get_task gives them to such a tool")
        controller.agents.readsTeam = { _ in false }

        // MARK: Another agent's change: never its lines, before or after you look
        let scribeWords = "Say why the payment failed, in plain words."
        let wakes = run.wakes(card: form.id).count
        let edited = await run.call("update_note", ["id": note.id.uuidString, "find": "- \(samMore)", "replace": "- \(samMore)\n- \(scribeWords)"], as: scribeActor)
        run.check(edited.ok, "Scribe changes the Payment form section: \(edited.text.prefix(80))")
        try? await Task.sleep(for: .milliseconds(300))
        let scribes = lines(form).last
        run.check(scribes?.text.contains(scribeWords) == true && scribes?.text.contains("by Scribe (your agent)") == true,
                  "the card shows people Scribe's change: \(scribes?.text ?? "nothing")")
        run.check(form.distilledFrom?.held == true && SectionChangeMark(json: scribes?.sectionChange)?.held == true, "held for a person to look")
        await run.gathered()
        run.check(run.wakes(card: form.id).count == wakes, "Echo isn't woken for it")
        let held = await timeline(form, as: echoActor, reads: .everything)
        run.check(!held.contains { $0.contains(scribeWords) || $0.contains("by Scribe") }, "get_task gives Echo nothing of it before you look")
        let heldTask = run.object((await run.call("get_task", ["id": form.id.uuidString], as: echoActor)).text)
        run.check((heldTask["distilled_from"] as? [String: Any])?["section_changed"] == nil, "nor that the section changed")
        service.passOn(form)
        await run.waitFor(wakes + 1, card: form.id)
        run.check(told(form).contains("by Scribe (your agent): 1 line added, and the user has looked at it"),
                  "once you looked, Echo hears who and how much: \(told(form).prefix(200))")
        run.check(!told(form).contains(scribeWords), "never Scribe's words")
        let after = await timeline(form, as: echoActor, reads: .everything)
        run.check(after.contains { $0.contains("by Scribe (your agent), 1 line added") && $0.contains("get_note_version") },
                  "get_task now says Scribe changed it, how much, and where to read it")
        run.check(!after.contains { $0.contains(scribeWords) }, "but not what Scribe wrote")
        run.check(SectionChangeMark(json: lines(form).last?.sectionChange)?.held == false, "its line waits for no one now")

        // MARK: Your change after an agent's: only yours
        type("- \(scribeWords)", "- \(scribeWords)\n- Show the total on the Pay button.")
        await run.waitFor(wakes + 2, card: form.id)
        run.check(told(form).contains("Show the total on the Pay button.") && !told(form).contains(scribeWords),
                  "your next change reaches Echo without Scribe's words: \(told(form).prefix(200))")
        run.check(lines(form).last?.text.contains(scribeWords) == false, "each line holds its own change")
        let progress = (await run.call("note_progress", ["id": note.id.uuidString], as: echoActor, reads: noTeam)).text
        run.check(!progress.contains(samWords) && !progress.contains(scribeWords) && progress.contains("Payment form"),
                  "note_progress says which sections changed and by whom, never anyone's lines")
    }
}
