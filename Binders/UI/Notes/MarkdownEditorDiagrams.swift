import AppKit
import BindersKit

// Lane MM1: Mermaid diagrams in the note editor. A ```mermaid block shows as its drawing while the cursor is elsewhere,
// the way a picture shows: its code takes no room and the drawing sits where it was. With the cursor in it (or the block
// selected, or Show Markdown on) the code shows as any code block does, with the drawing under it, drawn again a moment
// after typing stops. One Mermaid can't read shows a quiet line under its code instead. Nothing goes into the text, so
// the saved Markdown, copying, Find and everything that reads notes see the code as it's written.

extension NSAttributedString.Key {
    /// On a diagram's first line (drawn in place of its code) or its closing fence's line (drawn under the code): what's
    /// drawn there (`DiagramBox`).
    static let markdownDiagram = NSAttributedString.Key("io.binders.markdown.diagram")
    /// A diagram's code while its drawing shows in its place: it takes no room, even on the line being edited.
    static let markdownDiagramHidden = NSAttributedString.Key("io.binders.markdown.diagramHidden")
}

/// What a diagram's line carries for drawing it.
final class DiagramBox: NSObject {
    enum Place {
        /// In place of the code, in the room above its first line.
        case inPlace
        /// Under the code, in the room below its closing fence.
        case under
    }

    let place: Place
    let image: NSImage?
    /// "Mermaid couldn't draw this: …", shown under the code instead of a drawing.
    let error: String?
    /// The size the drawing is shown at, or the error line's.
    let size: NSSize
    let fontSize: CGFloat

    init(place: Place, image: NSImage?, error: String?, size: NSSize, fontSize: CGFloat) {
        self.place = place
        self.image = image
        self.error = error
        self.size = size
        self.fontSize = fontSize
    }

    /// The room it takes below the closing fence, when it's under the code.
    var room: CGFloat { place == .under ? DiagramLayout.gap * 2 + size.height : 0 }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? DiagramBox else { return false }
        return other.place == place && other.image === image && other.error == error && other.size == size
    }

    override var hash: Int { Int(size.width) ^ (Int(size.height) << 16) ^ (error?.hashValue ?? 0) }

    static func errorFont(_ fontSize: CGFloat) -> NSFont { .systemFont(ofSize: max(10, fontSize * 0.82)) }
}

enum DiagramLayout {
    /// Room above and below a drawing.
    static let gap: CGFloat = 10
    /// How long typing in a diagram pauses before it's drawn again.
    static var pause: TimeInterval = 0.5
}

/// The text view's part in it: the note's diagrams as its text is now, which are showing their code, and the drawings
/// kept while a diagram's code is being changed.
final class EditorDiagrams {
    /// The note's ```mermaid blocks; nil when the text changed and they're found again on next use.
    var blocks: [MermaidBlock]?
    /// The blocks showing their code, as the cursor or selection last left them.
    var showingCode: [NSRange] = []
    /// Where the edit being processed is, so a block being typed in shows its code before the cursor has moved.
    var editing: NSRange?
    /// Each diagram's last drawing, by its place among the note's diagrams: shown while its code changes, until the new
    /// one is drawn.
    var lastDrawn: [Int: NSImage] = [:]
    var observer: NSObjectProtocol?
    var redraw: DispatchWorkItem?

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        redraw?.cancel()
    }
}

extension MarkdownTextView {
    // MARK: Finding

    /// The note's diagrams, found again only after the text changed. A note that never says "mermaid" costs one search.
    func diagramBlocks() -> [MermaidBlock] {
        if let blocks = diagramState.blocks { return blocks }
        let found = MarkdownDiagrams.mermaidBlocks(in: string)
        diagramState.blocks = found
        if !found.isEmpty { watchDiagrams() }
        return found
    }

    /// The theme the editor's appearance asks for.
    var diagramTheme: MermaidRenderer.Theme {
        effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
    }

    /// The width a drawing may take: the text's.
    var diagramWidth: CGFloat {
        let padding = textContainer?.lineFragmentPadding ?? 5
        return max(160, (textContainer?.size.width ?? 600) - 2 * padding - 2)
    }

    func diagramRequest(_ block: MermaidBlock) -> MermaidRenderer.Request {
        MermaidRenderer.Request(source: block.source, theme: diagramTheme, width: diagramWidth)
    }

    /// Whether `selection` is in `block`: the cursor on any of its lines, or a selection touching it.
    private func selection(_ selection: NSRange, touches block: MermaidBlock) -> Bool {
        if selection.length == 0 { return selection.location >= block.range.location && selection.location <= NSMaxRange(block.closing) }
        return NSIntersectionRange(selection, block.range).length > 0
    }

