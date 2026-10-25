import Foundation
import SwiftData
import BindersKit

extension SelfTest {
    /// Distill (lane DS1), in a throwaway folder (BINDERS_DATA_DIR) with a stand-in language model, the router's stand-in
    /// decision model, and stand-in agents (commands the test writes, as `--selftest-agent-comments` has them): a note
    /// without Distill on offers none of it; Distill, review and place some; nothing on the board before Place; waits hold
    /// an agent back and the dispatcher wakes it when the wait is Done; a section change flags exactly its cards and tells
    /// the holding agent, an agent's change held back until a person looks; putting a version back adds one and a Distill
    /// note is never trimmed; Distill again proposes only the new and the changed; propose_work_items makes no card unless
    /// the binder allows it; the MCP tools; the progress numbers; the notifications; Ask.
    ///
    ///     BINDERS_DATA_DIR=<new empty folder> Binders --selftest-distill -notesShowMarkdown NO
    @MainActor
    static func distillSelfTest() async -> Int32 {
        guard AppPaths.isDemo else {
            print("ERROR: set BINDERS_DATA_DIR to an empty folder; this test writes notes, cards and agents")
            return 1
        }
        let controller = DictationController()
        let run = DistillTestRun(controller: controller)
        let store = Store.shared
        let board = controller.board
        let service = controller.distill
        let registry = AgentRegistry.shared
        if registry.paused { registry.setPaused(false) }
        service.start()
        // Your typing is looked at when the test says, not 45 seconds later.
        service.settleDelay = .seconds(600)
        let folder = AppPaths.support

        // MARK: Stand-ins: the language model, the decision model, the agents
        let model = DistillModelStandIn()
        service.model = { model }
        let standIn = RouterStandIn()
        let standIns = RouterStandIns()
        standIns.byChoice[.tev1] = standIn
        controller.router.models = DecisionModels(choice: .tev1, measures: DecisionMeasureStore(url: folder.appendingPathComponent("distill-test-measures.json")),
                                                  fingerprints: FolderFingerprints(url: folder.appendingPathComponent("distill-test-fingerprints.json")),
                                                  makeBackend: { standIns.make($0) })
        controller.router.budget = .seconds(3)
        for title in ["Combine checkout into one page", "Check card numbers as they're typed", "Add Apple Pay and Google Pay buttons",
                      "Keep entered details and offer Retry", "Log each payment failure with its reason code", "Show a live order summary",
                      "Ship behind a flag to 10% of visitors", "Show a receipt after paying"] {
            standIn.set(title, agent: ["Echo": 0.98])
        }
        // Echo writes a WAKE line with its event and card, then the card's JSON, as --selftest-agent-comments' stand-ins do.
        let command = #"printf 'WAKE %s %s\n' "$BINDERS_EVENT" "$BINDERS_CARD" >> echo.txt; cat >> echo.txt; printf '\n' >> echo.txt"#
        let echo = AgentProfile(name: "Echo", wake: .command(command: command, folder: folder.path), wakesPerHour: 60,
                                purpose: "the checkout's web pages and payments")
        let scribe = AgentProfile(name: "Scribe", wake: .board, purpose: "writes and edits documents")
        for agent in [echo, scribe] { run.check(registry.upsert(agent) == nil, "\(agent.name) is saved") }
        let echoActor = BoardActor(name: "Echo", kind: .agent), scribeActor = BoardActor(name: "Scribe", kind: .agent)

        let web = BinderRecord(name: "Web", colorIndex: 2)
        store.insert(web)
        let spec = DistillBench.specs.first { $0.name == "Checkout redesign" }!
        let note = NoteItem(text: spec.text)
        note.binderID = web.id
        store.insert(note)
        let documentation = NoteItem(text: "# How we name releases\n\nAfter rivers.")
        documentation.binderID = web.id
        store.insert(documentation)

        // MARK: A note without Distill on offers none of it
        if case .failure(.off) = await service.distill(documentation) {
            run.check(true, "a note without Distill on can't be distilled")
        } else {
            run.check(false, "a note without Distill on can't be distilled")
        }
        run.check(model.calls == 0, "and its words never went to the model")
        run.check(DistillBoard.workList(in: web.id).isEmpty, "no note of the binder is in its Work list yet")
        let offProgress = await run.call("note_progress", ["id": documentation.id.uuidString], as: scribeActor)
        run.check(!offProgress.ok && offProgress.text.contains("Distill is off"), "note_progress says Distill is off: \(offProgress.text)")
        let offPropose = await run.call("propose_work_items", ["id": documentation.id.uuidString, "items": [["title": "A"]]], as: scribeActor)
        run.check(!offPropose.ok && offPropose.text.contains("Distill is off"), "propose_work_items is refused for it: \(offPropose.text)")
        run.check(run.object((await run.call("get_note", ["id": documentation.id.uuidString], as: scribeActor)).text)["distill"] == nil,
                  "get_note says nothing of Distill for it, as before")
        run.check(DistillStore.shared.file(for: documentation.id).distills.isEmpty, "it has no distills")
        run.check(LinkServer.features.contains(LinkFeatures.distill), "the Mac lists distill in its hello")
        if case .failure(.off) = service.distill(documentation, with: echo) {
            run.check(true, "nor can it go to an agent to distill")
        } else {
            run.check(false, "nor can it go to an agent to distill")
        }

        // MARK: Turning it on, and the Spec template
        service.setDistill(true, for: note)
        run.check(note.distill && note.properties.distill, "Distill This Note turns it on")
        run.check(TeamFiles.noteMarkdown(TeamNote(body: note.text, properties: note.properties)).contains("binders_distill: true"),
                  "it's binders_distill: true in the Markdown copy")
        run.check(run.object((await run.call("get_note", ["id": note.id.uuidString], as: scribeActor)).text)["distill"] as? Bool == true, "get_note says distill: true")
        run.check(run.list((await run.call("list_notes", ["binder": "Web"], as: scribeActor)).text).contains { $0["id"] as? String == note.id.uuidString && $0["distill"] as? Bool == true },
                  "list_notes says it too")
        let template = TemplateStore.all.first { $0.name == "Spec" }
        let fromTemplate = TemplateStore.newNote(from: template, in: web)
        run.check(fromTemplate.distill, "a note from the Spec template has Distill on")
        run.check(DistillBoard.workList(in: web.id).count == 2, "both are in the binder's Work list")
        store.delete(fromTemplate)

        // MARK: Distill, review, place some
        let first = await service.distill(note)
        guard case .success(var proposal) = first else {
            run.check(false, "Binders' model reads the note: \(first)")
            return 1
        }
        // Lane DS8: the proposal is made first; who each item is for comes after, into it.
        run.check(proposal.items.allSatisfy { $0.meantForHow != "model" } && service.suggesting.contains(proposal.id),
                  "the proposal is made before the decision model suggests anyone")
        await service.suggestionsDone(proposal.id)
        proposal = DistillStore.shared.distill(proposal.id, of: note.id) ?? proposal
        run.check(model.calls == 1, "the model was asked once")
        run.check(proposal.items.count == 8 && proposal.status == .proposed && !proposal.readByAgent, "it proposes 8 items: \(proposal.items.count)")
        run.check(proposal.items[1].waitsFor == [proposal.items[0].id], "the card check waits for the one-page form")
        run.check(proposal.items[0].section == "Payment form" && proposal.items[0].sectionHash == DistillSections.section("Payment form", in: note.text)?.hash,
                  "each item has its section and that section's version")
        run.check(proposal.items[0].meantFor == "Echo" && proposal.items[0].meantForHow == "model", "the decision model suggests Echo for the form")
        run.check(proposal.items[7].meantFor == "You" && proposal.items[7].meantForHow == "reader", "the decision about 100% is meant for you, as the reader said")
        run.check(proposal.version != nil && NoteHistory.versions(of: note.id).contains { $0.stem == proposal.version && $0.text == note.text },
                  "the version it read is kept")
        run.check(board.cards(in: web.id).isEmpty, "nothing is on the board before Place on Board")
        run.check(DistillStore.shared.file(for: note.id).proposal?.id == proposal.id, "the proposal waits for review")

        // The review: drop one, and edit another's title.
        var reviewed = proposal
        reviewed.items[4].dropped = true
        reviewed.items[2].title = "Add the Apple Pay and Google Pay buttons"
        service.save(reviewed)
        let chosen: Set<UUID> = [reviewed.items[0].id, reviewed.items[1].id, reviewed.items[3].id, reviewed.items[5].id, reviewed.items[7].id]
        let placed = service.place(reviewed, items: chosen, column: .ready)
        run.check(placed.count == 5, "Place on Board places the 5 ticked: \(placed.count)")
        guard placed.count == 5 else { return 1 }
        let form = placed[0], cardCheck = placed[1], decision = placed[4]
        let after = DistillStore.shared.distill(proposal.id, of: note.id)
        run.check(after?.status == .proposed && after?.waiting.count == 2, "the 2 not ticked stay in the proposal: \(after?.waiting.count ?? -1)")
        run.check(after?.items[4].card == nil && after?.items[4].dropped == true, "the dropped one stays out")
        run.check(board.cards(in: web.id).count == 5, "the board has the 5 cards")
        run.check(placed.allSatisfy { $0.column == .ready && $0.sourceKind == "note" && $0.sourceID == note.id.uuidString }, "in Ready, from the note")
        run.check(cardCheck.waitsFor == [form.id.uuidString], "the card check waits for the form's card, as placed")
        run.check(decision.waitsFor.isEmpty, "a wait on an item not placed is left out")
        run.check(form.meantFor == "Echo" && !form.meantForByAgent, "meant for Echo, by you")
        run.check(decision.meantFor == "You" && !decision.meantForByAgent, "the decision is meant for you")
        run.check(form.details.contains("Distilled from [Checkout redesign](binders://note/\(note.id.uuidString)?section=Payment%20form)"),
                  "each card links back to its section: \(form.details.suffix(140))")
        run.check(form.details.contains("**Done when:**"), "with what done looks like")
        run.check(form.distilledFrom?.section == "Payment form" && form.distilledFrom?.version == proposal.version && form.distilledFrom?.sectionHash != nil,
                  "and records its section and that section's version")
        run.check(board.timeline(cardCheck.id).contains { $0.kind == .edited && $0.text.hasPrefix("Waits for “Combine checkout into one page”") },
                  "the card says what it waits for")
        run.check(DistillService.versionMark(proposal.id, note: note.id) == "Distilled by Binders' model (stand-in), 5 items placed",
                  "the version it read says so: \(DistillService.versionMark(proposal.id, note: note.id) ?? "none")")

        // MARK: Waits hold an agent back; the dispatcher wakes it when the wait is Done
        await run.waitFor(1, card: form.id)
        await run.gathered()
        run.check(run.wakes(card: form.id).map(\.line) == ["ready \(form.id.uuidString)"], "Echo is woken for the form, which waits for nothing")
        run.check(run.wakes(card: cardCheck.id).isEmpty, "and not for the card check, which waits for the form")
        run.check(controller.agents.outcomes[cardCheck.id]?.message == "Waits for “Combine checkout into one page”. Binders wakes Echo once it's done.",
                  "the card says why: \(controller.agents.outcomes[cardCheck.id]?.message ?? "none")")
        run.check(controller.agents.wakeNow(cardCheck)?.hasPrefix("Waits for “Combine checkout into one page”") == true, "Wake Now says the same")
        let refused = await run.call("claim_task", ["id": cardCheck.id.uuidString], as: echoActor)
        run.check(!refused.ok && refused.text.contains("waits for “Combine checkout into one page”"), "Echo can't claim it: \(refused.text)")
        let moved = await run.call("update_task", ["id": cardCheck.id.uuidString, "column": "in_progress"], as: echoActor)
        run.check(!moved.ok && cardCheck.column == .ready, "nor take it by moving it: \(moved.text)")
        let listed = run.list((await run.call("list_tasks", ["binder": "Web"], as: echoActor)).text).first { $0["id"] as? String == cardCheck.id.uuidString }
        run.check((listed?["waits_for"] as? [[String: Any]])?.first?["title"] as? String == "Combine checkout into one page",
                  "list_tasks says what it waits for")
        run.check((listed?["distilled_from"] as? [String: Any])?["section"] as? String == "Payment form", "and what it was distilled from")
        // A person still can take a card that waits.
        let personCard = board.create(title: "Write the checkout copy", binderID: web.id, column: .ready, by: .you)
        try? board.setWaits(personCard, to: [form.id], by: .you)
        run.check((try? board.claim(personCard, by: .you)) != nil && personCard.column == .inProgress, "a person can take a card that still waits")
        board.delete(personCard)
        // A card never waits for itself, directly or through others.
        do {
            try board.setWaits(form, to: [cardCheck.id], by: .you)
            run.check(false, "the form can't wait for the card check, which waits for it")
        } catch {
            run.check(error.localizedDescription.contains("can't wait for itself"), "a circle is refused: \(error.localizedDescription)")
        }
        do {
            try board.setWaits(form, to: [form.id], by: .you)
            run.check(false, "a card can't wait for itself")
        } catch {
            run.check(true, "a card can't wait for itself")
        }

        // Echo does the form; you approve it; the card check is woken.
        run.check((await run.call("claim_task", ["id": form.id.uuidString], as: echoActor)).ok, "Echo claims the form")
        run.check((await run.call("complete_task", ["id": form.id.uuidString, "summary": "One page now."], as: echoActor)).ok && form.column == .review,
                  "and hands it over for review")
        try? board.move(form, to: .done, by: .you)
        await run.waitFor(1, card: cardCheck.id)
        run.check(run.wakes(card: cardCheck.id).map(\.line) == ["ready \(cardCheck.id.uuidString)"], "once the form is Done, Echo is woken for the card check")
        run.check(board.timeline(cardCheck.id).contains { $0.text == "“Combine checkout into one page” is done, so this card is ready for Echo." },
                  "and the card says why")
        run.check((await run.call("claim_task", ["id": cardCheck.id.uuidString], as: echoActor)).ok && cardCheck.column == .inProgress, "Echo can claim it now")

        await distillSelfTestPartTwo(run, note: note, web: web, proposal: proposal, placed: placed, model: model)
        // Lane DS8: the same with v2's stand-in.
        await distillFastChecks(run, router: standIn)
        return run.failures == 0 ? 0 : 1
    }
}

