import AppKit
import AVFoundation
import SwiftData
import SwiftUI
import BindersKit

extension SelfTest {
    /// A long editing session on a throwaway store: typing, formatting, ticking, switching notes, text changing from
    /// elsewhere, and undo and redo all the way through. Undo once reached into an editor that had gone with the note
    /// it showed, and crashed the app.
    @MainActor
    static func notesStressSelfTest() async -> Int32 {
        guard AppPaths.isDemo else {
            print("ERROR: run with BINDERS_DATA_DIR pointing at a throwaway folder")
            return 1
        }
        var failures = 0
        func check(_ passed: Bool, _ label: String) {
            print("\(passed ? "PASS" : "FAIL"): \(label)")
            if !passed { failures += 1 }
        }
        let controller = DictationController()
        let binder = Store.shared.defaultBinder()
        let notes = (1...4).map { index in
            let note = NoteItem(text: "# Note \(index)\n\nWhere this one starts.\n\n- [ ] Something to do")
            note.binderID = binder.id
            Store.shared.insert(note)
            return note
        }
        let navigation = HubNavigation()
        navigation.binderID = binder.id
        navigation.selection = .binder
        navigation.pendingBinderTab = .notes
        let hosting = NSHostingView(rootView: HubView()
            .environment(controller).environment(controller.meetings).environment(controller.knowledge).environment(controller.team)
            .environment(controller.capture).environment(controller.commitments).environment(navigation).environment(AppSettings.shared)
            .modelContainer(Store.shared.container))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1300, height: 760), styleMask: [.titled, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        try? await Task.sleep(for: .milliseconds(800))

        func editor() -> MarkdownTextView? {
            func find(_ view: NSView) -> MarkdownTextView? { (view as? MarkdownTextView) ?? view.subviews.lazy.compactMap(find).first }
            return find(hosting)
        }
        /// ⌘Z and ⌘⇧Z, the way the Edit menu sends them: to whatever has focus, and up the chain from there.
        var undone = 0
        var gone: [Weak] = []
        func send(_ action: String) {
            let selector = Selector((action))
            if action == "undo:", (window.firstResponder?.undoManager ?? window.undoManager)?.canUndo == true { undone += 1 }
            if !(window.firstResponder ?? window).tryToPerform(selector, with: nil) {
                if action == "undo:" { window.undoManager?.undo() } else { window.undoManager?.redo() }
            }
        }
        func end(_ textView: NSTextView) { textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0)) }

        var mismatches = 0
        for round in 0..<36 {
            let note = notes[round % notes.count]
            navigation.pendingNoteID = note.id
            try? await Task.sleep(for: .milliseconds(200))
            // Undo straight after switching, before touching the new note: what the old editor left behind.
            send("undo:")
            try? await Task.sleep(for: .milliseconds(30))
            guard let textView = editor() else {
                check(false, "the editor opens for “\(note.title)”")
                break
            }
            gone.append(Weak(textView))
            window.makeFirstResponder(textView)
            for word in ["Some", " words", " typed", " in round \(round)."] {
                end(textView)
                textView.insertText(word, replacementRange: textView.selectedRange())
                try? await Task.sleep(for: .milliseconds(15))
            }
            if round == 0 {
                end(textView)
                textView.insertText(" Undo me.", replacementRange: textView.selectedRange())
                try? await Task.sleep(for: .milliseconds(30))
                send("undo:")
                try? await Task.sleep(for: .milliseconds(30))
                MarkdownEditor.flushAll()
                check(!textView.string.contains("Undo me") && !note.text.contains("Undo me"), "⌘Z takes back what was just typed")
                send("redo:")
                try? await Task.sleep(for: .milliseconds(30))
                MarkdownEditor.flushAll()
                check(note.text.contains("Undo me"), "⌘⇧Z puts it back")
            }
            textView.insertNewline(nil)
            textView.insertText("- [ ] A task from round \(round)", replacementRange: textView.selectedRange())
            textView.run(.bold)
            textView.insertText("loud", replacementRange: textView.selectedRange())
            textView.run(.heading(2))
            try? await Task.sleep(for: .milliseconds(30))
            // Text from elsewhere, as sync, a digest or the Scratchpad would put it.
            if round % 3 == 0 {
                MarkdownEditor.flushAll()
                note.text += "\n\nA line from a teammate in round \(round)."
                try? await Task.sleep(for: .milliseconds(60))
            }
            for _ in 0..<4 {
                send("undo:")
                try? await Task.sleep(for: .milliseconds(15))
            }
            send("redo:")
            try? await Task.sleep(for: .milliseconds(30))
            MarkdownEditor.flushAll()
            if textView.string != note.text { mismatches += 1 }
            // Deleting a lot, then putting it back.
            textView.selectAll(nil)
            textView.deleteBackward(nil)
            try? await Task.sleep(for: .milliseconds(20))
            send("undo:")
            try? await Task.sleep(for: .milliseconds(30))
            MarkdownEditor.flushAll()
            if textView.string != note.text { mismatches += 1 }
        }
        print("UNDONE: \(undone) · editors made \(gone.count), still alive \(gone.filter { $0.object != nil }.count) · window undo \(window.undoManager?.canUndo == true) · same manager \(editor()?.undoManager === window.undoManager)")
        check(mismatches == 0, "the note always holds what the editor shows (\(mismatches) times it didn't)")
        // A card's description, edited in a sheet that then closes: its undo is the hub window's.
        let card = TaskCard(title: "Plan the offsite", binderID: binder.id)
        card.binderID = binder.id
        Store.shared.insert(card)
        navigation.pendingBinderTab = .board
        try? await Task.sleep(for: .milliseconds(500))
        for round in 0..<3 {
            navigation.pendingCardID = card.id
            try? await Task.sleep(for: .milliseconds(700))
            let sheet = window.attachedSheet
            check(sheet != nil, "the card opens in a sheet (\(round + 1))")
            func findEditor(_ view: NSView) -> MarkdownTextView? { (view as? MarkdownTextView) ?? view.subviews.lazy.compactMap(findEditor).first }
            if let sheet, let content = sheet.contentView, let textView = findEditor(content) {
                sheet.makeFirstResponder(textView)
                for word in ["Book", " the", " room", " for round \(round)."] {
                    end(textView)
                    textView.insertText(word, replacementRange: textView.selectedRange())
                    try? await Task.sleep(for: .milliseconds(20))
                }
                window.endSheet(sheet)
            }
            try? await Task.sleep(for: .milliseconds(700))
            for _ in 0..<3 {
                send("undo:")
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
        // The Scratchpad: shown again, it gets a new editor.
        ScratchpadController.shared.show()
        try? await Task.sleep(for: .milliseconds(500))
        for round in 0..<4 {
            guard let panel = NSApp.windows.first(where: { $0.title == "Scratchpad" }), let content = panel.contentView else {
                check(false, "the Scratchpad opens")
                break
            }
            func findEditor(_ view: NSView) -> MarkdownTextView? { (view as? MarkdownTextView) ?? view.subviews.lazy.compactMap(findEditor).first }
            if let textView = findEditor(content) {
                panel.makeFirstResponder(textView)
                for word in ["Scratch", " words", " \(round)."] {
                    end(textView)
                    textView.insertText(word, replacementRange: textView.selectedRange())
                    try? await Task.sleep(for: .milliseconds(20))
                }
            }
            ScratchpadController.shared.show()
            try? await Task.sleep(for: .milliseconds(400))
            for _ in 0..<3 {
                if !(panel.firstResponder ?? panel).tryToPerform(Selector(("undo:")), with: nil) { panel.undoManager?.undo() }
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
        NSApp.windows.first { $0.title == "Scratchpad" }?.orderOut(nil)
        // Everything left to undo, across every note that was open.
        for _ in 0..<300 {
            send("undo:")
            if window.undoManager?.canUndo != true, editor()?.undoManager?.canUndo != true { break }
        }
        try? await Task.sleep(for: .milliseconds(100))
        check(true, "undo and redo after switching notes, typing, formatting and outside changes didn't crash")
        check(notes.allSatisfy { $0.modelContext != nil && $0.text.hasPrefix("# Note") }, "every note is still there and starts as it did")
        window.close()
        notes.forEach { Store.shared.delete($0) }
        print(failures == 0 ? "NOTES_STRESS_OK" : "NOTES_STRESS_FAILED: \(failures)")
        return failures == 0 ? 0 : 1
    }
}

extension SelfTest {
    /// Deleting notes from the list with ⌫ and ⌦, and Undo putting them back whole, on a throwaway store.
    @MainActor
    static func notesDeleteSelfTest() async -> Int32 {
        guard AppPaths.isDemo else {
            print("ERROR: run with BINDERS_DATA_DIR pointing at a throwaway folder")
            return 1
        }
        var failures = 0
        func check(_ passed: Bool, _ label: String) {
            print("\(passed ? "PASS" : "FAIL"): \(label)")
            if !passed { failures += 1 }
        }
        let controller = DictationController()
        let binder = Store.shared.defaultBinder()
        let notes = ["Groceries", "Offsite plan", "Reading list"].enumerated().map { index, title in
            let note = NoteItem(text: "# \(title)\n\nSomething about \(title.lowercased()).")
            note.binderID = binder.id
            note.status = index == 1 ? "Doing" : nil
            note.updatedAt = Date().addingTimeInterval(-Double(index) * 3600)
            Store.shared.insert(note)
            return note
        }
        let doomed = notes[1]
        NoteHistory.keep("# Offsite plan\n\nAn earlier draft.", for: doomed.id, at: Date().addingTimeInterval(-600))
        let navigation = HubNavigation()
        navigation.binderID = binder.id
        navigation.selection = .binder
        navigation.pendingBinderTab = .notes
        let hosting = NSHostingView(rootView: HubView()
            .environment(controller).environment(controller.meetings).environment(controller.knowledge).environment(controller.team)
            .environment(controller.capture).environment(controller.commitments).environment(navigation).environment(AppSettings.shared)
            .modelContainer(Store.shared.container))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1300, height: 760), styleMask: [.titled, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        try? await Task.sleep(for: .milliseconds(800))
        navigation.pendingNoteID = doomed.id
        try? await Task.sleep(for: .milliseconds(400))

        func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? { (view as? T) ?? view.subviews.lazy.compactMap { find(type, in: $0) }.first }
        func press(_ characters: String, code: UInt16) {
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: window.windowNumber, context: nil, characters: characters,
                                               charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code) else { return }
            window.sendEvent(event)
        }
        guard let list = find(NSTableView.self, in: hosting) else {
            check(false, "the notes list is there")
            return 1
        }
        // The list only takes ⌫ as Delete in the key window, as it is when you use it.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(list)
        // SwiftUI follows focus a moment after AppKit does.
        try? await Task.sleep(for: .milliseconds(300))
        press("\u{7F}", code: 51)
        try? await Task.sleep(for: .milliseconds(500))
        check(Store.shared.note(doomed.id) == nil, "⌫ in the list deletes the selected note, without asking")
        check(NoteTrash.shared.last?.title == "Offsite plan", "and offers to undo it")
        check(window.attachedSheet == nil, "no dialog in the way")
        check(!NoteHistory.versions(of: doomed.id).isEmpty, "its history is kept for Undo")

        window.makeFirstResponder(list)
        _ = (window.firstResponder ?? window).tryToPerform(Selector(("undo:")), with: nil)
        try? await Task.sleep(for: .milliseconds(500))
        let back = Store.shared.note(doomed.id)
        check(back?.text == "# Offsite plan\n\nSomething about offsite plan." && back?.status == "Doing" && back?.binderID == binder.id,
              "⌘Z puts it back as it was")
        check(NoteHistory.versions(of: doomed.id).count == 1, "with its history")

        navigation.pendingNoteID = notes[0].id
        try? await Task.sleep(for: .milliseconds(400))
        window.makeFirstResponder(list)
        try? await Task.sleep(for: .milliseconds(300))
        press(String(UnicodeScalar(NSDeleteFunctionKey)!), code: 117)
        try? await Task.sleep(for: .milliseconds(500))
        check(Store.shared.note(notes[0].id) == nil, "⌦ deletes too")
        NoteHistory.forgetDeletedNotes()
        check(!NoteHistory.versions(of: doomed.id).isEmpty, "the next launch keeps the history of notes that are there")
        Store.shared.note(doomed.id).map { Store.shared.delete($0, keepingHistory: true) }
        NoteHistory.forgetDeletedNotes()
        check(NoteHistory.versions(of: doomed.id).isEmpty, "and clears the history of notes that are gone")
        window.close()
        print(failures == 0 ? "NOTES_DELETE_OK" : "NOTES_DELETE_FAILED: \(failures)")
        return failures == 0 ? 0 : 1
    }
}

extension SelfTest {
    /// How long a keystroke takes in a long note, on the Notes page with a library of notes around it.
    @MainActor
    static func notesSpeedSelfTest() async -> Int32 {
        guard AppPaths.isDemo else {
            print("ERROR: run with BINDERS_DATA_DIR pointing at a throwaway folder")
            return 1
        }
        let controller = DictationController()
        let binder = Store.shared.defaultBinder()
        let block = """
        ## Section
        Some text with **bold**, *italic*, `code`, a [link](https://example.com), a [[Linked note]] and a #tag.
        - [ ] A task to do
        - [x] A task done
        1. A numbered point
        > A quote that runs on for a while so it wraps across the line at least once in the editor.

        ```swift
        let value = 42
        ```

        """
        let lines = Int(ProcessInfo.processInfo.environment["BINDERS_SPEED_SECTIONS"] ?? "") ?? 300
        let long = NoteItem(text: "# A long note\n\n" + String(repeating: block, count: lines))
        long.binderID = binder.id
        Store.shared.insert(long)
        for index in 0..<300 {
            let note = NoteItem(text: "# Note \(index)\n\nA short note about #topic\(index % 20) and [[Note \(index + 1)]].")
            note.binderID = binder.id
            note.updatedAt = Date().addingTimeInterval(-Double(index) * 60)
            Store.shared.insert(note)
        }
        Store.shared.save()
        let navigation = HubNavigation()
        navigation.binderID = binder.id
        navigation.selection = .binder
        navigation.pendingBinderTab = .notes
        let hosting = NSHostingView(rootView: HubView()
            .environment(controller).environment(controller.meetings).environment(controller.knowledge).environment(controller.team)
            .environment(controller.capture).environment(controller.commitments).environment(navigation).environment(AppSettings.shared)
            .modelContainer(Store.shared.container))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1300, height: 760), styleMask: [.titled, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        try? await Task.sleep(for: .milliseconds(800))
        let opened = Date()
        navigation.pendingNoteID = long.id
        try? await Task.sleep(for: .milliseconds(50))
        func find(_ view: NSView) -> MarkdownTextView? { (view as? MarkdownTextView) ?? view.subviews.lazy.compactMap(find).first }
        var editor: MarkdownTextView?
        while editor == nil, Date().timeIntervalSince(opened) < 10 {
            editor = find(hosting)
            try? await Task.sleep(for: .milliseconds(10))
        }
        guard let textView = editor else { print("FAIL: the editor opens"); return 1 }
        print("OPEN: \(ms(since: opened)) ms for \((long.text as NSString).length) characters")
        window.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length / 2, length: 0))
        var times: [Double] = []
        let typing = String(repeating: "The quick brown fox jumps over the lazy dog. ", count: Int(ProcessInfo.processInfo.environment["BINDERS_SPEED_REPEAT"] ?? "") ?? 1)
        print("TYPING_STARTS")
        fflush(stdout)
        for character in typing {
            let started = Date()
            textView.insertText(String(character), replacementRange: textView.selectedRange())
            // Until SwiftUI has caught up: the run loop turns once the views are updated.
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(1))
            times.append(Date().timeIntervalSince(started) * 1000)
        }
        times.sort()
        print(String(format: "KEYSTROKE: median %.1f ms, 90th %.1f ms, worst %.1f ms", times[times.count / 2], times[times.count * 9 / 10], times.last ?? 0))
        // The pause after typing: the note takes the text, and everything showing notes catches up.
        var pauses: [Double] = []
        print("PAUSES_START")
        fflush(stdout)
        for _ in 0..<(Int(ProcessInfo.processInfo.environment["BINDERS_SPEED_PAUSES"] ?? "") ?? 5) {
            textView.insertText("x", replacementRange: textView.selectedRange())
            let started = Date()
            MarkdownEditor.flushAll()
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(1))
            pauses.append(Date().timeIntervalSince(started) * 1000)
        }
        pauses.sort()
        print(String(format: "PAUSE: median %.1f ms, worst %.1f ms", pauses[pauses.count / 2], pauses.last ?? 0))
        window.close()
        return 0
    }
}

