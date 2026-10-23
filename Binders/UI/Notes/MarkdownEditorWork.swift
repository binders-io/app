import AppKit
import BindersKit

// Lane DS4: a Distill note's cards, shown in its editor at the words each came from. The words get a soft tint in the
// card's state colour, and their line a small chip at its end, drawn by the editor in room made after the line's last
// character (its kern), like the checkboxes and pictures: nothing goes into the text, so copying, Find, dictation and the
// saved Markdown never see it. A card whose words can't be found (or that has none) is counted on its section's heading.

/// What the editor marks in a Distill note: its cards, each with the note's words it came from, its section, and where
/// it is on the board; and how to open one.
struct NoteWork: Equatable {
    struct Card: Equatable {
        var id: UUID
        var title: String
        var quote: String?
        /// Its "## " heading; nil for the note's opening.
        var section: String?
        var chip: DistillMarks.ChipCard
        var state: DistillProgress.State
        /// For hovering: its board, column, who has it and its last update.
        var detail: String
    }

    var cards: [Card]
    /// Opens a card, as the Work panel's rows do.
    var open: @MainActor (UUID) -> Void = { _ in }

    /// Only the cards: what's drawn.
    static func == (a: NoteWork, b: NoteWork) -> Bool { a.cards == b.cards }

    /// The card's state colour, as the Work panel's badges wear it (`WorkItemRow.color`); closed cards are grey.
    static func color(_ card: Card) -> NSColor {
        if card.chip.closed { return BindersTheme.NS.muted }
        switch card.state {
        case .done: return BindersTheme.NS.done
        case .inProgress: return BindersTheme.NS.agent
        case .waitsOnYou: return BindersTheme.NS.needsYou
        case .heldUp, .notStarted: return BindersTheme.NS.muted
        }
    }

    static func symbol(_ card: Card) -> String {
        if card.chip.closed { return "xmark.circle" }
        switch card.state {
        // The outline: in one colour, the filled tick reads as a dot.
        case .done: return "checkmark.circle"
        case .inProgress: return "arrow.triangle.turn.up.right.circle"
        case .waitsOnYou: return "exclamationmark.bubble"
        case .heldUp: return "hourglass"
        case .notStarted: return "circle.dashed"
        }
    }

    /// What hovering a chip or marked words says: each card's title and where it is, and for a chip what a click does.
    static func help(_ cards: [Card], chip: Bool = true) -> String {
        let lines = cards.map { "“\($0.title)”\n\($0.detail)" }
        guard chip else { return lines.joined(separator: "\n\n") }
        return (lines + [cards.count == 1 ? "Click to open the card." : "Click to choose a card to open."]).joined(separator: "\n\n")
    }
}

/// The text view's part in it: the cards, where they show in the text as it is now, and the finding that waits for
/// typing to pause.
final class EditorWork {
    var work: NoteWork?
    var placement: DistillMarks.Placement = .empty
    /// What `placement` was found for: found again only when the text or the cards change.
    var placedText: String?
    var placedCards: [DistillMarks.Card] = []
    var rematch: DispatchWorkItem?
    /// How long typing pauses before the words it touched are found again.
    static var pause: TimeInterval = 0.6
}

extension NSAttributedString.Key {
    /// A card's words: the tint drawn behind them (`WorkTint`).
    static let workMark = NSAttributedString.Key("io.binders.markdown.workMark")
    /// The character a work chip follows (`WorkChip`); the chip is drawn in the room its kern makes.
    static let workChip = NSAttributedString.Key("io.binders.markdown.workChip")
}

/// The tint behind a card's words.
final class WorkTint: NSObject {
    let color: NSColor
    init(color: NSColor) { self.color = color }
}

/// A chip at the end of a line: what it says, its symbol and colour, faint when its cards are finished, and the cards a
/// click opens.
final class WorkChip: NSObject {
    let text: String
    let symbol: String
    let color: NSColor
    let faint: Bool
    let cards: [UUID]
    let fontSize: CGFloat
    /// Its width, and the room before it.
    let width: CGFloat
    static let gap: CGFloat = 8

