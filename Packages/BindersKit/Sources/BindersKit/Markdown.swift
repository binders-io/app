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
    case rule
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
        let string = text as NSString
        var spans: [MarkdownSpan] = []
        var inFence = false
        string.enumerateSubstrings(in: NSRange(location: 0, length: string.length), options: [.byLines, .substringNotRequired]) { _, line, _, _ in
            let content = string.substring(with: line)
            if Self.isFence(content) {
                spans.append(MarkdownSpan(line, .codeFence))
                inFence.toggle()
                return
            }
            if inFence {
                spans.append(MarkdownSpan(line, .codeBlock))
                return
            }
            spans += Self.lineSpans(content, at: line.location)
        }
        return spans
    }

    /// Where the fenced code blocks are, as ranges of whole lines including their fences; an unclosed fence runs to the
    /// end. Edits that add or remove a fence change how everything after them looks.
    public static func fenceCount(in text: String) -> Int {
        var count = 0
        (text as NSString).enumerateSubstrings(in: NSRange(location: 0, length: (text as NSString).length), options: .byLines) { line, _, _, _ in
            if let line, isFence(line) { count += 1 }
        }
        return count
    }

    public static func isFence(_ line: String) -> Bool {
        let trimmed = line.drop { $0 == " " }
        return line.count - trimmed.count <= 3 && (trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~"))
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
        for match in linkPattern.matches(in: line, range: range) where free(match.range) {
            let label = match.range(at: 1), url = match.range(at: 2)
            spans.append(MarkdownSpan(label, .link))
            spans.append(MarkdownSpan(NSRange(location: match.range.location, length: 1), .syntax))
            spans.append(MarkdownSpan(NSRange(location: label.upperBound, length: url.location - label.upperBound), .syntax))
            spans.append(MarkdownSpan(url, .linkURL))
            spans.append(MarkdownSpan(NSRange(location: match.range.upperBound - 1, length: 1), .syntax))
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