private final class Weak {
    weak var object: AnyObject?
    init(_ object: AnyObject) { self.object = object }
}

extension SelfTest {
    /// Pictures and videos in a note, on a throwaway store: shown, pasted, dropped, found under a click, tidied away.
    @MainActor
    static func notesMediaSelfTest(directory: URL) async -> Int32 {
        guard AppPaths.isDemo else {
            print("ERROR: run with BINDERS_DATA_DIR pointing at a throwaway folder")
            return 1
        }
        var failures = 0
        func check(_ passed: Bool, _ label: String) {
            print("\(passed ? "PASS" : "FAIL"): \(label)")
            if !passed { failures += 1 }
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("binders-media-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)

        // A wide picture, a tall photo and a two-second video, made here.
        func picture(_ name: String, width: Int, height: Int, colors: [NSColor], label: String) -> URL {
            let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
                NSGradient(colors: colors)?.draw(in: rect, angle: 35)
                let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: CGFloat(height) / 9, weight: .bold), .foregroundColor: NSColor.white]
                (label as NSString).draw(at: NSPoint(x: CGFloat(width) * 0.08, y: CGFloat(height) * 0.12), withAttributes: attributes)
                return true
            }
            let url = scratch.appendingPathComponent(name)
            let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
            try? rep.representation(using: name.hasSuffix("jpg") ? .jpeg : .png, properties: [:])?.write(to: url)
            return url
        }
        let wide = picture("Whiteboard.png", width: 1600, height: 900, colors: [.systemIndigo, .systemTeal], label: "Q4 plan")
        let tall = picture("Harbour.jpg", width: 900, height: 1200, colors: [.systemOrange, .systemPink], label: "Harbour")
        let video = scratch.appendingPathComponent("Demo clip.mov")
        await makeVideo(at: video, frames: 60, size: CGSize(width: 1280, height: 720))
        check(FileManager.default.fileExists(atPath: video.path), "a video to show")

