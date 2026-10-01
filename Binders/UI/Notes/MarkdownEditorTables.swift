import AppKit
import BindersKit

// Tables in the note editor. The text stays GitHub's Markdown; what shows is a grid: each "|" moves on to the next
// column's tab stop, the spaces around cells and the row of dashes take no room, and the lines are drawn around it.

extension NSAttributedString.Key {
    /// On every row of a table: the table, and where its columns start and end.
    static let markdownTable = NSAttributedString.Key("io.binders.markdown.table")
    /// A "|" drawn as a move to the next column.
    static let markdownTableTab = NSAttributedString.Key("io.binders.markdown.tableTab")
    /// Table markup that takes no room, even on the line being edited, so the columns stay put while you type.
    static let markdownTableHidden = NSAttributedString.Key("io.binders.markdown.tableHidden")
}

/// What each row of a table carries for drawing it.
final class TableBox: NSObject {
    let range: NSRange
    /// Where the columns start and end, from the left of the line: one more than there are columns.
    let edges: [CGFloat]

    init(range: NSRange, edges: [CGFloat]) {
        self.range = range
        self.edges = edges
    }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? TableBox else { return false }
        return other.range == range && other.edges == edges
    }

    override var hash: Int { range.location ^ (range.length << 20) ^ edges.count }
}

enum TableLayout {
    static let padding: CGFloat = 10
    static let minimumColumn: CGFloat = 56
    static let rowSpacing: CGFloat = 5

    /// The columns of `table`: each as wide as its widest cell.
    static func edges(of table: MarkdownTable, in string: NSString, font: NSFont, headerFont: NSFont) -> [CGFloat] {
        var widths = Array(repeating: minimumColumn, count: table.columns)
        for row in table.rows where !row.isDelimiter {
            for (index, cell) in row.cells.enumerated() where index < widths.count {
                let words = string.substring(with: cell).replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
                let width = (words as NSString).size(withAttributes: [.font: row.isHeader ? headerFont : font]).width
                widths[index] = max(widths[index], ceil(width) + 2 * padding)
            }
        }
        var edges: [CGFloat] = [0]
        for width in widths { edges.append(edges.last! + width) }
        return edges
    }

    /// A tab stop per column, where its words go: after its left edge, before its right edge, or in its middle.
    static func tabStops(_ edges: [CGFloat], alignments: [MarkdownTable.Alignment]) -> [NSTextTab] {
        alignments.enumerated().map { index, alignment in
            let left = edges[index], right = edges[index + 1]
            switch alignment {
            case .left: return NSTextTab(textAlignment: .left, location: left + padding)
            case .center: return NSTextTab(textAlignment: .center, location: (left + right) / 2)
            case .right: return NSTextTab(textAlignment: .right, location: right - padding)
            }
        }
    }
}

extension MarkdownStyler {
    /// A row of a table: its column stops, bold for the header, and next to nothing for the row of dashes.
    func styleTableRow(_ target: NSRange, table range: NSRange, header: Bool, delimiter: Bool, in storage: NSTextStorage,
                       layouts: inout [NSRange: (MarkdownTable, [CGFloat])]) {
        let string = storage.string as NSString
        if layouts[range] == nil, let table = MarkdownTables.table(around: range.location, in: string) {
            let bold = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
            layouts[range] = (table, TableLayout.edges(of: table, in: string, font: baseFont, headerFont: bold))
        }
        guard let (table, edges) = layouts[range] else { return }
        let style = baseParagraph.mutableCopy() as! NSMutableParagraphStyle
        style.tabStops = TableLayout.tabStops(edges, alignments: table.alignments)
        style.defaultTabInterval = 0
        style.lineSpacing = 0
        style.paragraphSpacingBefore = header ? fontSize * 0.6 + TableLayout.rowSpacing : TableLayout.rowSpacing
        style.paragraphSpacing = TableLayout.rowSpacing
        let last = table.rows.last.map { NSMaxRange($0.range) <= NSMaxRange(target) } ?? false
        if last { style.paragraphSpacing += fontSize * 0.6 }
        var attributes: [NSAttributedString.Key: Any] = [.paragraphStyle: style, .markdownTable: TableBox(range: range, edges: edges)]
        if header { attributes[.font] = NSFont.systemFont(ofSize: fontSize, weight: .semibold) }
        if delimiter {
            style.paragraphSpacingBefore = 0
            style.paragraphSpacing = 0
            style.minimumLineHeight = 1
            style.maximumLineHeight = 1
            attributes[.font] = NSFont.systemFont(ofSize: 1)
            attributes[.foregroundColor] = NSColor.clear
        }
        storage.addAttributes(attributes, range: target)
    }
}

