import AppKit
import SwiftData
import SwiftUI
import BindersKit

extension SelfTest {
    /// Put on Board tracked as Distill's cards are (lane DS6), in a throwaway folder (BINDERS_DATA_DIR), with stand-ins for
    /// the language and decision models: a note without Distill on put on the board whole, then words selected in it, then
    /// each line of a list, from the editor's menu and the Note menu's command; each card among the note's cards, marked
    /// at its words (a whole note's after its title), with the Work bar, its progress and the Work panel over a note
    /// without Distill on, the progress moving as cards move, the cards grouped on the board and staying in their note's
    /// group, a card made with Put on Board before this build adopted as it is, a to-do's card and another note's left
    /// out, a section's change said on its card with only who and how much reaching an agent and no way into the note,
    /// Distill Again leaving them alone, and the saved Markdown the note's words alone. A folder after the flag gets
    /// drawings.
    ///
    ///     BINDERS_DATA_DIR=<new empty folder> Binders --selftest-put-on-board [folder] -notesShowMarkdown NO
    @MainActor
    static func putOnBoardSelfTest(drawingTo directory: URL?) async -> Int32 {
        guard AppPaths.isDemo else {
            print("ERROR: set BINDERS_DATA_DIR to an empty folder; this test writes notes, cards and agents")
            return 1
        }
        if let directory { try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        FitProbe.isOn = true
        defer { FitProbe.isOn = false }
        let controller = DictationController()
        let run = DistillTestRun(controller: controller)
        let store = Store.shared
        let board = controller.board
        let service = controller.distill
        let registry = AgentRegistry.shared
        if registry.paused { registry.setPaused(false) }
        service.start()
        service.settleDelay = .seconds(600)
        EditorWork.pause = 0.3
        DistillNoteMarks.shown = true
        HubWindowController.shared.controller = HubWindowController.shared.controller ?? controller
        let folder = AppPaths.support
        // The decision model knows none of these titles: no one is suggested for them.
        let standIns = RouterStandIns()
        standIns.byChoice[.tev1] = RouterStandIn()
        controller.router.models = DecisionModels(choice: .tev1, measures: DecisionMeasureStore(url: folder.appendingPathComponent("put-measures.json")),
                                                  fingerprints: FolderFingerprints(url: folder.appendingPathComponent("put-fingerprints.json")),
                                                  makeBackend: { standIns.make($0) })
        controller.router.budget = .seconds(1)
        let echo = AgentProfile(name: "Echo", wake: .board, purpose: "the launch's web pages")
        run.check(registry.upsert(echo) == nil, "Echo is saved")
        let echoActor = BoardActor(name: "Echo", kind: .agent)

        let web = BinderRecord(name: "Web", colorIndex: 2)
        store.insert(web)
        let text = """
            # Launch plan

            Everything for the beta, in one place.

            ## Tasks
            - [ ] Write the release notes
            - [ ] Record the demo film
            - [ ] Email the testers

            ## Risks
            The sign-in page is slow on old phones.
            """
        let note = NoteItem(text: text)
        note.binderID = web.id
        store.insert(note)
        let other = NoteItem(text: "# Venue\n\nBook the hall.")
        other.binderID = web.id
        store.insert(other)
        store.save()
        run.check(!note.distill, "the note has Distill off")
        run.check(DistillBoard.cards(of: note.id).isEmpty && DistillNoteMarks.work(for: note, controller: controller) == nil,
                  "with no cards, its editor marks nothing and no Work bar shows, as before")

        // MARK: Cards from before, and cards that aren't the note's
        let old = board.create(title: "Plan the beta", details: NoteCards.details(text: text, noteID: note.id.uuidString), binderID: web.id, column: .ready,
                               source: (NoteWorkCards.noteKind, note.id.uuidString, note.title), by: .you)
        let todoCard = board.create(title: "Call the printer", binderID: web.id, column: .ready, source: (NoteWorkCards.noteKind, note.id.uuidString, note.title),
                                    sourceRef: UUID().uuidString, by: .you)
        let othersCard = board.create(title: "Book the hall", binderID: web.id, source: (NoteWorkCards.noteKind, other.id.uuidString, other.title), by: .you)
        store.save()
        run.check(old.groupNote == note.id && old.noteMembership?.tie == .put && old.distilledJSON.isEmpty,
                  "a card put on the board before this build is adopted as one of the note's, with nothing written to it")
        run.check(todoCard.groupNote == nil && othersCard.groupNote == other.id, "a to-do's card isn't the note's, and another note's card is that note's")

        // The board's change reaches the note's editor once it's saved.
        let start = service.boardRevision
        for _ in 0..<30 where service.boardRevision == start { try? await Task.sleep(for: .milliseconds(100)) }

        // MARK: The note in its editor, with Put on Board
        var made: [TaskCard] = []
        var said: [String] = []
        var work = DistillNoteMarks.work(for: note, controller: controller)
        let binding = Binding(get: { note.text }, set: { note.text = $0 })
        let put: (NSRange, Bool) -> Void = { selection, eachLine in
            guard let result = NotePutOnBoard.put(note, selection: selection, eachLine: eachLine, controller: controller) else { return }
            made += result.cards
            said.append(result.line)
        }
        func page(_ work: NoteWork?) -> some View {
            MarkdownNoteEditor(text: binding, fontSize: 15, paper: true, work: work, putOnBoard: put)
                .frame(width: 760, height: 560).background(Color(nsColor: BindersTheme.NS.paper))
        }
        let hosting = NSHostingView(rootView: AnyView(page(work)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 560), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.alphaValue = 0
        hosting.wantsLayer = true
        window.contentView = hosting
        window.orderFrontRegardless()
        defer { window.close() }
        try? await Task.sleep(for: .milliseconds(1200))
        func find(_ view: NSView) -> MarkdownTextView? { (view as? MarkdownTextView) ?? view.subviews.lazy.compactMap(find).first }
        guard let editor = find(hosting), let storage = editor.textStorage else {
            run.check(false, "the editor opens")
            return 1
        }
        let string = { editor.string as NSString }
        run.check(work?.cards.count == 1, "the card from before shows in the editor: \(work?.cards.count ?? 0)")

        // Nothing selected: the menu has no Put on Board, and the Note menu's puts the whole note.
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        let plain = editor.withPutOnBoard(NSMenu())
        run.check(plain?.items.contains { $0.title.hasPrefix("Put") } == false, "with nothing selected, the editor's menu has no Put on Board")
        let menuBar = MainMenu.build()
        let command = menuBar.items.first { $0.title == "Note" }?.submenu?.items.first { $0.title == "Put on Board" }
        run.check(command?.keyEquivalent == "b" && command?.keyEquivalentModifierMask == [.command, .shift],
                  "Note has Put on Board, ⇧⌘B (⌥⌘B is Fold into a Bubble's)")
        run.check(editor.putOnBoardFromMenu(), "Note → Put on Board with the editor at the keyboard and nothing selected puts the note")
        let whole = made.last
        run.check(made.count == 1 && whole?.title == "Launch plan" && whole?.column == .backlog && whole?.binderID == web.id,
                  "the whole note: one card in Backlog on its binder's board, with the note's title, as today")
        run.check(whole?.details == NoteCards.details(text: text, noteID: note.id.uuidString), "its details are the note's first lines and the link back, as today")
        run.check(whole?.distilledFrom?.put == true && whole?.distilledFrom?.section == nil && whole?.distilledFrom?.quote == nil && whole?.groupNote == note.id,
                  "and it's the note's card now, made from the whole note")
        run.check(said.last == "Added to the Web board", "it says where: \(said.last ?? "nothing")")

        // A selection: one card.
        let risk = string().range(of: "The sign-in page is slow on old phones.")
        editor.setSelectedRange(risk)
        let one = editor.withPutOnBoard(NSMenu())?.items ?? []
        run.check(one.first?.title == "Put on Board" && one.first?.keyEquivalent == "b" && !one.contains { $0.title.hasPrefix("Put Each Line") },
                  "with one line selected, the menu's first item is Put on Board (⇧⌘B), and no Put Each Line: \(one.map(\.title))")
        editor.putSelectionOnBoard(nil)
        let riskCard = made.last
        let riskFrom = riskCard?.distilledFrom
        run.check(made.count == 2 && riskCard?.title == "The sign-in page is slow on old phones.", "the selection: one card titled from it: \(riskCard?.title ?? "none")")
        run.check(riskFrom?.put == true && riskFrom?.section == "Risks" && riskFrom?.quote == "The sign-in page is slow on old phones."
                    && riskFrom?.sectionHash == DistillSections.section("Risks", in: text)?.hash,
                  "with the words it came from, their section and that section's version")
        run.check(riskCard?.details.hasPrefix("The sign-in page is slow on old phones.\n\nFrom the note, “Risks”: [open it](binders://note/") == true,
                  "its details: the words and the way back to them: \(riskCard?.details.debugDescription ?? "")")

        // Each line of a list.
        let lines = NSRange(location: string().range(of: "- [ ] Write").location,
                            length: NSMaxRange(string().range(of: "Email the testers")) - string().range(of: "- [ ] Write").location)
        editor.setSelectedRange(lines)
        let several = editor.withPutOnBoard(NSMenu())?.items.map(\.title) ?? []
        run.check(several.prefix(2) == ["Put on Board", "Put Each Line on Board (3)"], "three lines selected: Put Each Line on Board (3) too: \(several.prefix(3))")
        editor.putEachLineOnBoard(nil)
        let lineCards = Array(made.suffix(3))
        run.check(made.count == 5 && lineCards.map(\.title) == ["Write the release notes", "Record the demo film", "Email the testers"],
                  "a card for each line, titled without its checkbox: \(lineCards.map(\.title))")
        run.check(lineCards.map { $0.distilledFrom?.quote } == ["Write the release notes", "Record the demo film", "Email the testers"]
                    && lineCards.allSatisfy { $0.distilledFrom?.section == "Tasks" },
                  "each with its own words, in the Tasks section")
        run.check(said.last == "Added 3 cards to the Web board", "it says how many: \(said.last ?? "nothing")")
        editor.setSelectedRange(NSRange(location: 0, length: 0))

        // MARK: Marks and chips at the right places
        let revision = service.boardRevision
        for _ in 0..<30 where service.boardRevision == revision { try? await Task.sleep(for: .milliseconds(100)) }
        work = DistillNoteMarks.work(for: note, controller: controller)
        run.check(work?.cards.count == 6, "the editor gets the note's 6 cards, not the to-do's or the other note's: \(work?.cards.count ?? 0)")
        hosting.rootView = AnyView(page(work))
        try? await Task.sleep(for: .milliseconds(700))
        func marked(_ words: String) -> Bool {
            let range = string().range(of: words)
            guard range.location != NSNotFound else { return false }
            var whole = NSRange()
            let tint = storage.attribute(.workMark, at: range.location, longestEffectiveRange: &whole, in: NSRange(location: 0, length: storage.length))
            return tint != nil && whole.location <= range.location && NSMaxRange(whole) >= NSMaxRange(range)
        }
        func chip(onLineWith words: String) -> String? {
            editor.workChips().first { found in
                string().substring(with: string().lineRange(for: found.character)).contains(words)
            }?.chip.text
        }
        run.check(marked("The sign-in page is slow on old phones.") && chip(onLineWith: "The sign-in page")?.hasPrefix("Backlog") == true,
                  "the selection's words are marked, with a chip at their line's end: \(chip(onLineWith: "The sign-in page") ?? "none")")
        run.check(["Write the release notes", "Record the demo film", "Email the testers"].allSatisfy { marked($0) && chip(onLineWith: $0)?.hasPrefix("Backlog") == true },
                  "each line's words are marked, each with its own chip")
        run.check(!marked("- [ ] Write") , "the checkbox isn't part of the words marked")
        run.check(chip(onLineWith: "# Launch plan") == "2 cards", "the whole note's card and the one from before show after the title: \(chip(onLineWith: "# Launch plan") ?? "none")")
        run.check(chip(onLineWith: "## Tasks") == "3 cards" && chip(onLineWith: "## Risks") == "1 card",
                  "the headings count their sections' cards: \(chip(onLineWith: "## Tasks") ?? "none"), \(chip(onLineWith: "## Risks") ?? "none")")
        if let directory {
            capture(hosting, name: "put-on-board-marks-light", directory: directory)
            window.appearance = NSAppearance(named: .darkAqua)
            editor.restyle()
            try? await Task.sleep(for: .milliseconds(300))
            capture(hosting, name: "put-on-board-marks-dark", directory: directory)
            window.appearance = NSAppearance(named: .aqua)
            editor.restyle()
        }
        MarkdownEditor.flushAll()
        run.check(note.text == text && editor.string == text && !note.text.contains("Backlog") && !note.text.contains("cards"),
                  "the saved Markdown is the note's words alone")

        // MARK: The Work bar, its progress and the Work panel, on a note without Distill on
        var progress = DistillBoard.progress(of: note)
        run.check(DistillBoard.hasCards(note.id) && progress.counts.total == 6 && progress.counts.done == 0 && progress.items.count == 6,
                  "the note's progress counts its 6 cards, as the Work bar and panel read it: \(progress.line)")
        try? board.move(riskCard!, to: .done, by: .you)
        try? board.move(old, to: .inProgress, by: .you)
        store.save()
        progress = DistillBoard.progress(of: note)
        run.check(progress.counts.done == 1 && progress.counts.total == 6 && progress.line.hasPrefix("1 of 6 done"), "as cards move, it moves: \(progress.line)")
        let list = DistillBoard.workList(in: web.id)
        run.check(list.contains { $0.note == note.id.uuidString && $0.counts.done == 1 } && list.contains { $0.note == other.id.uuidString },
                  "the binder's Work list has the note, and the other note with its card: \(list.map(\.title))")
        let reply = run.object((await run.call("note_progress", ["id": note.id.uuidString], as: .you)).text)
        run.check((reply["counts"] as? [String: Any])?["done"] as? Int == 1, "note_progress gives it, Distill off: \(reply["line"] as? String ?? "none")")

        func hub(_ configure: (HubNavigation) -> Void) -> some View {
            let navigation = HubNavigation()
            navigation.binderID = web.id
            configure(navigation)
            return HubView().environment(navigation).environment(controller).environment(controller.meetings)
                .environment(controller.knowledge).environment(controller.team).environment(controller.capture)
                .environment(controller.commitments).environment(AppSettings.shared).modelContainer(store.container)
        }
        AppDefaults.store.set(true, forKey: "notesShowDigest")
        AppDefaults.store.set("work", forKey: "notesSidePanel")
        let hubWindow = HubWindowController.makeWindow(hub { $0.selection = .binder; $0.pendingBinderTab = .notes; $0.pendingNoteID = note.id },
                                                       size: NSSize(width: 1440, height: 900))
        hubWindow.alphaValue = 0
        hubWindow.orderFrontRegardless()
        try? await Task.sleep(for: .milliseconds(2200))
        hubWindow.contentView?.layoutSubtreeIfNeeded()
        run.check(!FitProbe.frames("workbar.first", in: hubWindow).isEmpty && !FitProbe.frames("workbar.last", in: hubWindow).isEmpty,
                  "the note page shows the Work bar over a note without Distill on")
        run.check(!FitProbe.frames("workpanel", in: hubWindow).isEmpty, "and the Work panel beside it")
        if let directory, let content = hubWindow.contentView {
            capture(content, name: "put-on-board-note-light", directory: directory)
            hubWindow.appearance = NSAppearance(named: .darkAqua)
            try? await Task.sleep(for: .milliseconds(500))
            capture(content, name: "put-on-board-note-dark", directory: directory)
        }
        hubWindow.close()
        // A note with no cards still looks as it did.
        let bare = NoteItem(text: "# Groceries\n\nMilk and bread.")
        bare.binderID = web.id
        store.insert(bare)
        store.save()
        let plainWindow = HubWindowController.makeWindow(hub { $0.selection = .binder; $0.pendingBinderTab = .notes; $0.pendingNoteID = bare.id },
                                                         size: NSSize(width: 1440, height: 900))
        plainWindow.alphaValue = 0
        plainWindow.orderFrontRegardless()
        try? await Task.sleep(for: .milliseconds(1800))
        run.check(FitProbe.frames("workbar.first", in: plainWindow).isEmpty && !FitProbe.frames("note.bottom.first", in: plainWindow).isEmpty,
                  "a note with no cards has no Work bar, as before")
        plainWindow.close()

        // MARK: Grouped on the board, and staying in the note's group
        let grouping = BoardView.grouping(board.cards(in: web.id))
        let backlog = grouping.groups(in: .backlog).first { $0.note == note.id }
        run.check(backlog?.cards.count == 4 && backlog?.title == "Launch plan" && backlog?.progress?.line == "1 of 6 done",
                  "on the board, the note's cards are one group, with its progress: \(backlog.map { BoardGroups.spoken($0) } ?? "none")")
        run.check(grouping.groups(in: .inProgress).first?.note == note.id && grouping.groups(in: .done).first?.cards == [riskCard!.id],
                  "the card from before and the one done are in it too, in their columns")
        run.check(grouping.groups(in: .ready).first { $0.note == nil }?.cards == [todoCard.id], "the to-do's card is in no note's group")
        let moved = BoardBulk.group([lineCards[0], todoCard], into: other, board: board, undoManager: nil)
        run.check(lineCards[0].groupNote == note.id && todoCard.groupNote == other.id
                    && moved.line == "Put 1 card in “Venue”. 1 stayed: it was put on the board from “Launch plan”, so it stays in that note's group.",
                  "a card put on the board from the note stays in its group; one from elsewhere can go in another's: \(moved.line)")
        WorkPanel.selectOnBoard(note)
        let navigation = HubWindowController.shared.navigation
        run.check(navigation.pendingBoardSelection == Set(([old, whole!, riskCard!] + lineCards).map(\.id)), "Select on Board chooses the note's 6 cards")
        navigation.pendingBoardSelection = nil
        if let directory {
            AppDefaults.store.set(true, forKey: BoardView.groupKey(web.id))
            let boardWindow = HubWindowController.makeWindow(hub { $0.selection = .binder; $0.pendingBinderTab = .board }, size: NSSize(width: 1440, height: 900))
            boardWindow.alphaValue = 0
            boardWindow.orderFrontRegardless()
            try? await Task.sleep(for: .milliseconds(2000))
            if let content = boardWindow.contentView { capture(content, name: "put-on-board-board", directory: directory) }
            boardWindow.close()
            AppDefaults.store.removeObject(forKey: BoardView.groupKey(web.id))
        }

        // MARK: A section's change, said on its card; an agent hears who and how much, and gets no way into the note
        try? board.move(riskCard!, to: .ready, by: .you)
        store.save()
        let before = service.boardRevision
        for _ in 0..<30 where service.boardRevision == before { try? await Task.sleep(for: .milliseconds(100)) }
        run.check(DistillBoard.followsSections(note.id), "the note's sections are followed for its cards, Distill off")
        let previous = note.text
        let edited = previous.replacingOccurrences(of: "slow on old phones.", with: "slow on old phones and tablets.")
        note.text = edited
        NoteHistory.changed(note.id, previous: previous)
        service.settleNow(note.id)
        let line = board.timeline(riskCard!.id).last { $0.sectionChange != nil }
        run.check(line?.text.hasPrefix("The Risks section of “Launch plan” changed after this card was made: by you, 1 line added, 1 removed.") == true
                    && line?.text.contains("+ The sign-in page is slow on old phones and tablets.") == true,
                  "the card made from the Risks section says it changed, with the lines: \(line?.text.debugDescription ?? "none")")
        run.check(riskCard?.distilledFrom?.change?.added == 1 && SectionChangeMark(json: line?.sectionChange)?.withoutNote == true,
                  "and keeps the change, marked as one an agent hears only in short")
        run.check(([whole!, old] + lineCards).allSatisfy { card in !board.timeline(card.id).contains { $0.sectionChange != nil } },
                  "the whole note's card, the one from before and the Tasks cards say nothing: their sections didn't change")
        let task = run.object((await run.call("get_task", ["id": riskCard!.id.uuidString], as: echoActor)).text)
        let heard = (task["timeline"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.first { $0.contains("Risks section") }
        run.check(heard == "The Risks section of “Launch plan” changed after this card was made: by you, 1 line added, 1 removed.",
                  "an agent reading the card hears who changed which section and how much, never the lines: \(heard ?? "nothing")")
        run.check(task["note_id"] as? String == note.id.uuidString && task["note_title"] as? String == "Launch plan" && task["distilled_from"] == nil,
                  "get_task names the note it's among, and nothing more of it")
        let reach = await run.call("get_note_version", ["id": riskCard!.id.uuidString], as: echoActor)
        run.check(!reach.ok, "and the card is no way into the note: \(reach.text)")
        run.check(DistillBoard.note(forCard: riskCard!.id) == nil, "nor for the agent holding it")
        let listed = run.list((await run.call("list_tasks", ["binder": web.name], as: echoActor)).text)
        run.check(listed.first { $0["id"] as? String == old.id.uuidString }?["note_id"] as? String == note.id.uuidString,
                  "list_tasks names the note for the card from before too")

        // MARK: Distill Again leaves Put on Board's cards alone
        service.setDistill(true, for: note)
        let reader = PutOnBoardModelStandIn()
        service.model = { reader }
        guard case .success(let first) = await service.distill(note) else {
            run.check(false, "the note is distilled: \(service.problems[note.id] ?? "")")
            return 1
        }
        let placed = service.place(first, items: Set(first.items.map(\.id)), column: .ready)
        run.check(placed.count == 2, "Distill places its 2 cards beside them: \(placed.count)")
        run.check(DistillBoard.cards(of: note.id).count == 8, "the note has 8 cards now: \(DistillBoard.cards(of: note.id).count)")
        let puts = [whole!, riskCard!, old] + lineCards
        let kept = puts.map { ($0.id, $0.details, $0.title, $0.column) }
        let previousAgain = note.text
        note.text = """
            # Launch plan

            Everything for the beta, in one place.

            ## Tasks
            - [ ] Write the release notes for the testers
            - [ ] Record the demo film
            - [ ] Email the testers
            """
        NoteHistory.changed(note.id, previous: previousAgain)
        service.settleNow(note.id)
        guard case .success(let again) = await service.distill(note) else {
            run.check(false, "the note is distilled again: \(service.problems[note.id] ?? "")")
            return 1
        }
        let ids = Set(puts.map(\.id))
        run.check(!again.updates.isEmpty && again.updates.allSatisfy { !ids.contains($0.card) },
                  "Distill Again offers changes only for Distill's cards: \(again.updates.map(\.kind.rawValue))")
        for update in again.updates { service.take(update, of: again) }
        let distillRisk = placed.first { $0.distilledFrom?.section == "Risks" }
        run.check(distillRisk?.distilledFrom?.closed != nil, "Distill's card from the gone section is closed")
        run.check(puts.allSatisfy { $0.distilledFrom?.closed == nil } && zip(puts, kept).allSatisfy { card, was in
            card.details == was.1 && card.title == was.2 && card.column == was.3 },
                  "and none of Put on Board's cards is closed or rewritten")
        run.check(board.timeline(riskCard!.id).last { $0.sectionChange != nil }?.text.contains("is gone from “Launch plan”") == true,
                  "the card from the gone section says so, as a change, and stays open")
        _ = othersCard
        print(run.failures == 0 ? "PUT_ON_BOARD_DONE: all passed" : "PUT_ON_BOARD_DONE: \(run.failures) failed")
        return run.failures == 0 ? 0 : 1
    }
}

/// Stands in for the language model in the Put on Board self-test: two items for the note as written, and for the note
/// once its Risks section is gone, the Tasks item read again.
final class PutOnBoardModelStandIn: LLMClient, @unchecked Sendable {
    var model: String { "stand-in" }

    func complete(system: String, user: String, maxTokens: Int, temperature: Double, timeout: TimeInterval) async throws -> String {
        Self.reply(to: user)
    }

    func stream(system: String, user: String, maxTokens: Int, temperature: Double, timeout: TimeInterval,
                stopWhen: @escaping @Sendable (String) -> Bool) async throws -> String {
        Self.reply(to: user)
    }

    func listModels() async throws -> [String] { [model] }
    func warmUp() async {}

    static func reply(to user: String) -> String {
        user.contains("## Risks") ? first : again
    }

    static let first = """
        [
          {"title": "Write the release notes", "brief": "Notes for the beta testers.", "done_when": "The notes are sent.", "section": "Tasks", "quote": "Write the release notes", "for": "person"},
          {"title": "Speed up the sign-in page", "brief": "It's slow on old phones.", "done_when": "It loads in a second.", "section": "Risks", "quote": "The sign-in page is slow", "for": "agent"}
        ]
        """

    static let again = """
        [
          {"title": "Write the release notes", "brief": "Notes for the beta testers, with what changed.", "done_when": "The notes are sent.", "section": "Tasks", "quote": "Write the release notes for the testers", "for": "person"}
        ]
        """
}
