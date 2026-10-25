import CoreGraphics
import Foundation

// Lane DS9: Distill you can see. Where an item's lines are in the note as it is now (`DistillSpots`), the stretch of the
// note a part is reading (`DistillSpots.span`), when a reading in the background is due and what holds it back
// (`DistillBackground`), the cards that fly from the note into the Distill list one after another (`DistillFlights`), and
// what the Distill button says (`DistillButtonFace`).

/// Where an item's lines are in the note as it is now: what the list highlights, scrolls to and glows.
public enum DistillSpots {
    /// The lines of the note an item came from, each a whole line without its break, in the note's order, once each: each of
    /// its source lines (a v2 item's first brief is the note's lines it named, one to a line) found in its section, else
    /// anywhere; then, with none found, its quote. Empty when the note no longer has them.
    public static func lines(quote: String?, source: String?, section: String?, in text: String,
                             regions given: [DistillMarks.Region]? = nil) -> [NSRange] {
        let string = text as NSString
        guard string.length > 0 else { return [] }
        let regions = given ?? DistillMarks.regions(of: text)
        var found: [NSRange] = []
        func add(_ range: NSRange) {
            let line = wholeLines(range, in: string)
            if line.length > 0, !found.contains(line) { found.append(line) }
        }
        let wanted = (source ?? "").components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.count >= 3 }
        for line in wanted.prefix(DistillLines.maxPerItem) {
            // The line as the note writes it, its list marker taken off where the source had it plain.
            if let hit = DistillQuote.find(line, section: section, in: text, regions: regions) { add(hit.range) }
        }
        if found.isEmpty, let quote = DistillQuote.clean(quote), let hit = DistillQuote.find(quote, section: section, in: text, regions: regions) {
            add(hit.range)
        }
        return found.sorted { $0.location < $1.location }
    }

    /// The whole lines `range` touches, from the start of its first to the end of its last, without the last line break.
    public static func wholeLines(_ range: NSRange, in string: NSString) -> NSRange {
        let start = min(max(0, range.location), string.length)
        let end = min(NSMaxRange(range), string.length)
        let lines = string.lineRange(for: NSRange(location: start, length: max(0, end - start)))
        var length = lines.length
        while length > 0 {
            let character = string.character(at: lines.location + length - 1)
            guard character == 0x0A || character == 0x0D else { break }
            length -= 1
        }
        return NSRange(location: lines.location, length: length)
    }

    /// The stretch of the note a part reads, for the light that sweeps down it: from the heading of the section its first
    /// line is in (or that line) to the end of its last line, found in the note as it is now. Nil when the note no longer
    /// has either.
    public static func span(of part: DistillLines, in text: String) -> NSRange? {
        let numbered = part.numbered
        guard let first = numbered.first, let last = numbered.last else { return nil }
        let string = text as NSString
        let regions = DistillMarks.regions(of: text)
        func find(_ line: DistillLines.Line, after: Int = 0) -> NSRange? {
            let words = line.text.components(separatedBy: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? line.text
            let region = DistillMarks.region(line.section, in: regions)
            let within = region.map { NSRange(location: max($0.body.location, after), length: max(0, NSMaxRange($0.body) - max($0.body.location, after))) }
            if let within, within.length > 0 {
                let hit = string.range(of: words, options: [], range: within)
                if hit.location != NSNotFound { return hit }
            }
            let rest = NSRange(location: after, length: string.length - after)
            let hit = string.range(of: words, options: [], range: rest)
            if hit.location != NSNotFound { return hit }
            return DistillQuote.find(words, section: line.section, in: text, regions: regions)?.range
        }
        guard let start = find(first) else { return nil }
        let end = find(last, after: start.location) ?? start
        var from = start.location
        // The section's heading too, when the part starts at its top.
        if let region = DistillMarks.region(first.section, in: regions), let heading = region.line, first.section != nil,
           start.location - NSMaxRange(heading) < 4 {
            from = heading.location
        }
        return wholeLines(NSRange(location: from, length: max(0, NSMaxRange(end) - from)), in: string)
    }
}

