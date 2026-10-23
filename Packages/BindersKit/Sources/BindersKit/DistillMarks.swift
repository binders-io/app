import Foundation

// Lane DS4: the work distilled from a note, shown in the note at the words it came from. Each item carries a quote (the
// note's words, as the reader copied them); the note is edited after Distill, so the quote is found in the text as it is
// now each time it's shown: exactly, then loosely, then by the line with the most words in common. A card whose words
// can't be found, or that has none (made before this), shows at its section's heading.

/// A work item's quote: kept as the reader wrote it, and found in the note's text as it is now.
public enum DistillQuote {
    /// What the prompt asks for: a phrase or one line, at most 25 words.
    public static let maxWords = 25
    /// The most words kept of a quote that runs on.
    static let keepWords = 40

    /// How a quote was found.
    public enum How: String, Equatable, Sendable {
        /// The same characters.
        case exact
        /// The same once case, accents, the space between words, Markdown's markup, list markers and curly quotes don't count.
        case loose
        /// Not there as written: the line of its section with the most of its words.
        case words
    }

    public struct Found: Equatable, Sendable {
        /// Where, in UTF-16, in the text as it is now.
        public var range: NSRange
        public var how: How
    }

    /// A quote as kept: trimmed, the quotation marks or ellipsis a reader put around it taken off, the space between words
    /// made plain, at most `keepWords` words. Nil for none.
    public static func clean(_ quote: String?) -> String? {
        guard var text = quote?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        let pairs: [(Character, Character)] = [("\"", "\""), ("“", "”"), ("'", "'"), ("‘", "’"), ("«", "»"), ("„", "“")]
        for (open, close) in pairs where text.count >= 2 && text.first == open && text.last == close {
            text = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        text = text.replacingOccurrences(of: #"^(?:…|\.\.\.)\s*|\s*(?:…|\.\.\.)$"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        let words = text.split(separator: " ")
        if words.count > keepWords { text = words.prefix(keepWords).joined(separator: " ") }
        return text.isEmpty ? nil : text
    }

    /// Finds a quote in the note's text as it is now: the same words in its section first, then anywhere in the note; then
    /// loosely (`How.loose`), in its section, then anywhere; then the line of its section with the most of its words, when
    /// that's at least `wordShare` of them and two or more. Nil when none of that finds it.
    /// - Parameters:
    ///   - section: the "## " heading the item came from; nil for the note's opening.
    ///   - regions: the note's sections (`DistillMarks.regions(of:)`), when the caller has them already.
    ///   - folded: the note folded for a loose match, made only when it's needed (`place` makes it once for every card).
    public static func find(_ quote: String, section: String?, in text: String, regions given: [DistillMarks.Region]? = nil,
                            folded: (() -> Folded)? = nil) -> Found? {
        let quote = quote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !quote.isEmpty else { return nil }
        let string = text as NSString
        let regions = given ?? DistillMarks.regions(of: text)
        let region = DistillMarks.region(section, in: regions)
        let whole = NSRange(location: 0, length: string.length)
        // The same words.
        if let region {
            let found = string.range(of: quote, options: [], range: region.body)
            if found.location != NSNotFound { return Found(range: found, how: .exact) }
        }
        let anywhere = string.range(of: quote, options: [], range: whole)
        if anywhere.location != NSNotFound { return Found(range: anywhere, how: .exact) }
        // Loosely.
        let needle = Folded(quote, trimPunctuation: true)
        if needle.scalars.count >= 3 {
            let haystack = folded?() ?? Folded(text)
            if let region, let found = haystack.find(needle.scalars, within: region.body) { return Found(range: found, how: .loose) }
            if let found = haystack.find(needle.scalars, within: whole) { return Found(range: found, how: .loose) }
        }
        // The line with the most of its words, in its section.
        if let region, let line = bestLine(for: quote, in: region.body, of: string) { return Found(range: line, how: .words) }
        return nil
    }

    /// How much of a quote's words a line must have to stand for it.
    public static let wordShare = 0.6

    /// The line in `range` with the most of the quote's words (`wordShare` of them and at least two), its list marker,
    /// checkbox and the space at its ends left out. The first such line when two have as many.
    static func bestLine(for quote: String, in range: NSRange, of string: NSString) -> NSRange? {
        let wanted = Set(words(quote))
        guard wanted.count >= 2 else { return nil }
        var best: (range: NSRange, common: Int)?
        var location = range.location
        while location < NSMaxRange(range) {
            let line = string.lineRange(for: NSRange(location: location, length: 0))
            defer { location = NSMaxRange(line) }
            let body = DistillMarks.lineBody(line, of: string)
            guard body.length > 0, !DistillMarks.isHeading(line, of: string) else { continue }
            let common = wanted.intersection(words(string.substring(with: body))).count
            guard Double(common) >= Double(wanted.count) * wordShare, common >= 2 else { continue }
            if best == nil || common > best!.common { best = (body, common) }
        }
        return best?.range
    }

    /// The words that tell a line apart: lower case, accents off, two letters or more, the commonest left out.
    static func words(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 && !stopWords.contains($0) }
    }

    static let stopWords: Set<String> = ["the", "an", "and", "or", "to", "of", "in", "on", "for", "with", "is", "are", "be", "it", "that",
                                         "this", "we", "our", "at", "by", "as", "so", "if", "it's", "its", "from", "into", "then"]

    /// Text as a loose match compares it, each of its characters knowing where it came from: lower case, accents off, curly
    /// quotes and dashes made plain, Markdown's markup (* _ ` ~ [ ]) and the start of a line's markup (a list marker, a
    /// checkbox, #s, >) left out, every run of space and line breaks one space.
    public struct Folded: Sendable {
        public private(set) var scalars: [Unicode.Scalar] = []
        /// Where each of `scalars` starts and ends in the text, in UTF-16.
        private var starts: [Int] = []
        private var ends: [Int] = []

        public init(_ text: String, trimPunctuation: Bool = false) {
            let string = text as NSString
            var skip = IndexSet()
            if let regex = Self.lineMarkup {
                for match in regex.matches(in: text, range: NSRange(location: 0, length: string.length)) where match.range.length > 0 {
                    skip.insert(integersIn: match.range.location..<NSMaxRange(match.range))
                }
            }
            scalars.reserveCapacity(string.length)
            var offset = 0
            var space = true // at the start, nothing to separate yet
            for scalar in text.unicodeScalars {
                let width = scalar.utf16.count
                defer { offset += width }
                if skip.contains(offset) { continue }
                if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                    if !space { append(" ", offset, width) }
                    space = true
                    continue
                }
                if Self.markup.contains(scalar) { continue }
                space = false
                if let plain = Self.plain[scalar] {
                    for each in plain.unicodeScalars { append(each, offset, width) }
                } else if scalar.isASCII {
                    let value = scalar.value
                    append((65...90).contains(value) ? Unicode.Scalar(value + 32)! : scalar, offset, width)
                } else {
                    for each in String(scalar).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).unicodeScalars {
                        append(each, offset, width)
                    }
                }
            }
            while scalars.last == " " { removeLast() }
            if trimPunctuation {
                while let last = scalars.last, Self.edgePunctuation.contains(last) || last == " " { removeLast() }
                while let first = scalars.first, Self.edgePunctuation.contains(first) || first == " " { removeFirst() }
            }
        }

