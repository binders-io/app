import AppKit
import QuartzCore
import BindersKit

// Lane DS9: Distill you can see, in the note. While a reading runs, a soft light in the accent colour sweeps down the part
// being read, behind its words; as each item is found its lines glow, and a card lifts out of them into the Distill list
// (`DistillFlightsOverlay`). The list's selected and hovered rows light their lines here too, and a click on a lit line
// selects its row. Everything is drawn behind the text by the layout manager, in the rects that change only: the text is
// never laid out again for it, and nothing goes into it.

/// What the note's editor shows of its Distill list.
struct EditorDistill: Equatable {
    /// An item of the list, by the note's lines it came from.
    struct Spot: Equatable {
        var id: UUID
        var quote: String?
        /// The note's lines it came from, one to a line (a v2 item's first brief); nil for an item read before.
        var source: String?
        var section: String?
        /// Who it's for, as its card will wear it.
        var color: NSColor
    }

    var spots: [Spot] = []
    var selected: UUID?
    var hovered: UUID?
    /// The part being read now, and since when: nil when nothing is read, or the reading is in the background.
    var reading: DistillLines?
    var readingSince: Date?
    /// When each item was found, for its lines' glow.
    var found: [UUID: Date] = [:]
    /// The accent the light is drawn in: the binder's colour on its pages.
    var accent: NSColor = BindersTheme.NS.accent
    var reduceMotion = false
    /// Where the flying cards are drawn, which asks the editor where an item's lines are.
    var stage: DistillStage?
    /// A click on a lit line: its item.
    var select: ((UUID) -> Void)?

    static func == (a: EditorDistill, b: EditorDistill) -> Bool {
        a.spots == b.spots && a.selected == b.selected && a.hovered == b.hovered && a.reading == b.reading
            && a.readingSince == b.readingSince && a.found == b.found && a.accent == b.accent && a.reduceMotion == b.reduceMotion
            && a.stage === b.stage
    }
}

/// The text view's part in it: the list as given, where its items' lines are in the text as it is now, the stretch being
/// read, and the display link that moves the light while something moves.
final class EditorDistillState {
    var given: EditorDistill?
    var ranges: [UUID: [NSRange]] = [:]
    var span: NSRange?
    /// What `ranges` and `span` were found for.
    var placedText: String?
    var placedSpots: [EditorDistill.Spot] = []
    var placedReading: DistillLines?
    var rematch: DispatchWorkItem?
    var link: CADisplayLink?
    /// Where the band of light was last drawn, and the glowing lines, in the view: what the next frame redraws.
    var lastBand: NSRect?
    var lastGlow: NSRect?
    /// The row last scrolled to, so a selection scrolls the note once.
    var scrolledTo: UUID?
    /// For the self-tests: frames drawn, and how long the drawing took in all.
    var frames = 0
    var drawing: TimeInterval = 0
}

/// The clock Distill's motion runs on: the time, unless a self-test holds it still to draw a frame.
enum DistillMotion {
    /// Set on the main thread only (the self-tests), read where Distill draws.
    nonisolated(unsafe) static var held: Date?
    static func now() -> Date { held ?? Date() }
}

extension MarkdownTextView {
    /// The list changed (a row selected, an item found, the part being read): placed again if its items or the text
    /// changed, and the lines either way touches redrawn.
    func setDistill(_ distill: EditorDistill?) {
        let before = distillState.given
        guard before != distill else {
            distillState.given = distill
            return
        }
        distillState.given = distill
        distill?.stage?.editor = self
        placeDistill()
        if let id = distill?.selected, id != before?.selected, id != distillState.scrolledTo {
            distillState.scrolledTo = id
            scrollToDistill(id)
        } else if distill?.selected == nil {
            distillState.scrolledTo = nil
        }
        updateDistillLink()
        needsDisplay = true
    }

