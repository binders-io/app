import AppKit
import Quartz
import UniformTypeIdentifiers
import BindersKit

// Pictures and videos in the note editor. A line that is only `![caption](attachments/photo.png)` shows the picture
// above its caption; a video shows its first frame and plays in Quick Look. Drop files in, paste a screenshot, or pick
// them from the toolbar: they're copied to the attachments folder and the line is written for you.

extension NSAttributedString.Key {
    /// On a picture's line: what it shows and how big, for drawing it and finding it under a click.
    static let markdownEmbed = NSAttributedString.Key("io.binders.markdown.embed")
}

/// What a picture's line carries: its source and the size it's drawn at.
final class EmbedBox: NSObject {
    let source: String
    let size: NSSize

    init(source: String, size: NSSize) {
        self.source = source
        self.size = size
    }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? EmbedBox else { return false }
        return other.source == source && other.size == size
    }

    override var hash: Int { source.hashValue ^ Int(size.width) ^ (Int(size.height) << 16) }
}

enum EmbedLayout {
    /// Room above a caption line, under the picture.
    static let gap: CGFloat = 8
    /// The widest a picture comes, unless its caption says otherwise.
    static let defaultMaxWidth: CGFloat = 720
    static let defaultMaxHeight: CGFloat = 560
    /// The sizes offered when resizing.
    static let sizes: [(String, Int?)] = [("Small", 240), ("Medium", 480), ("Large", 720), ("Original Size", nil)]
}

extension MarkdownTextView {
    // MARK: Size

    /// How big a picture is drawn: as the caption says, or its own size, never wider than the text.
    func embedSize(source: String, width: Int?) -> NSSize {
        let padding = textContainer?.lineFragmentPadding ?? 5
        let available = max(160, (textContainer?.size.width ?? 600) - 2 * padding - 2)
        guard let url = Attachments.url(for: source) else { return NSSize(width: min(available, 360), height: 56) }
        switch AttachmentPreviews.shared.state(of: url) {
        case .loading:
            return NSSize(width: min(available, CGFloat(width ?? 480)), height: 200)
        case .missing:
            return NSSize(width: min(available, 360), height: 56)
        case .ready(let preview):
            guard preview.size.width > 0, preview.size.height > 0 else { return NSSize(width: min(available, 360), height: 200) }
            var shown = width.map { CGFloat($0) } ?? min(preview.size.width, EmbedLayout.defaultMaxWidth)
            shown = min(shown, available)
            var height = shown * preview.size.height / preview.size.width
            if width == nil, height > EmbedLayout.defaultMaxHeight {
                shown *= EmbedLayout.defaultMaxHeight / height
                height = EmbedLayout.defaultMaxHeight
            }
            return NSSize(width: shown.rounded(), height: height.rounded())
        }
    }

    /// Lays the pictures out again: the text got wider or narrower, or a picture finished loading.
    func restyleEmbeds(showing url: URL? = nil) {
        guard let storage = textStorage, storage.length > 0 else { return }
        let string = storage.string as NSString
        var paragraphs: [NSRange] = []
        storage.enumerateAttribute(.markdownEmbed, in: NSRange(location: 0, length: storage.length)) { value, run, _ in
            guard let box = value as? EmbedBox else { return }
            if let url, Attachments.url(for: box.source) != url { return }
            let paragraph = string.paragraphRange(for: NSRange(location: run.location, length: 0))
            if paragraphs.last != paragraph { paragraphs.append(paragraph) }
        }
        guard !paragraphs.isEmpty else { return }
        storage.beginEditing()
        for paragraph in paragraphs {
            styler.apply(MarkdownSyntax.spans(in: storage.string, lines: paragraph), to: storage, in: paragraph, concealed: !showsMarkup)
        }
        storage.endEditing()
        needsDisplay = true
    }

    // MARK: Finding a picture

    /// The picture under a point in the text view, with where it's drawn and the paragraph it belongs to.
    func embed(at point: NSPoint) -> (box: EmbedBox, frame: NSRect, paragraph: NSRange)? {
        guard let layout = layoutManager as? MarkdownLayoutManager, let container = textContainer, let storage = textStorage, storage.length > 0
        else { return nil }
        let local = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let glyph = layout.glyphIndex(for: local, in: container)
        let character = layout.characterIndexForGlyph(at: glyph)
        guard character < storage.length else { return nil }
        let paragraph = (storage.string as NSString).paragraphRange(for: NSRange(location: character, length: 0))
        guard let box = storage.attribute(.markdownEmbed, at: paragraph.location, effectiveRange: nil) as? EmbedBox,
              let frame = layout.embedFrame(atParagraph: paragraph.location) else { return nil }
        let inView = frame.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
        return inView.contains(point) ? (box, inView, paragraph) : nil
    }

