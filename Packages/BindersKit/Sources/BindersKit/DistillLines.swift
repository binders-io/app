import Foundation

// Lane DS8: Distill reads fast. The note goes to the model as numbered lines, and each item it writes names the lines it
// comes from instead of copying them out (`DistillFormat.v2`): from those the app takes the quote the note marks, the
// section, and a first brief, so the model writes a quarter of what it did.

/// How Distill asks its model for a note's work items: `v1` as lanes DS1 to DS7 left it (each item with its brief, done
/// when, section and quote written out), `v2` with the note's lines numbered and each item naming its lines (lane DS8).
/// v2 unless `defaults write io.binders.mac distillFormat v1`, for comparing (the bench has `--format v1|v2`).
public enum DistillFormat: String, Codable, CaseIterable, Sendable {
    case v1, v2

    /// The format a setting names; v2 for none, or one this build doesn't know.
    public init(setting: String?) {
        self = setting.flatMap { DistillFormat(rawValue: $0.lowercased()) } ?? .v2
    }

    /// Tokens an item is expected to take, for sizing a slow model's parts: v1's brief, done when and 25-word quote made
    /// about 120; v2's title, lines, for and size about 30 (measured with the stand-in's replies; the bench measures the
    /// real model's).
    public var tokensPerItem: Int {
        switch self {
        case .v1: DistillPrompt.maxTokens / DistillPrompt.maxItems
        case .v2: 30
        }
    }

    /// Tokens of answer allowed for an item: room over the expected, for long titles.
    public var replyTokensPerItem: Int {
        switch self {
        case .v1: DistillPrompt.maxTokens / DistillPrompt.maxItems
        case .v2: 48
        }
    }

    /// How long the answer may be for `DistillPrompt.maxItems` items.
    public var maxTokens: Int { DistillPrompt.maxItems * replyTokensPerItem }

    /// Characters of answer for a character of note (`DistillSpeed.answerShare`): about 25 items of 450 characters for
    /// 16,000 characters in v1, of 100 in v2.
    public var answerShare: Double {
        switch self {
        case .v1: 0.6
        case .v2: 0.15
        }
    }
}

/// A part of a note as v2's reader sees it: each line with a short number ("12| …"), a paragraph over `longLine`
/// characters cut at its sentences' ends so a number points at a sentence, a fenced code block (a Mermaid diagram among
/// them) kept whole under one number, and headings shown as they are, without one: they're where the lines are, not work.
/// Numbers start at 1 for each part, so they stay short. Blank lines have none.
public struct DistillLines: Equatable, Sendable {
    public struct Line: Equatable, Sendable {
        /// Its number; 0 for a heading, which has none.
        public var id: Int
        /// As the note writes it: a whole fenced block, or a sentence or more of a long paragraph.
        public var text: String
        /// The "## " heading above it, as `MarkdownSyntax.plainTitle` gives it; nil for the note's opening.
        public var section: String?
        /// A heading's level (1 to 6); 0 for a line that isn't one.
        public var level: Int
    }

    /// A paragraph longer than this is cut into its sentences.
    public static let longLine = 300
    /// Sentences shorter than this go with the next one.
    static let shortSentence = 60
    /// The most lines an item may name.
    public static let maxPerItem = 4

    public private(set) var lines: [Line]