    /// Finds the items' lines and the stretch being read in the text as it is now, unless that's known already.
    func placeDistill() {
        let state = distillState
        guard let given = state.given, !(given.spots.isEmpty && given.reading == nil) else {
            state.ranges = [:]
            state.span = nil
            state.placedText = nil
            return
        }
        var text = string
        text.makeContiguousUTF8()
        guard state.placedText != text || state.placedSpots != given.spots || state.placedReading != given.reading else { return }
        let regions = DistillMarks.regions(of: text)
        var ranges: [UUID: [NSRange]] = [:]
        for spot in given.spots {
            let lines = DistillSpots.lines(quote: spot.quote, source: spot.source, section: spot.section, in: text, regions: regions)
            if !lines.isEmpty { ranges[spot.id] = lines }
        }
        state.ranges = ranges
        state.span = given.reading.flatMap { DistillSpots.span(of: $0, in: text) }
        state.placedText = text
        state.placedSpots = given.spots
        state.placedReading = given.reading
    }

    /// Typing: the lines move with the text at once, and are found again once typing pauses.
    func distillEdited(_ edited: NSRange, delta: Int) {
        let state = distillState
        guard state.given != nil, !state.ranges.isEmpty || state.span != nil else { return }
        let oldEnd = edited.location + edited.length - delta
        func moved(_ range: NSRange) -> NSRange? {
            if NSMaxRange(range) <= edited.location { return range }
            if range.location >= oldEnd { return NSRange(location: range.location + delta, length: range.length) }
            return nil
        }
        state.ranges = state.ranges.compactMapValues { lines in
            let kept = lines.compactMap(moved)
            return kept.isEmpty ? nil : kept
        }
        if let span = state.span {
            state.span = moved(span) ?? NSRange(location: span.location, length: max(0, span.length + delta))
        }
        state.placedText = nil
        state.rematch?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.hasMarkedText() { return }
                self.placeDistill()
                self.needsDisplay = true
            }
        }
        state.rematch = work
        DispatchQueue.main.asyncAfter(deadline: .now() + EditorWork.pause, execute: work)
    }

    /// The item whose lit line is under a click, told to the list; the click still places the cursor.
    func distillClicked(at point: NSPoint) {
        guard let given = distillState.given, let select = given.select, !distillState.ranges.isEmpty else { return }
        let index = characterIndexForInsertion(at: point)
        guard let hit = distillState.ranges.first(where: { $0.value.contains { NSLocationInRange(index, $0) || NSMaxRange($0) == index } }) else { return }
        distillState.scrolledTo = hit.key
        select(hit.key)
    }

    /// Where an item's lines are, in this view: the first of them; nil when they're not in the note.
    func distillRect(for id: UUID) -> NSRect? {
        guard let first = distillState.ranges[id]?.first, let rect = lineRect(first) else { return nil }
        return rect.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
    }

    /// Lines' bounds in the text container, across the words they show.
    func lineRect(_ range: NSRange) -> NSRect? {
        guard let layout = layoutManager, let container = textContainer, NSMaxRange(range) <= (string as NSString).length else { return nil }
        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        guard glyphs.length > 0 else { return nil }
        let rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
        return rect.isEmpty ? nil : rect
    }

    /// Scrolls the note so the item's lines show, in the middle when they're out of sight; nothing when they show already.
    func scrollToDistill(_ id: UUID) {
        guard let rect = distillRect(for: id), let scroll = enclosingScrollView else { return }
        let visible = visibleRect
        guard !visible.insetBy(dx: 0, dy: 24).contains(rect) else { return }
        let height = scroll.contentView.bounds.height
        let y = min(max(0, rect.midY - height / 2), max(0, bounds.height - height))
        let target = NSPoint(x: 0, y: y)
        if distillState.given?.reduceMotion == true || window == nil {
            scroll.contentView.scroll(to: target)
            scroll.reflectScrolledClipView(scroll.contentView)
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.32
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                scroll.contentView.animator().setBoundsOrigin(target)
            } completionHandler: {
                MainActor.assumeIsolated { scroll.reflectScrolledClipView(scroll.contentView) }
            }
        }
    }

    // MARK: Moving light

    /// Whether anything moves now: the sweep while a part is read, lines glowing as their items are found.
    private var distillMoving: Bool {
        guard let given = distillState.given, !given.reduceMotion else { return false }
        if given.reading != nil, distillState.span != nil { return true }
        let now = DistillMotion.now()
        return given.found.values.contains { DistillFlights.glow(found: $0, now: now) > 0 }
    }

    /// The display link runs while something moves, and stops when nothing does.
    func updateDistillLink() {
        if distillMoving {
            guard distillState.link == nil else { return }
            let link = displayLink(target: self, selector: #selector(distillFrame(_:)))
            link.add(to: .main, forMode: .common)
            distillState.link = link
        } else {
            distillState.link?.invalidate()
            distillState.link = nil
            // The last frame's light goes.
            if let band = distillState.lastBand { setNeedsDisplay(band) }
            if let glow = distillState.lastGlow { setNeedsDisplay(glow) }
            distillState.lastBand = nil
            distillState.lastGlow = nil
        }
    }

    @objc func distillFrame(_ link: CADisplayLink) {
        redrawDistillFrame()
        if !distillMoving { updateDistillLink() }
    }

    /// One frame: only where the band was and is now, and the lines that glow, are drawn again.
    func redrawDistillFrame() {
        let state = distillState
        let now = DistillMotion.now()
        var dirty: [NSRect] = []
        let band = sweepBand(at: now)
        if let band { dirty.append(band) }
        if let last = state.lastBand { dirty.append(last) }
        state.lastBand = band
        var glow: NSRect?
        if let given = state.given {
            for (id, found) in given.found where DistillFlights.glow(found: found, now: now) > 0 || now.timeIntervalSince(found) < DistillFlights.glow + 0.1 {
                for range in state.ranges[id] ?? [] {
                    if let rect = lineRect(range) { glow = (glow ?? rect).union(rect) }
                }
            }
        }
        if let glow { dirty.append(glow.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y).insetBy(dx: -24, dy: -6)) }
        if let last = state.lastGlow { dirty.append(last) }
        state.lastGlow = glow.map { $0.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y).insetBy(dx: -24, dy: -6) }
        for rect in dirty { setNeedsDisplay(rect.intersection(visibleRect.insetBy(dx: 0, dy: -40))) }
    }

    /// The stretch being read, in this view, the width of the page.
    func sweepArea() -> NSRect? {
        guard let span = distillState.span, let rect = lineRect(span), let container = textContainer else { return nil }
        // The text container's width: what's drawn behind its lines is clipped to it.
        return NSRect(x: textContainerOrigin.x, y: textContainerOrigin.y + rect.minY - 4, width: container.size.width, height: rect.height + 8)
    }

    /// The band of light at `now`, in this view: its height a third of the stretch, between 70 and 170 points.
    func sweepBand(at now: Date) -> NSRect? {
        guard let given = distillState.given, given.reading != nil, !given.reduceMotion, let area = sweepArea() else { return nil }
        let height = min(170, max(70, area.height * 0.34))
        let position = DistillFlights.sweep(started: given.readingSince ?? now, now: now)
        let middle = area.minY + area.height * position
        return NSRect(x: area.minX, y: middle - height / 2, width: area.width, height: height).intersection(area.insetBy(dx: 0, dy: -1))
    }
}