    /// A click on a picture puts the cursor on its line; a second click, or the play button, opens it in Quick Look.
    func clickedEmbed(_ event: NSEvent, at point: NSPoint) -> Bool {
        guard let (box, frame, paragraph) = embed(at: point) else { return false }
        let play = NSRect(x: frame.midX - 30, y: frame.midY - 30, width: 60, height: 60)
        let isVideo = MarkdownMedia.kind(of: box.source) == .video
        window?.makeFirstResponder(self)
        if event.clickCount >= 2 || (isVideo && play.contains(point)) {
            open(box)
        } else {
            let line = (string as NSString).lineRange(for: NSRange(location: paragraph.location, length: 0))
            let end = NSMaxRange(line) - ((string as NSString).substring(with: line).hasSuffix("\n") ? 1 : 0)
            setSelectedRange(NSRange(location: end, length: 0))
        }
        return true
    }

    // MARK: Menu

    func embedMenu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard let (box, _, paragraph) = embed(at: point) else { return nil }
        let menu = NSMenu()
        let isVideo = MarkdownMedia.kind(of: box.source) == .video
        let url = Attachments.url(for: box.source)
        menu.addItem(EmbedMenuItem(isVideo ? "Play" : "Quick Look") { [weak self] in self?.open(box) })
        if let url, url.isFileURL {
            menu.addItem(EmbedMenuItem("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) })
        }
        if !isVideo, let url {
            menu.addItem(EmbedMenuItem("Copy Image") {
                guard let image = NSImage(contentsOf: url) else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([image])
            })
        }
        menu.addItem(.separator())
        let current = MarkdownMedia.embed(inLine: (string as NSString).substring(with: paragraph).trimmingCharacters(in: .newlines), at: 0)?.width
        for (title, width) in EmbedLayout.sizes {
            let item = EmbedMenuItem(title) { [weak self] in self?.resizeEmbed(in: paragraph, to: width) }
            item.state = current == width ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(EmbedMenuItem("Remove") { [weak self] in
            guard let self else { return }
            self.replace(paragraph, with: "", selection: NSRange(location: paragraph.location, length: 0))
        })
        return menu
    }

    private func resizeEmbed(in paragraph: NSRange, to width: Int?) {
        let string = self.string as NSString
        let line = string.substring(with: paragraph)
        let ending = line.hasSuffix("\n") ? "\n" : ""
        let resized = MarkdownMedia.resized(line.trimmingCharacters(in: .newlines), width: width) + ending
        replace(paragraph, with: resized, selection: selectedRange())
    }

    // MARK: Opening

    /// Quick Look for files here, the browser for pictures on the web.
    func open(_ box: EmbedBox) {
        guard let url = Attachments.url(for: box.source) else { return }
        guard url.isFileURL else {
            NSWorkspace.shared.open(url)
            return
        }
        quickLookItem = url
        let panel = QLPreviewPanel.shared()
        if panel?.isVisible == true {
            panel?.reloadData()
        } else {
            panel?.makeKeyAndOrderFront(nil)
        }
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { quickLookItem != nil }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        quickLookItem = nil
    }

    // MARK: Bringing files in

    /// The kinds of things a drop or a paste can bring in as attachments.
    static let attachmentTypes: [NSPasteboard.PasteboardType] =
        [.fileURL, .png, .tiff, NSPasteboard.PasteboardType(UTType.jpeg.identifier), NSPasteboard.PasteboardType(UTType.heic.identifier)]
        + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }

    /// Whether `pasteboard` holds something that comes in as an attachment: files, a picture, or files on their way.
    static func carriesAttachment(_ pasteboard: NSPasteboard) -> Bool {
        if pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) { return true }
        if pasteboard.canReadObject(forClasses: [NSFilePromiseReceiver.self], options: nil) { return true }
        return picturesOnly(pasteboard) && pasteboard.canReadObject(forClasses: [NSImage.self], options: nil)
    }

    /// A picture was copied, not words: there's no text with it, or the text is only its address or file name, as a
    /// browser or Messages puts beside a copied picture.
    private static func picturesOnly(_ pasteboard: NSPasteboard) -> Bool {
        let text = (pasteboard.string(forType: .string) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return true }
        guard !text.contains(where: \.isNewline), !text.contains(" ") || MarkdownMedia.kind(of: text) == .image else { return false }
        return text.hasPrefix("http://") || text.hasPrefix("https://") || text.hasPrefix("file://") || MarkdownMedia.kind(of: text) == .image
    }