        let wideLine = (try? Attachments.add(wide)) ?? ""
        let tallLine = (try? Attachments.add(tall)) ?? ""
        let videoLine = (try? Attachments.add(video)) ?? ""
        check(wideLine == "![](attachments/Whiteboard.png)" && FileManager.default.fileExists(atPath: Attachments.folder.appendingPathComponent("Whiteboard.png").path),
              "adding a picture copies it in and writes its line: \(wideLine)")
        check(videoLine == "![](attachments/Demo%20clip.mov)", "a video's line: \(videoLine)")
        check(((try? Attachments.add(wide)) ?? "") == "![](attachments/Whiteboard%202.png)", "a second copy gets a name of its own")

        var text = """
        # Offsite photos

        The board after the planning session:
        \(wideLine.replacingOccurrences(of: "![]", with: "![The plan on the whiteboard]"))
        And the harbour, small:
        \(tallLine.replacingOccurrences(of: "![]", with: "![Harbour at dusk|240]"))
        \(videoLine)
        ![](attachments/gone.png)
        Last line.
        """
        let model = MarkdownEditorModel()
        let hosting = NSHostingView(rootView: MarkdownNoteEditor(text: Binding(get: { text }, set: { text = $0 }), fontSize: 15)
            .frame(width: 760, height: 1500).background(Color(nsColor: .textBackgroundColor)))
        _ = model
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 1500), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        hosting.wantsLayer = true
        window.contentView = hosting
        window.orderFrontRegardless()
        try? await Task.sleep(for: .milliseconds(2500))
        func find(_ view: NSView) -> MarkdownTextView? { (view as? MarkdownTextView) ?? view.subviews.lazy.compactMap(find).first }
        guard let editor = find(hosting), let layout = editor.layoutManager as? MarkdownLayoutManager else {
            check(false, "the editor opens")
            return 1
        }
        let string = editor.string as NSString
        let wideStart = string.range(of: "![The plan").location
        let frame = layout.embedFrame(atParagraph: wideStart)
        check(frame.map { $0.width >= 700 && $0.width <= 720 && abs($0.height - $0.width * 9 / 16) < 2 } == true,
              "the wide picture takes the width it can, in proportion: \(frame.map { "\(Int($0.width))×\(Int($0.height))" } ?? "none")")
        let tallFrame = layout.embedFrame(atParagraph: string.range(of: "![Harbour").location)
        check(tallFrame.map { $0.width == 240 && abs($0.height - 320) < 2 } == true, "a width in the caption sizes it: \(tallFrame.map { "\(Int($0.width))×\(Int($0.height))" } ?? "none")")
        if let frame {
            let center = NSPoint(x: frame.midX + editor.textContainerOrigin.x, y: frame.midY + editor.textContainerOrigin.y)
            check(editor.embed(at: center)?.box.source == "attachments/Whiteboard.png", "a click on the picture finds it")
            // The picture sits above its caption, clear of the line before.
            let previous = layout.lineFragmentUsedRect(forGlyphAt: layout.glyphIndexForCharacter(at: wideStart - 2), effectiveRange: nil)
            let caption = layout.lineFragmentUsedRect(forGlyphAt: layout.glyphIndexForCharacter(at: wideStart), effectiveRange: nil)
            check(frame.minY >= previous.maxY && frame.maxY <= caption.minY, "between the line before and its caption")
        }
        capture(hosting, name: "media-editor", directory: directory)

        // A screenshot pasted, then a file dropped.
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("binders-selftest-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setData(try? Data(contentsOf: wide), forType: .png)
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        check(editor.insertAttachments(from: pasteboard, at: editor.selectedRange().location), "a pasted picture comes in as an attachment")
        check(editor.string.contains("![](attachments/Pasted%20image%20"), "with a line of its own")
        pasteboard.clearContents()
        pasteboard.writeObjects([tall as NSURL])
        let middle = (editor.string as NSString).range(of: "The board after").location + 4
        check(editor.insertAttachments(from: pasteboard, at: middle), "a dropped file comes in")
        let lines = editor.string.components(separatedBy: "\n")
        check(lines.contains("The board after the planning session:") && lines.contains { $0.hasPrefix("![](attachments/Harbour%202.jpg)") },
              "after the line it was dropped on, not inside it")
        pasteboard.clearContents()
        pasteboard.setString("Just some words", forType: .string)
        check(!editor.insertAttachments(from: pasteboard, at: 0), "words paste as words")
        check(!MarkdownTextView.carriesAttachment(pasteboard), "and Paste treats them as words")
        // A picture copied from a browser comes with its address as text.
        pasteboard.clearContents()
        pasteboard.setData(try? Data(contentsOf: tall), forType: .tiff)
        pasteboard.setString("https://example.com/photos/harbour.jpg", forType: .string)
        check(MarkdownTextView.carriesAttachment(pasteboard), "a browser's copied picture can be pasted (Paste is on)")
        let before = editor.string.components(separatedBy: "Pasted%20image").count
        check(editor.insertAttachments(from: pasteboard, at: 0) && editor.string.components(separatedBy: "Pasted%20image").count == before + 1,
              "and comes in as a picture, not its address")
        // Only a picture, as a screenshot leaves it.
        pasteboard.clearContents()
        pasteboard.setData(try? Data(contentsOf: wide), forType: .png)
        check(MarkdownTextView.carriesAttachment(pasteboard), "a screenshot on the clipboard can be pasted")
        let pdf = scratch.appendingPathComponent("Minutes.pdf")
        try? Data("%PDF-1.4".utf8).write(to: pdf)
        check(((try? Attachments.add(pdf)) ?? "") == "[Minutes.pdf](attachments/Minutes.pdf)", "other files are linked")
        MarkdownEditor.flushAll()
        try? await Task.sleep(for: .milliseconds(1500))
        capture(hosting, name: "media-editor-after", directory: directory)
        window.close()

        // Tidying: what nothing refers to goes, what's used stays.
        let note = NoteItem(text: text)
        Store.shared.insert(note)
        Attachments.trashUnused(olderThan: 0, deleting: true)
        let left = Set((try? FileManager.default.contentsOfDirectory(atPath: Attachments.folder.path)) ?? [])
        check(left.contains("Whiteboard.png") && left.contains("Demo clip.mov") && !left.contains("Whiteboard 2.png") && !left.contains("Minutes.pdf"),
              "unused attachments are cleared, used ones kept: \(left.sorted())")
        Store.shared.delete(note)
        try? FileManager.default.removeItem(at: scratch)
        print(failures == 0 ? "MEDIA_OK" : "MEDIA_FAILED: \(failures)")
        return failures == 0 ? 0 : 1
    }

    /// A short video of a moving square, for the tests.
    @MainActor
    static func makeVideo(at url: URL, frames: Int, size: CGSize) async {
        try? FileManager.default.removeItem(at: url)
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: size.width, AVVideoHeightKey: size.height])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: size.width, kCVPixelBufferHeightKey as String: size.height])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<frames {
            while !input.isReadyForMoreMediaData { try? await Task.sleep(for: .milliseconds(5)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, Int(size.width), Int(size.height), kCVPixelFormatType_32BGRA, nil, &buffer)
            guard let buffer else { continue }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                       bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
                                       bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
                context.setFillColor(NSColor.systemPurple.cgColor)
                context.fill(CGRect(origin: .zero, size: size))
                context.setFillColor(NSColor.white.cgColor)
                context.fill(CGRect(x: CGFloat(frame) * 15 + 80, y: size.height / 2 - 80, width: 160, height: 160))
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
        }
        input.markAsFinished()
        await writer.finishWriting()
    }
}

