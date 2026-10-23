import Foundation

// Lane DS6: one idea of "a note's cards", read the same way wherever a note's work is shown or counted (its marks, the
// Work bar and panel, its progress and report, a binder's Work list, the board's groups, list_tasks), and the cards Put
// on Board makes from words selected in a note.

/// A note's cards: the ones Distill made from it, the ones put in its group by hand (lane DS5), and the ones made from it
/// with Put on Board, those made before this build among them (a card from the note with no Distill part: adopted as it
/// is, nothing written to it). A card asking an agent to distill a note isn't part of its work, nor a to-do's card.
public enum NoteWorkCards {
    /// How a card is among its note's cards.
    public enum Tie: String, Equatable, Sendable {
        /// Distill made it from an item of the note.
        case distilled
        /// You put it in the note's group by hand.
        case byHand
        /// Put on Board made it from the note, or from words in it.
        case put
    }

    /// A card's place among its note's cards.
    public struct Membership: Equatable, Sendable {
        public var note: UUID
        public var tie: Tie
        /// Its Distill part as the card keeps it; nil for a card made with Put on Board before this build.
        public var from: DistilledFrom?

        public init(note: UUID, tie: Tie, from: DistilledFrom?) {
            self.note = note
            self.tie = tie
            self.from = from
        }

        /// Made from the note (by Distill or with Put on Board): it's the note's work, so it stays in its group.
        public var staysInGroup: Bool { tie != .byHand }
        /// The note's words it came from, and their "## " section, for the note's marks; neither for a whole note's card.
        public var quote: String? { from?.quote }
        public var section: String? { from?.section }
    }

    /// The source kind of a card made from a note.
    public static let noteKind = "note"

    /// The note whose cards a card is among, and how; nil for none. `distilled`: the card's Distill part as it keeps it
    /// ("" for none); `sourceKind`, `sourceID`: where it came from; `todo`: the to-do it was made from, if any. A Distill
    /// part this build can't read (a later build's) says nothing, as before.
    public static func membership(distilled: String, sourceKind: String?, sourceID: String?, todo: String?) -> Membership? {
        if !distilled.isEmpty {
            guard let from = DistilledFrom(json: distilled), from.request != true else { return nil }
            let tie: Tie = from.byHand == true ? .byHand : from.put == true ? .put : .distilled
            return Membership(note: from.note, tie: tie, from: from)
        }
        // Put on Board before this build: from the note, with no Distill part. A team database's copy names the note in
        // lower case, which reads the same. Not a card made from a to-do the note holds.
        guard sourceKind == noteKind, todo?.isEmpty ?? true, let note = sourceID.flatMap(UUID.init(uuidString:)) else { return nil }
        return Membership(note: note, tie: .put, from: nil)
    }

    /// The note whose cards a card is among; nil for none.
    public static func note(distilled: String, sourceKind: String?, sourceID: String?, todo: String?) -> UUID? {
        membership(distilled: distilled, sourceKind: sourceKind, sourceID: sourceID, todo: todo)?.note
    }
}

/// What Put on Board makes from words selected in a note (lane DS6): one card for the selection, or one for each of its
/// lines. Each has a title from its first line (its Markdown, list marker and checkbox taken off, at most `titleLength`
/// characters), details with the words and the way back to them, the note's words the note marks it at (`quote`), and the
/// "## " section they're in, with that section's text as it reads now.
public enum NoteSelectionCards {
    public struct Piece: Equatable, Sendable {
        public var title: String
        public var details: String
        public var quote: String?
        /// The "## " heading the words are under; nil for the note's opening.
        public var section: String?
        /// That section's text now, from which its changes are told.
        public var sectionText: String?

        public init(title: String, details: String, quote: String?, section: String?, sectionText: String?) {
            self.title = title
            self.details = details
            self.quote = quote
            self.section = section
            self.sectionText = sectionText
        }
    }

    /// The longest a title from a line goes, cut at a word.
    public static let titleLength = 100
    /// How much of a selection goes into the card's details.
    public static let detailsCharacters = 6000

    /// The selected lines that would each be a card ("Put Each Line on Board"): each line the selection touches, as much of
    /// it as is selected, with words on it; not a heading, a code fence or a rule.
    public static func lines(in text: String, selection: NSRange) -> [NSRange] {
        let string = text as NSString
        guard let selection = clamp(selection, in: string), selection.length > 0 else { return [] }
        var lines: [NSRange] = []
        var location = selection.location
        while location < NSMaxRange(selection) {
            let line = string.lineRange(for: NSRange(location: location, length: 0))
            defer { location = max(NSMaxRange(line), location + 1) }
            let part = NSIntersectionRange(DistillMarks.withoutBreak(line, of: string), selection)
            guard part.length > 0 else { continue }
            let words = string.substring(with: part)
            guard !isStructure(words), !title(words).isEmpty else { continue }
            lines.append(part)
        }
        return lines
    }

    /// The cards for a selection: one, or with `eachLine` one per line (`lines`). `agent`: the note's agent mark, as
    /// `NoteCards.details` reads it: with an agent's words in it that you haven't made yours, the details carry only the
    /// way back and say why.
    public static func pieces(text: String, selection: NSRange, noteID: UUID, eachLine: Bool, agent: AgentMark = AgentMark()) -> [Piece] {
        let string = text as NSString
        guard let selection = clamp(selection, in: string), selection.length > 0 else { return [] }
        let regions = DistillMarks.regions(of: text)
        if eachLine {
            return lines(in: text, selection: selection).compactMap { piece(string.substring(with: $0), at: $0.location, text: text, regions: regions,
                                                                          noteID: noteID, agent: agent) }
        }
        return piece(string.substring(with: selection), at: selection.location, text: text, regions: regions, noteID: noteID, agent: agent)
            .map { [$0] } ?? []
    }