    init(text: String, symbol: String, color: NSColor, faint: Bool, cards: [UUID], fontSize: CGFloat) {
        self.text = text
        self.symbol = symbol
        self.color = color
        self.faint = faint
        self.cards = cards
        self.fontSize = fontSize
        let words = ceil((text as NSString).size(withAttributes: [.font: Self.font(fontSize)]).width)
        width = Self.padding * 2 + fontSize + 4 + words
    }

    static let padding: CGFloat = 6
    static func font(_ size: CGFloat) -> NSFont { .systemFont(ofSize: size, weight: .medium) }

    /// The kern after the character it follows: its gap, itself, and a little after.
    var room: CGFloat { Self.gap + width + 4 }
    var height: CGFloat { ceil(fontSize * 1.5) }
}

// MARK: - Placing and styling

extension MarkdownTextView {
    /// New cards (a card moved columns, one was placed, Show Work in the Note was turned off): found again if they differ
    /// from what's shown, and the lines either way touches restyled. The same cards change nothing.
    func setWork(_ work: NoteWork?) {
        guard workState.work != work else {
            // The newest way to open a card, nothing to redraw.
            workState.work = work
            return
        }
        let before = workState.placement
        workState.work = work
        placeWork(restyling: false)
        restyleWork(before.ranges + workState.placement.ranges)
    }

    /// Finds where each card shows in the text as it is now, unless that's known for this text and these cards. With
    /// `restyling`, the lines whose marks changed are restyled.
    func placeWork(restyling: Bool) {
        let cards = workState.work?.cards.map { DistillMarks.Card(id: $0.id.uuidString, quote: $0.quote, section: $0.section) } ?? []
        // A note without Distill's cards (most notes): nothing to find, and no copy of its text kept.
        if cards.isEmpty {
            let before = workState.placement
            workState.placement = .empty
            workState.placedText = nil
            workState.placedCards = []
            if restyling, before != .empty { restyleWork(before.ranges) }
            return
        }
        var text = string
        text.makeContiguousUTF8()
        guard workState.placedText != text || workState.placedCards != cards else { return }
        let before = workState.placement
        workState.placement = DistillMarks.place(cards, in: text)
        workState.placedText = text
        workState.placedCards = cards
        if restyling, before != workState.placement { restyleWork(Self.changed(from: before, to: workState.placement)) }
    }

    /// What differs between two placements: the lines and headings either has and the other doesn't.
    static func changed(from a: DistillMarks.Placement, to b: DistillMarks.Placement) -> [NSRange] {
        var ranges: [NSRange] = []
        for line in a.lines where !b.lines.contains(line) { ranges += [line.line] + line.marks.map(\.range) }
        for line in b.lines where !a.lines.contains(line) { ranges += [line.line] + line.marks.map(\.range) }
        for heading in a.headings where !b.headings.contains(heading) { ranges.append(heading.line) }
        for heading in b.headings where !a.headings.contains(heading) { ranges.append(heading.line) }
        return ranges
    }

    /// Restyles the paragraphs these ranges touch, as one change.
    func restyleWork(_ ranges: [NSRange]) {
        guard let storage = textStorage, storage.length > 0, !ranges.isEmpty else { return }
        let string = storage.string as NSString
        var paragraphs: [NSRange] = []
        for range in ranges {
            let start = min(range.location, string.length)
            let paragraph = string.paragraphRange(for: NSRange(location: start, length: min(range.length, string.length - start)))
            if let last = paragraphs.last, NSMaxRange(last) >= paragraph.location, paragraph.location >= last.location {
                paragraphs[paragraphs.count - 1] = NSUnionRange(last, paragraph)
            } else {
                paragraphs.append(paragraph)
            }
        }
        storage.beginEditing()
        for paragraph in paragraphs { restyle(paragraphs: paragraph) }
        storage.endEditing()
    }

    /// Typing: the marks move with the text, without finding anything (`Placement.shifted`), the edited paragraphs get
    /// theirs back, and the words are found again once typing pauses.
    func workEdited(_ edited: NSRange, delta: Int, dirty: NSRange) {
        guard workState.work.map({ !$0.cards.isEmpty }) == true else { return }
        workState.placement = workState.placement.shifted(edited: edited, delta: delta, in: string)
        workState.placedText = nil
        applyWork(in: dirty)
        scheduleWorkRematch()
    }

