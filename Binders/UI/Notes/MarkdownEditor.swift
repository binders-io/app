import AppKit
import SwiftUI
import BindersKit

// A note editor that keeps notes as plain Markdown and shows it rendered: headings, bold and italic, code spans and
// fenced code blocks, lists that continue on Return, checkboxes you click, quotes and links. The markup (#, **, [ ], the
// link's address) is hidden except on the lines being edited, where it shows faintly, like Obsidian's live preview;
// "Show Markdown" keeps it visible everywhere. Team sync, search and the MCP server read the same plain text.

/// The toolbar's handle on the editor it belongs to.
@MainActor
@Observable
final class MarkdownEditorModel {
    @ObservationIgnored fileprivate weak var textView: MarkdownTextView?

    enum Command {
        case bold, italic, strikethrough, inlineCode, codeBlock, link
        case bullet, numbered, task, quote
        case heading(Int)
    }

    func perform(_ command: Command) {
        guard let textView else { return }
        textView.window?.makeFirstResponder(textView)
        textView.run(command)
    }
}

/// The editor with its formatting toolbar above it.
struct MarkdownNoteEditor: View {
    @Binding var text: String
    var fontSize: CGFloat = 15
    var placeholder = ""
    var inset = NSSize(width: 20, height: 16)
    var compactToolbar = false
    @State private var model = MarkdownEditorModel()
    /// Every note editor follows the same choice.
    @AppStorage("notesShowMarkdown") private var showsMarkup = false

    var body: some View {
        VStack(spacing: 0) {
            MarkdownToolbar(model: model, compact: compactToolbar, showsMarkup: $showsMarkup)
            Divider().opacity(0.5)
            MarkdownEditor(text: $text, model: model, fontSize: fontSize, placeholder: placeholder, inset: inset, showsMarkup: showsMarkup)
        }
    }
}

struct MarkdownToolbar: View {
    let model: MarkdownEditorModel
    var compact = false
    @Binding var showsMarkup: Bool

    var body: some View {
        HStack(spacing: compact ? 2 : 4) {
            Menu {
                Button("Heading 1  ⌘⌥1") { model.perform(.heading(1)) }
                Button("Heading 2  ⌘⌥2") { model.perform(.heading(2)) }
                Button("Heading 3  ⌘⌥3") { model.perform(.heading(3)) }
            } label: {
                Image(systemName: "textformat.size")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Heading")
            separator
            button("bold", "Bold  ⌘B", .bold)
            button("italic", "Italic  ⌘I", .italic)
            button("strikethrough", "Strikethrough  ⌘⇧X", .strikethrough)
            button("chevron.left.forwardslash.chevron.right", "Code  ⌘E", .inlineCode)
            button("curlybraces", "Code block  ⌘⌥C", .codeBlock)
            button("link", "Link  ⌘K", .link)
            separator
            button("list.bullet", "Bulleted list  ⌘⇧8", .bullet)
            button("list.number", "Numbered list  ⌘⇧7", .numbered)
            button("checklist", "Checklist  ⌘⇧L", .task)
            button("text.quote", "Quote  ⌘⇧.", .quote)
            Spacer(minLength: 0)
            Toggle(isOn: $showsMarkup) {
                Image(systemName: "number").frame(width: compact ? 20 : 24, height: compact ? 18 : 20)
            }
            .toggleStyle(.button)
            .help(showsMarkup ? "Hide the Markdown except on the line you're editing" : "Show the Markdown (#, **, links) everywhere")
            .accessibilityLabel("Show Markdown")
        }
        .buttonStyle(.borderless)
        .imageScale(compact ? .small : .medium)
        .foregroundStyle(.secondary)
        .padding(.horizontal, compact ? 8 : 14)
        .padding(.vertical, compact ? 5 : 7)
    }

    private var separator: some View {
        Divider().frame(height: 14).padding(.horizontal, compact ? 2 : 4)
    }

    private func button(_ symbol: String, _ help: String, _ command: MarkdownEditorModel.Command) -> some View {
        Button { model.perform(command) } label: {
            Image(systemName: symbol).frame(width: compact ? 20 : 24, height: compact ? 18 : 20)
        }
        .help(help)
        .accessibilityLabel(help.components(separatedBy: "  ").first ?? help)
    }
}

struct MarkdownEditor: NSViewRepresentable {
    @Binding var text: String
    let model: MarkdownEditorModel
    var fontSize: CGFloat = 15
    var placeholder = ""
    var inset = NSSize(width: 20, height: 16)
    var showsMarkup = false

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let storage = NSTextStorage()
        let layout = MarkdownLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)