/// Reading a Distill note again in the background while you write (lane DS9): only after a pause in your typing, only when
/// what changed is more than space and markup, and never while you dictate, record or capture, on a low battery or Low
/// Power Mode, on a hot Mac, or while you run a Distill yourself.
public enum DistillBackground {
    /// How long the note's typing pauses before its changed sections are read: 20 seconds.
    public static let idle: TimeInterval = 20
    /// The fewest characters that count as a change worth reading for, markup and space left out.
    public static let fewest = 6
    /// Below this share of a battery, on battery, nothing is read in the background.
    public static let lowBattery = 0.2

    /// What holds a reading in the background back, in the words the list's line says.
    public enum Pause: String, Equatable, Sendable {
        case off, dictating, recording, capturing, battery, lowPower, hot, foreground

        public var words: String {
            switch self {
            case .off: "Distill in the background is off in Settings → AI."
            case .dictating: "Waiting while you dictate."
            case .recording: "Waiting while a meeting is recorded."
            case .capturing: "Waiting while all-day capture is on."
            case .battery: "Waiting for power: the battery is low."
            case .lowPower: "Waiting while Low Power Mode is on."
            case .hot: "Waiting for this Mac to cool down."
            case .foreground: "Waiting for the Distill you started."
            }
        }
    }

    /// What the Mac is doing now, as far as a reading in the background cares.
    public struct Conditions: Equatable, Sendable {
        public var enabled = true
        public var dictating = false
        public var recording = false
        public var capturing = false
        public var onBattery = false
        /// The battery's charge, 0 to 1; nil without one.
        public var battery: Double?
        public var lowPower = false
        /// Serious or critical thermal pressure.
        public var hot = false
        /// You're running a Distill yourself.
        public var foreground = false

        public init(enabled: Bool = true, dictating: Bool = false, recording: Bool = false, capturing: Bool = false, onBattery: Bool = false,
                    battery: Double? = nil, lowPower: Bool = false, hot: Bool = false, foreground: Bool = false) {
            self.enabled = enabled
            self.dictating = dictating
            self.recording = recording
            self.capturing = capturing
            self.onBattery = onBattery
            self.battery = battery
            self.lowPower = lowPower
            self.hot = hot
            self.foreground = foreground
        }
    }

    /// Why a reading in the background can't run now, or nil when it can.
    public static func pause(_ now: Conditions) -> Pause? {
        if !now.enabled { return .off }
        if now.dictating { return .dictating }
        if now.recording { return .recording }
        if now.capturing { return .capturing }
        if now.foreground { return .foreground }
        if now.lowPower { return .lowPower }
        if now.onBattery, let level = now.battery, level < lowBattery { return .battery }
        if now.hot { return .hot }
        return nil
    }

    /// How many characters changed between two versions of a note, markup and space left out: Markdown's marks, a task's
    /// tick and every space and line break don't count. From where they first differ to where they last do, so two edits
    /// far apart count the words between them too (which only makes a reading more likely, never less).
    public static func changed(from old: String, to new: String) -> Int {
        let a = Array(plain(old)), b = Array(plain(new))
        let shorter = min(a.count, b.count)
        var prefix = 0
        while prefix < shorter, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < shorter - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        return max(a.count, b.count) - prefix - suffix
    }

    /// Whether the change is worth reading for: more than a few characters of words.
    public static func meaningful(from old: String, to new: String, atLeast: Int = fewest) -> Bool {
        changed(from: old, to: new) >= atLeast
    }

    /// Text as `changed` compares it: no task ticks, no Markdown marks, no space.
    static func plain(_ text: String) -> String {
        let ticks = text.replacingOccurrences(of: #"\[[ xX]\]"#, with: "", options: .regularExpression)
        let marks: Set<Character> = ["*", "_", "`", "~", "#", ">"]
        return String(ticks.filter { !marks.contains($0) && !$0.isWhitespace })
    }
}

/// The cards that lift out of the note as their items are found and fly into the Distill list: one after another, a
/// fraction of a second apart, never piling up, each along a curve that rises before it falls.
public struct DistillFlights: Equatable, Sendable {
    /// Between one card setting off and the next.
    public static let gap: TimeInterval = 0.16
    /// From lifting off to landing.
    public static let duration: TimeInterval = 0.82
    /// How long the lines an item came from glow once it's found.
    public static let glow: TimeInterval = 1.4