    func scheduleWorkRematch() {
        workState.rematch?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Not in the middle of composing a character (Japanese, accents).
                if self.hasMarkedText() { return self.scheduleWorkRematch() }
                self.placeWork(restyling: true)
            }
        }
        workState.rematch = work
        DispatchQueue.main.asyncAfter(deadline: .now() + EditorWork.pause, execute: work)
    }

    /// The line being edited changed: its chip goes, and the one left gets its chip back.
    func workRevealChanged(from previous: NSRange, to next: NSRange) {
        guard workState.work != nil else { return }
        let chips = workState.placement.lines.filter { !$0.isHeading }.map(\.line) + workState.placement.headings.map(\.line)
        let touched = [previous, next].filter { range in
            range.location != NSNotFound && chips.contains { NSIntersectionRange($0, range).length > 0 || NSLocationInRange($0.location, range) }
        }
        guard !touched.isEmpty else { return }
        restyleWork(touched)
    }

    /// Adds the marks and chips that fall in `range` (whole paragraphs, just styled).
    func applyWork(in range: NSRange) {
        guard let work = workState.work, !work.cards.isEmpty, let storage = textStorage, storage.length > 0 else { return }
        let placement = workState.placement
        guard !placement.lines.isEmpty || !placement.headings.isEmpty else { return }
        let byID = Dictionary(work.cards.map { ($0.id.uuidString, $0) }, uniquingKeysWith: { a, _ in a })
        let whole = NSRange(location: 0, length: storage.length)
        func touches(_ line: NSRange) -> Bool {
            NSIntersectionRange(line, range).length > 0 || (line.length == 0 && NSLocationInRange(line.location, range))
        }
        for line in placement.lines {
            for mark in line.marks {
                guard let card = byID[mark.card] else { continue }
                let target = NSIntersectionRange(NSIntersectionRange(mark.range, range), whole)
                guard target.length > 0 else { continue }
                storage.addAttribute(.workMark, value: WorkTint(color: NoteWork.color(card).withAlpha(card.chip.finished ? 0.07 : 0.17)), range: target)
                // Hovering the words says which card they became, where nothing else has a word to say there.
                let help = NoteWork.help([card], chip: false)
                storage.enumerateAttribute(.toolTip, in: target) { value, run, _ in
                    if value == nil { storage.addAttribute(.toolTip, value: help, range: run) }
                }
            }
            guard !line.isHeading, touches(line.line) else { continue }
            let cards = line.cards.compactMap { byID[$0] }
            addChip(for: cards, text: DistillMarks.chip(cards.map(\.chip)), at: line.line, in: range)
        }
        for heading in placement.headings where touches(heading.line) {
            let cards = heading.cards.compactMap { byID[$0] }
            addChip(for: cards, text: DistillMarks.headingChip(cards.count), at: heading.line, in: range, heading: true)
        }
    }

    /// A chip after the line's last character that shows: its words, symbol and colour from its cards.
    private func addChip(for cards: [NoteWork.Card], text: String, at line: NSRange, in range: NSRange, heading: Bool = false) {
        guard !cards.isEmpty, let storage = textStorage else { return }
        let string = storage.string as NSString
        // Not on the line being edited, where it would sit in the way of typing.
        if revealed.location != NSNotFound, NSIntersectionRange(string.paragraphRange(for: line), revealed).length > 0 { return }
        guard let anchor = workChipAnchor(in: line), NSLocationInRange(anchor.location, range) else { return }
        let finished = cards.allSatisfy(\.chip.finished)
        let symbol: String, color: NSColor
        if heading || cards.count > 1 {
            symbol = "square.stack.3d.down.right"
            // The card that most needs someone sets the colour: one waiting on you, then one in progress.
            let lead = cards.first { $0.state == .waitsOnYou && !$0.chip.finished } ?? cards.first { $0.state == .inProgress && !$0.chip.finished }
            color = heading ? BindersTheme.NS.muted : lead.map(NoteWork.color) ?? (finished ? BindersTheme.NS.done : BindersTheme.NS.muted)
        } else {
            symbol = NoteWork.symbol(cards[0])
            color = NoteWork.color(cards[0])
        }
        let chip = WorkChip(text: text, symbol: symbol, color: color, faint: finished, cards: cards.map(\.id),
                            fontSize: max(10, (styler.fontSize * 0.78).rounded()))
        storage.addAttributes([.workChip: chip, .kern: chip.room, .toolTip: NoteWork.help(cards), .cursor: NSCursor.pointingHand], range: anchor)
    }

    /// The last character of a line that shows (not hidden markup, not space), as a whole character; nil for a line with
    /// none, or a table's row, whose cells line up in columns.
    func workChipAnchor(in line: NSRange) -> NSRange? {
        guard let storage = textStorage else { return nil }
        let string = storage.string as NSString
        var index = min(NSMaxRange(line), string.length) - 1
        while index >= line.location {
            let character = string.character(at: index)
            if storage.attribute(.markdownTableTab, at: index, effectiveRange: nil) != nil
                || storage.attribute(.markdownTableHidden, at: index, effectiveRange: nil) != nil { return nil }
            let hidden = !showsMarkup && storage.attribute(.markdownConceal, at: index, effectiveRange: nil) != nil
            if hidden || character == 0x20 || character == 0x09 || character == 0x0A || character == 0x0D {
                index -= 1
                continue
            }
            return string.rangeOfComposedCharacterSequence(at: index)
        }
        return nil
    }

    // MARK: Clicking a chip

    /// A click on a chip opens its card; with several, a menu of them.
    func clickedWorkChip(at point: NSPoint) -> Bool {
        guard let work = workState.work, let hit = workChip(at: point) else { return false }
        let cards = hit.chip.cards.compactMap { id in work.cards.first { $0.id == id } }
        if cards.count == 1 {
            work.open(cards[0].id)
            return true
        }
        guard !cards.isEmpty else { return false }
        let menu = NSMenu()
        for card in cards {
            let item = NSMenuItem(title: "\(card.title) · \(DistillMarks.chip([card.chip]))", action: #selector(openWorkCard(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = card.id
            item.image = NSImage(systemSymbolName: NoteWork.symbol(card), accessibilityDescription: nil)
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: hit.rect.minX + textContainerOrigin.x, y: hit.rect.maxY + textContainerOrigin.y + 2), in: self)
        return true
    }

    @objc func openWorkCard(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        workState.work?.open(id)
    }

    /// The chip under a point in the view, and its frame in the text container.
    func workChip(at point: NSPoint) -> (chip: WorkChip, rect: NSRect)? {
        guard let layout = layoutManager as? MarkdownLayoutManager, let storage = textStorage, storage.length > 0 else { return nil }
        let local = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        var found: (WorkChip, NSRect)?
        storage.enumerateAttribute(.workChip, in: NSRange(location: 0, length: storage.length)) { value, run, stop in
            guard let chip = value as? WorkChip, let rect = layout.workChipRect(for: run, chip: chip) else { return }
            if rect.insetBy(dx: -2, dy: -2).contains(local) {
                found = (chip, rect)
                stop.pointee = true
            }
        }
        return found
    }

    /// Every chip shown now, with its frame in the text container: for the self-test.
    func workChips() -> [(chip: WorkChip, character: NSRange, rect: NSRect)] {
        guard let layout = layoutManager as? MarkdownLayoutManager, let storage = textStorage, storage.length > 0 else { return [] }
        var chips: [(WorkChip, NSRange, NSRect)] = []
        storage.enumerateAttribute(.workChip, in: NSRange(location: 0, length: storage.length)) { value, run, _ in
            guard let chip = value as? WorkChip else { return }
            chips.append((chip, run, layout.workChipRect(for: run, chip: chip) ?? .zero))
        }
        return chips
    }

    // MARK: Going to a card's words

    /// Goes to a card's words in its section (or anywhere in the note) and flashes them; when they can't be found, to the
    /// section's heading, as before.
    func reveal(quote: String, in place: String) {
        let section = place.isEmpty ? nil : place
        guard let found = DistillQuote.find(quote, section: section, in: string) else {
            if section != nil { reveal(place) }
            return
        }
        jump(to: found.range.location)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, NSMaxRange(found.range) <= (self.string as NSString).length else { return }
                self.showFindIndicator(for: found.range)
            }
        }
    }
}

