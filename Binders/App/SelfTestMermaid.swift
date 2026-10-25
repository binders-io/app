import AppKit
import Network
import SwiftUI
import BindersKit

// Lane MM1's self-test: Mermaid diagrams in the note editor. A flowchart, a sequence diagram, a wide one, a broken one
// and one that tries to reach the network, in light and dark; the cursor in a block; typing in one; the saved Markdown
// and a copy unchanged; nothing loaded for a note without diagrams; ten diagrams timed; the web view let go when idle.

/// Counts every connection made to it on 127.0.0.1, and answers none.
private final class ConnectionCounter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "io.binders.selftest.mermaid-listener")
    private let lock = NSLock()
    private var listener: NWListener?
    private var connections = 0

    var count: Int { lock.withLock { connections } }

    func start() async -> UInt16? {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        guard let listener = try? NWListener(using: parameters) else { return nil }
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            self?.lock.withLock { self?.connections += 1 }
            connection.cancel()
        }
        return await withCheckedContinuation { continuation in
            var resumed = false
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: if !resumed { resumed = true; continuation.resume(returning: listener.port?.rawValue) }
                case .failed, .cancelled: if !resumed { resumed = true; continuation.resume(returning: nil) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() { listener?.cancel() }
}

extension SelfTest {
    @MainActor
    static func mermaidSelfTest(directory: URL) async -> Int32 {
        var failures = 0
        func check(_ passed: Bool, _ label: String) {
            print("\(passed ? "PASS" : "FAIL"): \(label)")
            fflush(stdout)
            if !passed { failures += 1 }
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let renderer = MermaidRenderer.shared
        MermaidRenderer.idleRelease = 3

        let counter = ConnectionCounter()
        guard let port = await counter.start() else {
            check(false, "a listener on 127.0.0.1 for the network checks")
            return 1
        }
        let address = "http://127.0.0.1:\(port)"

        // MARK: A note without diagrams costs nothing

        let plain = "# Release checklist\n\n```swift\nlet a = 1\n```\n\n| A | B |\n| --- | --- |\n| 1 | 2 |\n"
        do {
            let (window, editor) = await openEditor(plain, width: 760)
            check(editor != nil, "a note without diagrams opens")
            try? await Task.sleep(for: .milliseconds(400))
            check(!renderer.isLoaded && renderer.pagesLoaded == 0, "a note without diagrams loads nothing: no web view, no Mermaid")
            check(editor?.diagramBlocks().isEmpty == true, "and has no diagrams")
            window.close()
        }

        // MARK: The note

        let flow = "flowchart TD\n  A[Write the plan] --> B{Agreed?}\n  B -->|Yes| C[Put it on the board]\n  B -->|No| D[Talk it through]\n  D --> A"
        let sequence = "sequenceDiagram\n  participant Mac\n  participant iPhone\n  iPhone->>Mac: Pair\n  Mac-->>iPhone: Paired\n  iPhone->>Mac: Send a capture"
        let wide = "flowchart LR\n  A[The first step of it] --> B[Another step after that] --> C[A third step, longer] --> D[A fourth step] --> E[A fifth step] --> F[Done at last]"
        let broken = "flowchart TD\n  A --> \n  ][ this isn't a diagram"
        // Tries everything: a loose security level, a picture from the listener, a click to it, a link, and a script.
        let reaching = """
        %%{init: {"securityLevel": "loose"}}%%
        flowchart LR
          A["<img src='\(address)/label.png'> Picture <script>fetch('\(address)/script')</script>"] --> B[Open the page]
          click B "\(address)/clicked" "Open it"
          C[Link] --> D
          click D href "\(address)/href"
        """
        let text = """
        Diagram test

        Before the diagrams.

        ```mermaid
        \(flow)
        ```

        Between the first two.

        ~~~Mermaid
        \(sequence)
        ~~~

        ```mermaid
        \(wide)
        ```

        ```mermaid
        \(broken)
        ```

        ```mermaid
        \(reaching)
        ```

        After the diagrams.

        """
        var saved = text
        let opened = Date()
        let (window, found) = await openEditor(text, width: 760, binding: Binding(get: { saved }, set: { saved = $0 }))
        guard let editor = found else {
            check(false, "the note with diagrams opens")
            return 1
        }
        let blocks = editor.diagramBlocks()
        check(blocks.count == 5, "five diagrams found (\(blocks.count))")
        check(blocks.map(\.source) == [flow, sequence, wide, broken, reaching], "each diagram's text is its block's, fences left out")

        func settled(_ boxes: [(block: MermaidBlock, box: DiagramBox?)]) -> Bool {
            boxes.count == 5 && boxes.allSatisfy { $0.box?.image != nil || $0.box?.error != nil }
        }
        for _ in 0..<200 where !settled(editor.diagramBoxes()) { try? await Task.sleep(for: .milliseconds(100)) }
        print("DRAWN: five diagrams in \(String(format: "%.2f", Date().timeIntervalSince(opened))) s, \(renderer.pagesLoaded) page load(s), the page ready in \(String(format: "%.2f", renderer.lastLoadTime)) s")
        var boxes = editor.diagramBoxes()
        check(settled(boxes), "every diagram is drawn or says why not")
        let width = editor.diagramWidth
        for (index, name) in [(0, "flowchart"), (1, "sequence diagram"), (2, "wide flowchart"), (4, "diagram reaching out")] {
            guard let box = boxes[index].box, let image = box.image else {
                check(false, "the \(name) is drawn")
                continue
            }
            check(box.place == .inPlace, "the \(name) shows in place of its code")
            check(box.size.width >= 80 && box.size.height >= 40 && box.size.width <= width + 0.5,
                  "the \(name) has a sensible size: \(Int(box.size.width))×\(Int(box.size.height)) in \(Int(width)) points of text")
            let pixels = image.representations.first.map { "\($0.pixelsWide)×\($0.pixelsHigh)" } ?? "none"
            print("SIZE: \(name) \(Int(image.size.width))×\(Int(image.size.height)) points, \(pixels) pixels")
            save(image, as: "\(name.replacingOccurrences(of: " ", with: "-"))-light", in: directory)
        }
        if let wideBox = boxes[2].box {
            check(wideBox.size.width >= CGFloat(MarkdownDiagrams.widthBucket(Double(width))) - 2,
                  "a wide diagram is scaled down to the text's width (\(Int(wideBox.size.width)) of \(Int(width)))")
        }
        if let flowBox = boxes[0].box, let sequenceBox = boxes[1].box {
            check(flowBox.size.width < width - 100 && sequenceBox.size.width < width - 100, "small diagrams keep their own size")
        }
        let brokenBox = boxes[3].box
        check(brokenBox?.place == .under && brokenBox?.image == nil, "a broken diagram shows its code, with no drawing")
        check(brokenBox?.error?.hasPrefix("Mermaid couldn't draw this: ") == true, "and a quiet line under it: \(brokenBox?.error ?? "none")")
        check(!(brokenBox?.error ?? "").contains("\n"), "the line is one line of Mermaid's message")
        func hidden(_ block: MermaidBlock) -> Bool {
            let source = NSMaxRange(editor.string.lineRange(of: block.opening))
            return editor.textStorage?.attribute(.markdownDiagramHidden, at: source, effectiveRange: nil) != nil
        }
        check(hidden(blocks[0]) && hidden(blocks[1]), "a drawn diagram's code takes no room")
        check(!hidden(blocks[3]), "the broken one's code shows")
        let blockHeight = height(of: blocks[0].range, in: editor)
        if let box = boxes[0].box {
            check(blockHeight < box.size.height + 2 * DiagramLayout.gap + CGFloat(blocks[0].source.split(separator: "\n").count + 2) * 2 + 20,
                  "the drawing takes the code's place, not both (\(Int(blockHeight)) points for a \(Int(box.size.height))-point drawing)")
        }
        capture(editor, name: "editor-light", in: directory)

        // MARK: Nothing leaves the page

        try? await Task.sleep(for: .milliseconds(800))
        check(counter.count == 0, "a diagram's picture, click and link reached nothing (\(counter.count) connections)")
        let fetchFailed = await renderer.probeLoad("\(address)/probe")
        try? await Task.sleep(for: .milliseconds(500))
        check(fetchFailed, "a fetch from the page fails")
        check(counter.count == 0, "a picture put straight into the page loads nothing (\(counter.count) connections)")
        await MermaidRenderer.ruleListAlone(loading: address)
        check(counter.count == 0, "the rule list alone blocks a picture and a fetch (\(counter.count) connections)")
        let scripts = await renderer.pageScriptsRun()
        check(!scripts, "the page's own JavaScript doesn't run (an onclick in it did nothing)")
        let clickedBefore = counter.count
        if let (_, frame, _) = editor.diagram(at: diagramCenter(boxes[4], editor: editor)) {
            check(frame.width > 0, "the diagram reaching out is drawn where it's clicked")
        }
        check(counter.count == clickedBefore, "clicking a diagram goes nowhere")

        // MARK: The cursor in a block

        window.makeFirstResponder(editor)
        let inFlow = (editor.string as NSString).range(of: "A[Write the plan]")
        editor.setSelectedRange(NSRange(location: inFlow.location, length: 0))
        try? await Task.sleep(for: .milliseconds(200))
        boxes = editor.diagramBoxes()
        check(boxes[0].box?.place == .under && boxes[0].box?.image != nil, "with the cursor in it, the code shows and the drawing goes under it")
        check(!hidden(blocks[0]), "its code takes its room again")
        check(boxes[1].box?.place == .inPlace, "the other diagrams stay drawn in place")
        capture(editor, name: "editor-cursor-in-flowchart", in: directory)

        // Typing in it: the drawing under it stays, and is drawn again a moment after typing stops.
        let before = boxes[0].box?.image
        let lineEnd = NSMaxRange((editor.string as NSString).range(of: "D --> A"))
        editor.setSelectedRange(NSRange(location: lineEnd, length: 0))
        let typed = "\n  C --> E[Shipped]"
        let typingStarted = Date()
        for character in typed {
            editor.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        let typingTook = Date().timeIntervalSince(typingStarted)
        check(editor.diagramBoxes()[0].box?.image === before && editor.diagramBoxes()[0].box?.place == .under,
              "while typing, the last drawing stays under the code")
        check(typingTook < 0.5, "typing \(typed.count) characters in a diagram took \(Int(typingTook * 1000)) ms")
        let grown = editor.diagramBlocks()[0]
        for _ in 0..<50 {
            if case .image? = renderer.drawing(for: editor.diagramRequest(grown)), editor.diagramBoxes()[0].box?.image !== before { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        check(editor.diagramBoxes()[0].box?.image !== before && editor.diagramBoxes()[0].box?.image != nil,
              "a moment after typing stops, it's drawn again with the new step")
        if let image = editor.diagramBoxes()[0].box?.image { save(image, as: "flowchart-edited", in: directory) }
        capture(editor, name: "editor-typing", in: directory)
        while editor.undoManager?.canUndo == true { editor.undoManager?.undo() }
        check(editor.string == text, "undo takes the typing back out")

        // Out of the block again, then the block selected, then the editor left.
        let after = (editor.string as NSString).range(of: "After the diagrams.")
        editor.setSelectedRange(NSRange(location: after.location, length: 0))
        try? await Task.sleep(for: .milliseconds(150))
        check(editor.diagramBoxes()[0].box?.place == .inPlace, "with the cursor out of it, the drawing shows in place again")
        let between = (editor.string as NSString).range(of: "Between the first two.")
        editor.setSelectedRange(NSRange(location: between.location, length: NSMaxRange(editor.diagramBlocks()[1].range) - between.location))
        try? await Task.sleep(for: .milliseconds(150))
        check(editor.diagramBoxes()[1].box?.place == .under, "a selection over a block shows its code")
        editor.setSelectedRange(NSRange(location: inFlow.location, length: 0))
        window.makeFirstResponder(nil)
        try? await Task.sleep(for: .milliseconds(150))
        check(editor.diagramBoxes().enumerated().allSatisfy { $0.offset == 3 || $0.element.box?.place == .inPlace },
              "with the editor not in use, every drawn diagram shows in place")

        // A click on a drawing opens its code.
        if let center = Optional(diagramCenter(editor.diagramBoxes()[1], editor: editor)),
           let event = NSEvent.mouseEvent(with: .leftMouseDown, location: editor.convert(center, to: nil), modifierFlags: [], timestamp: 0,
                                          windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
            check(editor.clickedDiagram(event, at: center), "a click on a drawing is the diagram's")
            try? await Task.sleep(for: .milliseconds(150))
            check(editor.diagramBoxes()[1].box?.place == .under, "and opens its code, the cursor in it")
            window.makeFirstResponder(nil)
        }

        // MARK: The Markdown is never changed

        MarkdownEditor.flushAll()
        try? await Task.sleep(for: .milliseconds(500))
        check(editor.string == text, "the editor's text is the note's Markdown, unchanged")
        check(saved == text, "the saved note is unchanged")
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("io.binders.selftest.mermaid.\(UUID().uuidString)"))
        pasteboard.clearContents()
        editor.setSelectedRange(NSRange(location: 0, length: (editor.string as NSString).length))
        let wrote = editor.writeSelection(to: pasteboard, types: editor.writablePasteboardTypes)
        let copied = pasteboard.string(forType: .string)
        if copied != text { print("COPIED (\(wrote), \(editor.selectedRange()), \(editor.writablePasteboardTypes.map(\.rawValue))): \(copied.map { "\(($0 as NSString).length) characters" } ?? "nothing") of \((text as NSString).length)") }
        check(copied == text, "copying the note copies its Markdown, diagrams' code and all")
        pasteboard.releaseGlobally()
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        window.makeFirstResponder(nil)

        // MARK: Dark

        let light = editor.diagramBoxes().map { $0.box?.image }
        window.appearance = NSAppearance(named: .darkAqua)
        for _ in 0..<100 {
            let drawn = editor.diagramBlocks().enumerated().allSatisfy { index, block in
                index == 3 || { if case .image? = renderer.drawing(for: editor.diagramRequest(block)) { return true } else { return false } }()
            }
            if drawn, editor.diagramTheme == .dark { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        try? await Task.sleep(for: .milliseconds(200))
        boxes = editor.diagramBoxes()
        check(editor.diagramTheme == .dark, "the editor's appearance is dark")
        for (index, name) in [(0, "flowchart"), (1, "sequence diagram"), (2, "wide flowchart"), (4, "diagram reaching out")] {
            guard let image = boxes[index].box?.image else {
                check(false, "the \(name) is drawn in the dark")
                continue
            }
            check(image !== light[index], "the \(name) is drawn again in the dark theme")
            save(image, as: "\(name.replacingOccurrences(of: " ", with: "-"))-dark", in: directory)
        }
        if let darkFlow = boxes[0].box?.image, let lightFlow = light[0] {
            let (darkLuma, lightLuma) = (fillLuminance(darkFlow), fillLuminance(lightFlow))
            print("LUMINANCE: flowchart's shapes \(String(format: "%.2f", lightLuma)) in the light, \(String(format: "%.2f", darkLuma)) in the dark")
            check(darkLuma < lightLuma - 0.2, "the dark drawing's shapes are dark, the light one's light")
        }
        check(boxes[3].box?.error?.hasPrefix("Mermaid couldn't draw this") == true, "the broken one still says why in the dark")
        capture(editor, name: "editor-dark", in: directory)
        window.appearance = NSAppearance(named: .aqua)

        // Narrower: the drawings follow.
        window.setContentSize(NSSize(width: 460, height: 700))
        try? await Task.sleep(for: .milliseconds(300))
        for _ in 0..<50 {
            if case .image? = renderer.drawing(for: editor.diagramRequest(editor.diagramBlocks()[2])) { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        try? await Task.sleep(for: .milliseconds(200))
        let narrow = editor.diagramWidth
        check(editor.diagramBoxes().allSatisfy { ($0.box?.size.width ?? 0) <= narrow + 0.5 }, "in a narrower window every drawing fits (\(Int(narrow)) points)")
        capture(editor, name: "editor-narrow", in: directory)
        window.close()

        // MARK: Ten diagrams

        renderer.release()
        renderer.forgetDrawings()
        let ten = (1...10).map { index in
            "## Part \(index)\n\n```mermaid\nflowchart TD\n  A\(index)[Start \(index)] --> B\(index){Check \(index)}\n  B\(index) -->|Yes| C\(index)[Done \(index)]\n  B\(index) -->|No| A\(index)\n```\n"
        }.joined(separator: "\n")
        var longest: TimeInterval = 0
        var last = Date()
        let heartbeat = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { _ in
            let now = Date()
            longest = max(longest, now.timeIntervalSince(last))
            last = now
        }
        let start = Date()
        let (tenWindow, tenFound) = await openEditor("Ten diagrams\n\n" + ten, width: 760, wait: false)
        tenFound?.layoutManager?.ensureLayout(for: tenFound!.textContainer!)
        tenFound?.display()
        let openTook = Date().timeIntervalSince(start)
        last = Date()
        longest = 0
        var allDrawn = false
        if let tenEditor = tenFound {
            for _ in 0..<300 {
                allDrawn = tenEditor.diagramBoxes().count == 10 && tenEditor.diagramBoxes().allSatisfy { $0.box?.image != nil }
                if allDrawn { break }
                try? await Task.sleep(for: .milliseconds(50))
            }
            capture(tenEditor, name: "editor-ten", in: directory)
        }
        let drawTook = Date().timeIntervalSince(start)
        heartbeat.invalidate()
        print("TEN: page ready in \(Int(renderer.lastLoadTime * 1000)) ms")
        print("TEN: opened in \(Int(openTook * 1000)) ms; all ten drawn in \(Int(drawTook * 1000)) ms with the page loaded cold; the main thread's longest pause \(Int(longest * 1000)) ms")
        check(openTook < 0.6, "a note with ten diagrams opens without a stall (\(Int(openTook * 1000)) ms)")
        check(allDrawn, "all ten are drawn (\(Int(drawTook * 1000)) ms)")
        check(longest < 0.3, "drawing them never holds up the main thread for long (longest pause \(Int(longest * 1000)) ms)")
        tenWindow.close()

        // MARK: Let go when idle

        check(renderer.isLoaded, "the web view is held while diagrams are being drawn")
        try? await Task.sleep(for: .seconds(MermaidRenderer.idleRelease + 1.5))
        check(!renderer.isLoaded, "and let go after \(Int(MermaidRenderer.idleRelease)) seconds unused")

        counter.stop()
        print(failures == 0 ? "MERMAID_OK" : "MERMAID_FAILED: \(failures)")
        return failures == 0 ? 0 : 1
    }

    /// An editor on `text` in a window of its own, out of sight.
    @MainActor
    private static func openEditor(_ text: String, width: CGFloat, binding: Binding<String>? = nil, wait: Bool = true) async -> (NSWindow, MarkdownTextView?) {
        var local = text
        let bound = binding ?? Binding(get: { local }, set: { local = $0 })
        let hosting = NSHostingView(rootView: MarkdownNoteEditor(text: bound).frame(minWidth: 300, maxWidth: .infinity, minHeight: 300, maxHeight: .infinity))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 700), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        if wait { try? await Task.sleep(for: .milliseconds(300)) }
        func find(_ view: NSView) -> MarkdownTextView? { (view as? MarkdownTextView) ?? view.subviews.lazy.compactMap(find).first }
        return (window, find(hosting))
    }

    /// The middle of a diagram's drawing, in the text view.
    @MainActor
    private static func diagramCenter(_ item: (block: MermaidBlock, box: DiagramBox?), editor: MarkdownTextView) -> NSPoint {
        guard let layout = editor.layoutManager as? MarkdownLayoutManager else { return .zero }
        for anchor in [item.block.opening.location, item.block.closing.location] {
            if let (_, frame) = layout.diagramFrame(at: anchor) {
                return NSPoint(x: frame.midX + editor.textContainerOrigin.x, y: frame.midY + editor.textContainerOrigin.y)
            }
        }
        return .zero
    }

    /// How tall a range of lines is laid out.
    @MainActor
    private static func height(of range: NSRange, in editor: MarkdownTextView) -> CGFloat {
        guard let layout = editor.layoutManager else { return 0 }
        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var union = NSRect.null
        layout.enumerateLineFragments(forGlyphRange: glyphs) { rect, _, _, _, _ in union = union.union(rect) }
        return union.isNull ? 0 : union.height
    }

    @MainActor
    private static func save(_ image: NSImage, as name: String, in directory: URL) {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: directory.appendingPathComponent("\(name).png"))
        print("SNAPSHOT: \(name).png")
    }

    /// The whole editor as it draws, on its window's background.
    @MainActor
    private static func capture(_ editor: MarkdownTextView, name: String, in directory: URL) {
        editor.layoutManager?.ensureLayout(for: editor.textContainer!)
        let bounds = editor.bounds
        guard bounds.width > 0, bounds.height > 0, let rep = editor.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        editor.drawsBackground = true
        editor.backgroundColor = .textBackgroundColor
        editor.cacheDisplay(in: bounds, to: rep)
        editor.drawsBackground = false
        try? rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("\(name).png"))
        print("SNAPSHOT: \(name).png")
    }

    /// How light a drawing's shapes are: the average luminance of its most common opaque colour, 0 to 1.
    @MainActor
    private static func fillLuminance(_ image: NSImage) -> Double {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return 0 }
        var counts: [Int: (Int, Double)] = [:]
        let step = max(1, min(rep.pixelsWide, rep.pixelsHigh) / 120)
        for y in stride(from: 0, to: rep.pixelsHigh, by: step) {
            for x in stride(from: 0, to: rep.pixelsWide, by: step) {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), color.alphaComponent > 0.95 else { continue }
                let luma = 0.2126 * color.redComponent + 0.7152 * color.greenComponent + 0.0722 * color.blueComponent
                let bucket = Int(luma * 20)
                let current = counts[bucket] ?? (0, 0)
                counts[bucket] = (current.0 + 1, current.1 + luma)
            }
        }
        guard let common = counts.max(by: { $0.value.0 < $1.value.0 }) else { return 0 }
        return common.value.1 / Double(common.value.0)
    }
}

private extension String {
    /// The line `range` is on, with its ending.
    func lineRange(of range: NSRange) -> NSRange { (self as NSString).lineRange(for: range) }
}