        private mutating func append(_ scalar: Unicode.Scalar, _ start: Int, _ width: Int) {
            scalars.append(scalar)
            starts.append(start)
            ends.append(start + width)
        }

        private mutating func removeLast() {
            scalars.removeLast()
            starts.removeLast()
            ends.removeLast()
        }

        private mutating func removeFirst() {
            scalars.removeFirst()
            starts.removeFirst()
            ends.removeFirst()
        }

        /// Where `needle` first is, among the characters from `range` of the text, as a range of the text.
        func find(_ needle: [Unicode.Scalar], within range: NSRange) -> NSRange? {
            guard !needle.isEmpty, needle.count <= scalars.count else { return nil }
            // The first and last character from inside the range.
            var low = 0, high = starts.count
            while low < high {
                let mid = (low + high) / 2
                if starts[mid] < range.location { low = mid + 1 } else { high = mid }
            }
            let first = low
            let limit = NSMaxRange(range)
            var index = first
            let head = needle[0]
            while index + needle.count <= scalars.count, ends[index + needle.count - 1] <= limit {
                if scalars[index] == head {
                    var same = true
                    for step in 1..<needle.count where scalars[index + step] != needle[step] {
                        same = false
                        break
                    }
                    if same { return NSRange(location: starts[index], length: ends[index + needle.count - 1] - starts[index]) }
                }
                index += 1
            }
            return nil
        }

