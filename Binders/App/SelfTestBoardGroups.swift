import AppKit
import SwiftData
import SwiftUI
import BindersKit

extension SelfTest {
    /// A note's cards as one group on the board, and acting on many at once (lane DS5), in a throwaway folder
    /// (BINDERS_DATA_DIR) with stand-in items (no model) and a stand-in agent: a board with two distilled notes and loose
    /// cards; Group by Note on and off, remembered per board; choosing cards with ⌘-click, ⇧-click, ⌘A and a group's Select
    /// All, and Esc; Move to, Assign to (you, and a stand-in agent, with a receipt on each card), Delete (the note's marks
    /// for them go) and a note's group in and out, each undone in one step; a card an agent works on that stays; the
    /// parent in list_tasks and get_task; Select on Board from the note. A folder after the flag gets drawings in light and
    /// dark. The team's board is `--selftest-teamdb-board-groups`, on the throwaway Postgres.
    ///
    ///     BINDERS_DATA_DIR=<new empty folder> Binders --selftest-board-groups [folder] -notesShowMarkdown NO
    @MainActor
    static func boardGroupsSelfTest(drawingTo directory: URL?) async -> Int32 {
        guard AppPaths.isDemo else {
            print("ERROR: set BINDERS_DATA_DIR to an empty folder; this test writes notes, cards and agents")
            return 1
        }
        if let directory { try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        FitProbe.isOn = true
        BoardView.probesCards = true
        let controller = DictationController()
        let run = DistillTestRun(controller: controller)
        let store = Store.shared
        let board = controller.board
        let service = controller.distill
        let registry = AgentRegistry.shared
        if registry.paused { registry.setPaused(false) }
        service.start()
        service.settleDelay = .seconds(600)
        HubWindowController.shared.controller = HubWindowController.shared.controller ?? controller

        // Echo writes a WAKE line with its event and card, then the card's JSON, as the Distill self-test's stand-in does.
        let folder = AppPaths.support
        let command = #"printf 'WAKE %s %s\n' "$BINDERS_EVENT" "$BINDERS_CARD" >> echo.txt; cat >> echo.txt; printf '\n' >> echo.txt"#
        let echo = AgentProfile(name: "Echo", wake: .command(command: command, folder: folder.path), wakesPerHour: 60,
                                purpose: "the checkout's web pages and payments")
        let scribe = AgentProfile(name: "Scribe", wake: .board, purpose: "writes and edits documents")
        for agent in [echo, scribe] { run.check(registry.upsert(agent) == nil, "\(agent.name) is saved") }
        let echoActor = BoardActor(name: "Echo", kind: .agent), scribeActor = BoardActor(name: "Scribe", kind: .agent)

        let web = BinderRecord(name: "Web", colorIndex: 2)
        let errands = BinderRecord(name: "Errands", colorIndex: 4)
        store.insert(web)
        store.insert(errands)
        func note(_ text: String) -> NoteItem {
            let made = NoteItem(text: text)
            made.binderID = web.id
            store.insert(made)
            service.setDistill(true, for: made)
            return made
        }
        let checkout = note("""
            # Checkout redesign

            ## Payment form
            - Put address, delivery and card on one page instead of three.
            - Add Apple Pay and Google Pay buttons above the form.

            ## Retry
            Keep what was typed and offer Retry after a failed payment.
            Log each failure with its reason code.
            """)
        let launch = note("""
            # Launch plan

            ## Before
            Write the release notes. Record the demo film.

            ## After
            Post in the forum.
            """)

        /// Proposes the items as Scribe would (with their quotes), then places them all, as Place on Board does.
        func placed(_ items: [[String: Any]], from note: NoteItem, in column: BoardColumn) async -> [TaskCard] {
            _ = await run.call("propose_work_items", ["id": note.id.uuidString, "items": items], as: scribeActor)
            guard let proposal = DistillStore.shared.file(for: note.id).proposal else { return [] }
            return service.place(proposal, items: Set(proposal.items.map(\.id)), column: column)
        }
        let made = await placed([
            ["title": "Combine checkout into one page", "section": "Payment form", "quote": "Put address, delivery and card on one page instead of three."],
            ["title": "Add the Apple Pay button", "section": "Payment form", "quote": "Add Apple Pay"],
            ["title": "Keep what was typed", "section": "Retry", "quote": "Keep what was typed and offer Retry after a failed payment."],
            ["title": "Log each failure", "section": "Retry", "quote": "Log each failure with its reason code."],
        ], from: checkout, in: .ready)
        try? await Task.sleep(for: .milliseconds(20))
        let planned = await placed([
            ["title": "Write the release notes", "section": "Before", "quote": "Write the release notes."],
            ["title": "Record the demo film", "section": "Before", "quote": "Record the demo film."],
            ["title": "Post in the forum", "section": "After", "quote": "Post in the forum."],
        ], from: launch, in: .backlog)
        run.check(made.count == 4 && planned.count == 3, "two notes' items are placed: \(made.count) and \(planned.count)")
        guard made.count == 4, planned.count == 3 else { return 1 }
        try? await Task.sleep(for: .milliseconds(20))
        let domain = board.create(title: "Renew the domain", binderID: web.id, column: .ready, by: .you)
        let venue = board.create(title: "Book the venue", binderID: web.id, column: .ready, by: .you)
        let stickers = board.create(title: "Order stickers", binderID: web.id, column: .backlog, by: .you)
        func cards() -> [TaskCard] { board.cards(in: web.id).sorted { $0.position > $1.position } }

        // MARK: Grouping: order, counts, progress, cards from no note
        run.check(made.allSatisfy { $0.groupNote == checkout.id } && planned.allSatisfy { $0.groupNote == launch.id } && domain.groupNote == nil,
                  "a card Distill made is in its note's group; one made by hand is in none")
        try? board.move(planned[0], to: .ready, by: .you)
        var grouping = BoardView.grouping(cards())
        var ready = grouping.groups(in: .ready)
        run.check(ready.map(\.title) == ["Launch plan", "Checkout redesign", "Not from a note"],
                  "Ready: the newer note's group first, then the older's, then the cards from no note: \(ready.map(\.title))")
        run.check(ready.map(\.cards.count) == [1, 4, 2], "each header counts its cards in this column: \(ready.map(\.cards.count))")
        run.check(ready[1].progress?.line == "0 of 4 done" && ready[0].progress?.line == "0 of 3 done" && ready[2].progress == nil,
                  "and the whole group's progress on the board: \(ready.compactMap(\.progress?.line))")
        let backlog = grouping.groups(in: .backlog)
        run.check(backlog.map(\.title) == ["Launch plan", "Not from a note"] && backlog.first?.cards.count == 2,
                  "Backlog: the same order, its own counts: \(backlog.map(\.title)) \(backlog.map(\.cards.count))")
        try? board.claim(made[3], by: .you)
        try? board.complete(made[3], summary: "Logged.", by: .you)
        try? board.move(made[3], to: .done, by: .you)
        grouping = BoardView.grouping(cards())
        ready = grouping.groups(in: .ready)
        run.check(ready.first { $0.note == checkout.id }?.progress?.line == "1 of 4 done" && grouping.groups(in: .done).first?.cards == [made[3].id],
                  "a card done counts toward its group in every column: \(ready.first { $0.note == checkout.id }?.progress?.line ?? "-")")
        run.check(DistillBoard.cards(of: checkout.id).count == 4, "the note's Work panel still has its 4 cards")

        // MARK: On the board: Group by Note on and off, remembered for each board
        let navigation = HubNavigation()
        navigation.binderID = web.id
        navigation.selection = .binder
        func hosted(_ view: some View) -> AnyView {
            AnyView(view.environment(controller).environment(navigation).environment(controller.team).environment(controller.knowledge)
                .environment(controller.meetings).environment(controller.capture).environment(controller.commitments).environment(AppSettings.shared)
                .modelContainer(store.container).defaultAppStorage(throwawayDefaults).pageGround().binderTint(web.colorIndex))
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 860), styleMask: [.titled, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.appearance = NSAppearance(named: .aqua)
        defer { window.close() }
        func show(_ binder: BinderRecord) async {
            window.contentView = NSHostingView(rootView: hosted(BoardView(binder: binder).id(UUID())))
            window.orderFrontRegardless()
            try? await Task.sleep(for: .milliseconds(900))
        }
        AppDefaults.store.removeObject(forKey: BoardView.groupKey(web.id))
        AppDefaults.store.removeObject(forKey: BoardView.groupKey(errands.id))
        await show(web)
        run.check(BoardView.lastShown != nil && BoardView.lastShown?.groups == nil, "Group by Note starts off: the board as it was")
        AppDefaults.store.set(true, forKey: BoardView.groupKey(web.id))
        await show(web)
        let shownReady = BoardView.lastShown?.groups?[.ready]?.map(\.title) ?? []
        run.check(shownReady == ["Launch plan", "Checkout redesign", "Not from a note"], "on, each column shows its groups: \(shownReady)")
        run.check(!FitProbe.frames("board.group." + checkout.id.uuidString, in: window).isEmpty, "with a header over each")
        await show(errands)
        run.check(BoardView.lastShown?.groups == nil, "another binder's board keeps its own setting: off")
        await show(web)
        run.check(BoardView.lastShown?.groups != nil, "and this one stays on: \(AppDefaults.store.bool(forKey: BoardView.groupKey(web.id)))")

        // MARK: Choosing cards: ⌘-click, ⇧-click, ⌘A, a group's Select All, Esc
        func click(_ probe: String, _ flags: NSEvent.ModifierFlags = []) async {
            guard let frame = FitProbe.frames(probe, in: window).first else { return run.check(false, "\(probe) is drawn") }
            let point = NSPoint(x: frame.midX, y: frame.midY)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                    NSApp.sendEvent(event)
                }
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        func card(_ card: TaskCard) -> String { "board.card." + card.id.uuidString }
        var chosen: Set<UUID> { BoardView.lastShown?.selection ?? [] }
        await click(card(made[0]), .command)
        await click(card(made[2]), .command)
        run.check(chosen == [made[0].id, made[2].id], "⌘-click chooses two cards: \(chosen.count)")
        run.check(!FitProbe.frames("board.several", in: window).isEmpty, "with two chosen, the bar shows over the columns")
        await click(card(made[2]), .command)
        run.check(chosen == [made[0].id], "⌘-click again takes one away")
        await click(card(made[0]), .command)
        await click(card(made[0]), .command)
        await click(card(made[2]), .shift)
        run.check(chosen == Set([made[0], made[1], made[2]].map(\.id)), "⇧-click takes the run in the column: \(chosen.count)")
        run.check(FitProbe.frames("board.several", in: window).count == 1, "the bar says 3 cards selected")
        _ = window.firstResponder?.tryToPerform(#selector(NSText.selectAll(_:)), with: nil)
        try? await Task.sleep(for: .milliseconds(250))
        run.check(chosen == Set(cards().map(\.id)), "⌘A chooses every card on this board: \(chosen.count) of \(cards().count)")
        _ = window.firstResponder?.tryToPerform(#selector(NSResponder.cancelOperation(_:)), with: nil)
        try? await Task.sleep(for: .milliseconds(250))
        run.check(chosen.isEmpty, "Esc clears the choice")
        await click("board.group.all." + launch.id.uuidString)
        run.check(chosen == Set(planned.map(\.id)), "a group's Select All takes the note's cards in every column: \(chosen.count)")
        if let directory {
            // In both appearances: the groups, the chosen cards and the bar.
            capture(window.contentView!, name: "board-groups-light", directory: directory)
            window.appearance = NSAppearance(named: .darkAqua)
            try? await Task.sleep(for: .milliseconds(400))
            capture(window.contentView!, name: "board-groups-dark", directory: directory)
            window.appearance = NSAppearance(named: .aqua)
        }

        // One Undo for each of what follows: the window groups by event; here, by step.
        let undo = UndoManager()
        undo.groupsByEvent = false
        func step(_ work: () -> BoardBulk.Outcome) -> BoardBulk.Outcome {
            undo.beginUndoGrouping()
            let outcome = work()
            undo.endUndoGrouping()
            return outcome
        }

        // MARK: Move to, with a card an agent is working on
        let claimed = await run.call("claim_task", ["id": made[1].id.uuidString], as: echoActor)
        run.check(claimed.ok && made[1].assignee == "Echo", "Echo takes one of the note's cards: \(claimed.text.prefix(80))")
        var moving = [made[0], made[1], made[2]]
        var outcome = step { BoardBulk.move(moving, to: .backlog, board: board, undoManager: undo) }
        run.check(outcome.line == "Moved 2 cards to Backlog. 1 stayed: Echo is working on it.", "Move to says what it did and what stayed: \(outcome.line)")
        run.check(made[0].column == .backlog && made[2].column == .backlog && made[1].column == .inProgress && made[1].assignee == "Echo",
                  "the two moved; Echo's stays with Echo")
        undo.undo()
        run.check(made[0].column == .ready && made[2].column == .ready && made[1].column == .inProgress, "one Undo puts both back in Ready")
        undo.redo()
        run.check(made[0].column == .backlog && made[2].column == .backlog, "Redo moves them again")
        undo.undo()
        moving = [made[0], made[2], made[3]]
        outcome = step { BoardBulk.move(moving, to: .done, board: board, undoManager: undo) }
        run.check(outcome.line == "Moved 2 cards to Done. 1 was in Done already.", "one already there is said: \(outcome.line)")
        undo.undo()
        run.check(made[0].column == .ready && made[2].column == .ready, "and Undo puts them back: \(made[0].column.title)")

        // MARK: Assign to: you, and the stand-in agent, with a receipt on each card
        outcome = step { BoardBulk.assign(planned, to: .you, board: board, undoManager: undo) }
        run.check(outcome.line == "3 cards are for you now." && planned.allSatisfy { $0.meantFor == BoardActor.you.name && !$0.meantForByAgent },
                  "Assign to You: each is meant for you: \(outcome.line)")
        undo.undo()
        run.check(planned.allSatisfy { $0.meantFor == nil }, "one Undo: meant for anyone again")
        let echoWakesBefore = run.wakes(card: domain.id).count + run.wakes(card: stickers.id).count
        outcome = step { BoardBulk.assign([domain, stickers, made[3]], to: .agent("Echo"), board: board, undoManager: undo) }
        run.check(outcome.line.hasPrefix("Gave 2 cards to Echo. 1 stayed: it's done."), "given to Echo, the one done stays: \(outcome.line)")
        run.check(domain.meantFor == "Echo" && stickers.meantFor == "Echo" && stickers.column == .ready && made[3].meantFor == nil,
                  "both are meant for Echo, the one in Backlog went to Ready, as Give to does")
        await run.waitFor(1, card: domain.id)
        await run.waitFor(1, card: stickers.id)
        run.check(run.wakes(card: domain.id).count == 1 && run.wakes(card: stickers.id).count == 1, "Echo was woken once for each, by this tap")
        let receipts = [domain, stickers].map { board.timeline($0.id).filter { $0.kind == .woke && $0.author == "Echo" }.count }
        run.check(receipts == [1, 1], "each card keeps its receipt: \(receipts)")
        undo.undo()
        run.check(domain.meantFor == nil && stickers.meantFor == nil && stickers.column == .backlog, "one Undo: meant for no one, and Backlog again")
        await run.gathered()
        run.check(run.wakes(card: domain.id).count + run.wakes(card: stickers.id).count == echoWakesBefore + 2, "Undo woke no one")

        // MARK: A note's group: put in, taken out, and a card Distill made stays
        outcome = step { BoardBulk.group([domain, venue, planned[1]], into: checkout, board: board, undoManager: undo) }
        run.check(outcome.line == "Put 2 cards in “Checkout redesign”. 1 stayed: Distill made it from “Launch plan”, so it stays in that note's group.",
                  "Part of: two go in, Distill's stays in its own note's: \(outcome.line)")
        run.check(domain.groupNote == checkout.id && domain.distilledFrom?.byHand == true && planned[1].groupNote == launch.id,
                  "the hand-made cards are in the note's group now, by hand")
        run.check(domain.distilledFrom?.teamJSON.object.map { Set($0.keys) } == ["note", "by_hand"], "their part for the team names the note alone")
        // Lane DS6: one idea of a note's cards: the Work panel and the note's marks have the ones put in by hand too, after
        // the note's title.
        run.check(DistillBoard.cards(of: checkout.id).count == 6 && DistillNoteMarks.cards(of: checkout.id).count == 6
                    && DistillNoteMarks.cards(of: checkout.id).filter { $0.quote == nil && $0.section == nil }.count >= 2,
                  "the note's Work panel and marks have the cards put in by hand too: \(DistillBoard.cards(of: checkout.id).count)")
        run.check(domain.meantFor == nil && domain.column == .ready && domain.binderID == web.id, "nothing else of the group is copied onto them")
        run.check(DistillBoard.note(forCard: domain.id) == nil, "and a card put in by hand gives an agent no way into the note")
        grouping = BoardView.grouping(cards())
        run.check(grouping.groups(in: .ready).first { $0.note == checkout.id }.map { Set($0.cards).isSuperset(of: [domain.id, venue.id]) } == true,
                  "on the board they're under the note's header")
        undo.undo()
        run.check(domain.groupNote == nil && venue.groupNote == nil, "one Undo takes them out again")
        undo.redo()
        run.check(domain.groupNote == checkout.id && venue.groupNote == checkout.id, "Redo puts them back in")
        outcome = step { BoardBulk.group([venue], into: nil, board: board, undoManager: undo) }
        run.check(outcome.line == "Took 1 card out of its note's group." && venue.groupNote == nil, "taken out of its group: \(outcome.line)")
        undo.undo()
        run.check(venue.groupNote == checkout.id, "and Undo puts it back")
        let homeless = board.create(title: "Check the receipts", binderID: web.id, column: .backlog, by: .you)
        homeless.binderID = nil
        outcome = step { BoardBulk.group([homeless], into: checkout, board: board, undoManager: undo) }
        run.check(homeless.binderID == web.id && homeless.groupNote == checkout.id, "a card with no binder takes the group's")

        // MARK: What agents read: the parent in list_tasks and get_task
        let listed = run.list((await run.call("list_tasks", ["binder": "Web"], as: echoActor)).text)
        func entry(_ id: UUID) -> [String: Any]? { listed.first { $0["id"] as? String == id.uuidString } }
        run.check(entry(made[0].id)?["note_id"] as? String == checkout.id.uuidString && entry(made[0].id)?["note_title"] as? String == "Checkout redesign",
                  "list_tasks names a distilled card's note: note_id and note_title")
        run.check(entry(made[0].id)?["distilled_from"] != nil && entry(made[0].id)?["id"] != nil && entry(made[0].id)?["column"] != nil,
                  "beside every key it had")
        run.check(entry(domain.id)?["note_id"] as? String == checkout.id.uuidString && entry(domain.id)?["distilled_from"] == nil,
                  "a card put in by hand has the note, and no distilled_from")
        run.check(entry(stickers.id)?["note_id"] == nil && entry(stickers.id)?["note_title"] == nil, "a card from no note has neither key")
        let task = run.object((await run.call("get_task", ["id": domain.id.uuidString], as: echoActor)).text)
        run.check(task["note_title"] as? String == "Checkout redesign", "get_task says it too")

        // MARK: Delete: asked once in the window, through the one-card path; the note's marks for them go; one Undo
        let beforeMarks = DistillNoteMarks.cards(of: checkout.id).map(\.id)
        let going = [made[0], made[2], venue]
        let goingIDs = going.map(\.id)
        let events = goingIDs.map { board.timeline($0).count }
        outcome = step { BoardBulk.delete(going, board: board, undoManager: undo) }
        run.check(outcome.line == "Deleted 3 cards." && goingIDs.allSatisfy { board.card($0) == nil }, "Delete takes all three: \(outcome.line)")
        run.check(goingIDs.allSatisfy { board.timeline($0).isEmpty }, "their timelines with them")
        let afterMarks = DistillNoteMarks.cards(of: checkout.id).map(\.id)
        // Lane DS6: the one put in by hand is among the note's marked cards too, so its mark goes with them.
        run.check(Set(beforeMarks).subtracting(afterMarks) == Set(goingIDs),
                  "the note's marks for the three go, the one put in by hand among them: \(beforeMarks.count) → \(afterMarks.count)")
        undo.undo()
        let back = goingIDs.compactMap { board.card($0) }
        run.check(back.count == 3 && back.map(\.title) == ["Combine checkout into one page", "Keep what was typed", "Book the venue"],
                  "one Undo puts all three back, the same cards: \(back.map(\.title))")
        run.check(goingIDs.map { board.timeline($0).count } == events, "with their timelines: \(goingIDs.map { board.timeline($0).count })")
        run.check(back[0].distilledFrom?.quote == "Put address, delivery and card on one page instead of three." && back[2].groupNote == checkout.id,
                  "and what they were from")
        run.check(Set(DistillNoteMarks.cards(of: checkout.id).map(\.id)) == Set(beforeMarks), "the note marks them again")
        undo.redo()
        run.check(goingIDs.allSatisfy { board.card($0) == nil }, "Redo deletes them again")
        undo.undo()
        run.check(goingIDs.allSatisfy { board.card($0) != nil }, "and Undo brings them back")
        let message = BoardBulkWords.deleteMessage(3, shared: 0)
        run.check(BoardBulkWords.deleteQuestion(3) == "Delete 3 cards?" && message == "You can undo this.", "the one question: “Delete 3 cards?” \(message)")

        // MARK: An old card's distilled part, from before this lane, groups under its note
        let old = board.create(title: "An older distilled card", binderID: web.id, column: .ready, by: .you)
        old.distilledJSON = #"{"note":"\#(launch.id.uuidString)","distill":"\#(UUID().uuidString)","item":"\#(UUID().uuidString)","section":"After"}"#
        run.check(old.groupNote == launch.id && old.distilledFrom?.isDistilled == true, "a card from before this build is in its note's group")
        store.save()

        // MARK: From the note: Select on Board
        let hub = HubWindowController.shared.navigation
        WorkPanel.selectOnBoard(checkout)
        let wanted = Set(DistillBoard.groupCards(of: checkout.id).filter { $0.binderID == web.id }.map(\.id))
        run.check(hub.pendingBoardSelection == wanted && hub.binderID == web.id && hub.pendingBinderTab == .board,
                  "Select on Board opens the note's board with its cards to select: \(hub.pendingBoardSelection?.count ?? 0)")
        navigation.pendingBoardSelection = hub.pendingBoardSelection
        hub.pendingBoardSelection = nil
        await show(web)
        run.check(chosen == wanted, "and the board shows them chosen: \(chosen.count) of \(wanted.count)")

        if let directory {
            // The card's way back to its note, and the bar from the note's side, in both appearances.
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                let details = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 520), styleMask: [.titled], backing: .buffered, defer: false)
                details.isReleasedWhenClosed = false
                details.alphaValue = 0
                details.appearance = NSAppearance(named: appearance)
                details.contentView = NSHostingView(rootView: hosted(CardDetailsPanel(card: domain, confirmDelete: .constant(false)).frame(width: 340)))
                details.orderFrontRegardless()
                try? await Task.sleep(for: .milliseconds(700))
                capture(details.contentView!, name: "board-groups-card-\(name)", directory: directory)
                details.close()
                window.appearance = NSAppearance(named: appearance)
                try? await Task.sleep(for: .milliseconds(400))
                capture(window.contentView!, name: "board-groups-selected-\(name)", directory: directory)
            }
            window.appearance = NSAppearance(named: .aqua)
        }

        FitProbe.isOn = false
        BoardView.probesCards = false
        print(run.failures == 0 ? "BOARD_GROUPS_DONE: all passed" : "BOARD_GROUPS_DONE: \(run.failures) failed")
        return run.failures == 0 ? 0 : 1
    }
}

// MARK: - The team's board

extension SelfTest {
    /// Lane DS5 on a board shared through the team database, on TeamDBTestBed's throwaway Postgres: several of a teammate's
    /// cards moved at once reach the database, one Alex works on stays, a note's group goes to the database as the card's
    /// distilled part (the note and by_hand), and deleting several deletes them for everyone, without an Undo.
    ///
    ///     BINDERS_DATA_DIR=<new empty folder> Binders --selftest-teamdb-board-groups -notesShowMarkdown NO
    @MainActor
    static func teamBoardGroupChecks(_ bed: TeamDBTestBed) async throws {
        let mac = try await TeamMac.start(bed)
        let alex = try await bed.teammate()
        let undo = UndoManager()
        undo.groupsByEvent = false
        func step(_ work: () -> BoardBulk.Outcome) -> BoardBulk.Outcome {
            undo.beginUndoGrouping()
            let outcome = work()
            undo.endUndoGrouping()
            return outcome
        }
        /// Until `condition` holds, or `seconds`.
        func until(_ seconds: Double, _ condition: () async -> Bool) async -> Bool {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end {
                if await condition() { return true }
                try? await Task.sleep(for: .milliseconds(200))
            }
            return await condition()
        }
        var ids: [UUID] = []
        for title in ["Draft the launch post", "Check the screenshots", "Proofread the post", "Book the room"] { ids.append(try await bed.made(title, by: alex)) }
        let arrived = await bed.eventually(10) { ids.allSatisfy { mac.card($0) != nil && TeamCardShadow(mac.card($0)!.teamShadow) != nil } }
        bed.check(arrived, "Alex's four cards are here")
        _ = try await alex.call(.claimCard(ids[2]))
        _ = await bed.eventually(5) { mac.card(ids[2])?.assignee == "Alex" }
        let cards = ids.compactMap { mac.card($0) }
        guard cards.count == 4 else { return bed.check(false, "the cards are here") }

        // Move to: three go, Alex's stays, and the team sees it.
        var outcome = step { BoardBulk.move(Array(cards.prefix(3)), to: .backlog, board: mac.board, undoManager: undo) }
        bed.check(outcome.line == "Moved 2 cards to Backlog. 1 stayed: Alex is working on it.", "on the team's board, what stayed is said: \(outcome.line)")
        bed.check(await mac.drained(), "the moves went to the database")
        var rows = try await alex.rows(.cards, ids: ids)
        func column(_ id: UUID) -> String? { rows.first { $0.rowID == id }?["board_column"]?.string }
        bed.check(column(ids[0]) == "backlog" && column(ids[1]) == "backlog" && column(ids[2]) == "in_progress", "Alex sees the two in Backlog, theirs in progress")
        undo.undo()
        bed.check(await mac.drained(), "Undo's moves went too")
        rows = try await alex.rows(.cards, ids: ids)
        bed.check(column(ids[0]) == "ready" && column(ids[1]) == "ready", "and Alex sees them back in Ready")

        // A note's group: the card's distilled part, through the database, without a migration.
        let launch = BinderRecord(name: "Notes here", colorIndex: 1)
        Store.shared.insert(launch)
        let note = NoteItem(text: "# Launch week\n\nWhat we ship.")
        note.binderID = launch.id
        Store.shared.insert(note)
        outcome = step { BoardBulk.group([cards[0], cards[3]], into: note, board: mac.board, undoManager: undo) }
        bed.check(outcome.line == "Put 2 cards in “Launch week”.", "two of Alex's cards go in a note's group here: \(outcome.line)")
        let grouped = await until(10) {
            guard let rows = try? await alex.rows(.cards, ids: [ids[0], ids[3]]) else { return false }
            return rows.count == 2 && rows.allSatisfy { $0["distilled"]?.object?["by_hand"]?.bool == true && $0["distilled"]?.object?["note"]?.uuid == note.id }
        }
        bed.check(grouped, "the team's database keeps the group in each card's distilled part: the note and by_hand")
        undo.undo()
        let ungrouped = await until(10) {
            guard let rows = try? await alex.rows(.cards, ids: [ids[0], ids[3]]) else { return false }
            return rows.count == 2 && rows.allSatisfy { $0["distilled"]?.object == nil }
        }
        bed.check(ungrouped, "Undo takes them out there too")
        _ = try await alex.call(.setCardDistilled(ids[1], DistilledFrom.byHand(note: note.id).teamJSON))
        let theirs = await bed.eventually(10) { mac.card(ids[1])?.groupNote == note.id }
        bed.check(theirs, "a teammate's Mac puts one in the group: here it's in the note's group")

        // Delete: for everyone, after the one question, and Undo can't bring them back.
        bed.check(BoardBulkWords.deleteMessage(2, shared: 2) == "They're on the team's board: they're deleted for everyone, which can't be undone.",
                  "the question says they go for everyone")
        outcome = step { BoardBulk.delete([cards[0], cards[3]], board: mac.board, undoManager: undo) }
        bed.check(outcome.line == "Deleted 2 cards." && !outcome.undoable, "deleted, with no Undo for the team's cards: \(outcome.line)")
        bed.check(await mac.drained(), "the deletions went")
        rows = try await alex.rows(.cards, ids: [ids[0], ids[3]])
        bed.check(rows.allSatisfy { $0["deleted_at"]?.string != nil } || rows.isEmpty, "the team's database has them deleted: \(rows.count) rows left")
        await mac.stop()
    }
}