extension SelfTest {
    /// The editor's helpers: pasting formatted text and links, wrapping a selection, moving lines, finding.
    @MainActor
    static func notesEditingSelfTest() async -> Int32 {
        var failures = 0
        func check(_ passed: Bool, _ label: String) {
            print("\(passed ? "PASS" : "FAIL"): \(label)")
            if !passed { failures += 1 }
        }
        var text = "First line\nSecond line\nThird line"
        let hosting = NSHostingView(rootView: MarkdownNoteEditor(text: Binding(get: { text }, set: { text = $0 })).frame(width: 700, height: 500))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        try? await Task.sleep(for: .milliseconds(600))
        func find(_ view: NSView) -> MarkdownTextView? { (view as? MarkdownTextView) ?? view.subviews.lazy.compactMap(find).first }
        guard let editor = find(hosting) else { check(false, "the editor opens"); return 1 }
        window.makeFirstResponder(editor)

        // Typing * over a word wraps it.
        editor.setSelectedRange((editor.string as NSString).range(of: "Second"))
        editor.insertText("*", replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.insertText("*", replacementRange: NSRange(location: NSNotFound, length: 0))
        check(editor.string.contains("**Second** line") && (editor.string as NSString).substring(with: editor.selectedRange()) == "Second",
              "typing * twice over a word makes it bold, and keeps it selected")
        editor.setSelectedRange((editor.string as NSString).range(of: "Third"))
        editor.insertText("[", replacementRange: NSRange(location: NSNotFound, length: 0))
        check(editor.string.contains("[Third] line"), "[ wraps it in brackets")

        // ⌥⌘↓ moves the line down.
        editor.setSelectedRange(NSRange(location: 2, length: 0))
        let down = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .option, .numericPad, .function], timestamp: 0,
                                    windowNumber: window.windowNumber, context: nil, characters: "\u{F701}", charactersIgnoringModifiers: "\u{F701}",
                                    isARepeat: false, keyCode: 125)!
        _ = editor.performKeyEquivalent(with: down)
        check(editor.string.hasPrefix("**Second** line\nFirst line\n"), "⌥⌘↓ moves the line down: \(editor.string.prefix(30).debugDescription)")