    /// Whether `block` shows its code: Show Markdown is on, the cursor or selection is in it, or it's being typed in.
    func showsCode(_ block: MermaidBlock) -> Bool {
        if showsMarkup { return true }
        if let editing = diagramState.editing, editing.location >= block.range.location, editing.location <= NSMaxRange(block.range) { return true }
        if diagramState.showingCode.contains(where: { NSIntersectionRange($0, block.range).length > 0 || $0.location == block.range.location }) { return true }
        guard textStorage?.editedMask.isEmpty ?? true, window?.firstResponder === self else { return false }
        return selection(selectedRange(), touches: block)
    }

    // MARK: Keeping up

    /// The text changed: the blocks are found again, and the ones showing their code move with it.
    func diagramsEdited(_ editedRange: NSRange, delta: Int) {
        guard diagramState.blocks.map({ !$0.isEmpty }) ?? true || MarkdownDiagrams.mightContainMermaid(string) else {
            diagramState.blocks = []
            return
        }
        diagramState.blocks = nil
        diagramState.editing = editedRange
        diagramState.showingCode = diagramState.showingCode.map { range in
            var range = range
            if editedRange.location >= range.location, editedRange.location <= NSMaxRange(range) {
                range.length = max(0, range.length + delta)
            } else if editedRange.location < range.location {
                range.location = max(0, range.location + delta)
            }
            return range
        }
    }

    /// The edit has been styled.
    func diagramsEditDone() {
        diagramState.editing = nil
    }

    /// The cursor moved or the editor gained or lost focus: a block the cursor came into shows its code, and one it left
    /// its drawing.
    func diagramSelectionChanged(focused: Bool) {
        guard let storage = textStorage, storage.editedMask.isEmpty else { return }
        let blocks = diagramBlocks()
        guard !blocks.isEmpty || !diagramState.showingCode.isEmpty else { return }
        let selection = selectedRange()
        let now = focused ? blocks.filter { self.selection(selection, touches: $0) }.map(\.range) : []
        guard now != diagramState.showingCode else { return }
        let before = diagramState.showingCode
        diagramState.showingCode = now
        restyleDiagrams(before + now)
    }

    /// Restyles the blocks `ranges` touch, or every diagram.
    func restyleDiagrams(_ ranges: [NSRange]? = nil) {
        guard let storage = textStorage, storage.length > 0 else { return }
        let blocks = diagramBlocks()
        guard !blocks.isEmpty else { return }
        let targets = ranges.map { ranges in
            blocks.filter { block in ranges.contains { NSIntersectionRange($0, block.range).length > 0 || $0.location == block.range.location } }
        } ?? blocks
        guard !targets.isEmpty else { return }
        storage.beginEditing()
        for block in targets where NSMaxRange(block.range) <= storage.length {
            restyle(paragraphs: block.range)
        }
        storage.endEditing()
        needsDisplay = true
    }