    /// Files, pictures or promised files on `pasteboard`, copied in and written at `location` on lines of their own.
    /// False when there's nothing of the kind, so the text goes in as usual.
    func insertAttachments(from pasteboard: NSPasteboard, at location: Int) -> Bool {
        let files = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        if !files.isEmpty {
            insertBlock(files.compactMap { try? Attachments.add($0) }, at: location)
            return true
        }
        // A picture as data: a screenshot, a photo, or one copied from a page or another app.
        if Self.picturesOnly(pasteboard) {
            for (type, uti) in [(NSPasteboard.PasteboardType.png, UTType.png), (NSPasteboard.PasteboardType(UTType.jpeg.identifier), .jpeg),
                                (NSPasteboard.PasteboardType(UTType.heic.identifier), .heic), (.tiff, .tiff)] {
                if let data = pasteboard.data(forType: type), let line = try? Attachments.add(imageData: data, type: uti) {
                    insertBlock([line], at: location)
                    return true
                }
            }
            // Any other kind of picture macOS can read (a PDF page, GIF, WebP…), kept as PNG.
            if let image = (pasteboard.readObjects(forClasses: [NSImage.self]) as? [NSImage])?.first, let tiff = image.tiffRepresentation,
               let line = try? Attachments.add(imageData: tiff, type: .tiff) {
                insertBlock([line], at: location)
                return true
            }
        }
        // Promised files, from Photos and Mail: they're written somewhere first, then brought in.
        if let promises = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver], !promises.isEmpty {
            let destination = FileManager.default.temporaryDirectory.appendingPathComponent("Binders drops/\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            for promise in promises {
                promise.receivePromisedFiles(atDestination: destination, options: [:], operationQueue: .main) { [weak self] file, error in
                    guard error == nil else { return }
                    MainActor.assumeIsolated {
                        guard let self, let line = try? Attachments.add(file) else { return }
                        self.insertBlock([line], at: min(location, (self.string as NSString).length))
                        try? FileManager.default.removeItem(at: file)
                    }
                }
            }
            return true
        }
        return false
    }

    /// Lines put in on their own: after the line the cursor is on if it has words, else in its place.
    func insertBlock(_ lines: [String], at location: Int) {
        guard !lines.isEmpty else { return }
        let string = self.string as NSString
        let location = min(location, string.length)
        let line = string.lineRange(for: NSRange(location: location, length: 0))
        let content = string.substring(with: line)
        let block = lines.joined(separator: "\n")
        let range: NSRange
        let text: String
        if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            range = NSRange(location: line.location, length: (content as NSString).length - (content.hasSuffix("\n") ? 1 : 0))
            text = block
        } else {
            let end = NSMaxRange(line) - (content.hasSuffix("\n") ? 1 : 0)
            range = NSRange(location: end, length: 0)
            text = "\n" + block
        }
        // A line after it to keep writing on.
        let after = NSMaxRange(range) < string.length ? "" : "\n"
        replace(range, with: text + after, selection: NSRange(location: range.location + (text as NSString).length + (after.isEmpty ? 1 : 1), length: 0))
    }

    /// Picks pictures, videos or files to add, from the toolbar.
    func chooseAttachments() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Pictures and videos show in the note; other files are linked."
        panel.prompt = "Add"
        let location = selectedRange().location
        let done: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let self else { return }
            self.insertBlock(panel.urls.compactMap { try? Attachments.add($0) }, at: location)
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: done) } else { done(panel.runModal()) }
    }

    /// One undoable change.
    func replace(_ range: NSRange, with text: String, selection: NSRange) {
        guard shouldChangeText(in: range, replacementString: text) else { return }
        textStorage?.replaceCharacters(in: range, with: text)
        didChangeText()
        let length = (string as NSString).length
        setSelectedRange(NSRange(location: min(selection.location, length), length: min(selection.length, max(0, length - selection.location))))
        scrollRangeToVisible(selectedRange())
    }
}

extension MarkdownTextView: QLPreviewPanelDataSource {
    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { quickLookItem == nil ? 0 : 1 }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        MainActor.assumeIsolated { quickLookItem as NSURL? }
    }
}

/// A menu item that runs a closure.
final class EmbedMenuItem: NSMenuItem {
    private let run: () -> Void

    init(_ title: String, _ run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(runAction), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func runAction() { run() }
}

// MARK: - Drawing

extension MarkdownLayoutManager {
    /// Where the picture of the paragraph starting at `location` is drawn, in the text container: in the room above its
    /// caption line.
    func embedFrame(atParagraph location: Int) -> NSRect? {
        guard let storage = textStorage, location < storage.length, let container = textContainers.first,
              let box = storage.attribute(.markdownEmbed, at: location, effectiveRange: nil) as? EmbedBox else { return nil }
        let glyph = glyphIndexForCharacter(at: location)
        guard glyph < numberOfGlyphs else { return nil }
        let used = lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
        return NSRect(x: container.lineFragmentPadding, y: used.minY - EmbedLayout.gap - box.size.height, width: box.size.width, height: box.size.height)
    }

