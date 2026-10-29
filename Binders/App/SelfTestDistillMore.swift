import Foundation
import SwiftData
import BindersKit

extension SelfTest {
    /// The rest of `--selftest-distill`: section changes and who's told, versions, Distill again, agents' proposals, the MCP
    /// tools, the progress numbers, the notifications and Ask.
    @MainActor
    static func distillSelfTestPartTwo(_ run: DistillTestRun, note: NoteItem, web: BinderRecord, proposal: DistillRecord, placed: [TaskCard],
                                       model: DistillModelStandIn) async {
        let controller = run.controller
        let board = controller.board
        let service = controller.distill
        let echoActor = BoardActor(name: "Echo", kind: .agent), scribeActor = BoardActor(name: "Scribe", kind: .agent)
        let form = placed[0], cardCheck = placed[1], retry = placed[2], summary = placed[3], decision = placed[4]
        func sectionLines(_ card: TaskCard) -> [TaskEvent] {
            board.timeline(card.id).filter { $0.author == BoardService.binders.name && $0.text.contains("after this card was made") }
        }

        // MARK: A section change flags exactly its cards, and tells the agent holding them
        await run.waitFor(1, card: retry.id)
        run.check((await run.call("claim_task", ["id": retry.id.uuidString], as: echoActor)).ok, "Echo takes the retry card too")
        let before = note.text
        note.text = before.replacingOccurrences(of: "- Apple Pay and Google Pay buttons above the form.",
                                                with: "- Apple Pay and Google Pay buttons above the form.\n- Show the card's brand as it's typed.")
        NoteHistory.changed(note.id, previous: before, by: .you)
        service.settleNow(note.id)
        let line = sectionLines(cardCheck).last?.text ?? ""
        run.check(line.hasPrefix("The Payment form section of “Checkout redesign” changed after this card was made: by you, 1 line added.")
                  && line.contains("\n+ - Show the card's brand as it's typed."), "the card from that section says what changed and who: \(line)")
        run.check(sectionLines(form).isEmpty, "a card already Done isn't flagged")
        run.check(sectionLines(retry).isEmpty && sectionLines(summary).isEmpty && sectionLines(decision).isEmpty,
                  "nor are the cards from the other sections")
        run.check(cardCheck.distilledFrom?.change?.by == "you" && cardCheck.distilledFrom?.held == false, "the card keeps who changed it")
        await run.waitFor(2, card: cardCheck.id)
        let told = run.wakes(card: cardCheck.id).last
        run.check(told?.line == "commented \(cardCheck.id.uuidString)" && (told?.json["answer"] as? String ?? "").contains("The Payment form section"),
                  "Echo, holding it, is told as a comment reaches it: \(told?.line ?? "none")")
        // Again with nothing new: no second line.
        service.checkSections(of: note, by: .you)
        run.check(sectionLines(cardCheck).count == 1, "the same change isn't said twice")

        // An agent's change is shown on its card but held back from the agent holding it.
        let edited = await run.call("update_note", ["id": note.id.uuidString, "find": "keep everything the customer typed and offer Retry.",
                                                    "replace": "keep everything the customer typed, say why it failed and offer Retry."], as: scribeActor)
        run.check(edited.ok, "Scribe changes the Retry section: \(edited.text)")
        try? await Task.sleep(for: .milliseconds(300))
        let agentLine = sectionLines(retry).last?.text ?? ""
        run.check(agentLine.contains("by Scribe (your agent)"), "the retry card shows the agent's change: \(agentLine)")
        run.check(retry.distilledFrom?.held == true, "and holds it back")
        await run.gathered()
        run.check(!run.wakes(card: retry.id).contains { $0.line.hasPrefix("commented") }, "Echo isn't told until a person has looked")
        service.passOn(retry)
        await run.waitFor(2, card: retry.id)
        let passed = run.wakes(card: retry.id).last
        let passedWords = passed?.json["answer"] as? String ?? ""
        run.check(passed?.line == "commented \(retry.id.uuidString)" && passedWords.contains("the user has looked at it"),
                  "once you looked, Echo is told: \(passedWords.prefix(120))")
        run.check(!passedWords.contains("say why it failed"), "without the other agent's words")
        run.check(retry.distilledFrom?.held == false, "nothing is held any more")
        // Hovering the heading: who last changed it, and its cards.
        let tip = service.headingTip("Retry after a failed payment", in: note) ?? ""
        run.check(tip.hasPrefix("Changed by Scribe (your agent)") && tip.contains("“Keep entered details and offer Retry” (In progress)"), "the heading's tip: \(tip)")

        // MARK: Versions: who made each, kept for good, a version put back adds one
        let history = run.object((await run.call("get_note_history", ["id": note.id.uuidString], as: scribeActor)).text)
        let versions = history["versions"] as? [[String: Any]] ?? []
        run.check(versions.first?["id"] as? String == "now" || versions.first != nil, "get_note_history lists the versions, newest first")
        run.check(versions.contains { $0["by"] as? String == "Scribe" && $0["by_kind"] as? String == "agent" && $0["owner"] as? String == "You" },
                  "the agent's version says whose agent it is")
        run.check(versions.contains { $0["by"] as? String == "You" && $0["by_kind"] as? String == "person" }, "yours say you")
        run.check(versions.contains { ($0["distills"] as? [[String: Any]])?.first?["placed"] as? Int == 5 }, "the version Distill read says what it placed")
        if let read = proposal.version {
            NoteHistory.name(read, of: note, "Approved")
            run.check(NoteHistory.entries(of: note).first { $0.id == read }?.name == "Approved", "a version can be given a name")
            let count = NoteHistory.versions(of: note.id).count
            if let version = NoteHistory.versions(of: note.id).first(where: { $0.stem == read }) {
                NoteHistory.restore(version, to: note)
                let now = NoteHistory.versions(of: note.id)
                run.check(now.count == count + 2 && note.text == version.text, "putting a version back adds versions and takes nothing away: \(count) → \(now.count)")
                let newest = NoteHistory.entries(of: note).first { $0.id == now.first?.stem }
                run.check(newest?.by == .you && newest?.restoredFrom == read, "the version put back is yours, from the one you chose")
            }
        }
        // 25 versions from over a month ago, then one now, which is when old ones would go.
        for day in 0..<25 { NoteHistory.keep("# Checkout redesign\n\nDraft \(day)", for: note.id, at: Date().addingTimeInterval(-Double(40 + day) * 86_400)) }
        NoteHistory.keep(note.text + "\n", for: note.id, at: Date())
        run.check(NoteHistory.versions(of: note.id).filter { $0.text.hasPrefix("# Checkout redesign\n\nDraft") }.count == 25,
                  "a Distill note's versions are never trimmed")
        let plain = NoteItem(text: "# Plain\n\nNot a spec.")
        plain.binderID = web.id
        Store.shared.insert(plain)
        for day in 0..<25 { NoteHistory.keep("# Plain\n\nDraft \(day)", for: plain.id, at: Date().addingTimeInterval(-Double(40 + day) * 86_400)) }
        NoteHistory.keep("# Plain\n\nNow.", for: plain.id, at: Date())
        run.check(NoteHistory.versions(of: plain.id).count == NoteVersions.keepLatest, "another note's are, as before: \(NoteHistory.versions(of: plain.id).count)")

        // MARK: Distill again proposes only the new and the changed
        let current = note.text
        var changed = current.replacingOccurrences(of: "Show the items, the delivery cost and the total", with: "Show the items, the delivery cost, the tax and the total")
        if let rollout = changed.range(of: "## Rollout"), let end = changed.range(of: "## Out of scope") {
            changed.removeSubrange(rollout.lowerBound..<end.lowerBound)
        }
        changed += "\n\n## Receipts\nShow a receipt page with the order number, and send the same by email."
        note.text = changed
        NoteHistory.changed(note.id, previous: current, by: .you)
        service.settleNow(note.id)
        run.check(sectionLines(summary).last?.text.contains("The Order summary section") == true, "the summary card hears its section changed")
        run.check(board.timeline(decision.id).contains { $0.text.hasPrefix("The Rollout section is gone from “Checkout redesign”") },
                  "the decision card hears its section is gone")
        let againResult = await service.distill(note)
        guard case .success(let again) = againResult else {
            run.check(false, "Distill again: \(againResult)")
            return
        }
        run.check(again.items.map(\.title) == ["Show a receipt after paying"], "it proposes only the new section's item: \(again.items.map(\.title))")
        run.check(!again.items.contains { $0.title == "Combine checkout into one page" }, "never the same item twice")
        run.check(again.updates.contains { $0.kind == .brief && $0.card == summary.id && $0.brief.contains("tax") },
                  "it offers to bring the summary card's brief up to date")
        run.check(again.updates.contains { $0.kind == .close && $0.card == decision.id }, "and to close the card whose section is gone")
        run.check(again.after == proposal.id, "compared with the last proposal")
        for update in again.updates { service.take(update, of: again) }
        run.check(summary.details.hasPrefix("Items, delivery cost, tax and total beside the form.") && summary.distilledFrom?.briefUpdated != nil,
                  "the brief is up to date: \(summary.details.prefix(60))")
        run.check(decision.column == .done && decision.distilledFrom?.closed != nil, "the card is closed")

        // MARK: An agent's proposal makes no card unless the binder lets it place them
        let cardsBefore = board.cards(in: web.id).count
        let proposed = await run.call("propose_work_items", ["id": note.id.uuidString,
                                                             "items": [["title": "Write the checkout help page", "section": "Payment form", "for": "person"]]],
                                      as: scribeActor)
        let proposedReply = run.object(proposed.text)
        run.check(proposed.ok && (proposedReply["items"] as? [[String: Any]])?.first?["title"] as? String == "Write the checkout help page",
                  "propose_work_items makes a proposal and says its items: \(proposed.text.prefix(160))")
        run.check(board.cards(in: web.id).count == cardsBefore, "and no card")
        let scribes = DistillStore.shared.file(for: note.id).distills.last
        run.check(scribes?.readByAgent == true && scribes?.readBy == "Scribe" && scribes?.status == .proposed, "read by Scribe, waiting for review")
        web.agentsMayPlace = true
        Store.shared.save()
        let placing = await run.call("propose_work_items", ["id": note.id.uuidString,
                                                            "items": [["title": "Add an FAQ about refunds", "section": "Receipts", "for": "Echo"]]],
                                     as: scribeActor)
        let faq = board.cards(in: web.id).first { $0.title == "Add an FAQ about refunds" }
        // Lane DB2: as Place on Board does, in Ready, meant for whoever the agent picked, so agents take them.
        run.check(placing.ok && faq?.column == .ready, "with Agents may place work items on, its card goes to Ready: \(placing.text.prefix(120))")
        run.check(faq?.meantFor == "Echo" && faq?.meantForByAgent == false, "meant for Echo, as Place on Board does")
        run.check(faq.map { board.timeline($0.id).contains { $0.author == "Binders" && $0.text == "Meant for Echo: placed by Scribe, which this binder lets place work items." } } ?? false,
                  "by Binders, saying Scribe placed it")
        run.check(faq?.details.hasPrefix("Placed by Scribe") == true, "and the card says no one reviewed it")
        await run.gathered()
        run.check(faq.map { run.wakes(card: $0.id).isEmpty } ?? false, "Echo, which may not start on cards on its own, isn't woken for it")
        run.check(faq.map { board.timeline($0.id).contains { $0.text.hasPrefix("Waits for your Give to: Echo starts on cards an agent placed only once") } } ?? false,
                  "the card says it waits for your Give to")
        // With Echo's start switch on (and its yes), an agent's placing starts it.
        if var starting = AgentRegistry.shared.agent(named: "Echo") {
            starting.autoStart = true
            AgentRegistry.shared.upsert(starting, startsOnItsOwn: true)
            let again = await run.call("propose_work_items", ["id": note.id.uuidString,
                                                              "items": [["title": "Add a refunds help page", "section": "Receipts", "for": "Echo"]]],
                                       as: scribeActor)
            let refunds = board.cards(in: web.id).first { $0.title == "Add a refunds help page" }
            await run.gathered()
            run.check(again.ok && refunds.map { run.wakes(card: $0.id).map(\.line) == ["ready \($0.id.uuidString)"] } == true,
                      "with Echo's start switch on, Echo is woken for the card Scribe placed")
            starting.autoStart = nil
            AgentRegistry.shared.upsert(starting, startsOnItsOwn: false)
        } else {
            run.check(false, "Echo is set up")
        }
        web.agentsMayPlace = false
        Store.shared.save()

        // "Distill with…" an agent: a card given to it, asking for propose_work_items with that card's id. The note has a new
        // section since it was last read, which is what an agent reading it again proposes for.
        let withRefunds = note.text + "\n\n## Refunds\nRefund a payment from the order page."
        let beforeRefunds = note.text
        note.text = withRefunds
        NoteHistory.changed(note.id, previous: beforeRefunds, by: .you)
        service.settleNow(note.id)
        let echo = AgentRegistry.shared.agent(named: "Echo")!
        if case .success(let request) = service.distill(note, with: echo) {
            run.check(request.meantFor == "Echo" && !request.meantForByAgent && request.column == .ready, "Distill with Echo gives it a card, by you")
            await run.waitFor(1, card: request.id)
            let asked = run.wakes(card: request.id).first
            run.check(asked?.line == "ready \(request.id.uuidString)" && (asked?.json["details"] as? String ?? "").contains("propose_work_items"),
                      "Echo is woken with what to do and the note")
            let answered = await run.call("propose_work_items", ["id": request.id.uuidString,
                                                                 "items": [["title": "Show a receipt after paying", "section": "Receipts", "for": "agent"],
                                                                           ["title": "Add a refund button", "section": "Refunds", "for": "agent"]]],
                                          as: echoActor)
            run.check(DistillStore.shared.file(for: note.id).distills.last?.items.map(\.title) == ["Add a refund button"],
                      "read again by an agent, only the new section's item is proposed")
            run.check(answered.ok && DistillStore.shared.file(for: note.id).distills.last?.requestCard == request.id,
                      "its proposal answers the card: \(answered.text.prefix(100))")
            run.check(board.timeline(request.id).contains { $0.text.hasPrefix("Echo proposed 1 work item") }, "and the card says so")
            run.check(!DistillBoard.cards(of: note.id).contains { $0.id == request.id }, "the asking card isn't one of the spec's work items")
            // One whose tie to the note didn't come with it (a shared board's, before build 48): known by its title and source.
            let tie = request.distilledFrom
            run.check(tie?.request == true, "the asking card is tied to its note when it's made")
            request.distilledFrom = nil
            run.check((try? DistillTools.note(request.id.uuidString, cardOnly: true, reads: .everything, actor: echoActor))?.note.id == note.id,
                      "an asking card without its tie still opens its note to the agent holding it")
            let untied = run.object((await run.call("get_task", ["id": request.id.uuidString], as: echoActor)).text)
            run.check((untied["distilled_from"] as? [String: Any])?["asks_to_distill"] as? Bool == true, "and get_task says it asks to distill it")
            request.distilledFrom = tie
        } else {
            run.check(false, "Distill with Echo gives it a card")
        }
        let private_ = NoteItem(text: "# Thinking out loud\n\n## Plan\nSomething I said.")
        private_.binderID = web.id
        private_.staysUnshared = true
        private_.distill = true
        Store.shared.insert(private_)
        if case .failure(.notForAgents) = service.distill(private_, with: echo) {
            run.check(true, "a note made from what you said doesn't go to an agent")
        } else {
            run.check(false, "a note made from what you said doesn't go to an agent")
        }

        // MARK: The MCP tools, and a card's reply
        let progressReply = run.object((await run.call("note_progress", ["id": note.id.uuidString], as: scribeActor)).text)
        let counts = progressReply["counts"] as? [String: Any] ?? [:]
        let mine = DistillBoard.counts(of: note.id)
        run.check(counts["total"] as? Int == mine.total && counts["done"] as? Int == mine.done && counts["held_up"] as? Int == mine.heldUp,
                  "note_progress gives the Work bar's numbers: \(counts)")
        run.check((progressReply["items"] as? [[String: Any]])?.count == mine.total, "and every card")
        run.check((progressReply["report"] as? [String: Any])?["summary"] as? String != nil, "and the report")
        let workList = run.list((await run.call("note_progress", ["binder": "Web"], as: scribeActor)).text)
        run.check(workList.contains { $0["note"] as? String == note.id.uuidString }, "with binder, the Work list")
        let versionReply = run.object((await run.call("get_note_version", ["id": summary.id.uuidString, "version": proposal.version ?? "",
                                                                           "compare_to": "now"], as: echoActor)).text)
        run.check((versionReply["changes"] as? [String])?.contains { $0.contains("the tax") } == true
                  && (versionReply["sections"] as? [String])?.contains("Order summary") == true,
                  "get_note_version, through a card, says what changed since it was made")
        let task = run.object((await run.call("get_task", ["id": cardCheck.id.uuidString], as: echoActor)).text)
        run.check((task["waits_for"] as? [[String: Any]])?.first?["column"] as? String == "done", "get_task says what it waits for, and where that stands")
        let from = task["distilled_from"] as? [String: Any]
        run.check(from?["note"] as? String == note.id.uuidString && from?["section"] as? String == "Payment form" && from?["version"] as? String == proposal.version
                  && (from?["link"] as? String ?? "").contains("section=Payment%20form"), "and what it was distilled from")
        let viaMCP = await run.call("distill_note", ["id": note.id.uuidString], as: scribeActor)
        run.check(viaMCP.ok && run.object(viaMCP.text)["message"] != nil, "distill_note has Binders' model make a proposal: \(viaMCP.text.prefix(100))")
        let fromCardOnly = try? DistillTools.note(cardCheck.id.uuidString, cardOnly: true, reads: .everything)
        run.check(fromCardOnly?.note.id == note.id, "a server confined to the board reaches the note through a card distilled from it")
        run.check((try? DistillTools.note(note.id.uuidString, cardOnly: true, reads: .everything)) == nil, "but not by the note's own id")
        let plainFromNote = board.create(title: "Look at the totals", binderID: web.id, source: (NoteWorkCards.noteKind, note.id.uuidString, note.title), by: .you)
        run.check((try? DistillTools.note(plainFromNote.id.uuidString, cardOnly: true, reads: .everything)) == nil,
                  "nor through a card that names the note but neither came from Distill nor asks to distill it")
        board.removeHere(plainFromNote)
        run.check((try? DistillTools.note(cardCheck.id.uuidString, cardOnly: true, reads: .everything, actor: echoActor)) != nil,
                  "an agent reaches it through a card it holds")
        run.check((try? DistillTools.note(cardCheck.id.uuidString, cardOnly: true, reads: .everything, actor: BoardActor(name: "Stranger", kind: .agent))) == nil,
                  "and not through someone else's card")

        // MARK: The progress numbers, the notifications, Ask
        let cards = DistillBoard.cards(of: note.id).filter { $0.distilledFrom?.closed == nil }
        let doneByHand = cards.filter { $0.column == .done }.count
        let progress = DistillBoard.progress(of: note)
        run.check(progress.counts.total == cards.count && progress.counts.done == doneByHand, "the numbers are the board's: \(progress.line)")
        let report = progress.report
        run.check(report.inProgress.contains { $0.title == "Check card numbers as they're typed" && $0.who == "Echo" }, "the report says what Echo is on")
        run.check(report.sections.contains { $0.section == "Payment form" } && report.sections.contains { $0.section == "Retry after a failed payment" },
                  "and which sections changed since their cards were made")
        run.check(DistillBoard.progress(of: note).report == report, "the same every time")
        // Your turn: a card for you whose wait is done.
        if let turnProposal = DistillStore.shared.file(for: note.id).distills.first(where: { $0.items.contains { $0.title == "Show a receipt after paying" } }),
           let item = turnProposal.items.first(where: { $0.title == "Show a receipt after paying" }) {
            var mineNow = turnProposal
            if let index = mineNow.items.firstIndex(where: { $0.id == item.id }) { mineNow.items[index].meantFor = "You" }
            service.save(mineNow)
            let receipt = service.place(mineNow, items: [item.id], column: .ready).first
            if let receipt {
                try? board.setWaits(receipt, to: [summary.id], by: .you)
                service.boardChanged()
                try? board.move(summary, to: .done, by: .you)
                service.boardChanged()
                run.check(service.posted.contains("Your turn in “Checkout redesign”"), "your turn rings when what your card waits for is done: \(service.posted)")
            } else {
                run.check(false, "the receipt card is placed")
            }
        }
        for card in DistillBoard.cards(of: note.id) where card.column != .done { try? board.move(card, to: .done, by: .you) }
        service.boardChanged()
        run.check(service.posted.contains("“Checkout redesign” is done"), "and the spec being done rings too")
        let answer = DistillService.answer("How's the checkout redesign spec going?")
        run.check(answer?.hasPrefix("“Checkout redesign”: ") == true, "Ask answers from the report: \(answer?.prefix(80) ?? "nothing")")
        let asked = await controller.knowledge.ask("How's the checkout redesign spec going?")
        run.check(asked.text == answer, "the same from Ask on the Knowledge page")
        run.check(DistillService.answer("What did we decide about checkout?") == nil, "a question about something else isn't one")
        _ = model
    }
}