        // An address pasted over words makes them a link.
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("binders-selftest-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString("https://example.com/plan", forType: .string)
        editor.setSelectedRange((editor.string as NSString).range(of: "First"))
        check(editor.pasteSpecially(from: pasteboard) && editor.string.contains("[First](https://example.com/plan) line"), "an address pasted over words links them")

        // A page copied from a browser comes in as Markdown.
        let html = """
        <h1>Launch plan</h1><p>We ship on the <b>28th</b>, with <i>annual</i> pricing. See <a href="https://example.com/pricing">the pricing page</a>.</p>
        <h2>Before Friday</h2><ul><li>Confirm the discount</li><li>Send the checklist<ul><li>Support first</li></ul></li></ul>
        <ol><li>Draft</li><li>Review</li></ol><pre><code>make import-test</code></pre><p>Plain <code>inline</code> words.</p>
        """
        pasteboard.clearContents()
        pasteboard.setData(Data(html.utf8), forType: .html)
        pasteboard.setString("Launch plan We ship on the 28th", forType: .string)
        let markdown = RichPaste.markdown(from: pasteboard) ?? ""
        print("RICH_PASTE:\n\(markdown)\n---")
        check(markdown.hasPrefix("# Launch plan\n\nWe ship on the **28th**, with *annual* pricing. See [the pricing page](https://example.com/pricing)."),
              "headings, bold, italic and links come along")
        check(markdown.contains("## Before Friday\n\n- Confirm the discount\n- Send the checklist\n  - Support first"), "lists, nested ones too")
        check(markdown.contains("1. Draft\n2. Review"), "numbered lists number")
        check(markdown.contains("```\nmake import-test\n```") && markdown.contains("Plain `inline` words."), "code stays code")
        pasteboard.clearContents()
        pasteboard.setString("Just words", forType: .string)
        check(RichPaste.markdown(from: pasteboard) == nil, "plain words paste as they are")

        check(editor.usesFindBar, "⌘F finds in the note")
        window.close()
        print(failures == 0 ? "NOTES_EDITING_OK" : "NOTES_EDITING_FAILED: \(failures)")
        return failures == 0 ? 0 : 1
    }
}