/// What the Distill self-test works with: its checks, the MCP tools as an agent or you, and what the stand-in agent heard.
@MainActor
final class DistillTestRun {
    private(set) var failures = 0
    let controller: DictationController
    let write: MCPServer.Writer
    let folder = AppPaths.support

    init(controller: DictationController) {
        self.controller = controller
        write = MCPServer.writeInApp(controller: controller)
    }

    func check(_ condition: Bool, _ label: String) {
        print("\(condition ? "PASS" : "FAIL"): \(label)")
        if !condition { failures += 1 }
    }

    /// A tool, as `actor`, from a tool that may read what `reads` allows (Settings → MCP).
    func call(_ tool: String, _ arguments: [String: Any], as actor: BoardActor, reads: MCPServer.Reads = .everything) async -> (ok: Bool, text: String) {
        do { return (true, try await MCPServer.call(tool, arguments, knowledge: controller.knowledge, write: write, actor: actor, reads: reads)) }
        catch { return (false, (error as? MCPCore.ToolFailure)?.message ?? error.localizedDescription) }
    }

    func object(_ text: String) -> [String: Any] { (try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]) ?? [:] }
    func list(_ text: String) -> [[String: Any]] { (try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]]) ?? [] }

    /// What Echo heard for a card: each wake's line ("ready <card>") and the card's JSON that came with it.
    func wakes(card: UUID) -> [(line: String, json: [String: Any])] {
        let lines = ((try? String(contentsOf: folder.appendingPathComponent("echo.txt"), encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        var found: [(line: String, json: [String: Any])] = []
        for (index, line) in lines.enumerated() where line.hasPrefix("WAKE ") && line.hasSuffix(card.uuidString) {
            let next = lines.indices.contains(index + 1) ? lines[index + 1] : ""
            found.append((String(line.dropFirst("WAKE ".count)), object(next)))
        }
        return found
    }

    /// Until Echo has heard `count` wakes for the card, with their JSON, or `seconds`.
    func waitFor(_ count: Int, card: UUID, seconds: Int = 8) async {
        for _ in 0..<(seconds * 10) {
            let got = wakes(card: card)
            if got.count >= count, got.allSatisfy({ !$0.json.isEmpty }) { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// The moment a wake gathers for, and a little more.
    func gathered() async { try? await Task.sleep(for: .milliseconds(2600)) }
}

/// Stands in for the language model in the Distill self-test: the bench's checkout reply for the note as it was written,
/// another once the note has its Receipts section, counting its calls.
final class DistillModelStandIn: LLMClient, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var calls: Int { lock.withLock { count } }

    var model: String { "stand-in" }

    func complete(system: String, user: String, maxTokens: Int, temperature: Double, timeout: TimeInterval) async throws -> String {
        lock.withLock { count += 1 }
        return Self.reply(to: user)
    }

    func stream(system: String, user: String, maxTokens: Int, temperature: Double, timeout: TimeInterval,
                stopWhen: @escaping @Sendable (String) -> Bool) async throws -> String {
        lock.withLock { count += 1 }
        return Self.reply(to: user)
    }

    func listModels() async throws -> [String] { [model] }
    func warmUp() async {}

    static func reply(to user: String) -> String {
        guard user.contains("## Receipts") else { return first }
        return again
    }

    /// The checkout spec as written: the bench's clean reply.
    static let first = """
        [
          {"title": "Combine checkout into one page", "brief": "Put address, delivery and card on one page instead of three.", "done_when": "Checkout is a single page with all three parts.", "section": "Payment form", "waits_for": [], "size": "medium", "for": "agent"},
          {"title": "Check card numbers as they're typed", "brief": "Validate the card number while typing and show the error under the field.", "done_when": "A wrong number shows an error under the field.", "section": "Payment form", "waits_for": [1], "size": "small", "for": "agent"},
          {"title": "Add Apple Pay and Google Pay buttons", "brief": "Show both buttons above the form.", "done_when": "Both buttons appear above the form.", "section": "Payment form", "waits_for": [1], "size": "medium", "for": "agent"},
          {"title": "Keep entered details and offer Retry", "brief": "When the bank declines or the connection drops, keep what was typed and offer Retry.", "done_when": "A failed payment keeps the form filled and shows Retry.", "section": "Retry after a failed payment", "waits_for": [], "size": "medium", "for": "agent"},
          {"title": "Log each payment failure with its reason code", "brief": "Every failed payment is logged with its reason code.", "done_when": "Failures show in the log with reason codes.", "section": "Retry after a failed payment", "waits_for": [], "size": "small", "for": "agent"},
          {"title": "Show a live order summary", "brief": "Items, delivery cost and total beside the form.", "done_when": "Changing delivery updates the total.", "section": "Order summary", "waits_for": [], "size": "small", "for": "agent"},
          {"title": "Ship behind a flag to 10% of visitors", "brief": "Release the new checkout to 10% once the form, retry and summary are done.", "done_when": "10% of visitors see it.", "section": "Rollout", "waits_for": [1, 4, 6], "size": "small", "for": "agent"},
          {"title": "Compare abandonment and decide on 100%", "brief": "After two weeks, compare abandonment and decide.", "done_when": "A decision is written down.", "section": "Rollout", "waits_for": [7], "size": "small", "for": "person"}
        ]
        """

    /// After the note changed: its Order summary now shows tax too, Rollout is gone and Receipts is new. The same items
    /// come back for what didn't change, as a model reads the whole note again.
    static let again = """
        [
          {"title": "Combine checkout into one page", "brief": "One page.", "section": "Payment form", "for": "agent"},
          {"title": "Check card numbers as they're typed", "brief": "Validate as typed.", "section": "Payment form", "waits_for": [1], "for": "agent"},
          {"title": "Show a live order summary", "brief": "Items, delivery cost, tax and total beside the form.", "done_when": "Changing delivery updates the tax and total.", "section": "Order summary", "for": "agent"},
          {"title": "Show a receipt after paying", "brief": "A receipt page with the order number, and the same by email.", "done_when": "Paying shows the receipt and sends it.", "section": "Receipts", "for": "agent"}
        ]
        """
}
