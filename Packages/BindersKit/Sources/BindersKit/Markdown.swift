import Foundation

/// How a stretch of a note should look in the editor. Notes stay plain Markdown; this only says how to show it.
public enum MarkdownStyle: Hashable, Sendable {
    case heading(level: Int)
    case bold, italic, strikethrough
    case inlineCode
    /// A line inside a fenced code block, and the fence lines themselves.
    case codeBlock, codeFence
    case quote
    /// "-", "*", "+" or "3." at the start of a list item.
    case listMarker
    /// The "[ ]" or "[x]" of a task, drawn as a checkbox.
    case task(checked: Bool)
    /// The words of a ticked task.
    case checkedText
    case link, linkURL
    /// A web address written as it is, which opens like a link.
    case autolink
    /// The words of a [[link]] to a note, meeting, person or binder, and what it points to.
    case wikiLink(target: String)
    /// A #tag, "#" included.
    case tag
    case rule
    /// A picture or video on a line of its own: where it is, and how wide when the caption says.
    case embed(source: String, width: Int?)
    /// A row of a table: the whole table it's in, and whether it's the header or the row of dashes under it.
    case tableRow(table: NSRange, header: Bool, delimiter: Bool)
    /// A "|" that moves on to the next column.
    case tableTab
    /// Table markup that takes no room: the spaces around a cell, the last "|", the row of dashes.
    case tableHidden
    /// A line of code, with the language its fence names ("" when none), for colouring it.
    case codeLine(language: String)
    /// Markup characters (**, `, #, >) that are shown faintly.
    case syntax
}

public struct MarkdownSpan: Hashable, Sendable {
    /// UTF-16 range, as NSString and NSTextStorage count.
    public let range: NSRange
    public let style: MarkdownStyle

    public init(_ range: NSRange, _ style: MarkdownStyle) {
        self.range = range
        self.style = style
    }
}

/// Reads Markdown into styled spans, line by line, the way a note editor needs it: fast, forgiving, and never
/// changing the text.
public enum MarkdownSyntax {
    public static func spans(in text: String) -> [MarkdownSpan] {
        spans(in: text, lines: NSRange(location: 0, length: (text as NSString).length))
    }

    /// The spans of the lines `range` touches, the same as `spans(in:)` finds there. The lines before only say whether
    /// these start inside a code block, so a keystroke costs its own paragraph, not the whole note.
    public static func spans(in text: String, lines range: NSRange) -> [MarkdownSpan] {
        let string = text as NSString
        let start = min(range.location, string.length)
        let lines = string.lineRange(for: NSRange(location: start, length: min(range.length, string.length - start)))
        var spans: [MarkdownSpan] = []
        var (count, language) = fenceState(in: string, before: lines.location)
        var inFence = count % 2 == 1
        var table: MarkdownTable?
        string.enumerateSubstrings(in: lines, options: [.byLines, .substringNotRequired]) { _, line, _, _ in
            if Self.isFence(string, line: line) {
                spans.append(MarkdownSpan(line, .codeFence))
                inFence.toggle()
                if inFence { language = Self.fenceLanguage(string, line: line) }
                return
            }
            if inFence {
                spans.append(MarkdownSpan(line, .codeBlock))
                spans.append(MarkdownSpan(line, .codeLine(language: language)))
                return
            }
            if MarkdownTables.looksLikeRow(string, line: line) {
                if table.map({ !NSLocationInRange(line.location, $0.range) }) ?? true { table = MarkdownTables.table(around: line.location, in: string) }
                if let table, let row = table.rows.first(where: { $0.range.location == line.location }) {
                    spans += Self.tableSpans(row, in: table, string: string)
                    return
                }
            }
            spans += Self.lineSpans(string.substring(with: line), at: line.location)
        }
        return spans
    }

    /// Where the fenced code blocks are, as ranges of whole lines including their fences; an unclosed fence runs to the
    /// end. Edits that add or remove a fence change how everything after them looks.
    public static func fenceCount(in text: String) -> Int {
        let string = text as NSString
        return fences(in: string, before: string.length)
    }

    /// How many fence lines start before `location`.
    private static func fences(in string: NSString, before location: Int) -> Int {
        fenceState(in: string, before: location).count
    }

    /// How many fence lines start before `location`, and the language the last one to open a block named.
    private static func fenceState(in string: NSString, before location: Int) -> (count: Int, language: String) {
        var count = 0
        var language = ""
        string.enumerateSubstrings(in: NSRange(location: 0, length: min(location, string.length)), options: [.byLines, .substringNotRequired]) { _, line, _, _ in
            guard isFence(string, line: line) else { return }
            count += 1
            if count % 2 == 1 { language = fenceLanguage(string, line: line) }
        }
        return (count, language)
    }