    /// Drawings that finish are shown in every editor with that diagram.
    private func watchDiagrams() {
        guard diagramState.observer == nil else { return }
        diagramState.observer = NotificationCenter.default.addObserver(forName: MermaidRenderer.drawn, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let key = note.object as? String else { return }
                let ranges = self.diagramBlocks().filter { self.diagramRequest($0).key == key }.map(\.range)
                if !ranges.isEmpty { self.restyleDiagrams(ranges) }
            }
        }
    }

    /// The diagram being typed in is drawn once typing pauses.
    private func redrawLater(_ request: MermaidRenderer.Request) {
        diagramState.redraw?.cancel()
        let work = DispatchWorkItem { MermaidRenderer.shared.draw(request) }
        diagramState.redraw = work
        DispatchQueue.main.asyncAfter(deadline: .now() + DiagramLayout.pause, execute: work)
    }

    // MARK: Styling

    /// Styles the diagrams `range` touches, after the rest of the styling: each shows its drawing in place of its code,
    /// or under it, or the line saying why there's none. One not drawn yet shows its code and is asked for.
    func applyDiagrams(in range: NSRange) {
        guard let storage = textStorage, storage.length > 0 else { return }
        let blocks = diagramBlocks()
        guard !blocks.isEmpty else { return }
        for (index, block) in blocks.enumerated() where NSMaxRange(block.range) <= storage.length {
            guard NSIntersectionRange(block.range, range).length > 0 else { continue }
            let request = diagramRequest(block)
            let code = showsCode(block)
            var image: NSImage?
            var error: String?
            switch MermaidRenderer.shared.drawing(for: request) {
            case .image(let drawn):
                image = drawn
                diagramState.lastDrawn[index] = drawn
            case .failed(let message):
                error = message
            case nil:
                image = diagramState.lastDrawn[index]
                if code, !showsMarkup { redrawLater(request) } else { MermaidRenderer.shared.draw(request) }
            }
            if let image, !code {
                hideCode(of: block, showing: image, in: range, storage: storage)
            } else if image != nil || error != nil {
                placeUnder(block, image: image, error: error, in: range, storage: storage)
            }
        }
    }

    /// The size `image` is shown at: its own, or narrower to fit the text, keeping its shape.
    private func shownSize(of image: NSImage) -> NSSize {
        let width = min(image.size.width, diagramWidth)
        guard image.size.width > 0 else { return image.size }
        return NSSize(width: width.rounded(), height: (image.size.height * width / image.size.width).rounded())
    }

    /// The code takes no room, and the drawing is shown in the room above its first line.
    private func hideCode(of block: MermaidBlock, showing image: NSImage, in range: NSRange, storage: NSTextStorage) {
        let lines = NSIntersectionRange(block.range, range)
        guard lines.length > 0 else { return }
        let size = shownSize(of: image)
        let fontSize = styler.fontSize
        let tiny = NSFont.systemFont(ofSize: 1)
        let string = storage.string as NSString
        string.enumerateSubstrings(in: lines, options: [.byLines, .substringNotRequired]) { _, line, enclosing, _ in
            let style = NSMutableParagraphStyle()
            style.minimumLineHeight = 1
            style.maximumLineHeight = 1
            style.lineSpacing = 0
            style.paragraphSpacing = 0
            if line.location == block.range.location { style.paragraphSpacingBefore = DiagramLayout.gap + size.height + DiagramLayout.gap }
            if NSMaxRange(enclosing) >= NSMaxRange(block.range) { style.paragraphSpacing = fontSize * 0.5 }
            storage.setAttributes([.font: tiny, .foregroundColor: NSColor.clear, .paragraphStyle: style], range: enclosing)
            // Not the line ending: it still has to end the line.
            if line.length > 0 { storage.addAttribute(.markdownDiagramHidden, value: true, range: line) }
            if line.location == block.range.location, line.length > 0 {
                storage.addAttribute(.markdownDiagram, value: DiagramBox(place: .inPlace, image: image, error: nil, size: size, fontSize: fontSize),
                                     range: line)
            }
        }
    }

    /// The code shows as it is; the drawing, or why there's none, goes in room made under its closing fence.
    private func placeUnder(_ block: MermaidBlock, image: NSImage?, error: String?, in range: NSRange, storage: NSTextStorage) {
        let string = storage.string as NSString
        let line = string.lineRange(for: block.closing)
        guard NSIntersectionRange(line, range).length > 0 else { return }
        let fontSize = styler.fontSize
        let size: NSSize
        if let image {
            size = shownSize(of: image)
        } else {
            let font = DiagramBox.errorFont(fontSize)
            let words = ((error ?? "") as NSString).boundingRect(with: NSSize(width: diagramWidth, height: 10_000), options: [.usesLineFragmentOrigin],
                                                                 attributes: [.font: font])
            size = NSSize(width: ceil(words.width), height: ceil(words.height))
        }
        let box = DiagramBox(place: .under, image: image, error: image == nil ? error : nil, size: size, fontSize: fontSize)
        let current = (storage.attribute(.paragraphStyle, at: line.location, effectiveRange: nil) as? NSParagraphStyle) ?? styler.baseParagraph
        let style = current.mutableCopy() as! NSMutableParagraphStyle
        style.paragraphSpacing += box.room
        storage.addAttributes([.paragraphStyle: style, .markdownDiagram: box], range: line)
    }

    // MARK: Finding a drawing

    /// The diagram drawn under a point, with where it's drawn and its block.
    func diagram(at point: NSPoint) -> (box: DiagramBox, frame: NSRect, block: MermaidBlock)? {
        guard let layout = layoutManager as? MarkdownLayoutManager, let storage = textStorage, storage.length > 0 else { return nil }
        for block in diagramBlocks() where NSMaxRange(block.range) <= storage.length {
            for anchor in [block.opening.location, block.closing.location] {
                guard let (box, frame) = layout.diagramFrame(at: anchor) else { continue }
                let inView = frame.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
                if inView.contains(point) { return (box, inView, block) }
            }
        }
        return nil
    }

    /// A click on a diagram shown in place of its code opens the code, the cursor on its first line.
    func clickedDiagram(_ event: NSEvent, at point: NSPoint) -> Bool {
        guard let (box, _, block) = diagram(at: point), box.place == .inPlace else { return false }
        editDiagram(block)
        return true
    }

    func editDiagram(_ block: MermaidBlock) {
        window?.makeFirstResponder(self)
        let string = self.string as NSString
        let firstLine = NSMaxRange(string.lineRange(for: block.opening))
        let location = min(firstLine, block.closing.location)
        setSelectedRange(NSRange(location: location, length: 0))
        scrollRangeToVisible(NSRange(location: location, length: 0))
    }

    func diagramMenu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard let (box, _, block) = diagram(at: point) else { return nil }
        let menu = NSMenu()
        if box.place == .inPlace {
            menu.addItem(EmbedMenuItem("Edit Diagram") { [weak self] in self?.editDiagram(block) })
        }
        if let image = box.image {
            menu.addItem(EmbedMenuItem("Copy Image") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([image])
            })
        }
        return menu.items.isEmpty ? nil : menu
    }

    /// The diagrams' boxes as they're styled now, in order (the self-test).
    func diagramBoxes() -> [(block: MermaidBlock, box: DiagramBox?)] {
        guard let storage = textStorage else { return [] }
        return diagramBlocks().map { block in
            guard NSMaxRange(block.range) <= storage.length else { return (block, nil) }
            let box = [block.opening.location, block.closing.location].lazy
                .compactMap { storage.attribute(.markdownDiagram, at: $0, effectiveRange: nil) as? DiagramBox }.first
            return (block, box)
        }
    }
}

