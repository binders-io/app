import Foundation

/// A table as GitHub writes it: a header row, a row of dashes (colons say how a column lines up), then the rows.
///
///     | Name  | Due    |
///     | ----- | -----: |
///     | Draft | Friday |
public struct MarkdownTable: Equatable, Sendable {
    public enum Alignment: Equatable, Sendable { case left, center, right }

    public struct Row: Equatable, Sendable {
        /// The line, without its line break.
        public let range: NSRange
        /// Each cell's words, without the spaces around them (zero length when empty, at the cell's start).
        public let cells: [NSRange]
        /// The "|" between and around the cells.
        public let pipes: [NSRange]
        public let isHeader: Bool
        public let isDelimiter: Bool
    }

    /// Every line of the table, from the start of the header to the end of the last row, line breaks included.
    public let range: NSRange
    public let rows: [Row]
    public let alignments: [Alignment]
    public var columns: Int { alignments.count }
}

public enum MarkdownTables {
    /// Whether a line could be a row: it starts with "|", after at most three spaces.
    public static func looksLikeRow(_ string: NSString, line: NSRange) -> Bool {
        var index = line.location
        let end = NSMaxRange(line)
        while index < end, index - line.location <= 3, string.character(at: index) == 0x20 { index += 1 }
        return index < end && index - line.location <= 3 && string.character(at: index) == 0x7C    // |
    }

    /// The run of lines that look like rows around `location`, whole lines; nil when its line doesn't look like one.
    public static func block(around location: Int, in string: NSString) -> NSRange? {
        guard string.length > 0 else { return nil }
        let first = string.lineRange(for: NSRange(location: min(location, string.length - 1), length: 0))
        guard looksLikeRow(string, line: contentRange(first, in: string)) else { return nil }
        var block = first
        while block.location > 0 {
            let previous = string.lineRange(for: NSRange(location: block.location - 1, length: 0))
            guard looksLikeRow(string, line: contentRange(previous, in: string)) else { break }
            block = NSUnionRange(previous, block)
        }
        while NSMaxRange(block) < string.length {
            let next = string.lineRange(for: NSRange(location: NSMaxRange(block), length: 0))
            guard looksLikeRow(string, line: contentRange(next, in: string)) else { break }
            block = NSUnionRange(block, next)
        }
        return block
    }

    /// The table `location` is in, when its lines make one: the second line is the row of dashes.
    public static func table(around location: Int, in string: NSString) -> MarkdownTable? {
        guard let block = block(around: location, in: string) else { return nil }
        var lines: [NSRange] = []
        string.enumerateSubstrings(in: block, options: [.byLines, .substringNotRequired]) { _, line, _, _ in lines.append(line) }
        guard lines.count >= 2, let alignments = delimiter(string.substring(with: lines[1])) else { return nil }
        let header = cells(of: lines[0], in: string)
        guard header.cells.count == alignments.count else { return nil }
        var rows: [MarkdownTable.Row] = []
        for (index, line) in lines.enumerated() {
            let parsed = cells(of: line, in: string)
            rows.append(MarkdownTable.Row(range: line, cells: parsed.cells, pipes: parsed.pipes, isHeader: index == 0, isDelimiter: index == 1))
        }
        return MarkdownTable(range: block, rows: rows, alignments: alignments)
    }

    /// The line without its line break.
    private static func contentRange(_ line: NSRange, in string: NSString) -> NSRange {
        var length = line.length
        while length > 0, [0x0A, 0x0D].contains(string.character(at: line.location + length - 1)) { length -= 1 }
        return NSRange(location: line.location, length: length)
    }

    private static let delimiterCell = try! NSRegularExpression(pattern: #"^\s*(:?)-{3,}(:?)\s*$"#)

    /// The alignments a row of dashes gives, or nil when it isn't one.
    static func delimiter(_ line: String) -> [MarkdownTable.Alignment]? {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("|") else { return nil }
        trimmed.removeFirst()
        if trimmed.hasSuffix("|") { trimmed.removeLast() }
        let parts = trimmed.components(separatedBy: "|")
        var alignments: [MarkdownTable.Alignment] = []
        for part in parts {
            guard let match = delimiterCell.firstMatch(in: part, range: NSRange(location: 0, length: (part as NSString).length)) else { return nil }
            let left = match.range(at: 1).length > 0, right = match.range(at: 2).length > 0
            alignments.append(left && right ? .center : right ? .right : .left)
        }
        return alignments.isEmpty ? nil : alignments
    }

    /// The pipes of a row, and the words between them. A "\|" or a pipe in `code` is part of the words.
    static func cells(of line: NSRange, in string: NSString) -> (cells: [NSRange], pipes: [NSRange]) {
        var pipes: [NSRange] = []
        var inCode = false
        var index = line.location
        while index < NSMaxRange(line) {
            let character = string.character(at: index)
            if character == 0x60 { inCode.toggle() }    // `
            if character == 0x7C, !inCode, index == line.location || string.character(at: index - 1) != 0x5C {    // | not after \
                pipes.append(NSRange(location: index, length: 1))
            }
            index += 1
        }
        var cells: [NSRange] = []
        for (index, pipe) in pipes.enumerated() {
            let start = NSMaxRange(pipe)
            let end = index + 1 < pipes.count ? pipes[index + 1].location : NSMaxRange(line)
            // Words after the last pipe make a cell of their own; nothing after it is just the row's end.
            if index + 1 == pipes.count, string.substring(with: NSRange(location: start, length: end - start)).trimmingCharacters(in: .whitespaces).isEmpty {
                break
            }
            var from = start, to = end
            while from < to, string.character(at: from) == 0x20 || string.character(at: from) == 0x09 { from += 1 }
            while to > from, string.character(at: to - 1) == 0x20 || string.character(at: to - 1) == 0x09 { to -= 1 }
            // An empty cell is typed into after a space, so its words end up "| like this |".
            if from == to { from = min(start + 1, end); to = from }
            cells.append(NSRange(location: from, length: to - from))
        }
        return (cells, pipes)
    }
}