    /// The word after a fence's ``` or ~~~: "swift", "bash".
    static func fenceLanguage(_ string: NSString, line: NSRange) -> String {
        string.substring(with: line).trimmingCharacters(in: .whitespaces).drop { $0 == "`" || $0 == "~" }
            .split(separator: " ").first.map { String($0).lowercased() } ?? ""
    }

    /// The same as `isFence(_:)`, without making a string of the line.
    static func isFence(_ string: NSString, line: NSRange) -> Bool {
        var index = line.location
        let end = NSMaxRange(line)
        while index < end, index - line.location <= 3, string.character(at: index) == 0x20 { index += 1 }
        guard index - line.location <= 3, index + 3 <= end else { return false }
        let mark = string.character(at: index)
        guard mark == 0x60 || mark == 0x7E else { return false }    // ` or ~
        return string.character(at: index + 1) == mark && string.character(at: index + 2) == mark
    }

    /// A note's first line as a title: without the heading, quote, list or task marker in front, and without the
    /// emphasis and link markup inside. "## **Launch** plan" → "Launch plan".
    public static func plainTitle(_ line: String) -> String {
        if let known = titles.object(forKey: line as NSString) { return known as String }
        let title = makePlainTitle(line)
        titles.setObject(title as NSString, forKey: line as NSString)
        return title
    }