// MARK: - Drawing

extension MarkdownLayoutManager {
    /// Where the diagram on the line at `location` is drawn, in the text container.
    func diagramFrame(at location: Int) -> (DiagramBox, NSRect)? {
        guard let storage = textStorage, location < storage.length, let container = textContainers.first,
              let box = storage.attribute(.markdownDiagram, at: location, effectiveRange: nil) as? DiagramBox else { return nil }
        let glyph = glyphIndexForCharacter(at: location)
        guard glyph < numberOfGlyphs else { return nil }
        let fragment = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let x = container.lineFragmentPadding
        switch box.place {
        case .inPlace:
            return (box, NSRect(x: x, y: fragment.minY + DiagramLayout.gap, width: box.size.width, height: box.size.height))
        case .under:
            // The room is at the bottom of the closing fence's line.
            return (box, NSRect(x: x, y: fragment.maxY - box.room + DiagramLayout.gap, width: box.size.width, height: box.size.height))
        }
    }

    /// The code block runs in `run`, each with the room under it that a diagram takes, which its background leaves out.
    func codeBlockPieces(of run: NSRange) -> [(range: NSRange, room: CGFloat)] {
        guard let storage = textStorage else { return [(run, 0)] }
        var pieces: [(NSRange, CGFloat)] = []
        var start = run.location
        storage.enumerateAttribute(.markdownDiagram, in: run) { value, found, _ in
            guard let box = value as? DiagramBox, box.place == .under else { return }
            let end = NSMaxRange(found)
            pieces.append((NSRange(location: start, length: end - start), box.room))
            start = end
        }
        if start < NSMaxRange(run) || pieces.isEmpty { pieces.append((NSRange(location: start, length: NSMaxRange(run) - start), 0)) }
        return pieces
    }

    /// Where a code block's background ends when a diagram is under it: above the room its last line makes.
    func codeBottom(above piece: NSRange, room: CGFloat) -> CGFloat {
        let glyph = glyphIndexForCharacter(at: max(piece.location, NSMaxRange(piece) - 1))
        guard glyph < numberOfGlyphs else { return .greatestFiniteMagnitude }
        return lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).maxY - room
    }

    func drawDiagrams(in characters: NSRange, at origin: NSPoint) {
        guard let storage = textStorage else { return }
        var drawn = Set<Int>()
        storage.enumerateAttribute(.markdownDiagram, in: characters) { value, run, _ in
            guard value is DiagramBox, drawn.insert(run.location).inserted, let (box, frame) = diagramFrame(at: run.location) else { return }
            let rect = frame.offsetBy(dx: origin.x, dy: origin.y)
            MainActor.assumeIsolated { Self.draw(box, in: rect) }
        }
    }

    @MainActor
    private static func draw(_ box: DiagramBox, in rect: NSRect) {
        if let image = box.image {
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
                       hints: [.interpolation: NSNumber(value: NSImageInterpolation.high.rawValue)])
        } else if let error = box.error {
            (error as NSString).draw(with: rect, options: [.usesLineFragmentOrigin],
                                     attributes: [.font: DiagramBox.errorFont(box.fontSize), .foregroundColor: NSColor.secondaryLabelColor])
        }
    }
}