extension SelfTest {
    /// The "/" menu, driven by keys: it opens, narrows, chooses, closes.
    @MainActor
    static func slashMenuSelfTest(directory: URL) async -> Int32 {
        var failures = 0
        func check(_ passed: Bool, _ label: String) {
            print("\(passed ? "PASS" : "FAIL"): \(label)")
            if !passed { failures += 1 }
        }
        var text = "# Plan\n\n"
        let hosting = NSHostingView(rootView: MarkdownNoteEditor(text: Binding(get: { text }, set: { text = $0 })).frame(width: 700, height: 500))
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 700, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        try? await Task.sleep(for: .milliseconds(600))
        func find(_ view: NSView) -> MarkdownTextView? { (view as? MarkdownTextView) ?? view.subviews.lazy.compactMap(find).first }
        guard let editor = find(hosting) else { check(false, "the editor opens"); return 1 }
        window.makeFirstResponder(editor)
        func type(_ characters: String) {
            for character in characters { editor.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0)) }
        }
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        type("/")
        check(editor.slashMenu != nil && editor.slashMenu?.items.count == SlashMenu.all.count, "/ at the start of a line opens the menu with everything")
        try? await Task.sleep(for: .milliseconds(300))
        if let panel = window.childWindows?.first, let content = panel.contentView { capture(content, name: "slash-menu", directory: directory) }
        type("che")
        check(editor.slashMenu?.items.map(\.id) == ["task"], "typing narrows it: \(editor.slashMenu?.items.map(\.id) ?? [])")
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        check(editor.slashMenu == nil && editor.string.hasSuffix("- [ ] "), "Return takes it: a checklist item, and the /che is gone: \(editor.string.debugDescription)")
        type("Buy milk")
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        type("/h")
        check(editor.slashMenu?.items.prefix(3).map(\.id) == ["h1", "h2", "h3"], "/h offers the headings first: \(editor.slashMenu?.items.map(\.id) ?? [])")
        editor.doCommand(by: #selector(NSResponder.moveDown(_:)))
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        check(editor.string.hasSuffix("\n## "), "↓ then Return makes a second-level heading: \(editor.string.suffix(12).debugDescription)")
        type("Notes /")
        check(editor.slashMenu != nil, "after a space too")
        editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        check(editor.slashMenu == nil && editor.string.hasSuffix("Notes /"), "Escape closes it and leaves the /")
        type("x")
        type(" and/or ")
        check(editor.slashMenu == nil, "a / inside a word isn't a command")
        type("/zzzzz")
        check(editor.slashMenu == nil, "nothing matching for a while closes it")

        // A table from the menu, filled in.
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        type("/table")
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        check((editor.string as NSString).substring(with: editor.selectedRange()) == "Column", "/table makes a table with its first header selected")
        type("Task")
        let string = editor.string as NSString
        editor.setSelectedRange(NSRange(location: string.range(of: "| Column |").location + 2, length: 6))
        type("Owner")
        let lastRow = (editor.string as NSString).range(of: "|  |  |")
        editor.replace(lastRow, with: "| Book the venue | Samir |\n| Send the agenda to everyone | Maya |", selection: NSRange(location: lastRow.location, length: 0))
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        try? await Task.sleep(for: .milliseconds(400))
        let table = MarkdownTables.table(around: (editor.string as NSString).range(of: "Book the venue").location, in: editor.string as NSString)
        check(table?.rows.count == 4 && table?.columns == 2, "a table of two columns and four rows: \(editor.string.components(separatedBy: "\n").suffix(5))")
        if let layout = editor.layoutManager as? MarkdownLayoutManager, let table {
            // Every row's second column starts at the same place.
            let starts = table.rows.filter { !$0.isDelimiter }.map { row -> CGFloat in
                let glyph = layout.glyphIndexForCharacter(at: row.cells[1].location)
                return layout.location(forGlyphAt: glyph).x
            }
            check(Set(starts.map { Int($0.rounded()) }).count == 1, "the second column lines up in every row: \(starts.map { Int($0) })")
        }
        // Tab from cell to cell, Return for a row, Return on an empty last row to leave.
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).range(of: "Book the venue").location + 2, length: 0))
        editor.insertTab(nil)
        check((editor.string as NSString).substring(with: editor.selectedRange()) == "Samir", "Tab goes to the next cell")
        editor.insertBacktab(nil)
        check((editor.string as NSString).substring(with: editor.selectedRange()) == "Book the venue", "⇧Tab goes back")
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).range(of: "Maya").location + 4, length: 0))
        editor.insertTab(nil)
        type("Print badges")
        editor.insertTab(nil)
        type("Noah")
        editor.insertNewline(nil)
        editor.insertNewline(nil)
        type("After the table")
        check(editor.string.hasSuffix("| Print badges | Noah |\n\nAfter the table") || editor.string.hasSuffix("| Print badges | Noah |\nAfter the table"),
              "Tab in the last cell adds a row; Return twice leaves the table: \(editor.string.suffix(45).debugDescription)")
        try? await Task.sleep(for: .milliseconds(300))
        capture(hosting, name: "table", directory: directory)
        window.close()
        print(failures == 0 ? "SLASH_OK" : "SLASH_FAILED: \(failures)")
        return failures == 0 ? 0 : 1
    }
}