    func drawEmbeds(in characters: NSRange, at origin: NSPoint) {
        guard let storage = textStorage else { return }
        let string = storage.string as NSString
        var drawn = Set<Int>()
        let selection = firstTextView?.selectedRange()
        let focused = firstTextView.map { $0.window?.firstResponder === $0 } ?? false
        storage.enumerateAttribute(.markdownEmbed, in: characters) { value, run, _ in
            guard let box = value as? EmbedBox else { return }
            let paragraph = string.paragraphRange(for: NSRange(location: run.location, length: 0))
            guard drawn.insert(paragraph.location).inserted, let frame = embedFrame(atParagraph: paragraph.location) else { return }
            let rect = frame.offsetBy(dx: origin.x, dy: origin.y)
            let selected = focused && selection.map { NSIntersectionRange($0, paragraph).length > 0 || NSLocationInRange($0.location, paragraph) } == true
            MainActor.assumeIsolated { Self.draw(box, in: rect, selected: selected) }
        }
    }

    @MainActor
    private static func draw(_ box: EmbedBox, in rect: NSRect, selected: Bool) {
        let shape = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
        let state = Attachments.url(for: box.source).map { AttachmentPreviews.shared.state(of: $0) } ?? .missing
        switch state {
        case .ready(let preview):
            NSGraphicsContext.saveGraphicsState()
            shape.addClip()
            preview.image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
                               hints: [.interpolation: NSNumber(value: NSImageInterpolation.high.rawValue)])
            NSGraphicsContext.restoreGraphicsState()
            NSColor.labelColor.withAlphaComponent(0.12).setStroke()
            shape.lineWidth = 0.5
            shape.stroke()
            if preview.isVideo { drawPlayButton(in: rect, duration: preview.duration) }
        case .loading:
            NSColor.labelColor.withAlphaComponent(0.05).setFill()
            shape.fill()
            drawSymbol("photo", in: rect, label: nil)
        case .missing:
            NSColor.labelColor.withAlphaComponent(0.05).setFill()
            shape.fill()
            drawSymbol("exclamationmark.triangle", in: rect, label: "Can't find \((box.source as NSString).lastPathComponent)")
        }
        if selected {
            let ring = NSBezierPath(roundedRect: rect.insetBy(dx: -2, dy: -2), xRadius: 10, yRadius: 10)
            ring.lineWidth = 3
            NSColor.controlAccentColor.setStroke()
            ring.stroke()
        }
    }

    @MainActor
    private static func drawPlayButton(in rect: NSRect, duration: Double?) {
        let side: CGFloat = min(60, rect.height * 0.4)
        let circle = NSRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side)
        NSColor.black.withAlphaComponent(0.55).setFill()
        NSBezierPath(ovalIn: circle).fill()
        let triangle = NSBezierPath()
        let inset = side * 0.32
        triangle.move(to: NSPoint(x: circle.minX + inset * 1.15, y: circle.minY + inset))
        triangle.line(to: NSPoint(x: circle.minX + inset * 1.15, y: circle.maxY - inset))
        triangle.line(to: NSPoint(x: circle.maxX - inset * 0.85, y: circle.midY))
        triangle.close()
        NSColor.white.setFill()
        triangle.fill()
        guard let duration, duration.isFinite, duration > 0 else { return }
        let seconds = Int(duration.rounded())
        let label = seconds >= 3600 ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
                                    : String(format: "%d:%02d", seconds / 60, seconds % 60)
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.white]
        let size = (label as NSString).size(withAttributes: attributes)
        let pill = NSRect(x: rect.maxX - size.width - 18, y: rect.maxY - size.height - 12, width: size.width + 10, height: size.height + 4)
        NSColor.black.withAlphaComponent(0.6).setFill()
        NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
        (label as NSString).draw(at: NSPoint(x: pill.minX + 5, y: pill.minY + 2), withAttributes: attributes)
    }

    @MainActor
    private static func drawSymbol(_ name: String, in rect: NSRect, label: String?) {
        let configuration = NSImage.SymbolConfiguration(pointSize: 20, weight: .regular).applying(.init(paletteColors: [.tertiaryLabelColor]))
        let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor]
        let labelSize = label.map { ($0 as NSString).size(withAttributes: attributes) } ?? .zero
        let symbolSize = symbol?.size ?? .zero
        let total = symbolSize.width + (label == nil ? 0 : 8 + labelSize.width)
        var x = rect.midX - total / 2
        symbol?.draw(in: NSRect(x: x, y: rect.midY - symbolSize.height / 2, width: symbolSize.width, height: symbolSize.height),
                     from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        x += symbolSize.width + 8
        if let label { (label as NSString).draw(at: NSPoint(x: x, y: rect.midY - labelSize.height / 2), withAttributes: attributes) }
    }
}
