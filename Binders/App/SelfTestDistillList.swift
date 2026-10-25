import AppKit
import SwiftData
import SwiftUI
import BindersKit

/// Lets the v2 stand-in write one item at a time, as the self-test says (lane DS9).
final class DistillItemGate: @unchecked Sendable {
    private let lock = NSLock()
    private var permits = 0
    private var open = false
    private var _written = 0
    var written: Int { lock.withLock { _written } }

    func allow(_ count: Int) { lock.withLock { permits += count } }
    func openWide() { lock.withLock { open = true } }
    func close() { lock.withLock { open = false; permits = 0 } }

    /// After each item: waits for a permit.
    func pass() async {
        lock.withLock { _written += 1 }
        while true {
            let go: Bool = lock.withLock {
                if open { return true }
                if permits > 0 { permits -= 1; return true }
                return false
            }
            if go { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }
}

extension SelfTest {
    /// The Distill list beside the note, the Distill button and the distilling motion (lane DS9), in a throwaway folder
    /// (BINDERS_DATA_DIR) with the v2 stand-in model: items showing in the list one by one in the note's order; keys
    /// accepting, dismissing, accepting all, with Undo; a row selected lighting and scrolling to its lines, a click on a lit
    /// line selecting its row; Split, Merge and Drop; the panel at the smallest window; the button in every note, its first
    /// click turning Distill on and reading, its states, the Note menu's Distill (⇧⌘D); and frames of the motion (the sweep,
    /// a card in flight and landing, Reduce Motion, nothing for a reading in the background, the time a frame takes on a long
    /// note). Pictures and frames go to the folder given.
    ///
    ///     BINDERS_DATA_DIR=<new empty folder> Binders --selftest-distill-list <folder> -notesShowMarkdown NO
    @MainActor
    static func distillListSelfTest(to directory: URL) async -> Int32 {
        guard AppPaths.isDemo else {
            print("ERROR: set BINDERS_DATA_DIR to an empty folder; this test writes notes, cards and agents")
            return 1
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let controller = DictationController()
        let run = DistillTestRun(controller: controller)
        let store = Store.shared
        let service = controller.distill
        let registry = AgentRegistry.shared
        if registry.paused { registry.setPaused(false) }
        service.start()
        service.settleDelay = .seconds(600)
        service.format = .v2
        service.progressEvery = 0
        service.background.idle = .seconds(3600)
        HubWindowController.shared.controller = HubWindowController.shared.controller ?? controller
        registry.upsert(AgentProfile(name: "Claude Code · checkout", wake: .board, purpose: "the checkout's web pages and payments"))
        registry.upsert(AgentProfile(name: "Pennant", wake: .board, purpose: "errands and email"))
        let web = BinderRecord(name: "Web", colorIndex: 0)
        store.insert(web)
        let spec = DistillBench.specs.first { $0.name == "Checkout redesign" }!
        let note = NoteItem(text: spec.text)
        note.binderID = web.id
        store.insert(note)
        let other = NoteItem(text: "# Team offsite\n\nBook the venue and send the agenda.")
        other.binderID = web.id
        store.insert(other)

        let gate = DistillItemGate()
        let reader = DistillV2StandIn(spec: spec)
        reader.peek = { await gate.pass() }
        service.model = { reader }
        service.briefModel = { BriefStandIn() }
        AppDefaults.store.set(true, forKey: "notesShowDigest")
        AppDefaults.store.set(330.0, forKey: "notesDigestWidth")
        AppDefaults.store.set("distill", forKey: "notesSidePanel")

        // The note page, in the app's window as it draws in the hub.
        func root(_ navigation: HubNavigation, reduceMotion: Bool? = nil) -> AnyView {
            AnyView(HubView().environment(navigation).environment(controller).environment(controller.team)
                .environment(controller.knowledge).environment(controller.meetings).environment(controller.capture)
                .environment(controller.commitments).environment(AppSettings.shared).modelContainer(store.container)
                .environment(\.reduceMotionOverride, reduceMotion)
                .defaultAppStorage(throwawayDefaults))
        }
        func navigation(to item: NoteItem) -> HubNavigation {
            let navigation = HubNavigation()
            navigation.binderID = web.id
            navigation.pendingBinderTab = .notes
            navigation.pendingNoteID = item.id
            navigation.selection = .binder
            return navigation
        }
        FitProbe.isOn = true
        defer { FitProbe.isOn = false }
        /// A window of its own for each page, as the drawings do.
        func open(_ item: NoteItem, reduceMotion: Bool? = nil, size: NSSize = NSSize(width: 1500, height: 950)) async -> (NSWindow, NSHostingView<AnyView>) {
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.alphaValue = 0
            let hosting = NSHostingView(rootView: root(navigation(to: item), reduceMotion: reduceMotion))
            window.contentView = hosting
            window.appearance = NSAppearance(named: .aqua)
            window.orderFrontRegardless()
            try? await Task.sleep(for: .milliseconds(1500))
            // A busy Mac takes longer to open the note: up to 8 seconds more.
            for _ in 0..<40 where findEditor(in: hosting) == nil { try? await Task.sleep(for: .milliseconds(200)) }
            try? await Task.sleep(for: .milliseconds(300))
            return (window, hosting)
        }
        var (window, hosting) = await open(note)
        if findEditor(in: hosting) == nil {
            // Once more, when the note didn't open in it.
            window.close()
            (window, hosting) = await open(note)
        }
        run.check(findEditor(in: hosting) != nil, "the note opens in the window")
        func editor() -> MarkdownTextView? {
            func walk(_ view: NSView) -> MarkdownTextView? {
                if let text = view as? MarkdownTextView { return text }
                for sub in view.subviews { if let found = walk(sub) { return found } }
                return nil
            }
            return walk(hosting)
        }
        var shot = 0
        func draw(_ name: String) {
            shot += 1
            hosting.layoutSubtreeIfNeeded()
            editor()?.needsDisplay = true
            capture(hosting, name: name, directory: directory)
        }
        func settle(_ ms: Int = 250) async { try? await Task.sleep(for: .milliseconds(ms)) }

        // MARK: The button, in every note
        run.check(!FitProbe.frames("distill.button", in: window).isEmpty, "the Distill button is in the note's toolbar")
        if let button = FitProbe.frames("distill.button", in: window).first, let bold = FitProbe.frames("toolbar.first", in: window).first {
            run.check(button.height > bold.height, "it's larger than the toolbar's icons: \(Int(button.height)) against \(Int(bold.height))")
        }
        draw("distill-button-idle")
        let list = service.list(for: note.id)
        list.landsOnItsOwn = false

        // MARK: First click: Distill on, reading, items one by one
        run.check(!note.distill, "the note isn't distilled yet")
        DistillActions.press(note, controller: controller)
        run.check(note.distill, "the first click turns Distill on for the note")
        for _ in 0..<100 where service.live[note.id]?.items.isEmpty ?? true { await settle(30) }
        run.check(service.reading.contains(note.id), "and reads it at once")
        run.check(service.live[note.id]?.items.count == 1, "the first item shows as soon as it's written: \(service.live[note.id]?.items.count ?? 0)")
        await settle(300)
        let rows1 = list.rows(service, text: note.text)
        run.check(rows1.count == 1 && rows1.first?.live == true, "the list has its row while the note is read")
        run.check(list.launches.count == 1, "a card sets off for it")
        run.check(service.readingLines[note.id] != nil, "the part being read is known, for the sweep")

        // The motion, frame by frame, the clock held still.
        if let launch = list.launches.first {
            for (index, t) in [0.06, 0.3, 0.52, 0.78].enumerated() {
                DistillMotion.held = launch.start.addingTimeInterval(t * DistillFlights.duration)
                await settle(160)
                draw("distill-frame-\(index + 1)-\(["liftoff", "rising", "arc", "landing"][index])")
            }
            DistillMotion.held = launch.start.addingTimeInterval(DistillFlights.duration + 0.05)
            list.landed(launch.id)
            await settle(200)
            draw("distill-frame-5-landed")
        }
        // Two found at once: one after the other, never piled up.
        gate.allow(2)
        for _ in 0..<100 where list.launches.count < 2 { await settle(30) }
        let pair = list.launches
        run.check(pair.count == 2, "two found together: two cards: \(pair.count)")
        if pair.count == 2 {
            run.check(abs(pair[1].start.timeIntervalSince(pair[0].start) - DistillFlights.gap) < 0.01, "a moment apart: \(pair[1].start.timeIntervalSince(pair[0].start))")
            DistillMotion.held = pair[0].start.addingTimeInterval(0.42)
            await settle(160)
            draw("distill-frame-6-two-in-flight")
            window.appearance = NSAppearance(named: .darkAqua)
            editor()?.restyle()
            await settle(250)
            draw("distill-frame-6-two-in-flight-dark")
            DistillMotion.held = pair[0].start.addingTimeInterval(0.15)
            await settle(160)
            draw("distill-frame-6-liftoff-dark")
            window.appearance = NSAppearance(named: .aqua)
            editor()?.restyle()
            DistillMotion.held = pair[1].start.addingTimeInterval(DistillFlights.duration + 0.05)
            pair.forEach { list.landed($0.id) }
        }
        // The sweep, at two moments.
        if let since = list.readingSince {
            for (index, t) in [0.9, 1.6].enumerated() {
                DistillMotion.held = since.addingTimeInterval(t)
                await settle(160)
                draw("distill-frame-\(7 + index)-sweep")
            }
        }
        // Frame time: one sweep frame on this note.
        run.check(editor() != nil, "the note's editor is there to draw in")
        if let text = editor() {
            let before = (text.distillState.frames, text.distillState.drawing)
            let started = Date()
            for step in 0..<30 {
                DistillMotion.held = (list.readingSince ?? Date()).addingTimeInterval(Double(step) / 60)
                text.redrawDistillFrame()
                text.displayIfNeeded()
            }
            let wall = Date().timeIntervalSince(started) / 30
            let drawn = text.distillState.frames - before.0
            run.check(drawn > 0, "the sweep draws behind the text: \(drawn) passes")
            run.check(wall < 1.0 / 60, "a frame of the sweep takes \(String(format: "%.1f", wall * 1000)) ms (under 16.7)")
        }
        DistillMotion.held = nil
        run.check(rows1.count <= list.rows(service, text: note.text).count, "rows only come, in the note's order")

        // The rest, then the proposal.
        gate.openWide()
        for _ in 0..<200 where service.reading.contains(note.id) { await settle(30) }
        list.landsOnItsOwn = true
        list.launches.forEach { list.landed($0.id) }
        let rows = list.rows(service, text: note.text)
        run.check(!service.reading.contains(note.id), "the reading ends")
        run.check(rows.count >= 5 && rows.allSatisfy { !$0.live }, "every item is a row of the proposal: \(rows.count)")
        let order = rows.map { DistillSections.sections(of: note.text).map(\.heading).firstIndex(of: $0.item.section) ?? 0 }
        run.check(order == order.sorted(), "in the note's order: \(order)")
        let live = service.live[note.id]?.items.map(\.id) ?? []
        run.check(Set(rows.map(\.id)).isSubset(of: Set(live)) || live.isEmpty, "each row kept the id it had while read")
        await settle(400)
        draw("distill-list-light")
        window.appearance = NSAppearance(named: .darkAqua)
        editor()?.restyle()
        await settle(400)
        draw("distill-list-dark")

        // A row selected lights its lines in the note; a dark frame mid-flight too.
        list.selected = rows.last?.id
        await settle(500)
        draw("distill-selected-dark")
        if let text = editor(), let id = rows.last?.id {
            run.check(text.distillState.ranges[id]?.isEmpty == false, "the selected row's lines are found in the note")
            run.check(text.distillRect(for: id).map { text.visibleRect.intersects($0) } == true, "and scrolled into sight")
            // A click on another lit line selects its row.
            if let first = rows.first, let rect = text.distillRect(for: first.id) {
                text.scrollToDistill(first.id)
                text.distillClicked(at: NSPoint(x: rect.minX + 30, y: rect.midY))
                run.check(list.selected == first.id, "a click on a lit line in the note selects its row")
            }
        }
        window.appearance = NSAppearance(named: .aqua)
        editor()?.restyle()
        list.selected = rows.first?.id
        await settle(400)
        draw("distill-selected-light")

        return await distillListChecks(run, list: list, note: note, other: other, window: window, hosting: hosting, open: open,
                                       directory: directory, gate: gate, reader: reader)
    }
}