        let textView = MarkdownTextView(frame: .zero, textContainer: container)
        layout.delegate = textView
        textView.showsMarkup = showsMarkup
        textView.styler = MarkdownStyler(fontSize: fontSize)
        textView.placeholder = placeholder
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isContinuousSpellCheckingEnabled = true
        textView.textContainerInset = inset
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.typingAttributes = textView.styler.baseAttributes
        storage.delegate = textView
        textView.string = text
        textView.restyle()
        model.textView = textView

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.documentView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scroll.documentView as? MarkdownTextView else { return }
        model.textView = textView
        textView.showsMarkup = showsMarkup
        // Only text that changed elsewhere (sync, a digest, another window) is pushed in; typing goes the other way.
        if textView.string != text, !context.coordinator.isEditing {
            let selection = textView.selectedRange()
            textView.string = text
            textView.restyle()
            let length = (text as NSString).length
            textView.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownEditor
        var isEditing = false

        init(_ parent: MarkdownEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            isEditing = true
            parent.text = textView.string
            isEditing = false
        }
    }
}

// MARK: - Styling

private extension NSAttributedString.Key {
    static let markdownCodeBlock = NSAttributedString.Key("io.binders.markdown.codeBlock")
    static let markdownQuote = NSAttributedString.Key("io.binders.markdown.quote")
    static let markdownTask = NSAttributedString.Key("io.binders.markdown.task")
    static let markdownRule = NSAttributedString.Key("io.binders.markdown.rule")
    /// Markup hidden when its line isn't being edited: #, **, `, >, a task's "- ", a fence's ```, a link's brackets and address.
    static let markdownConceal = NSAttributedString.Key("io.binders.markdown.conceal")
    /// A "-", "*" or "+" list marker, shown as • when its line isn't being edited.
    static let markdownBullet = NSAttributedString.Key("io.binders.markdown.bullet")
    /// A link's address, on its label, for ⌘-click.
    static let markdownLink = NSAttributedString.Key("io.binders.markdown.link")
}

/// Turns the spans `MarkdownSyntax` finds into text attributes.
@MainActor
struct MarkdownStyler {
    let fontSize: CGFloat

    var baseFont: NSFont { .systemFont(ofSize: fontSize) }
    var codeFont: NSFont { .monospacedSystemFont(ofSize: fontSize * 0.9, weight: .regular) }