extension MarkdownLayoutManager {
    /// The grid: a frame around the table, a tint behind the header, lines between rows and columns.
    func drawTables(in characters: NSRange, at origin: NSPoint) {
        guard let storage = textStorage, let container = textContainers.first else { return }
        let string = storage.string as NSString
        var drawn = Set<Int>()
        storage.enumerateAttribute(.markdownTable, in: characters) { value, _, _ in
            guard let box = value as? TableBox, drawn.insert(box.range.location).inserted, NSMaxRange(box.range) <= storage.length else { return }
            var rows: [(rect: NSRect, header: Bool, delimiter: Bool)] = []
            var index = 0
            string.enumerateSubstrings(in: box.range, options: [.byLines, .substringNotRequired]) { _, line, _, _ in
                defer { index += 1 }
                let glyphs = self.glyphRange(forCharacterRange: NSRange(location: line.location, length: max(1, line.length)), actualCharacterRange: nil)
                var rect = NSRect.null
                self.enumerateLineFragments(forGlyphRange: glyphs) { fragment, _, _, _, _ in rect = rect.union(fragment) }
                guard !rect.isNull else { return }
                rows.append((rect, index == 0, index == 1))
            }
            guard let first = rows.first, let last = rows.last, let right = box.edges.last else { return }
            let left = origin.x + container.lineFragmentPadding
            // From under the room above the header to above the room below the last row.
            let headerBefore = (storage.attribute(.paragraphStyle, at: box.range.location, effectiveRange: nil) as? NSParagraphStyle)?.paragraphSpacingBefore ?? 0
            let tableTop = origin.y + first.rect.minY + headerBefore - TableLayout.rowSpacing
            let lastAfter = (storage.attribute(.paragraphStyle, at: max(box.range.location, NSMaxRange(box.range) - 2), effectiveRange: nil) as? NSParagraphStyle)?.paragraphSpacing ?? 0
            let tableBottom = origin.y + last.rect.maxY - lastAfter + TableLayout.rowSpacing
            let frame = NSRect(x: left, y: tableTop, width: right, height: max(0, tableBottom - tableTop))
            let shape = NSBezierPath(roundedRect: frame, xRadius: 6, yRadius: 6)
            // The header's tint, down to the line under it.
            if rows.count > 1 {
                let headerBottom = origin.y + rows[1].rect.midY
                NSGraphicsContext.saveGraphicsState()
                shape.addClip()
                NSColor.labelColor.withAlphaComponent(0.045).setFill()
                NSRect(x: left, y: tableTop, width: right, height: headerBottom - tableTop).fill()
                NSGraphicsContext.restoreGraphicsState()
            }
            NSColor.separatorColor.setStroke()
            shape.lineWidth = 1
            shape.stroke()
            NSColor.separatorColor.setFill()
            // Between rows: under the header (where the dashes are), then between the others.
            for (position, row) in rows.enumerated() where position > 0 && position < rows.count - 1 {
                let y = row.delimiter ? origin.y + row.rect.midY : origin.y + row.rect.maxY
                NSRect(x: left, y: y - 0.5, width: right, height: 1).fill()
            }
            for edge in box.edges.dropFirst().dropLast() {
                NSRect(x: left + edge - 0.5, y: tableTop, width: 1, height: frame.height).fill()
            }
        }
    }
}

extension MarkdownTextView {
    /// The table the cursor is in, and which row and cell.
    private func tableCursor() -> (table: MarkdownTable, row: Int, cell: Int)? {
        let location = selectedRange().location
        guard let table = MarkdownTables.table(around: location, in: string as NSString),
              let row = table.rows.firstIndex(where: { NSLocationInRange(location, $0.range) || NSMaxRange($0.range) == location }),
              !table.rows[row].isDelimiter else { return nil }
        let pipes = table.rows[row].pipes
        let cell = max(0, (pipes.lastIndex { $0.location < location } ?? 0))
        return (table, row, min(cell, max(0, table.rows[row].cells.count - 1)))
    }

    /// Tab and ⇧Tab go from cell to cell; Tab in the last cell starts a new row.
    func tableTab(backward: Bool) -> Bool {
        guard let (table, row, cell) = tableCursor() else { return false }
        var targets: [NSRange] = []
        for (index, item) in table.rows.enumerated() where !item.isDelimiter {
            for found in item.cells { targets.append(found) }
            if index == row { break }
        }
        let current = targets.count - table.rows[row].cells.count + cell
        if backward {
            if current > 0 { setSelectedRange(targets[current - 1]) }
            return true
        }
        let after = table.rows.flatMap { $0.isDelimiter ? [] : $0.cells }
        if current + 1 < after.count {
            setSelectedRange(after[current + 1])
        } else {
            addTableRow(after: table.rows[row], columns: table.columns)
        }
        return true
    }

    /// Return adds a row under this one; on an empty last row it leaves the table.
    func tableReturn() -> Bool {
        guard selectedRange().length == 0, let (table, row, _) = tableCursor(), !table.rows[row].isHeader else { return false }
        let current = table.rows[row]
        let empty = current.cells.allSatisfy { $0.length == 0 }
        if empty, row == table.rows.count - 1 {
            // Out of the table: the empty row goes, and the cursor is on a line of its own after it.
            let line = (string as NSString).lineRange(for: current.range)
            replace(line, with: "\n", selection: NSRange(location: line.location + 1, length: 0))
            return true
        }
        addTableRow(after: current, columns: table.columns)
        return true
    }

    private func addTableRow(after row: MarkdownTable.Row, columns: Int) {
        let newRow = "\n|" + String(repeating: "  |", count: columns)
        replace(NSRange(location: NSMaxRange(row.range), length: 0), with: newRow, selection: NSRange(location: NSMaxRange(row.range) + 3, length: 0))
    }
}