    /// Lists show every note's title each time they redraw; most first lines don't change between redraws.
    private static let titles: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 5000
        return cache
    }()

    private static func makePlainTitle(_ line: String) -> String {
        var title = line.trimmingCharacters(in: .whitespaces)
        for prefix in [#"^#{1,6}[ \t]+"#, #"^>[ \t]?"#, #"^[-*+][ \t]+\[[ xX]\][ \t]+"#, #"^[-*+][ \t]+"#] {
            title = title.replacingOccurrences(of: prefix, with: "", options: .regularExpression)
        }
        title = title.replacingOccurrences(of: #"\[([^\]\n]+)\]\([^)\s]+\)"#, with: "$1", options: .regularExpression)
        for marker in ["**", "__", "~~", "`"] { title = title.replacingOccurrences(of: marker, with: "") }
        return title.trimmingCharacters(in: .whitespaces)
    }

    public static func isFence(_ line: String) -> Bool {
        let trimmed = line.drop { $0 == " " }
        return line.count - trimmed.count <= 3 && (trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~"))
    }

    // MARK: Tables

    static func tableSpans(_ row: MarkdownTable.Row, in table: MarkdownTable, string: NSString) -> [MarkdownSpan] {
        var spans = [MarkdownSpan(row.range, .tableRow(table: table.range, header: row.isHeader, delimiter: row.isDelimiter))]
        if row.isDelimiter {
            spans.append(MarkdownSpan(row.range, .tableHidden))
            return spans
        }
        guard let first = row.pipes.first else { return spans }
        if first.location > row.range.location {
            spans.append(MarkdownSpan(NSRange(location: row.range.location, length: first.location - row.range.location), .tableHidden))
        }
        for (index, pipe) in row.pipes.enumerated() {
            spans.append(MarkdownSpan(pipe, index < row.cells.count ? .tableTab : .tableHidden))
        }
        let line = string.substring(with: row.range)
        for (index, cell) in row.cells.enumerated() {
            let opening = row.pipes[index]
            let closing = index + 1 < row.pipes.count ? row.pipes[index + 1].location : NSMaxRange(row.range)
            let before = NSRange(location: NSMaxRange(opening), length: cell.location - NSMaxRange(opening))
            let after = NSRange(location: NSMaxRange(cell), length: closing - NSMaxRange(cell))
            if before.length > 0 { spans.append(MarkdownSpan(before, .tableHidden)) }
            if after.length > 0 { spans.append(MarkdownSpan(after, .tableHidden)) }
            let local = NSRange(location: cell.location - row.range.location, length: cell.length)
            spans += inlineSpans(line, in: local).map { MarkdownSpan(NSRange(location: $0.range.location + row.range.location, length: $0.range.length), $0.style) }
        }
        return spans
    }

    // MARK: Lines

    private static let heading = try! NSRegularExpression(pattern: #"^(#{1,6})[ \t]+"#)
    private static let rule = try! NSRegularExpression(pattern: #"^ {0,3}(?:(?:\*[ \t]*){3,}|(?:-[ \t]*){3,}|(?:_[ \t]*){3,})$"#)
    private static let quote = try! NSRegularExpression(pattern: #"^ {0,3}>[ \t]?"#)
    private static let task = try! NSRegularExpression(pattern: #"^([ \t]*)([-*+])[ \t]+(\[[ xX]\])(?=[ \t]|$)"#)
    private static let bullet = try! NSRegularExpression(pattern: #"^([ \t]*)([-*+])[ \t]+"#)
    private static let ordered = try! NSRegularExpression(pattern: #"^([ \t]*)(\d{1,9}[.)])[ \t]+"#)

    static func lineSpans(_ line: String, at offset: Int) -> [MarkdownSpan] {
        let string = line as NSString
        let whole = NSRange(location: 0, length: string.length)
        func shifted(_ range: NSRange) -> NSRange { NSRange(location: range.location + offset, length: range.length) }
        var spans: [MarkdownSpan] = []
        var body = whole

        if rule.firstMatch(in: line, range: whole) != nil {
            return [MarkdownSpan(shifted(whole), .rule)]
        }
        if let embed = MarkdownMedia.embed(inLine: line, at: offset) {
            // Everything but the caption is markup.
            var spans = [MarkdownSpan(embed.range, .embed(source: embed.source, width: embed.width))]
            if let caption = embed.captionRange {
                spans.append(MarkdownSpan(NSRange(location: embed.range.location, length: caption.location - embed.range.location), .syntax))
                spans.append(MarkdownSpan(NSRange(location: caption.upperBound, length: embed.range.upperBound - caption.upperBound), .syntax))
            } else {
                spans.append(MarkdownSpan(embed.range, .syntax))
            }
            return spans
        }
        if let match = heading.firstMatch(in: line, range: whole) {
            spans.append(MarkdownSpan(shifted(whole), .heading(level: match.range(at: 1).length)))
            spans.append(MarkdownSpan(shifted(match.range), .syntax))
            body = NSRange(location: match.range.upperBound, length: whole.length - match.range.upperBound)
        } else if let match = quote.firstMatch(in: line, range: whole) {
            spans.append(MarkdownSpan(shifted(whole), .quote))
            spans.append(MarkdownSpan(shifted(match.range), .syntax))
            body = NSRange(location: match.range.upperBound, length: whole.length - match.range.upperBound)
        } else if let match = task.firstMatch(in: line, range: whole) {
            let box = match.range(at: 3)
            let checked = string.substring(with: box).lowercased() == "[x]"
            spans.append(MarkdownSpan(shifted(match.range(at: 2)), .listMarker))
            spans.append(MarkdownSpan(shifted(box), .task(checked: checked)))
            body = NSRange(location: box.upperBound, length: whole.length - box.upperBound)
            // The words only, so the strike doesn't start on the space before them.
            let words = string.rangeOfCharacter(from: CharacterSet.whitespaces.inverted, options: [], range: body)
            if checked, words.location != NSNotFound {
                spans.append(MarkdownSpan(shifted(NSRange(location: words.location, length: body.upperBound - words.location)), .checkedText))
            }
        } else if let match = bullet.firstMatch(in: line, range: whole) ?? ordered.firstMatch(in: line, range: whole) {
            spans.append(MarkdownSpan(shifted(match.range(at: 2)), .listMarker))
            body = NSRange(location: match.range.upperBound, length: whole.length - match.range.upperBound)
        }
        spans += inlineSpans(line, in: body).map { MarkdownSpan(shifted($0.range), $0.style) }
        return spans
    }

    // MARK: Inline

    private static let code = try! NSRegularExpression(pattern: #"(`+)(?!`)(.+?)(?<!`)\1(?!`)"#)
    private static let linkPattern = try! NSRegularExpression(pattern: #"\[([^\]\n]+)\]\(([^)\s]+)\)"#)
    private static let boldPattern = try! NSRegularExpression(pattern: #"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#)
    private static let italicPattern = try! NSRegularExpression(pattern: #"(?<![*\w])\*(?![*\s])(.+?)(?<![*\s])\*(?!\*)|(?<![_\w])_(?![_\s])(.+?)(?<![_\s])_(?![_\w])"#)
    private static let strikePattern = try! NSRegularExpression(pattern: #"~~(?=\S)(.+?)(?<=\S)~~"#)
    /// A web or mail address, without the punctuation that ends the sentence around it.
    private static let autolinkPattern = try! NSRegularExpression(pattern: #"(?<![\w@/.(<\[])(?:https?://|mailto:)[^\s<>\[\]"'`]*[^\s<>\[\]"'`.,;:!?)]"#)

    static func inlineSpans(_ line: String, in range: NSRange) -> [MarkdownSpan] {
        guard range.length > 0 else { return [] }
        var spans: [MarkdownSpan] = []
        var taken: [NSRange] = []
        func free(_ candidate: NSRange) -> Bool { !taken.contains { NSIntersectionRange($0, candidate).length > 0 } }

        for match in code.matches(in: line, range: range) {
            let ticks = match.range(at: 1).length
            spans.append(MarkdownSpan(match.range, .inlineCode))
            spans.append(MarkdownSpan(NSRange(location: match.range.location, length: ticks), .syntax))
            spans.append(MarkdownSpan(NSRange(location: match.range.upperBound - ticks, length: ticks), .syntax))
            taken.append(match.range)
        }
        // [[Title]] and [[Title|shown as]]: the brackets, and the title when something else is shown, are markup.
        for match in WikiLinks.pattern.matches(in: line, range: range) where free(match.range) {
            let target = match.range(at: 1), alias = match.range(at: 2)
            let name = (line as NSString).substring(with: target).trimmingCharacters(in: .whitespaces)
            spans.append(MarkdownSpan(NSRange(location: match.range.location, length: 2), .syntax))
            if alias.location != NSNotFound {
                spans.append(MarkdownSpan(NSRange(location: target.location, length: alias.location - target.location), .syntax))
                spans.append(MarkdownSpan(alias, .wikiLink(target: name)))
            } else {
                spans.append(MarkdownSpan(target, .wikiLink(target: name)))
            }
            spans.append(MarkdownSpan(NSRange(location: match.range.upperBound - 2, length: 2), .syntax))
            taken.append(match.range)
        }
        for match in NoteTags.pattern.matches(in: line, range: range) where free(match.range) {
            spans.append(MarkdownSpan(match.range, .tag))
            taken.append(match.range)
        }
        for match in linkPattern.matches(in: line, range: range) where free(match.range) {
            let label = match.range(at: 1), url = match.range(at: 2)
            spans.append(MarkdownSpan(label, .link))
            spans.append(MarkdownSpan(NSRange(location: match.range.location, length: 1), .syntax))
            spans.append(MarkdownSpan(NSRange(location: label.upperBound, length: url.location - label.upperBound), .syntax))
            spans.append(MarkdownSpan(url, .linkURL))
            spans.append(MarkdownSpan(NSRange(location: match.range.upperBound - 1, length: 1), .syntax))
            taken.append(match.range)
        }
        // Underscores and asterisks in an address are part of it, not emphasis.
        for match in autolinkPattern.matches(in: line, range: range) where free(match.range) {
            spans.append(MarkdownSpan(match.range, .autolink))
            taken.append(match.range)
        }
        func delimited(_ pattern: NSRegularExpression, _ style: MarkdownStyle, marker: (NSTextCheckingResult) -> Int) {
            for match in pattern.matches(in: line, range: range) where free(match.range) {
                let length = marker(match)
                spans.append(MarkdownSpan(match.range, style))
                spans.append(MarkdownSpan(NSRange(location: match.range.location, length: length), .syntax))
                spans.append(MarkdownSpan(NSRange(location: match.range.upperBound - length, length: length), .syntax))
            }
        }
        delimited(boldPattern, .bold) { $0.range(at: 1).length }
        delimited(strikePattern, .strikethrough) { _ in 2 }
        delimited(italicPattern, .italic) { _ in 1 }
        return spans
    }
}

/// A heading in a note, for its outline: how deep, its words, and where it starts (UTF-16).
public struct MarkdownHeading: Equatable, Identifiable, Sendable {
    public let level: Int
    public let title: String
    public let location: Int
    public var id: Int { location }
}

public enum MarkdownOutline {
    /// The note's headings in order, leaving out lines inside code blocks, which only look like headings.
    public static func headings(in text: String) -> [MarkdownHeading] {
        var result: [MarkdownHeading] = []
        var inCode = false
        let string = text as NSString
        // Line by line without making strings of them: only a line that starts with # is worth a closer look.
        string.enumerateSubstrings(in: NSRange(location: 0, length: string.length), options: [.byLines, .substringNotRequired]) { _, line, _, _ in
            if MarkdownSyntax.isFence(string, line: line) {
                inCode.toggle()
                return
            }
            guard !inCode, line.length > 1, string.character(at: line.location) == 0x23 else { return }    // #
            var level = 0
            while level < line.length, string.character(at: line.location + level) == 0x23 { level += 1 }
            guard level <= 6, level < line.length else { return }
            let after = string.character(at: line.location + level)
            guard after == 0x20 || after == 0x09 else { return }
            let title = MarkdownSyntax.plainTitle(string.substring(with: line))
            if !title.isEmpty { result.append(MarkdownHeading(level: level, title: title, location: line.location)) }
        }
        return result
    }
}