// MARK: - Drawing

extension MarkdownLayoutManager {
    /// Where a chip goes, in the text container: after the character it follows, at its line's middle.
    func workChipRect(for character: NSRange, chip: WorkChip) -> NSRect? {
        guard let storage = textStorage, NSMaxRange(character) <= storage.length else { return nil }
        let glyphs = glyphRange(forCharacterRange: character, actualCharacterRange: nil)
        guard glyphs.length > 0 else { return nil }
        let glyph = NSMaxRange(glyphs) - 1
        guard glyph < numberOfGlyphs else { return nil }
        let fragment = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let place = location(forGlyphAt: glyph)
        let font = (storage.attribute(.font, at: character.location, effectiveRange: nil) as? NSFont) ?? .systemFont(ofSize: 15)
        let advance = font.advancement(forCGGlyph: cgGlyph(at: glyph)).width
        let baseline = fragment.minY + place.y
        let middle = baseline - font.xHeight / 2
        return NSRect(x: fragment.minX + place.x + advance + WorkChip.gap, y: middle - chip.height / 2, width: chip.width, height: chip.height)
    }

    /// The tints behind cards' words, under the words, not the room between lines.
    func drawWorkTints(in characters: NSRange, at origin: NSPoint) {
        guard let storage = textStorage, let container = textContainers.first else { return }
        storage.enumerateAttribute(.workMark, in: characters) { value, run, _ in
            guard let tint = value as? WorkTint else { return }
            let glyphs = glyphRange(forCharacterRange: run, actualCharacterRange: nil)
            let spacing = (storage.attribute(.paragraphStyle, at: run.location, effectiveRange: nil) as? NSParagraphStyle)?.lineSpacing ?? 0
            // The chip's room after the last character isn't the words'.
            let chip = NSMaxRange(run) > 0 ? storage.attribute(.workChip, at: NSMaxRange(run) - 1, effectiveRange: nil) as? WorkChip : nil
            var rects: [NSRect] = []
            enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: container) { rect, _ in
                rects.append(rect)
            }
            tint.color.setFill()
            for (index, rect) in rects.enumerated() {
                var box = rect.offsetBy(dx: origin.x, dy: origin.y)
                box.size.height = max(2, box.height - spacing)
                if index == rects.count - 1, let chip { box.size.width = max(2, box.width - chip.room) }
                NSBezierPath(roundedRect: box.insetBy(dx: -1.5, dy: 0), xRadius: 3, yRadius: 3).fill()
            }
        }
    }

    /// The chips: a soft capsule in the colour of their cards, the state's symbol, and what they say.
    func drawWorkChips(in characters: NSRange, at origin: NSPoint) {
        guard let storage = textStorage else { return }
        storage.enumerateAttribute(.workChip, in: characters) { value, run, _ in
            guard let chip = value as? WorkChip, let frame = workChipRect(for: run, chip: chip) else { return }
            let rect = frame.offsetBy(dx: origin.x, dy: origin.y)
            chip.color.withAlpha(chip.faint ? 0.08 : 0.16).setFill()
            NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
            let side = chip.fontSize
            let symbolBox = NSRect(x: rect.minX + WorkChip.padding, y: rect.midY - side / 2, width: side, height: side)
            let configuration = NSImage.SymbolConfiguration(pointSize: side * 0.85, weight: .medium)
                .applying(NSImage.SymbolConfiguration(paletteColors: [chip.faint ? BindersTheme.NS.faint : chip.color]))
            NSImage(systemSymbolName: chip.symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration)?
                .draw(in: symbolBox, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            let font = WorkChip.font(chip.fontSize)
            let words = NSAttributedString(string: chip.text, attributes: [.font: font,
                                                                            .foregroundColor: chip.faint ? BindersTheme.NS.faint : BindersTheme.NS.muted])
            let height = words.size().height
            words.draw(at: NSPoint(x: symbolBox.maxX + 4, y: rect.midY - height / 2))
        }
    }
}
