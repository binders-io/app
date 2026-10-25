import AppKit
import SwiftData
import SwiftUI
import BindersKit

extension SelfTest {
    /// The Distill list's keys, Undo, Split, Merge and Drop, the button's states and the Note menu, the panel at the smallest
    /// window, Reduce Motion and a reading in the background (lane DS9), after `distillListSelfTest` has read the note.
    @MainActor
    static func distillListChecks(_ run: DistillTestRun, list: DistillListModel, note: NoteItem, other: NoteItem, window first: NSWindow,
                                  hosting firstHosting: NSHostingView<AnyView>,
                                  open: (NoteItem, Bool?, NSSize) async -> (NSWindow, NSHostingView<AnyView>),
                                  directory: URL, gate: DistillItemGate, reader: DistillV2StandIn) async -> Int32 {
        var window = first
        var hosting = firstHosting
        func reopen(_ item: NoteItem, reduceMotion: Bool? = nil, size: NSSize = NSSize(width: 1500, height: 950)) async {
            // The new window first, then the old one goes; once more if the note didn't open in it.
            let old = window
            for _ in 0..<2 {
                (window, hosting) = await open(item, reduceMotion, size)
                if findEditor(in: hosting) != nil { break }
                window.close()
            }
            old.close()
        }
        func draw(_ name: String) {
            hosting.layoutSubtreeIfNeeded()
            findEditor(in: hosting)?.needsDisplay = true
            capture(hosting, name: name, directory: directory)
        }
        let controller = run.controller
        let service = controller.distill
        func settle(_ ms: Int = 250) async { try? await Task.sleep(for: .milliseconds(ms)) }
        func rows() -> [DistillListRow] { list.rows(service, text: note.text) }
        func item(_ id: UUID) -> DistillItem? { DistillStore.shared.file(for: note.id).distills.flatMap(\.items).first { $0.id == id } }
        let undo = UndoManager()
        undo.groupsByEvent = false
        func undoable(_ body: () -> Void) {
            undo.beginUndoGrouping()
            body()
            undo.endUndoGrouping()
        }
        func perform(_ outcome: DistillListModel.KeyOutcome?) {
            switch outcome {
            case .accept(let ids)?: undoable { list.accept(ids, service: service, undo: undo) }
            case .dismiss(let ids)?: undoable { list.dismiss(ids, service: service, undo: undo) }
            default: break
            }
        }

        // MARK: Split, Merge, Drop, Move
        let before = rows()
        if let first = before.first {
            list.split(first.id)
            let split = rows()
            run.check(split.count == before.count + 1 && split.contains { $0.item.title == first.item.title + " (part 2)" }, "Split makes a second part below it")
            if let part = split.first(where: { $0.item.title == first.item.title + " (part 2)" }) {
                list.merge(first.id, with: part.id)
                run.check(rows().count == before.count, "Merge with Next folds it back in")
            }
            if let second = before.dropFirst().first, before.count > 1, second.item.section == first.item.section {
                list.move(first.id, with: second.id)
                run.check(rows().first?.id == second.id, "Move Down swaps it with the row below")
                list.move(first.id, with: second.id)
            }
        }

        // MARK: Keys, with Undo
        list.selected = nil
        _ = list.key(.down, rows: rows())
        let firstRow = rows().first
        run.check(list.selected == firstRow?.id, "↓ selects the first row")
        _ = list.key(.down, rows: rows())
        _ = list.key(.up, rows: rows())
        run.check(list.selected == firstRow?.id, "↑ goes back up")
        let secondRow = rows().dropFirst().first
        perform(list.key(.accept, rows: rows()))
        let placedCard = firstRow.flatMap { item($0.id)?.card }
        run.check(placedCard.flatMap { controller.board.card($0) } != nil, "Return accepts: the item is a card on the board")
        run.check(controller.board.card(placedCard ?? UUID())?.binderID == note.binderID, "on the note's board, as Place on Board puts it")
        run.check(list.placed.first?.line == "Placed on Web", "with “Placed on Web · Undo”: \(list.placed.first?.line ?? "none")")
        run.check(list.selected == secondRow?.id, "and the next row is selected")
        run.check(!rows().contains { $0.id == firstRow?.id }, "the accepted row leaves the list")
        undo.undo()
        run.check(firstRow.map { item($0.id)?.card == nil } == true && placedCard.flatMap { controller.board.card($0) } == nil,
                  "Undo takes the card off the board and the item waits again")
        run.check(rows().contains { $0.id == firstRow?.id }, "back in the list")
        list.selected = secondRow?.id
        perform(list.key(.dismiss, rows: rows()))
        run.check(secondRow.map { item($0.id)?.dropped == true } == true, "Delete dismisses: the item is left out")
        undo.undo()
        run.check(secondRow.map { item($0.id)?.dropped == false } == true, "Undo brings it back")
        list.selected = secondRow?.id
        perform(list.key(.dismiss, rows: rows()))
        list.selected = rows().first?.id
        run.check(list.key(.edit, rows: rows()) == .handled && list.editing == rows().first?.id, "Space opens the row to edit")
        if let id = list.editing {
            list.edit(id) { $0.title = "Put the whole checkout on one page" }
            run.check(item(id)?.title == "Put the whole checkout on one page", "an edit is kept in the proposal")
        }
        run.check(list.key(.escape, rows: rows()) == .handled && list.editing == nil, "Escape closes it")
        await settle(300)
        draw("distill-list-after-keys")

        // Distill Again never proposes a dismissed item again.
        let dismissedTitle = secondRow?.item.title ?? ""
        DistillActions.start(note, controller: controller, full: true)
        for _ in 0..<50 where !service.reading.contains(note.id) { await settle(20) }
        for _ in 0..<200 where service.reading.contains(note.id) { await settle(30) }
        await settle(300)
        run.check(!rows().contains { $0.item.title == dismissedTitle }, "Distill Again doesn't propose the dismissed item again")

        // ⌘Return accepts every one left.
        let left = rows().count
        perform(list.key(.acceptAll, rows: rows()))
        run.check(left > 0 && rows().isEmpty, "⌘Return accepts every one left: \(left)")
        run.check(list.placed.last?.line == "Placed \(left) on Web" || left == 1, "“Placed \(left) on Web”: \(list.placed.last?.line ?? "none")")
        undo.undo()
        run.check(rows().count == left, "and Undo puts them all back")

        // MARK: The button's states
        func face() -> DistillButtonFace {
            DistillButtonFace.face(reading: service.reading.contains(note.id) && !service.quietReading.contains(note.id) ? service.readingItems[note.id] ?? 0 : nil,
                                   newItems: list.newItems.count, upToDateUntil: list.upToDateUntil)
        }
        run.check(face() == .idle, "idle, it says Distill")
        let asked = reader.asks.count
        DistillActions.press(note, controller: controller)
        run.check(reader.asks.count == asked && !service.reading.contains(note.id), "nothing changed: Distill asks the model nothing")
        run.check(face() == .upToDate && DistillActions.upToDateLine(note.id)?.hasPrefix("Up to date · read") == true,
                  "and says Up to date (\(DistillActions.upToDateLine(note.id) ?? "none"))")
        await settle(200)
        draw("distill-button-up-to-date")
        list.upToDateUntil = nil
        list.found(Array(rows().prefix(3).map(\.id)))
        run.check(face() == .new(3), "items found in the background: “3 new”")
        await settle(200)
        draw("distill-button-3-new")
        list.looked()
        run.check(face() == .idle, "looking at the list clears it")

        // MARK: Every note has it, and the Note menu's Distill (⇧⌘D)
        run.check(MenuCommand.distill.defaultShortcut == Hotkey(modifiers: [.command, .shift], keyCode: 2), "Distill is ⇧⌘D in the Note menu")
        run.check(MenuShortcuts.conflict(for: Hotkey(modifiers: [.command, .shift], keyCode: 2), except: .distill) == nil, "and no other command has ⇧⌘D")
        await reopen(other)
        run.check(!FitProbe.frames("distill.button", in: window).isEmpty, "a note never distilled has the button too, in the same place")
        gate.openWide()
        NotificationCenter.default.post(name: DistillActions.fromMenu, object: nil, userInfo: ["note": other.id, "popout": false])
        await settle(100)
        run.check(other.distill, "the Note menu's Distill turns Distill on for the note in front, and reads it")
        for _ in 0..<100 where service.reading.contains(other.id) { await settle(30) }
        await settle(400)
        draw("distill-other-note")

        // MARK: The smallest window: the list over the note
        await reopen(note, size: HubWindowController.smallestSize)
        DistillActions.open(note.id)
        await settle(700)
        let panel = FitProbe.frames("distill.list", in: window).first
        let inside = window.contentView.map { $0.bounds } ?? .zero
        run.check(panel.map { inside.insetBy(dx: -1, dy: -1).contains($0) } == true, "at the smallest window the list shows, inside it: \(panel.map { "\($0)" } ?? "none")")
        draw("distill-list-smallest")
        window.appearance = NSAppearance(named: .darkAqua)
        await settle(400)
        draw("distill-list-smallest-dark")
        window.appearance = NSAppearance(named: .aqua)

        // MARK: Reduce Motion: no sweep, no cards; a steady light
        await reopen(note, reduceMotion: true)
        gate.close()
        DistillActions.start(note, controller: controller, full: true)
        for _ in 0..<100 where (service.live[note.id]?.items.count ?? 0) < 1 || !service.reading.contains(note.id) { await settle(30) }
        await settle(400)
        let text = findEditor(in: hosting)
        run.check(text?.distillState.given?.reduceMotion == true, "Reduce Motion reaches the note's editor")
        run.check(text?.distillState.link == nil, "and nothing moves in it: no display link")
        draw("distill-reduce-motion")
        gate.openWide()
        for _ in 0..<200 where service.reading.contains(note.id) { await settle(30) }
        await reopen(note)

        // MARK: The list closed: the cards fly into the button
        let third = NoteItem(text: note.text.replacingOccurrences(of: "Checkout redesign", with: "Checkout for the second shop"))
        third.binderID = note.binderID
        Store.shared.insert(third)
        await reopen(third)
        let thirdList = service.list(for: third.id)
        thirdList.landsOnItsOwn = false
        gate.close()
        DistillActions.press(third, controller: controller)
        await settle(200)
        AppDefaults.store.set("work", forKey: "notesSidePanel")
        gate.allow(1)
        for _ in 0..<100 where thirdList.launches.count < 2 { await settle(30) }
        await settle(300)
        if let launch = thirdList.launches.last {
            DistillMotion.held = launch.start.addingTimeInterval(DistillFlights.duration * 0.55)
            await settle(160)
            draw("distill-frame-9-into-button")
            DistillMotion.held = launch.start.addingTimeInterval(DistillFlights.duration * 0.9)
            await settle(160)
            draw("distill-frame-10-into-button-late")
            DistillMotion.held = nil
        }
        run.check(thirdList.launches.count >= 1, "with the list closed, cards still fly (into the button)")
        thirdList.landsOnItsOwn = true
        thirdList.launches.forEach { thirdList.landed($0.id) }
        gate.openWide()
        for _ in 0..<200 where service.reading.contains(third.id) { await settle(30) }
        AppDefaults.store.set("distill", forKey: "notesSidePanel")
        await reopen(note)

        // MARK: A reading in the background: quiet
        service.backgroundModel = { reader }
        list.readingStarted()
        let quietBefore = list.launches.count
        note.text += "\n\n## Receipts\nSend a receipt by email after paying, with the order number.\n"
        reader.slowFirst = true
        let refreshing = Task { await service.refresh(note: note, background: true) }
        var sawQuiet = false, sawSweep = false
        for _ in 0..<100 {
            if service.quietReading.contains(note.id) {
                sawQuiet = true
                await settle(60)
                if findEditor(in: hosting)?.distillState.given?.reading != nil { sawSweep = true }
            }
            if !service.reading.contains(note.id), sawQuiet { break }
            await settle(10)
        }
        _ = await refreshing.value
        reader.slowFirst = false
        run.check(sawQuiet && !sawSweep, "a reading in the background is quiet: no sweep in the note")
        run.check(list.launches.count == quietBefore && list.found.isEmpty, "and no cards fly")
        reader.peek = nil

        // MARK: Frame time on a long note (about 60,000 characters)
        let long = NoteItem(text: DistillBench.longStatus.text)
        long.binderID = note.binderID
        Store.shared.insert(long)
        await reopen(long)
        if let text = findEditor(in: hosting), let layout = text.layoutManager, let container = text.textContainer {
            layout.ensureLayout(for: container)
            let part = String(long.text.prefix(14_000))
            let since = Date()
            text.setDistill(EditorDistill(reading: DistillLines(part), readingSince: since, accent: BindersTheme.NS.accent))
            if let area = text.sweepArea() { text.scroll(NSPoint(x: 0, y: area.minY + 900)) }
            var worst = 0.0, total = 0.0
            let frames = 90
            for step in 0..<frames {
                DistillMotion.held = since.addingTimeInterval(Double(step) / 60)
                let started = Date()
                text.redrawDistillFrame()
                text.displayIfNeeded()
                let took = Date().timeIntervalSince(started)
                total += took
                worst = max(worst, took)
            }
            DistillMotion.held = nil
            let span = text.distillState.span?.length ?? 0
            run.check(span > 10_000, "the long note's first part is the stretch being read: \(span) characters")
            run.check(total / Double(frames) < 1.0 / 60 && worst < 1.0 / 30,
                      "on the long note a frame of the sweep takes \(String(format: "%.2f", total / Double(frames) * 1000)) ms on average, \(String(format: "%.2f", worst * 1000)) at most")
            print("NOTE: sweep frame on a \(long.text.count)-character note: \(String(format: "%.2f", total / Double(frames) * 1000)) ms average, \(String(format: "%.2f", worst * 1000)) ms worst")
            DistillMotion.held = since.addingTimeInterval(1.1)
            text.redrawDistillFrame()
            text.displayIfNeeded()
            draw("distill-frame-long-note-sweep")
            DistillMotion.held = nil
            text.setDistill(nil)
        }

        window.close()
        return run.failures == 0 ? 0 : 1
    }

    /// The note's editor in a view.
    @MainActor
    static func findEditor(in view: NSView) -> MarkdownTextView? {
        if let text = view as? MarkdownTextView { return text }
        for sub in view.subviews { if let found = findEditor(in: sub) { return found } }
        return nil
    }
}