        static let markup = CharacterSet(charactersIn: "*_`~[]")
        static let edgePunctuation: Set<Unicode.Scalar> = [".", ",", ";", ":", "!", "?", "\"", "'", "(", ")"]
        static let plain: [Unicode.Scalar: String] = [
            "‘": "'", "’": "'", "‚": "'", "‛": "'", "′": "'", "“": "\"", "”": "\"", "„": "\"", "‟": "\"", "″": "\"",
            "–": "-", "—": "-", "‐": "-", "‑": "-", "…": "...", "\u{00A0}": " ",
        ]
        /// A line's markup at its start: indent, a list marker and checkbox, #s, > for a quote.
        static let lineMarkup = try? NSRegularExpression(pattern: #"^[ \t]*(?:(?:[-*+]|\d+[.)])[ \t]+(?:\[[ xX]\][ \t]+)?|#{1,6}[ \t]+|(?:>[ \t]?)+)"#,
                                                         options: [.anchorsMatchLines])
    }
}

/// Where each card distilled from a note shows in it: the words it came from with the line they end on, or its section's
/// heading; and how many cards each heading's section has.
public enum DistillMarks {
    /// A card as the note marks it: its id, the note's words it came from, and its section.
    public struct Card: Equatable, Sendable {
        public var id: String
        public var quote: String?
        /// The "## " heading it came from; nil for the note's opening.
        public var section: String?

        public init(id: String, quote: String?, section: String?) {
            self.id = id
            self.quote = quote
            self.section = section
        }
    }

    /// One card's words in the note.
    public struct Mark: Equatable, Sendable {
        public var card: String
        public var range: NSRange
        public var how: DistillQuote.How
    }

    /// A line holding the words of one card or more: its chip goes at its end.
    public struct Line: Equatable, Sendable {
        /// The line, its line break left out.
        public var line: NSRange
        public var marks: [Mark]
        /// A heading's line: its words are marked, and its heading's chip says the cards.
        public var isHeading: Bool
        /// The cards on it, in order, each once.
        public var cards: [String] {
            var seen: Set<String> = []
            return marks.map(\.card).filter { seen.insert($0).inserted }
        }
    }

    /// A section's heading, with every card from its section. The note's opening goes on its title line.
    public struct Heading: Equatable, Sendable {
        /// The heading as the cards name it; nil for the opening.
        public var heading: String?
        /// Its line, without its line break.
        public var line: NSRange
        public var cards: [String]
    }

    /// Where every card shows in the note as it is now.
    public struct Placement: Equatable, Sendable {
        public var lines: [Line] = []
        public var headings: [Heading] = []
        /// Cards shown at no words, only at their heading: no quote, or one the note no longer has.
        public var atHeading: [String] = []
        /// Cards shown nowhere: their words and their section are both gone.
        public var nowhere: [String] = []

        public init(lines: [Line] = [], headings: [Heading] = [], atHeading: [String] = [], nowhere: [String] = []) {
            self.lines = lines
            self.headings = headings
            self.atHeading = atHeading
            self.nowhere = nowhere
        }

        public static let empty = Placement()

        /// The card's words, if the note shows them.
        public func mark(of card: String) -> Mark? {
            for line in lines { if let mark = line.marks.first(where: { $0.card == card }) { return mark } }
            return nil
        }

        /// Every range something is drawn for: marked words, lines with chips, headings.
        public var ranges: [NSRange] { lines.flatMap { [$0.line] + $0.marks.map(\.range) } + headings.map(\.line) }