    /// One card for `words`, which start at `location` in the note.
    static func piece(_ words: String, at location: Int, text: String, regions: [DistillMarks.Region], noteID: UUID, agent: AgentMark) -> Piece? {
        let lines = words.components(separatedBy: .newlines)
        let bodies = lines.map(stripLineMarkup).filter { !$0.isEmpty }
        guard let first = bodies.first(where: { !title($0).isEmpty }) else { return nil }
        let section = self.section(at: location, in: text, regions: regions)
        let sectionText = section.flatMap { DistillSections.section($0, in: text)?.text }
        // The whole selection when it's short (it's found across its lines, loosely), else its first line.
        let joined = bodies.joined(separator: " ")
        let short = bodies.count == 1 || joined.split(whereSeparator: \.isWhitespace).count <= DistillQuote.maxWords
        let quote = DistillQuote.clean(short ? joined : first)
        let back = "From the note\(section.map { ", “\($0)”" } ?? ""): [open it](\(DistillLinks.section(note: noteID, heading: section)))"
        let details: String
        if let label = agent.label {
            details = "\(label). Its words aren't copied onto the card; open the note to read them.\n\n\(back)"
        } else {
            details = "\(excerpt(words))\n\n\(back)"
        }
        return Piece(title: title(first), details: details, quote: quote, section: section, sectionText: sectionText)
    }

    /// The "## " heading whose section holds `location`; nil for the note's opening (its title among it).
    public static func section(at location: Int, in text: String, regions given: [DistillMarks.Region]? = nil) -> String? {
        let regions = given ?? DistillMarks.regions(of: text)
        for region in regions where region.heading != nil {
            let start = region.line?.location ?? region.body.location
            // Its heading's line, its text, and the very end of the note when it's the last.
            if location >= start, location < NSMaxRange(region.body) || (location == NSMaxRange(region.body) && region.body.length == 0)
                || location == (text as NSString).length && NSMaxRange(region.body) == location {
                return region.heading
            }
        }
        return nil
    }

    /// A card's title from a line: its Markdown taken off (a list marker and checkbox, #s, >, emphasis, code, links shown
    /// as their words), its space made plain, at most `titleLength` characters, cut at a word. "" for a line with no words.
    public static func title(_ line: String) -> String {
        var text = stripLineMarkup(line)
        let replacements: [(String, String)] = [
            (#"!\[[^\]]*\]\([^)]*\)"#, ""),                       // a picture
            (#"\[\[([^\]|]+)\|([^\]]+)\]\]"#, "$2"),              // [[note|shown]]
            (#"\[\[([^\]]+)\]\]"#, "$1"),                        // [[note]]
            (#"\[([^\]]+)\]\([^)]*\)"#, "$1"),                   // [words](link)
            (#"(\*\*|__)(.+?)\1"#, "$2"),                         // **bold**
            (#"~~(.+?)~~"#, "$1"),                               // ~~struck~~
            (#"`([^`]+)`"#, "$1"),                               // `code`
            (#"(^|[\s(])\*(\S(?:.*?\S)?)\*(?=$|[\s).,;:!?])"#, "$1$2"), // *italic*
            (#"(^|[\s(])_(\S(?:.*?\S)?)_(?=$|[\s).,;:!?])"#, "$1$2"),   // _italic_
        ]
        for (pattern, template) in replacements {
            text = text.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        guard text.contains(where: { $0.isLetter || $0.isNumber }) else { return "" }
        guard text.count > titleLength else { return text }
        let head = text.prefix(titleLength)
        let cut = head.lastIndex(where: \.isWhitespace).map { head[..<$0] } ?? head
        return cut.trimmingCharacters(in: .whitespaces.union(.punctuationCharacters)) + "…"
    }

    /// A line without the markup at its start: indent, a list marker and checkbox, #s, > for a quote.
    static func stripLineMarkup(_ line: String) -> String {
        let string = line as NSString
        var start = 0
        if let regex = DistillQuote.Folded.lineMarkup,
           let match = regex.firstMatch(in: line, options: [.anchored], range: NSRange(location: 0, length: string.length)) {
            start = NSMaxRange(match.range)
        }
        return string.substring(from: start).trimmingCharacters(in: .whitespaces)
    }

    /// A heading, a code fence or a rule: lines that hold no work of their own.
    static func isStructure(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.range(of: #"^(#{1,6}\s|```|~~~|(?:[-*_]\s*){3,}$)"#, options: .regularExpression) != nil
    }

    /// The selection as the card's details keep it: without blank lines at its ends, at most `detailsCharacters`, cut at a
    /// line when it runs on.
    static func excerpt(_ words: String) -> String {
        let text = DistillSections.trimmed(words.replacingOccurrences(of: "\r\n", with: "\n"))
        guard text.count > detailsCharacters else { return text }
        let head = text.prefix(detailsCharacters)
        let cut = head.lastIndex(of: "\n").map { head[..<$0] } ?? head
        return cut.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n…"
    }

    /// The selection within the text, or nil when it's outside it.
    static func clamp(_ range: NSRange, in string: NSString) -> NSRange? {
        guard range.location != NSNotFound, range.location <= string.length else { return nil }
        return NSRange(location: range.location, length: min(range.length, string.length - range.location))
    }
}