// MARK: - Drawing

extension MarkdownLayoutManager {
    /// Behind the words: the stretch being read and its moving light, then the lines of the items the list lights.
    func drawDistill(in characters: NSRange, at origin: NSPoint) {
        guard let view = firstTextView as? MarkdownTextView, let given = view.distillState.given else { return }
        let state = view.distillState
        let started = Date()
        let now = DistillMotion.now()
        let accent = given.accent
        // In the text container's coordinates, as `origin` places them.
        func local(_ rect: NSRect) -> NSRect { rect.offsetBy(dx: origin.x - view.textContainerOrigin.x, dy: origin.y - view.textContainerOrigin.y) }
        if given.reading != nil, let area = view.sweepArea().map(local) {
            let shape = NSBezierPath(roundedRect: area, xRadius: 10, yRadius: 10)
            // The part being read: a faint wash, and a thread down its left edge.
            accent.withAlpha(given.reduceMotion ? 0.07 : 0.035).setFill()
            shape.fill()
            let thread = NSRect(x: area.minX + 1, y: area.minY + 6, width: 2.5, height: max(0, area.height - 12))
            accent.withAlpha(0.22).setFill()
            NSBezierPath(roundedRect: thread, xRadius: 1.25, yRadius: 1.25).fill()
            if let band = view.sweepBand(at: now).map(local) {
                NSGraphicsContext.saveGraphicsState()
                shape.addClip()
                let gradient = NSGradient(colorsAndLocations: (accent.withAlpha(0), 0), (accent.withAlpha(0.10), 0.35),
                                          (accent.withAlpha(0.17), 0.5), (accent.withAlpha(0.10), 0.65), (accent.withAlpha(0), 1))
                gradient?.draw(in: band, angle: 90)
                // The thread lights where the band is.
                let lit = thread.intersection(band)
                if !lit.isEmpty {
                    let glow = NSGradient(colorsAndLocations: (accent.withAlpha(0), 0), (accent.withAlpha(0.95), 0.5), (accent.withAlpha(0), 1))
                    glow?.draw(in: NSRect(x: thread.minX - 0.5, y: band.minY, width: thread.width + 1, height: band.height), angle: 90)
                }
                NSGraphicsContext.restoreGraphicsState()
            }
        }
        for spot in given.spots {
            let glow = given.found[spot.id].map { given.reduceMotion ? (now.timeIntervalSince($0) < DistillFlights.glow ? 0.6 : 0) : DistillFlights.glow(found: $0, now: now) } ?? 0
            let lit = spot.id == given.selected ? 1.0 : spot.id == given.hovered ? 0.6 : 0
            let strength = max(lit, glow)
            guard strength > 0, let ranges = state.ranges[spot.id] else { continue }
            for range in ranges where NSIntersectionRange(range, characters).length > 0 || NSLocationInRange(range.location, characters) {
                guard let rect = view.lineRect(range) else { continue }
                let left = max(0, rect.minX - 6)
                let box = NSRect(x: left, y: rect.minY, width: rect.maxX - left + 6, height: rect.height).offsetBy(dx: origin.x, dy: origin.y)
                let path = NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5)
                if glow > 0 {
                    // Found just now: a soft halo that fades.
                    NSGraphicsContext.saveGraphicsState()
                    let shadow = NSShadow()
                    shadow.shadowColor = spot.color.withAlpha(0.7 * glow)
                    shadow.shadowBlurRadius = 14
                    shadow.shadowOffset = .zero
                    shadow.set()
                    spot.color.withAlpha(0.30 * glow).setFill()
                    path.fill()
                    NSGraphicsContext.restoreGraphicsState()
                }
                if lit > 0 {
                    spot.color.withAlpha(0.13 * lit).setFill()
                    path.fill()
                }
                // A mark down its left edge, in its colour.
                let mark = NSRect(x: box.minX, y: box.minY + 2, width: 3, height: max(4, box.height - 4))
                spot.color.withAlpha(0.9 * strength).setFill()
                NSBezierPath(roundedRect: mark, xRadius: 1.5, yRadius: 1.5).fill()
            }
        }
        state.frames += 1
        state.drawing += Date().timeIntervalSince(started)
    }
}