    var baseParagraph: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = fontSize * 0.25
        style.paragraphSpacing = fontSize * 0.3
        return style
    }

    var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: baseFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: baseParagraph]
    }

    func apply(_ spans: [MarkdownSpan], to storage: NSTextStorage, in range: NSRange) {
        storage.setAttributes(baseAttributes, range: range)
        func clipped(_ span: MarkdownSpan) -> NSRange? {
            let overlap = NSIntersectionRange(span.range, range)
            return overlap.length > 0 || (span.range.length == 0 && NSLocationInRange(span.range.location, range)) ? overlap : nil
        }
        // Block styles first, then inline ones, then the faint markup on top.
        for span in spans {
            guard let target = clipped(span) else { continue }
            switch span.style {
            case .heading(let level):
                let scale: CGFloat = [1.6, 1.35, 1.15, 1.05, 1, 1][min(level, 6) - 1]
                storage.addAttribute(.font, value: NSFont.systemFont(ofSize: fontSize * scale, weight: .bold), range: target)
                let style = baseParagraph.mutableCopy() as! NSMutableParagraphStyle
                style.paragraphSpacingBefore = fontSize * (level <= 2 ? 0.6 : 0.3)
                storage.addAttribute(.paragraphStyle, value: style, range: target)
            case .codeBlock, .codeFence:
                // The whole line, newline included, so a block's background is one piece and blank lines in it keep theirs.
                let line = NSIntersectionRange((storage.string as NSString).lineRange(for: span.range), range)
                storage.addAttributes([.font: codeFont, .markdownCodeBlock: true], range: line)
                if span.style == .codeFence {
                    storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: target)
                    // The ``` goes; a language name after it stays, faintly.
                    let fence = (storage.string as NSString).range(of: #"^ {0,3}(`{3,}|~{3,})"#, options: .regularExpression, range: span.range)
                    if fence.location != NSNotFound { storage.addAttribute(.markdownConceal, value: true, range: NSIntersectionRange(fence, range)) }
                }
            case .quote:
                let style = baseParagraph.mutableCopy() as! NSMutableParagraphStyle
                style.firstLineHeadIndent = 14
                style.headIndent = 14
                storage.addAttributes([.foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: style, .markdownQuote: true], range: target)
            case .rule:
                storage.addAttributes([.foregroundColor: NSColor.clear, .markdownRule: true], range: target)
            default:
                break
            }
        }
        for span in spans {
            guard let target = clipped(span) else { continue }
            switch span.style {
            case .bold: convert(storage, target, to: .boldFontMask)
            case .italic: convert(storage, target, to: .italicFontMask)
            case .strikethrough:
                storage.addAttributes([.strikethroughStyle: NSUnderlineStyle.single.rawValue, .foregroundColor: NSColor.secondaryLabelColor], range: target)
            case .inlineCode:
                storage.addAttributes([.font: codeFont, .backgroundColor: NSColor.labelColor.withAlphaComponent(0.07)], range: target)
            case .listMarker:
                storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: target)
                if target.length == 1, "-*+".contains((storage.string as NSString).substring(with: target)) {
                    storage.addAttribute(.markdownBullet, value: true, range: target)
                }
            case .checkedText:
                storage.addAttributes([.strikethroughStyle: NSUnderlineStyle.single.rawValue, .foregroundColor: NSColor.tertiaryLabelColor], range: target)
            case .link:
                storage.addAttributes([.foregroundColor: NSColor.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue], range: target)
                if let address = linkAddress(after: span.range, in: storage.string) {
                    storage.addAttributes([.markdownLink: address, .toolTip: "⌘-click to open \(address)"], range: target)
                }
            case .linkURL:
                storage.addAttributes([.foregroundColor: NSColor.tertiaryLabelColor, .markdownConceal: true], range: target)
            default:
                break
            }
        }
        for span in spans {
            guard let target = clipped(span) else { continue }
            switch span.style {
            case .syntax:
                storage.addAttributes([.foregroundColor: NSColor.tertiaryLabelColor, .markdownConceal: true], range: target)
            case .task(let checked):
                // The "[ ]" stays in the text; the layout manager draws a checkbox where it is.
                // Monospaced, so "[ ]" and "[x]" are the same width and the words after them line up.
                storage.addAttributes([.font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular),
                                       .foregroundColor: NSColor.clear, .markdownTask: checked], range: target)
                // The "- " in front goes too, so a checklist reads as checkboxes. Indentation stays for nesting.
                let string = storage.string as NSString
                let line = string.lineRange(for: span.range)
                let before = NSRange(location: line.location, length: span.range.location - line.location)
                let marker = string.range(of: #"[-*+][ \t]+$"#, options: .regularExpression, range: before)
                if marker.location != NSNotFound { storage.addAttribute(.markdownConceal, value: true, range: NSIntersectionRange(marker, range)) }
            default:
                break
            }
        }
    }

    /// The address of the link whose label is at `label`: what's between "](" and ")".
    private func linkAddress(after label: NSRange, in text: String) -> String? {
        let string = text as NSString
        let start = NSMaxRange(label) + 2
        guard start <= string.length, string.substring(with: NSRange(location: NSMaxRange(label), length: min(2, string.length - NSMaxRange(label)))) == "](" else { return nil }
        let close = string.range(of: ")", options: [], range: NSRange(location: start, length: string.length - start))
        guard close.location != NSNotFound else { return nil }
        return string.substring(with: NSRange(location: start, length: close.location - start))
    }

    private func convert(_ storage: NSTextStorage, _ range: NSRange, to trait: NSFontTraitMask) {
        storage.enumerateAttribute(.font, in: range) { value, run, _ in
            let font = (value as? NSFont) ?? baseFont
            storage.addAttribute(.font, value: NSFontManager.shared.convert(font, toHaveTrait: trait), range: run)
        }
    }
}