extension SelfTest {
    /// A note popped out, typed in, folded into a bubble and opened again, on a throwaway store.
    @MainActor
    static func popoutsSelfTest(directory: URL) async -> Int32 {
        guard AppPaths.isDemo else {
            print("ERROR: run with BINDERS_DATA_DIR pointing at a throwaway folder")
            return 1
        }
        var failures = 0
        func check(_ passed: Bool, _ label: String) {
            print("\(passed ? "PASS" : "FAIL"): \(label)")
            if !passed { failures += 1 }
        }
        // The saved pop-outs live in this app's settings: keep whatever's there and put it back after.
        let kept = UserDefaults.standard.data(forKey: "notePopouts")
        defer { UserDefaults.standard.set(kept, forKey: "notePopouts") }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let note = NoteItem(text: "# 🚀 Launch checklist\n\n- [ ] Pricing page\n- [ ] Support macros")
        note.binderID = Store.shared.defaultBinder().id
        Store.shared.insert(note)
        NSApp.activate(ignoringOtherApps: true)
        NotePopouts.shared.open(note)
        try? await Task.sleep(for: .milliseconds(700))
        let window = NSApp.windows.first { $0.identifier?.rawValue == note.id.uuidString }
        check(window?.isVisible == true && window?.level == .floating, "the note opens in its own window, in front")
        check(window?.title == "🚀 Launch checklist", "titled with the note: \(window?.title ?? "")")
        func find(_ view: NSView) -> MarkdownTextView? { (view as? MarkdownTextView) ?? view.subviews.lazy.compactMap(find).first }
        if let window, let editor = window.contentView.flatMap(find) {
            window.makeFirstResponder(editor)
            editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
            editor.insertText("\n- [ ] Tell the team", replacementRange: editor.selectedRange())
            MarkdownEditor.flushAll()
            check(note.text.hasSuffix("- [ ] Tell the team"), "typing in it changes the note")
            if let content = window.contentView { capture(content, name: "popout-window", directory: directory) }
        } else {
            check(false, "the window has an editor")
        }
        NotePopouts.shared.collapse(note.id)
        try? await Task.sleep(for: .milliseconds(400))
        let bubble = NSApp.windows.first { $0.frame.size == NSSize(width: 56, height: 56) && $0.isVisible }
        let visible = NSScreen.main?.visibleFrame ?? .zero
        check(window?.isVisible == false && bubble != nil, "folding hides the window and shows a bubble")
        check(bubble.map { abs($0.frame.maxX - (visible.maxX - 8)) < 2 || abs($0.frame.minX - (visible.minX + 8)) < 2 } == true,
              "on the edge of the screen: \(bubble.map { NSStringFromRect($0.frame) } ?? "none")")
        check(bubble?.collectionBehavior.contains(.canJoinAllSpaces) == true && bubble?.level == .floating, "over every app and Space")
        if let content = bubble?.contentView { capture(content, name: "popout-bubble", directory: directory) }
        // A second bubble wears another colour; a colour picked sticks.
        let other = NoteItem(text: "Groceries")
        other.binderID = note.binderID
        Store.shared.insert(other)
        NotePopouts.shared.open(other, collapsed: true)
        try? await Task.sleep(for: .milliseconds(300))
        check(NotePopouts.shared.color(of: other.id) != NotePopouts.shared.color(of: note.id), "a second bubble gets a colour of its own")
        NotePopouts.shared.setColor(other.id, 4)
        try? await Task.sleep(for: .milliseconds(300))
        if let second = NSApp.windows.filter({ $0.frame.size == NSSize(width: 56, height: 56) && $0.isVisible }).first(where: { $0 !== bubble }),
           let content = second.contentView {
            capture(content, name: "popout-bubble-green", directory: directory)
        }
        let colors = (UserDefaults.standard.data(forKey: "notePopouts")).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] }?
            .first { $0["id"] as? String == other.id.uuidString }?["color"] as? Int
        check(NotePopouts.shared.color(of: other.id) == 4 && colors == 4, "the colour you pick is kept")
        NotePopouts.shared.close(other.id)
        Store.shared.delete(other)
        let saved = (UserDefaults.standard.data(forKey: "notePopouts")).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] }
        check(saved?.first?["collapsed"] as? Bool == true && saved?.first?["id"] as? String == note.id.uuidString, "and it's remembered for next time")
        NotePopouts.shared.expand(note.id)
        try? await Task.sleep(for: .milliseconds(400))
        check(window?.isVisible == true && bubble?.isVisible == false, "a click on the bubble opens the note again")
        if let window, let bubble { check(abs(window.frame.maxY - bubble.frame.maxY) < 2 || window.frame.maxY <= visible.maxY, "beside where the bubble was") }
        NotePopouts.shared.setPinned(note.id, false)
        check(window?.level == .normal, "unpinned, it's an ordinary window")
        NoteTrash.shared.delete(note, undoManager: nil)
        try? await Task.sleep(for: .milliseconds(300))
        check(!NotePopouts.shared.isOpen(note.id) && window?.isVisible == false, "deleting the note closes it")
        print(failures == 0 ? "POPOUTS_OK" : "POPOUTS_FAILED: \(failures)")
        return failures == 0 ? 0 : 1
    }
}

