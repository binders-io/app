import Foundation
import SwiftData
import BindersKit

extension SelfTest {
    /// The rest of `--selftest-distill-more`, Distill's smaller gaps: the review sheet's link to each item's section, who an
    /// item is meant for (a sure nobody is you, a teammate named in `for`), editing sessions in History, the Work panel's
    /// column and last update, whom a card waits on, a spec's blocked card ringing once, the Work bar's section line, a
    /// Distill again of only changes staying reviewable, and undoing a rename's links kept in history.
    @MainActor
    static func distillFinishChecks(_ run: DistillTestRun, note: NoteItem, web: BinderRecord, cards: [TaskCard], router: RouterStandIn) async {
        let controller = run.controller
        let board = controller.board
        let service = controller.distill
        let echoActor = BoardActor(name: "Echo", kind: .agent), scribeActor = BoardActor(name: "Scribe", kind: .agent)
        let form = cards[0], retry = cards[3], log = cards[4], summary = cards[5], decision = cards[7]

        // MARK: The review sheet: each item's section links to its heading, as its card's link does
        let link = DistillItemEditor.sectionLink(note: note.id, section: "Payment form")
        run.check(link?.absoluteString == DistillLinks.section(note: note.id, heading: "Payment form") && form.details.contains(link?.absoluteString ?? "-"),
                  "an item's section links where its card's link goes: \(link?.absoluteString ?? "none")")
        if let link { URLCommands.handle(link, controller: controller) }
        let navigation = HubWindowController.shared.navigation
        run.check(navigation.pendingNoteID == note.id && navigation.pendingNotePlace == "Payment form", "and opens the note at that heading")
        navigation.pendingNoteID = nil
        navigation.pendingNotePlace = nil
        run.check(DistillItemEditor.sectionLink(note: note.id, section: nil)?.absoluteString == NoteCards.link(noteID: note.id.uuidString),
                  "the note's opening links to the note")

        // MARK: Who it's for: sure no agent fits, you; a teammate named in for, them
        service.teamPeopleOverride = { _ in ["Sam Lee", "Dana"] }
        let people = service.people(for: web.id)
        run.check(people.contains("Echo") && people.contains("You") && people.contains("Sam Lee") && people.contains("Dana"),
                  "the For list has your agents, you and the team's people: \(people)")
        router.set("Call the bank about the new card terms", agent: [RouterQuestions.nobody: 0.96])
        let proposed = await run.call("propose_work_items", ["id": note.id.uuidString, "items": [
            ["title": "Call the bank about the new card terms", "section": "Payment form", "for": "either"],
            ["title": "Pick the wording of the card errors", "section": "Payment form", "for": "either"],
            ["title": "Sign off the checkout copy", "section": "Payment form", "for": "Sam"],
            ["title": "Write the release note", "section": "Rollout", "for": "dana"],
        ]], as: scribeActor)
        let proposal = DistillStore.shared.file(for: note.id).distills.last
        func meant(_ title: String) -> String { proposal?.items.first { $0.title == title }.map { "\($0.meantFor ?? "no one") by \($0.meantForHow ?? "-")" } ?? "missing" }
        run.check(proposed.ok && meant("Call the bank about the new card terms") == "You by model",
                  "the router sure that no agent fits: meant for you (\(meant("Call the bank about the new card terms")))")
        run.check(meant("Pick the wording of the card errors") == "no one by -", "unsure: no one, as before (\(meant("Pick the wording of the card errors")))")
        run.check(meant("Sign off the checkout copy") == "Sam Lee by reader", "a teammate named in for is matched (\(meant("Sign off the checkout copy")))")
        run.check(meant("Write the release note") == "Dana by reader", "whatever the case it's written in (\(meant("Write the release note")))")
        router.set("Phone the payment provider", agent: [RouterQuestions.nobody: 0.96])
        router.usable = false
        _ = await run.call("propose_work_items", ["id": note.id.uuidString, "items": [["title": "Phone the payment provider", "section": "Payment form"]]],
                           as: scribeActor)
        let unmodelled = DistillStore.shared.file(for: note.id).distills.last?.items.first { $0.title == "Phone the payment provider" }
        run.check(unmodelled != nil && unmodelled?.meantFor == nil, "without a decision model, no one")
        router.usable = true
        service.teamPeopleOverride = nil
        // Put aside, so the Distill again below is the one waiting.
        for record in DistillStore.shared.file(for: note.id).distills where record.status == .proposed { service.dismiss(record) }

        // MARK: History: a version is one editing session
        let plain = NoteItem(text: "# Plain\n\nOne.")
        plain.binderID = web.id
        Store.shared.insert(plain)
        NoteHistory.keep("# Plain\n\nZero.", for: plain.id, at: Date().addingTimeInterval(-86_400))
        func typePlain(_ line: String, by author: NoteAuthor = .you, always: Bool = false) {
            let before = plain.text
            plain.text = before + "\n" + line
            NoteHistory.changed(plain.id, previous: before, always: always, by: author)
        }
        func count() -> Int { NoteHistory.versions(of: plain.id).count }
        typePlain("Two.")
        let first = count()
        run.check(first == 2, "the first change of a session keeps what was there: \(first) versions")
        typePlain("Three.")
        run.check(count() == first, "typing on is the same session: no version every few minutes")
        NoteHistory.endSession(plain.id)
        let ended = NoteHistory.versions(of: plain.id)
        run.check(ended.count == first + 1 && ended.first?.text == plain.text, "leaving the note keeps what the session made")
        typePlain("Four.")
        run.check(count() == first + 1, "coming back begins a session with nothing new to keep")
        typePlain("Five.", by: .agent("Scribe"), always: true)
        run.check(count() == first + 2 && NoteHistory.versions(of: plain.id).first?.text.hasSuffix("Four.") == true, "someone else's edit ends your session")
        NoteHistory.endSession(plain.id)
        run.check(count() == first + 2, "your leaving doesn't end the agent's session")
        typePlain("Six.")
        run.check(count() == first + 3 && NoteHistory.versions(of: plain.id).first?.text.hasSuffix("Five.") == true, "and your typing after it ends theirs")
        run.check(NoteHistory.versions(of: plain.id).contains { $0.text == "# Plain\n\nZero." }, "a version kept before stays as it is")
        // Each version's lines are its own change, from the one before it.
        let entries = NoteHistory.entries(of: plain)
        let session = entries.first { $0.id == ended.first?.stem }
        run.check(session?.added == 2 && session?.removed == 0, "the session's version counts its own 2 lines, not those since: \(session?.added ?? -1)")
        run.check(NoteHistory.entries(of: note).contains { $0.sections.contains("Payment form") }, "a version says the sections it touched")
        run.check(NoteHistorySheet.sectionsLabel(["Payment form"]) == "In Payment form"
                  && NoteHistorySheet.sectionsLabel(["A", "B", "C", "D"]) == "In A, B and 2 more" && NoteHistorySheet.sectionsLabel([]) == nil,
                  "History says them: \(NoteHistorySheet.sectionsLabel(["A", "B", "C", "D"]) ?? "nothing")")

        // MARK: The Work panel: each card's column, and its last update with its time, beside what its agent says
        _ = await run.call("update_task", ["id": form.id.uuidString, "progress": "Halfway through the form."], as: echoActor)
        let item = DistillBoard.progress(of: note).items.first { $0.card == form.id.uuidString }
        run.check(item?.columnTitle == "In progress" && item?.lastUpdate == "Halfway through the form." && item?.lastUpdateAt != nil,
                  "an item has its column and its last update's time: \(item?.columnTitle ?? "none"), \(item?.lastUpdateAt ?? "none")")
        let lastLine = item.flatMap { WorkItemRow.lastUpdateLine($0) } ?? ""
        run.check(lastLine.hasPrefix("Last update just now: Halfway through the form.") && lastLine.hasSuffix(" · Echo"),
                  "the panel says when: \(lastLine)")
        if var saying = item {
            saying.doing = "Running the form's tests"
            run.check(WorkItemRow.lastUpdateLine(saying) != nil, "beside what its agent says it's doing, not instead of it")
        }
        let waiting = DistillBoard.progress(of: note).items.first { $0.card == decision.id.uuidString }
        run.check(waiting?.columnTitle == "Ready" && waiting.map { WorkItemRow.stateWord($0) } == "Held up", "a held-up card in Ready says both")

        // MARK: A spec's card blocked on you with only a reason rings once; never again for what the board rang for
        let waitsTitle = "“\(note.title)” waits on you"
        func rang() -> Int { service.posted.filter { $0 == waitsTitle }.count }
        service.boardChanged()
        let before = rang()
        run.check((await run.call("claim_task", ["id": log.id.uuidString], as: echoActor)).ok, "Echo takes the logging card")
        try? board.move(log, to: .blocked, by: echoActor, note: "Waiting for the logging service's key.")
        service.boardChanged()
        run.check(rang() == before + 1, "Echo blocks it with only a reason: it rings (\(service.posted.suffix(2)))")
        service.boardChanged()
        run.check(rang() == before + 1, "once")
        run.check((await run.call("claim_task", ["id": retry.id.uuidString], as: echoActor)).ok, "Echo takes the retry card")
        controller.agents.saidBlocked(retry.id)
        try? board.move(retry, to: .blocked, by: echoActor, note: "Its run ended before it finished.")
        service.boardChanged()
        run.check(rang() == before + 1, "not for a run's end, whose stop rang already")
        try? board.move(summary, to: .blocked, by: .you, note: "Waiting on the designs.")
        service.boardChanged()
        run.check(rang() == before + 1, "nor for a card you blocked yourself")
        let asked = await run.call("ask_on_task", ["id": form.id.uuidString, "question": "Should saved cards show here too?"], as: echoActor)
        service.boardChanged()
        run.check(asked.ok && form.column == .blocked && rang() == before + 1, "nor for a question, which rings on its own")

        // MARK: The Work bar says who changed a section, when, and how much
        let changedLine = DistillBoard.progress(of: note).report.sections.first { $0.section == "Payment form" }.map { WorkBar.sectionLine($0) } ?? ""
        run.check(changedLine.hasPrefix("The Payment form section changed by you, ") && changedLine.contains(": 1 line added."),
                  "the Work bar's line: \(changedLine)")

        // MARK: Distill again that only offers to update cards stays reviewable until it's placed or put aside
        let beforeSummary = note.text
        note.text = beforeSummary.replacingOccurrences(of: "Show the items, the delivery cost and the total", with: "Show the items, the delivery cost, the tax and the total")
        NoteHistory.changed(note.id, previous: beforeSummary, by: .you)
        service.settleNow(note.id)
        guard case .success(let again) = await service.distill(note) else {
            run.check(false, "Distill again reads the note")
            return
        }
        run.check(again.items.isEmpty && !again.updates.isEmpty && again.status == .proposed,
                  "it offers only changes to cards on the board: \(again.items.count) items, \(again.updates.count) changes")
        run.check(DistillStore.shared.file(for: note.id).proposal?.id == again.id, "Review is on the Work bar")
        service.save(again)
        run.check(DistillStore.shared.file(for: note.id).proposal?.id == again.id, "and still after Not Now")
        run.check(WorkBar.waitingLine(again).hasPrefix("\(again.updates.count) changes to cards on the board wait for your review"),
                  "the Work bar says what waits: \(WorkBar.waitingLine(again))")
        run.check(DistillBoard.progress(of: note).proposed == again.updates.count, "and so does the Work list: \(DistillBoard.progress(of: note).proposed ?? 0)")
        service.take(again.updates[0], of: again)
        run.check(DistillStore.shared.file(for: note.id).proposal?.id == again.id || again.updates.count == 1, "one taken, the rest still wait")
        for update in again.updates.dropFirst() { service.leave(update, of: again) }
        let settled = DistillStore.shared.distill(again.id, of: note.id)
        run.check(settled?.status == .placed && DistillStore.shared.file(for: note.id).proposal?.id != again.id, "every change taken or let be: it's done")

        // MARK: Undoing a rename's links is kept in the other notes' history, like any change
        let target = NoteItem(text: "# Pricing page\n\nTiers.")
        target.binderID = web.id
        let linking = NoteItem(text: "# Launch checklist\n\nSee [[Pricing page]] first.")
        linking.binderID = web.id
        Store.shared.insert(target)
        Store.shared.insert(linking)
        target.text = "# Pricing plans\n\nTiers."
        Store.shared.save()
        guard let rename = LinkTargets.renameLinks(from: "Pricing page", to: "Pricing plans") else {
            run.check(false, "a renamed note's links follow it")
            return
        }
        run.check(linking.text.contains("[[Pricing plans]]"), "a renamed note's links follow it")
        let kept = NoteHistory.versions(of: linking.id).count
        LinkTargets.undo(rename)
        let history = NoteHistory.versions(of: linking.id)
        run.check(linking.text.contains("[[Pricing page]]") && history.count == kept + 1 && history.first?.text.contains("[[Pricing plans]]") == true,
                  "undoing it keeps the note as it was before the undo: \(kept) → \(history.count) versions")
    }
}