        /// The same places once the text was edited (`edited`, in the new text, `delta` longer than before), without finding
        /// anything again, for while you type: what's before the edit stays, what's after it moves with it, and words or a
        /// heading the edit touched drop to their heading until the next `place`. Lines are found again in `text`.
        public func shifted(edited: NSRange, delta: Int, in text: String) -> Placement {
            // The edit replaced edited.location ..< oldEnd of the text before it.
            let oldEnd = edited.location + edited.length - delta
            func moved(_ range: NSRange) -> NSRange? {
                if NSMaxRange(range) <= edited.location { return range }
                if range.location >= oldEnd { return NSRange(location: range.location + delta, length: range.length) }
                return nil
            }
            var marks: [Mark] = []
            var dropped: [String] = atHeading
            for line in lines {
                for mark in line.marks {
                    if let range = moved(mark.range) { marks.append(Mark(card: mark.card, range: range, how: mark.how)) } else { dropped.append(mark.card) }
                }
            }
            let headings = self.headings.compactMap { heading -> Heading? in
                moved(heading.line).map { Heading(heading: heading.heading, line: $0, cards: heading.cards) }
            }
            var placement = Placement(lines: DistillMarks.lines(marks, in: text as NSString), headings: headings, atHeading: [], nowhere: nowhere)
            let shown = Set(marks.map(\.card))
            var seen: Set<String> = []
            placement.atHeading = dropped.filter { !shown.contains($0) && seen.insert($0).inserted }
            return placement
        }
    }

    /// A section of the note as it is now: its heading's line and the text under it.
    public struct Region: Equatable, Sendable {
        /// Nil for the opening, before the first "## ".
        public var heading: String?
        /// The heading's line without its break; for the opening, the note's title line, when it has one.
        public var line: NSRange?
        /// Its text, after its heading's line, up to the next "# " or "## " heading.
        public var body: NSRange
    }

    /// The note's sections, as `DistillSections.sections` reads them, with where each is in the text: the opening (after the
    /// title line, up to the first "## "), then each "## " heading's.
    public static func regions(of text: String) -> [Region] {
        let string = text as NSString
        let headings = MarkdownOutline.headings(in: text).filter { $0.level <= 2 }
        let firstSection = headings.first { $0.level == 2 }?.location ?? string.length
        var regions: [Region] = []
        // The title: the first "# " heading before any "## ", else the first line.
        let titleLine: NSRange? = {
            guard string.length > 0, firstSection > 0 else { return nil }
            let at = headings.first(where: { $0.level == 1 && $0.location < firstSection })?.location ?? 0
            let line = withoutBreak(string.lineRange(for: NSRange(location: at, length: 0)), of: string)
            return line.length > 0 ? line : nil
        }()
        let openingStart = titleLine.map { min(NSMaxRange(string.lineRange(for: $0)), firstSection) } ?? 0
        regions.append(Region(heading: nil, line: titleLine, body: NSRange(location: openingStart, length: max(0, firstSection - openingStart))))
        for (index, heading) in headings.enumerated() where heading.level == 2 {
            let line = string.lineRange(for: NSRange(location: heading.location, length: 0))
            let end = headings.dropFirst(index + 1).first.map(\.location) ?? string.length
            let start = min(NSMaxRange(line), end)
            regions.append(Region(heading: heading.title, line: withoutBreak(line, of: string), body: NSRange(location: start, length: end - start)))
        }
        return regions
    }

    /// The region a card's section names: the same heading, else one `DistillSections.match` finds; nil for the opening's.
    public static func region(_ section: String?, in regions: [Region]) -> Region? {
        guard let section else { return regions.first { $0.heading == nil } }
        if let same = regions.first(where: { $0.heading == section }) { return same }
        guard let found = DistillSections.match(section, in: regions.compactMap(\.heading)) else { return nil }
        return regions.first { $0.heading == found }
    }

    /// Where each card shows in the note as it is now.
    public static func place(_ cards: [Card], in text: String) -> Placement {
        guard !cards.isEmpty else { return .empty }
        let string = text as NSString
        let regions = regions(of: text)
        var folded: DistillQuote.Folded?
        let fold = { () -> DistillQuote.Folded in
            if let folded { return folded }
            let made = DistillQuote.Folded(text)
            folded = made
            return made
        }
        var marks: [Mark] = []
        var atHeading: [String] = []
        var nowhere: [String] = []
        var byHeading: [Int: [String]] = [:]
        for card in cards {
            let region = region(card.section, in: regions)
            if let index = region.flatMap({ found in regions.firstIndex { $0.heading == found.heading } }), regions[index].line != nil {
                byHeading[index, default: []].append(card.id)
            }
            // The loose fold of the note is made once, and only when a quote needs it.
            let found = card.quote.flatMap { $0.isEmpty ? nil : DistillQuote.find($0, section: card.section, in: text, regions: regions, folded: fold) }
            if let found {
                marks.append(Mark(card: card.id, range: found.range, how: found.how))
            } else if region?.line != nil {
                atHeading.append(card.id)
            } else {
                nowhere.append(card.id)
            }
        }
        let headings = byHeading.keys.sorted().compactMap { index -> Heading? in
            regions[index].line.map { Heading(heading: regions[index].heading, line: $0, cards: byHeading[index] ?? []) }
        }
        return Placement(lines: lines(marks, in: string), headings: headings, atHeading: atHeading, nowhere: nowhere)
    }