// MARK: - The text view

final class MarkdownTextView: NSTextView, NSTextStorageDelegate, NSLayoutManagerDelegate {
    var styler = MarkdownStyler(fontSize: 15)
    var placeholder = ""
    private var fences = 0

    // MARK: Hiding the markup

    /// Keeps the markup visible everywhere instead of only on the lines being edited.
    var showsMarkup = false {
        didSet { if showsMarkup != oldValue { refreshAll() } }
    }

    /// The paragraphs that show their markup: the ones the cursor or selection is in, while the editor has focus.
    private var revealed = NSRange(location: NSNotFound, length: 0)

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        updateRevealed()
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        updateRevealed()
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { updateRevealed(focused: false) }
        return resigned
    }

    private func updateRevealed(focused: Bool? = nil) {
        guard let storage = textStorage, storage.editedMask.isEmpty else { return }
        let hasFocus = focused ?? (window?.firstResponder === self)
        let next = hasFocus ? (string as NSString).paragraphRange(for: selectedRange()) : NSRange(location: NSNotFound, length: 0)
        guard next != revealed else { return }
        let previous = revealed
        revealed = next
        for range in [previous, next] where range.location != NSNotFound { relayout(range) }
    }

    /// Lays the paragraphs in `range` out again, so their markup is hidden or shown.
    private func relayout(_ range: NSRange) {
        guard let layout = layoutManager, let storage = textStorage, storage.length > 0 else { return }
        let string = storage.string as NSString
        let start = min(range.location, string.length)
        let paragraphs = string.paragraphRange(for: NSRange(location: start, length: min(range.length, string.length - start)))
        layout.invalidateGlyphs(forCharacterRange: paragraphs, changeInLength: 0, actualCharacterRange: nil)
        layout.invalidateLayout(forCharacterRange: paragraphs, actualCharacterRange: nil)
        needsDisplay = true
    }

    private func refreshAll() {
        guard let storage = textStorage else { return }
        relayout(NSRange(location: 0, length: storage.length))
    }

    /// Hidden markup gets no glyph at all, so the text closes up around it; list dashes become bullets.
    nonisolated func layoutManager(_ layoutManager: NSLayoutManager, shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
                                   properties props: UnsafePointer<NSLayoutManager.GlyphProperty>, characterIndexes charIndexes: UnsafePointer<Int>,
                                   font aFont: NSFont, forGlyphRange glyphRange: NSRange) -> Int {
        MainActor.assumeIsolated {
            guard !showsMarkup, let storage = layoutManager.textStorage else { return 0 }
            let count = glyphRange.length
            var properties: [NSLayoutManager.GlyphProperty]?
            var replaced: [CGGlyph]?
            for i in 0..<count {
                let index = charIndexes[i]
                guard index < storage.length, !NSLocationInRange(index, revealed) else { continue }
                if storage.attribute(.markdownConceal, at: index, effectiveRange: nil) != nil {
                    if properties == nil { properties = Array(UnsafeBufferPointer(start: props, count: count)) }
                    properties?[i] = .null
                } else if storage.attribute(.markdownBullet, at: index, effectiveRange: nil) != nil, let bullet = Self.bulletGlyph(in: aFont) {
                    if replaced == nil { replaced = Array(UnsafeBufferPointer(start: glyphs, count: count)) }
                    replaced?[i] = bullet
                }
            }
            guard properties != nil || replaced != nil else { return 0 }
            let finalProperties = properties ?? Array(UnsafeBufferPointer(start: props, count: count))
            let finalGlyphs = replaced ?? Array(UnsafeBufferPointer(start: glyphs, count: count))
            finalGlyphs.withUnsafeBufferPointer { glyphBuffer in
                finalProperties.withUnsafeBufferPointer { propertyBuffer in
                    layoutManager.setGlyphs(glyphBuffer.baseAddress!, properties: propertyBuffer.baseAddress!, characterIndexes: charIndexes,
                                            font: aFont, forGlyphRange: glyphRange)
                }
            }
            return count
        }
    }

    private static func bulletGlyph(in font: NSFont) -> CGGlyph? {
        var character: UniChar = 0x2022
        var glyph: CGGlyph = 0
        return CTFontGetGlyphsForCharacters(font as CTFont, &character, &glyph, 1) ? glyph : nil
    }

    /// Restyles everything, e.g. after the text was replaced wholesale.
    func restyle() {
        guard let storage = textStorage else { return }
        fences = MarkdownSyntax.fenceCount(in: storage.string)
        storage.beginEditing()
        styler.apply(MarkdownSyntax.spans(in: storage.string), to: storage, in: NSRange(location: 0, length: storage.length))
        storage.endEditing()
        needsDisplay = true
    }

    // Typing restyles the paragraphs it touched; adding or removing a code fence restyles everything after it too.
    nonisolated func textStorage(_ storage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                                 range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        MainActor.assumeIsolated {
            // Typing in a revealed line grows it before the layout manager sees the change, so new markup isn't hidden
            // for a moment; an edit above it moves it along.
            if revealed.location != NSNotFound {
                let editStart = editedRange.location
                if editStart >= revealed.location, editStart <= NSMaxRange(revealed) {
                    revealed.length = max(0, revealed.length + delta)
                } else if editStart < revealed.location {
                    revealed.location = max(0, revealed.location + delta)
                }
            }
            let text = storage.string
            let string = text as NSString
            let count = MarkdownSyntax.fenceCount(in: text)
            var dirty = string.paragraphRange(for: NSRange(location: min(editedRange.location, string.length), length: min(editedRange.length, string.length - min(editedRange.location, string.length))))
            if count != fences {
                fences = count
                dirty = NSRange(location: dirty.location, length: string.length - dirty.location)
            }
            styler.apply(MarkdownSyntax.spans(in: text), to: storage, in: dirty)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let origin = NSPoint(x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 5), y: textContainerInset.height)
        (placeholder as NSString).draw(at: origin, withAttributes: [.font: styler.baseFont, .foregroundColor: NSColor.placeholderTextColor])
    }

    // MARK: Commands

    func run(_ command: MarkdownEditorModel.Command) {
        let selection = selectedRange()
        let edit: MarkdownEditing.Edit
        switch command {
        case .bold: edit = MarkdownEditing.toggleWrap(string, selection: selection, marker: "**")
        case .italic: edit = MarkdownEditing.toggleWrap(string, selection: selection, marker: "*")
        case .strikethrough: edit = MarkdownEditing.toggleWrap(string, selection: selection, marker: "~~")
        case .inlineCode: edit = MarkdownEditing.toggleWrap(string, selection: selection, marker: "`")
        case .codeBlock: edit = MarkdownEditing.insertCodeBlock(string, selection: selection)
        case .link: edit = MarkdownEditing.insertLink(string, selection: selection)
        case .bullet: edit = MarkdownEditing.toggle(.bullet, in: string, selection: selection)
        case .numbered: edit = MarkdownEditing.toggle(.numbered, in: string, selection: selection)
        case .task: edit = MarkdownEditing.toggle(.task, in: string, selection: selection)
        case .quote: edit = MarkdownEditing.toggle(.quote, in: string, selection: selection)
        case .heading(let level): edit = MarkdownEditing.toggle(.heading(level), in: string, selection: selection)
        }
        apply(edit)
    }

    /// Applies a command's result as one undoable change of only the part that differs.
    private func apply(_ edit: MarkdownEditing.Edit) {
        let old = string as NSString, new = edit.text as NSString
        var prefix = 0
        while prefix < old.length, prefix < new.length, old.character(at: prefix) == new.character(at: prefix) { prefix += 1 }
        var suffix = 0
        while suffix < old.length - prefix, suffix < new.length - prefix,
              old.character(at: old.length - 1 - suffix) == new.character(at: new.length - 1 - suffix) { suffix += 1 }
        let range = NSRange(location: prefix, length: old.length - prefix - suffix)
        let replacement = new.substring(with: NSRange(location: prefix, length: new.length - prefix - suffix))
        if range.length > 0 || !replacement.isEmpty {
            guard shouldChangeText(in: range, replacementString: replacement) else { return }
            textStorage?.replaceCharacters(in: range, with: replacement)
            didChangeText()
        }
        setSelectedRange(edit.selection)
        scrollRangeToVisible(edit.selection)
    }

    // MARK: Keys

    override func insertNewline(_ sender: Any?) {
        let selection = selectedRange()
        guard selection.length == 0, !hasMarkedText() else { return super.insertNewline(sender) }
        let text = string as NSString
        let line = text.lineRange(for: NSRange(location: selection.location, length: 0))
        let before = text.substring(with: NSRange(location: line.location, length: selection.location - line.location))
        switch MarkdownEditing.returnAction(lineBeforeCursor: before, inCodeBlock: isInCodeBlock(line.location)) {
        case .newline:
            super.insertNewline(sender)
        case .continueWith(let marker):
            insertText("\n" + marker, replacementRange: selection)
        case .endList(let count):
            insertText("", replacementRange: NSRange(location: selection.location - count, length: count))
        }
    }

    override func insertTab(_ sender: Any?) {
        if let edit = MarkdownEditing.indent(string, selection: selectedRange(), outdent: false) { apply(edit) } else { super.insertTab(sender) }
    }

    override func insertBacktab(_ sender: Any?) {
        if let edit = MarkdownEditing.indent(string, selection: selectedRange(), outdent: true) { apply(edit) } else { super.insertBacktab(sender) }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let command: MarkdownEditorModel.Command? = switch (flags, event.keyCode, key) {
        case (.command, _, "b"): .bold
        case (.command, _, "i"): .italic
        case (.command, _, "e"): .inlineCode
        case (.command, _, "k"): .link
        case ([.command, .shift], _, "x"): .strikethrough
        case ([.command, .shift], 28, _): .bullet        // ⌘⇧8
        case ([.command, .shift], 26, _): .numbered      // ⌘⇧7
        case ([.command, .shift], _, "l"): .task
        case ([.command, .shift], 47, _): .quote         // ⌘⇧.
        case ([.command, .option], _, "c"), ([.command, .option], 8, _): .codeBlock
        case ([.command, .option], 18, _): .heading(1)
        case ([.command, .option], 19, _): .heading(2)
        case ([.command, .option], 20, _): .heading(3)
        default: nil
        }
        guard let command else { return super.performKeyEquivalent(with: event) }
        run(command)
        return true
    }

    // MARK: Checkboxes

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if event.modifierFlags.contains(.command), let address = link(at: point), let url = URL(string: address), url.scheme != nil {
            NSWorkspace.shared.open(url)
            return
        }
        if let box = taskBox(at: point), let edit = MarkdownEditing.toggleTask(string, at: box.location) {
            let selection = selectedRange()
            apply(edit)
            setSelectedRange(selection)
            return
        }
        super.mouseDown(with: event)
    }

    /// The address of the link label under a click.
    private func link(at point: NSPoint) -> String? {
        guard let layout = layoutManager, let container = textContainer, let storage = textStorage, storage.length > 0 else { return nil }
        let local = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let character = layout.characterIndexForGlyph(at: layout.glyphIndex(for: local, in: container))
        guard character < storage.length else { return nil }
        return storage.attribute(.markdownLink, at: character, effectiveRange: nil) as? String
    }

    /// The "[ ]" under a click, if the click landed on a checkbox.
    private func taskBox(at point: NSPoint) -> NSRange? {
        guard let layout = layoutManager, let container = textContainer, let storage = textStorage, storage.length > 0 else { return nil }
        let local = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let glyph = layout.glyphIndex(for: local, in: container)
        let character = layout.characterIndexForGlyph(at: glyph)
        guard character < storage.length else { return nil }
        var run = NSRange()
        guard storage.attribute(.markdownTask, at: character, effectiveRange: &run) != nil else { return nil }
        let rect = layout.boundingRect(forGlyphRange: layout.glyphRange(forCharacterRange: run, actualCharacterRange: nil), in: container)
        return rect.insetBy(dx: -3, dy: -3).contains(local) ? run : nil
    }

    private func isInCodeBlock(_ location: Int) -> Bool {
        guard let storage = textStorage, location < storage.length else { return false }
        return storage.attribute(.markdownCodeBlock, at: location, effectiveRange: nil) != nil
            && !MarkdownSyntax.isFence((string as NSString).substring(with: (string as NSString).lineRange(for: NSRange(location: location, length: 0))).trimmingCharacters(in: .newlines))
    }
}