    /// When the last card set off.
    public private(set) var last: Date?

    public init() {}

    /// When a card found `now` sets off: now, or `gap` after the one before it.
    public mutating func start(at now: Date) -> Date {
        let start = last.map { max(now, $0.addingTimeInterval(Self.gap)) } ?? now
        last = start
        return start
    }

    /// How far along a flight is, 0 to 1, unhurried at both ends; 0 before it sets off.
    public static func progress(started: Date, now: Date, duration: TimeInterval = duration) -> Double {
        let t = min(1, max(0, now.timeIntervalSince(started) / duration))
        // Ease in and out (smootherstep), so it lifts gently and settles into its row.
        return t * t * t * (t * (t * 6 - 15) + 10)
    }

    /// Where a card is at `t` (0 to 1) along its curve from `from` to `to`: a quadratic curve whose middle rises `lift`
    /// above the higher of the two, so it arcs up out of the note and over into the list.
    public static func point(from: CGPoint, to: CGPoint, lift: CGFloat, t: Double) -> CGPoint {
        let t = CGFloat(min(1, max(0, t)))
        let control = CGPoint(x: (from.x + to.x) / 2, y: min(from.y, to.y) - lift)
        let u = 1 - t
        return CGPoint(x: u * u * from.x + 2 * u * t * control.x + t * t * to.x,
                       y: u * u * from.y + 2 * u * t * control.y + t * t * to.y)
    }

    /// How bright a found item's lines glow at `now`: full as it's found, fading out over `glow` seconds.
    public static func glow(found: Date, now: Date) -> Double {
        let age = now.timeIntervalSince(found)
        guard age >= 0, age < glow else { return 0 }
        let t = age / glow
        return (1 - t) * (1 - t)
    }

    /// Where the sweeping light is in the stretch being read, as a share of its height: it comes in from just above the
    /// top, eases down past the bottom and starts again, every `period` seconds.
    public static func sweep(started: Date, now: Date, period: TimeInterval = 2.6) -> Double {
        let elapsed = max(0, now.timeIntervalSince(started))
        let p = elapsed.truncatingRemainder(dividingBy: period) / period
        let eased = p * p * (3 - 2 * p)
        return -0.2 + 1.4 * eased
    }
}

/// What the Distill button says: Distill; reading, with how many items so far; how many new items a reading in the
/// background found; or, for a moment after a click with nothing changed, Up to date.
public enum DistillButtonFace: Equatable, Sendable {
    case idle
    case reading(items: Int)
    case new(Int)
    case upToDate

    /// From the note's state: `reading` is a reading you started (one in the background doesn't show), `newItems` the items
    /// background readings found that you haven't looked at, `upToDateUntil` when "Up to date" goes.
    public static func face(reading: Int?, newItems: Int, upToDateUntil: Date?, now: Date = Date()) -> DistillButtonFace {
        if let reading { return .reading(items: reading) }
        if let until = upToDateUntil, until > now { return .upToDate }
        if newItems > 0 { return .new(newItems) }
        return .idle
    }

    public var title: String {
        switch self {
        case .idle: "Distill"
        case .reading: "Distilling"
        case .new(let count): "\(count) new"
        case .upToDate: "Up to date"
        }
    }

    /// For VoiceOver and the help.
    public var spoken: String {
        switch self {
        case .idle: "Distill"
        case .reading(let items): items == 0 ? "Distilling" : "Distilling, \(items == 1 ? "1 item" : "\(items) items") so far"
        case .new(let count): count == 1 ? "Distill, 1 new item" : "Distill, \(count) new items"
        case .upToDate: "Distill: up to date"
        }
    }
}