    /// `text` numbered from 1. `section`: the heading the text starts under, when it doesn't start with one (a piece of a
    /// long section starts with its heading again, so this is for a caller's own text).
    public init(_ text: String, section: String? = nil) {
        var lines: [Line] = []
        var section = section
        var next = 1
        var fence: [String]?
        func add(_ text: String) {
            lines.append(Line(id: next, text: text, section: section, level: 0))
            next += 1
        }
        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            if var open = fence {
                open.append(raw)
                if MarkdownSyntax.isFence(raw) {
                    add(open.joined(separator: "\n"))
                    fence = nil
                } else {
                    fence = open
                }
                continue
            }
            if MarkdownSyntax.isFence(raw) {
                fence = [raw]
                continue
            }
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if let level = Self.headingLevel(trimmed) {
                let title = MarkdownSyntax.plainTitle(trimmed)
                if level == 2 { section = title.isEmpty ? section : title }
                lines.append(Line(id: 0, text: trimmed, section: section, level: level))
                continue
            }
            if raw.count > Self.longLine {
                for sentence in Self.sentences(raw) { add(sentence) }
            } else {
                add(raw)
            }
        }
        // A fence never closed: what's in it is still the note's.
        if let open = fence { add(open.joined(separator: "\n")) }
        self.lines = lines
    }

    /// The numbered lines, in order.
    public var numbered: [Line] { lines.filter { $0.id > 0 } }
    /// The highest number.
    public var last: Int { lines.last { $0.id > 0 }?.id ?? 0 }

    public func line(_ id: Int) -> Line? {
        guard id > 0 else { return nil }
        return lines.first { $0.id == id }
    }

    /// What the model reads: each line with its number, a heading as it is.
    public var rendered: String {
        lines.map { $0.id > 0 ? "\($0.id)| \($0.text)" : $0.text }.joined(separator: "\n")
    }

    /// What an item's lines say: the numbers that are lines here, in the order given, once each, at most `maxPerItem`;
    /// the quote the note marks (the first of them, as the note writes it, its list marker off); the section above the
    /// first; and the lines themselves, for a first brief.
    public struct Resolved: Equatable, Sendable {
        public var ids: [Int]
        /// How many of the numbers given weren't lines here.
        public var dropped: Int
        public var quote: String?
        public var section: String?
        public var source: String
    }

    public func resolve(_ ids: [Int]) -> Resolved {
        var valid: [Int] = []
        var dropped = 0
        for id in ids {
            guard line(id) != nil else { dropped += 1; continue }
            if !valid.contains(id), valid.count < Self.maxPerItem { valid.append(id) }
        }
        let found = valid.compactMap(line)
        let quote = found.lazy.compactMap { Self.quote(of: $0.text) }.first
        let source = found.map { Self.plain($0.text) }.joined(separator: "\n")
        return Resolved(ids: valid, dropped: dropped, quote: quote, section: found.first?.section, source: source)
    }

    /// A line as a quote: its list, task or quote marker off (the rest is still the note's own words), the words the
    /// marks find; a code block's first line of code. Nil for nothing left.
    static func quote(of text: String) -> String? {
        if MarkdownSyntax.isFence(text.components(separatedBy: "\n").first ?? "") {
            let code = text.components(separatedBy: "\n").dropFirst().first { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !MarkdownSyntax.isFence($0) }
            return code.flatMap { DistillQuote.clean($0.trimmingCharacters(in: .whitespaces)) }
        }
        return DistillQuote.clean(plain(text))
    }

    /// A line without the marker in front of it.
    static func plain(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: #"^(?:>\s*)*(?:[-*+•]\s+(?:\[[ xX]\]\s+)?|\d+[.)]\s+)?"#, with: "", options: .regularExpression)
    }

    /// A "#" heading's level, or nil for a line that isn't one.
    static func headingLevel(_ line: String) -> Int? {
        var level = 0
        for character in line {
            guard character == "#" else { break }
            level += 1
        }
        guard (1...6).contains(level), line.count > level else { return nil }
        let after = line[line.index(line.startIndex, offsetBy: level)]
        return after == " " || after == "\t" ? level : nil
    }

    /// A long paragraph in sentences: cut after ".", "!", "?" or "…" (and a closing quote or bracket) before a space;
    /// a sentence under `shortSentence` goes with the one after it. The pieces keep the paragraph's own characters, so
    /// each is found in the note as it's written.
    static func sentences(_ paragraph: String) -> [String] {
        let characters = Array(paragraph)
        var pieces: [String] = []
        var current = ""
        var index = 0
        while index < characters.count {
            let character = characters[index]
            current.append(character)
            index += 1
            guard ".!?…".contains(character) else { continue }
            // A closing quote or bracket stays with its sentence.
            while index < characters.count, "\"”’')]".contains(characters[index]) {
                current.append(characters[index])
                index += 1
            }
            guard index < characters.count, characters[index] == " " else { continue }
            // "e.g. this" and "3.5 days" aren't ends: the next word starts with a capital, a digit or a quote.
            var after = index
            while after < characters.count, characters[after] == " " { after += 1 }
            guard after < characters.count, characters[after].isUppercase || characters[after].isNumber || "\"“‘([".contains(characters[after]) else { continue }
            if current.trimmingCharacters(in: .whitespaces).count >= shortSentence {
                pieces.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
                index = after
            }
        }
        let rest = current.trimmingCharacters(in: .whitespaces)
        if !rest.isEmpty {
            if rest.count < shortSentence, let last = pieces.popLast() { pieces.append(last + " " + rest) } else { pieces.append(rest) }
        }
        return pieces.isEmpty ? [paragraph] : pieces
    }
}

extension DistillReading.Result {
    /// A v2 reply's items given their lines (lane DS8): each item that named lines gets its quote, section (one of
    /// `headings`, nil for the opening) and first brief from them, the numbers that aren't lines of the part left out; an
    /// item left with no line keeps its title and has no quote. An item that named no lines (a reply written as v1's)
    /// keeps what it wrote. Then an item that names the same lines as one before it with much the same title is a repeat.
    public mutating func resolve(lines: DistillLines, headings: [String]) {
        for index in items.indices where items[index].named {
            let resolved = lines.resolve(items[index].lines)
            droppedLines += resolved.dropped
            items[index].lines = resolved.ids
            guard !resolved.ids.isEmpty else {
                items[index].quote = nil
                continue
            }
            items[index].quote = resolved.quote
            items[index].section = resolved.section.flatMap { DistillSections.match($0, in: headings) }
            items[index].unknownSection = nil
            if items[index].brief.isEmpty, items[index].doneWhen.isEmpty {
                items[index].brief = resolved.source
                items[index].briefPending = true
            }
        }
        // Repeats: the same lines, much the same title.
        var drop: [Int: Int] = [:]
        for index in items.indices where !items[index].lines.isEmpty {
            let mine = Set(items[index].lines)
            if let earlier = items.indices.prefix(index).first(where: { other in
                drop[other] == nil && !mine.isDisjoint(with: items[other].lines) && DistillAgain.similarity(items[other].title, items[index].title) >= 0.5
            }) {
                drop[index] = earlier
            }
        }
        guard !drop.isEmpty else { return }
        repeats += drop.count
        let kept = items.indices.filter { drop[$0] == nil }
        let position = Dictionary(kept.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        var lists: [[Int]] = []
        for old in kept {
            let waits = items[old].waitsFor.compactMap { target in position[drop[target] ?? target] }.filter { $0 != position[old] }
            lists.append(Array(Set(waits)).sorted())
        }
        let acyclic = CardWaits.acyclic(lists)
        droppedWaits += acyclic.dropped.count
        items = kept.enumerated().map { new, old in
            var item = items[old]
            item.waitsFor = acyclic.waits[new]
            return item
        }
    }
}