// MARK: - Drawing code blocks, quotes, rules and checkboxes

final class MarkdownLayoutManager: NSLayoutManager {
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage, let container = textContainers.first else { return }
        let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        let width = container.size.width - container.lineFragmentPadding * 2

        storage.enumerateAttribute(.markdownCodeBlock, in: characters) { value, run, _ in
            guard value != nil else { return }
            var union = NSRect.null
            visibleFragments(of: run) { union = union.union($0) }
            guard !union.isNull else { return }
            let box = NSRect(x: origin.x + container.lineFragmentPadding, y: origin.y + union.minY, width: width, height: union.height)
            NSColor.labelColor.withAlphaComponent(0.06).setFill()
            NSBezierPath(roundedRect: box.insetBy(dx: -6, dy: 0), xRadius: 6, yRadius: 6).fill()
        }
        storage.enumerateAttribute(.markdownQuote, in: characters) { value, run, _ in
            guard value != nil else { return }
            visibleFragments(of: run) { rect in
                NSColor.tertiaryLabelColor.setFill()
                NSBezierPath(roundedRect: NSRect(x: origin.x + container.lineFragmentPadding, y: origin.y + rect.minY + 2, width: 3, height: rect.height - 4),
                             xRadius: 1.5, yRadius: 1.5).fill()
            }
        }
        storage.enumerateAttribute(.markdownRule, in: characters) { value, run, _ in
            guard value != nil else { return }
            visibleFragments(of: run) { rect in
                NSColor.separatorColor.setFill()
                NSRect(x: origin.x + container.lineFragmentPadding, y: origin.y + rect.midY, width: width, height: 1).fill()
            }
        }
    }

    /// The line fragments that show some of `run`. Hidden markup at the start of a line can sit in the fragment above it,
    /// and a fragment holding only hidden glyphs mustn't get a quote bar or code background.
    private func visibleFragments(of run: NSRange, _ body: (NSRect) -> Void) {
        let glyphs = glyphRange(forCharacterRange: run, actualCharacterRange: nil)
        var rects: [NSRect] = []
        enumerateLineFragments(forGlyphRange: glyphs) { rect, _, _, fragment, _ in
            let shared = NSIntersectionRange(fragment, glyphs)
            if (shared.location..<NSMaxRange(shared)).contains(where: { self.propertyForGlyph(at: $0) != .null }) { rects.append(rect) }
        }
        rects.forEach(body)
    }

    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage, let container = textContainers.first else { return }
        let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        storage.enumerateAttribute(.markdownTask, in: characters) { value, run, _ in
            guard let checked = value as? Bool else { return }
            let rect = boundingRect(forGlyphRange: glyphRange(forCharacterRange: run, actualCharacterRange: nil), in: container)
            let font = (storage.attribute(.font, at: run.location, effectiveRange: nil) as? NSFont) ?? .systemFont(ofSize: 15)
            let side = font.pointSize * 1.1
            let box = NSRect(x: origin.x + rect.midX - side / 2, y: origin.y + rect.midY - side / 2, width: side, height: side)
            let symbol = checked ? "checkmark.square.fill" : "square"
            // A white tick on the accent colour, or an empty grey box.
            let colors: [NSColor] = checked ? [.white, .controlAccentColor] : [.secondaryLabelColor]
            let configuration = NSImage.SymbolConfiguration(pointSize: font.pointSize, weight: .regular)
                .applying(NSImage.SymbolConfiguration(paletteColors: colors))
            NSImage(systemSymbolName: symbol, accessibilityDescription: checked ? "Done" : "To do")?
                .withSymbolConfiguration(configuration)?
                .draw(in: box)
        }
    }
}