extension SelfTest {
    /// ⌘N: a new note on the Notes page, with the cursor in it.
    @MainActor
    static func newNoteSelfTest() async -> Int32 {
        guard AppPaths.isDemo else {
            print("ERROR: run with BINDERS_DATA_DIR pointing at a throwaway folder")
            return 1
        }
        var failures = 0
        func check(_ passed: Bool, _ label: String) {
            print("\(passed ? "PASS" : "FAIL"): \(label)")
            if !passed { failures += 1 }
        }
        let menu = MainMenu.build()
        let item = menu.items.first { $0.title == "File" }?.submenu?.items.first { $0.keyEquivalent == "n" && $0.keyEquivalentModifierMask == .command }
        check(item?.title == "New Note" && item?.target === HubWindowController.shared, "File → New Note is ⌘N")
        let controller = DictationController()
        HubWindowController.shared.controller = controller
        let before = (try? Store.shared.context.fetchCount(FetchDescriptor<NoteItem>())) ?? 0
        NSApp.activate(ignoringOtherApps: true)
        HubWindowController.shared.newNote(nil)
        try? await Task.sleep(for: .milliseconds(1500))
        let after = (try? Store.shared.context.fetchCount(FetchDescriptor<NoteItem>())) ?? 0
        check(after == before + 1, "it makes a note")
        let window = NSApp.windows.first { $0.title == "Binders" && $0.isVisible }
        let field = ((window?.firstResponder as? NSTextView)?.delegate as? NSTextField).map { "a text field “\($0.placeholderString ?? $0.stringValue)”" }
        check(window?.firstResponder is MarkdownTextView, "and the cursor is in it, ready to type: \(field ?? String(describing: window?.firstResponder))")
        window?.close()
        print(failures == 0 ? "NEW_NOTE_OK" : "NEW_NOTE_FAILED: \(failures)")
        return failures == 0 ? 0 : 1
    }
}

extension SelfTest {
    /// The menus' shortcuts, changing one, and zooming the words in notes.
    @MainActor
    static func menusSelfTest() async -> Int32 {
        var failures = 0
        func check(_ passed: Bool, _ label: String) {
            print("\(passed ? "PASS" : "FAIL"): \(label)")
            if !passed { failures += 1 }
        }
        // This app's settings: keep what's there and put it back.
        let keptShortcuts = UserDefaults.standard.data(forKey: "menuShortcuts")
        let keptZoom = UserDefaults.standard.object(forKey: TextZoom.key)
        defer {
            UserDefaults.standard.set(keptShortcuts, forKey: "menuShortcuts")
            UserDefaults.standard.set(keptZoom, forKey: TextZoom.key)
        }
        UserDefaults.standard.removeObject(forKey: "menuShortcuts")
        UserDefaults.standard.removeObject(forKey: TextZoom.key)
        func item(_ menu: NSMenu, _ title: String) -> NSMenuItem? {
            menu.items.lazy.compactMap { $0.submenu }.flatMap { $0.items }.first { $0.title == title && !$0.isHidden }
        }
        var menu = MainMenu.build()
        func shown(_ item: NSMenuItem?) -> String {
            guard let item else { return "missing" }
            var text = ""
            if item.keyEquivalentModifierMask.contains(.control) { text += "⌃" }
            if item.keyEquivalentModifierMask.contains(.option) { text += "⌥" }
            if item.keyEquivalentModifierMask.contains(.shift) { text += "⇧" }
            if item.keyEquivalentModifierMask.contains(.command) { text += "⌘" }
            return text + item.keyEquivalent.uppercased()
        }
        check(shown(item(menu, "Zoom In")) == "⌘=" && shown(item(menu, "Zoom Out")) == "⌘-" && shown(item(menu, "Actual Size")) == "⌘0",
              "View has Zoom In ⌘=, Zoom Out ⌘- and Actual Size ⌘0")
        check(menu.items.lazy.compactMap { $0.submenu }.flatMap { $0.items }.contains { $0.keyEquivalent == "+" && $0.isHidden }, "⌘+ zooms in too")
        check(shown(item(menu, "Pop Out Note")) == "⌥⌘P" && shown(item(menu, "Fold into a Bubble")) == "⌥⌘B", "Note has Pop Out ⌥⌘P and Fold into a Bubble ⌥⌘B")
        check(shown(item(menu, "New Note")) == "⌘N", "File has New Note ⌘N")
        MenuShortcuts.set(Hotkey(modifiers: [.command, .shift], keyCode: 35), for: .popOut)
        menu = MainMenu.build()
        check(shown(item(menu, "Pop Out Note")) == "⇧⌘P", "a shortcut set in Settings is the menu's: \(shown(item(menu, "Pop Out Note")))")
        MenuShortcuts.set(nil, for: .foldIntoBubble)
        menu = MainMenu.build()
        check(item(menu, "Fold into a Bubble")?.keyEquivalent == "", "and a command can have none")
        check(MenuShortcuts.conflict(for: Hotkey(modifiers: .command, keyCode: 8), except: .popOut) == "Copy", "⌘C stays Copy")
        check(MenuShortcuts.conflict(for: Hotkey(modifiers: .command, keyCode: 45), except: .popOut) == "New Note", "two commands can't share one")
        MenuShortcuts.reset()
        check(MenuShortcuts.shortcut(for: .popOut) == MenuCommand.popOut.defaultShortcut, "Reset puts the defaults back")

        // Zoom: the words in an editor get bigger, and back.
        var text = "# Zoom\n\nSome words."
        let hosting = NSHostingView(rootView: MarkdownNoteEditor(text: Binding(get: { text }, set: { text = $0 }), fontSize: 15).frame(width: 600, height: 300))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.contentView = hosting
        window.orderFrontRegardless()
        try? await Task.sleep(for: .milliseconds(400))
        func find(_ view: NSView) -> MarkdownTextView? { (view as? MarkdownTextView) ?? view.subviews.lazy.compactMap(find).first }
        let editor = find(hosting)
        check(editor?.styler.fontSize == 15, "words start at their size")
        HubWindowController.shared.zoomIn(nil)
        HubWindowController.shared.zoomIn(nil)
        try? await Task.sleep(for: .milliseconds(400))
        let font = editor?.textStorage?.attribute(.font, at: (editor!.string as NSString).range(of: "Some").location, effectiveRange: nil) as? NSFont
        check(TextZoom.level == 1.2 && editor?.styler.fontSize == 18 && font?.pointSize == 18, "⌘= twice: 20% bigger, in the text too (\(font?.pointSize ?? 0))")
        HubWindowController.shared.actualSize(nil)
        try? await Task.sleep(for: .milliseconds(400))
        check(editor?.styler.fontSize == 15, "⌘0 puts them back")
        window.close()
        print(failures == 0 ? "MENUS_OK" : "MENUS_FAILED: \(failures)")
        return failures == 0 ? 0 : 1
    }
}