    /// Marks grouped by the line each ends on, in the note's order.
    static func lines(_ marks: [Mark], in string: NSString) -> [Line] {
        var byLine: [Int: Line] = [:]
        for mark in marks {
            guard NSMaxRange(mark.range) <= string.length else { continue }
            let end = max(mark.range.location, NSMaxRange(mark.range) - 1)
            let full = string.lineRange(for: NSRange(location: min(end, max(0, string.length - 1)), length: 0))
            let line = withoutBreak(full, of: string)
            if byLine[line.location] == nil {
                byLine[line.location] = Line(line: line, marks: [], isHeading: isHeading(full, of: string))
            }
            byLine[line.location]?.marks.append(mark)
        }
        return byLine.keys.sorted().compactMap { byLine[$0] }
    }

    static func withoutBreak(_ line: NSRange, of string: NSString) -> NSRange {
        var length = line.length
        while length > 0, [0x0A, 0x0D].contains(string.character(at: line.location + length - 1)) { length -= 1 }
        return NSRange(location: line.location, length: length)
    }

    /// A line's words: its indent, list marker, checkbox, #s or > left out, and the space at its end.
    static func lineBody(_ line: NSRange, of string: NSString) -> NSRange {
        let bare = withoutBreak(line, of: string)
        guard bare.length > 0 else { return bare }
        var start = bare.location
        if let regex = DistillQuote.Folded.lineMarkup, let match = regex.firstMatch(in: string as String, options: [.anchored], range: bare), match.range.length > 0 {
            start = NSMaxRange(match.range)
        }
        var end = NSMaxRange(bare)
        while end > start, [0x20, 0x09].contains(string.character(at: end - 1)) { end -= 1 }
        while start < end, [0x20, 0x09].contains(string.character(at: start)) { start += 1 }
        return NSRange(location: start, length: end - start)
    }

    static func isHeading(_ line: NSRange, of string: NSString) -> Bool {
        guard line.length > 0 else { return false }
        return string.substring(with: withoutBreak(line, of: string)).range(of: #"^#{1,6}[ \t]"#, options: .regularExpression) != nil
    }

    // MARK: What a chip says

    /// A card as its chip says it: its column, the state Distill's progress gives it, who has it or is meant to, and
    /// whether Distill again closed it.
    public struct ChipCard: Equatable, Sendable {
        public var id: String
        public var title: String
        /// Its board column (`BoardColumn` raw value).
        public var column: String
        public var state: DistillProgress.State?
        public var who: String?
        public var closed: Bool

        public init(id: String, title: String, column: String, state: DistillProgress.State?, who: String?, closed: Bool = false) {
            self.id = id
            self.title = title
            self.column = column
            self.state = state
            self.who = who
            self.closed = closed
        }

        /// Done, or closed: its mark goes faint.
        public var finished: Bool { closed || column == BoardColumn.done.rawValue }
    }

    /// What a line's chip says: for one card, where it is ("Ready · Echo", "In progress · Claude Code", "Done", "Closed");
    /// for more, how many and how many are done ("3 cards · 1 done").
    public static func chip(_ cards: [ChipCard]) -> String {
        guard cards.count != 1 else {
            let card = cards[0]
            if card.closed { return "Closed" }
            let column = BoardColumn(rawValue: card.column)
            if column == .done { return "Done" }
            let place = column?.title ?? card.column
            guard let who = card.who?.trimmingCharacters(in: .whitespaces), !who.isEmpty else { return place }
            return "\(place) · \(who)"
        }
        let done = cards.filter(\.finished).count
        return count(cards.count) + (done == 0 ? "" : done == cards.count ? " · all done" : " · \(done) done")
    }

    /// What a heading's chip says: how many cards its section has.
    public static func headingChip(_ cards: Int) -> String { count(cards) }

    static func count(_ cards: Int) -> String { cards == 1 ? "1 card" : "\(cards) cards" }
}
