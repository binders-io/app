import Foundation

/// The note editor's commands, as pure edits of Markdown text: each takes the text and the selection (UTF-16, as
/// NSTextView counts) and returns the new text and selection.
public enum MarkdownEditing {
    public struct Edit: Equatable, Sendable {
        public let text: String
        public let selection: NSRange
    }

    // MARK: Return in a list

    public enum ReturnAction: Equatable, Sendable {
        /// An ordinary new line.
        case newline
        /// A new line, then this (the next item's marker, or the code block's indentation).
        case continueWith(String)
        /// The item was empty: remove its marker (the last `count` characters before the cursor) and end the list.
        case endList(count: Int)
    }

    private static let taskItem = try! NSRegularExpression(pattern: #"^([ \t]*)([-*+])[ \t]+\[[ xX]\][ \t]?(.*)$"#)
    private static let bulletItem = try! NSRegularExpression(pattern: #"^([ \t]*)([-*+])[ \t]+(.*)$"#)
    private static let orderedItem = try! NSRegularExpression(pattern: #"^([ \t]*)(\d{1,9})([.)])[ \t]+(.*)$"#)
    private static let quoteLine = try! NSRegularExpression(pattern: #"^ {0,3}>[ \t]?(.*)$"#)

    /// What Return should do, given the part of the line before the cursor.
    public static func returnAction(lineBeforeCursor line: String, inCodeBlock: Bool) -> ReturnAction {
        let whole = NSRange(location: 0, length: (line as NSString).length)
        func group(_ match: NSTextCheckingResult, _ index: Int) -> String {
            let range = match.range(at: index)
            return range.location == NSNotFound ? "" : (line as NSString).substring(with: range)
        }
        if inCodeBlock {
            let indent = String(line.prefix { $0 == " " || $0 == "\t" })
            return indent.isEmpty ? .newline : .continueWith(indent)
        }
        if let match = taskItem.firstMatch(in: line, range: whole) {
            if group(match, 3).trimmingCharacters(in: .whitespaces).isEmpty { return .endList(count: whole.length) }
            return .continueWith("\(group(match, 1))\(group(match, 2)) [ ] ")
        }
        if let match = orderedItem.firstMatch(in: line, range: whole) {
            if group(match, 4).trimmingCharacters(in: .whitespaces).isEmpty { return .endList(count: whole.length) }
            let next = (Int(group(match, 2)) ?? 0) + 1
            return .continueWith("\(group(match, 1))\(next)\(group(match, 3)) ")
        }
        if let match = bulletItem.firstMatch(in: line, range: whole) {
            if group(match, 3).trimmingCharacters(in: .whitespaces).isEmpty { return .endList(count: whole.length) }
            return .continueWith("\(group(match, 1))\(group(match, 2)) ")
        }
        if let match = quoteLine.firstMatch(in: line, range: whole) {
            if group(match, 1).trimmingCharacters(in: .whitespaces).isEmpty { return .endList(count: whole.length) }
            return .continueWith("> ")
        }
        return .newline
    }

    // MARK: Inline markers

    /// Bold (`**`), italic (`*`), inline code (`` ` ``) or strikethrough (`~~`): wraps the selection, unwraps it when it is
    /// already wrapped, or puts a pair of markers around the cursor.
    public static func toggleWrap(_ text: String, selection: NSRange, marker: String) -> Edit {
        let string = text as NSString
        let size = (marker as NSString).length
        if selection.length == 0 {
            let updated = string.replacingCharacters(in: selection, with: marker + marker)
            return Edit(text: updated, selection: NSRange(location: selection.location + size, length: 0))
        }
        let selected = string.substring(with: selection)
        let selectedLength = (selected as NSString).length
        if selectedLength >= 2 * size, selected.hasPrefix(marker), selected.hasSuffix(marker) {
            let inner = (selected as NSString).substring(with: NSRange(location: size, length: selectedLength - 2 * size))
            let updated = string.replacingCharacters(in: selection, with: inner)
            return Edit(text: updated, selection: NSRange(location: selection.location, length: (inner as NSString).length))
        }
        let before = NSRange(location: selection.location - size, length: size)
        let after = NSRange(location: selection.upperBound, length: size)
        if before.location >= 0, after.upperBound <= string.length,
           string.substring(with: before) == marker, string.substring(with: after) == marker {
            let outer = NSRange(location: before.location, length: selection.length + 2 * size)
            let updated = string.replacingCharacters(in: outer, with: selected)
            return Edit(text: updated, selection: NSRange(location: before.location, length: selection.length))
        }
        let updated = string.replacingCharacters(in: selection, with: marker + selected + marker)
        return Edit(text: updated, selection: NSRange(location: selection.location + size, length: selection.length))
    }

    /// A link: the selected words become its text, or a selected address its target; the cursor lands where the other
    /// half goes.
    public static func insertLink(_ text: String, selection: NSRange) -> Edit {
        let string = text as NSString
        let selected = string.substring(with: selection)
        if selected.hasPrefix("http://") || selected.hasPrefix("https://") {
            let updated = string.replacingCharacters(in: selection, with: "[](\(selected))")
            return Edit(text: updated, selection: NSRange(location: selection.location + 1, length: 0))
        }
        let updated = string.replacingCharacters(in: selection, with: "[\(selected)]()")
        return Edit(text: updated, selection: NSRange(location: selection.location + (selected as NSString).length + 3, length: 0))
    }

    // MARK: Line prefixes

    public enum LineStyle: Equatable, Sendable {
        case bullet, numbered, task, quote
        case heading(Int)
    }

    private static let anyPrefix = try! NSRegularExpression(
        pattern: #"^([ \t]*)(?:#{1,6}[ \t]+|>[ \t]?|[-*+][ \t]+\[[ xX]\][ \t]?|[-*+][ \t]+|\d{1,9}[.)][ \t]+)?"#)

    /// Turns the selected lines into a list, a checklist, a quote or a heading, or back to plain text when they
    /// already are. Other list or heading markers on those lines are replaced, and numbered lists count from 1.
    public static func toggle(_ style: LineStyle, in text: String, selection: NSRange) -> Edit {
        let string = text as NSString
        let block = string.lineRange(for: selection)
        var lines = string.substring(with: block).components(separatedBy: "\n")
        let trailingNewline = lines.count > 1 && lines.last == ""
        if trailingNewline { lines.removeLast() }

        let parsed = lines.map { line -> (indent: String, prefix: String, rest: String) in
            let range = NSRange(location: 0, length: (line as NSString).length)
            guard let match = anyPrefix.firstMatch(in: line, range: range) else { return ("", "", line) }
            let indent = (line as NSString).substring(with: match.range(at: 1))
            let prefix = (line as NSString).substring(with: NSRange(location: match.range(at: 1).upperBound,
                                                                  length: match.range.length - match.range(at: 1).length))
            return (indent, prefix, (line as NSString).substring(from: match.range.upperBound))
        }
        func has(_ prefix: String) -> Bool {
            switch style {
            case .bullet: prefix.hasPrefix("- ") && !prefix.contains("[") || prefix.hasPrefix("* ") || prefix.hasPrefix("+ ")
            case .numbered: prefix.first?.isNumber == true
            case .task: prefix.contains("[")
            case .quote: prefix.hasPrefix(">")
            case .heading(let level): prefix.hasPrefix(String(repeating: "#", count: level) + " ")
            }
        }
        let nonEmpty = parsed.filter { !$0.rest.trimmingCharacters(in: .whitespaces).isEmpty || !$0.prefix.isEmpty }
        let removing = !nonEmpty.isEmpty && nonEmpty.allSatisfy { has($0.prefix) }
        var number = 0
        let rebuilt = parsed.map { line -> String in
            if removing { return line.indent + line.rest }
            if line.rest.trimmingCharacters(in: .whitespaces).isEmpty, line.prefix.isEmpty, parsed.count > 1 { return line.indent }
            number += 1
            let marker: String
            switch style {
            case .bullet: marker = "- "
            case .numbered: marker = "\(number). "
            case .task: marker = "- [ ] "
            case .quote: marker = "> "
            case .heading(let level): marker = String(repeating: "#", count: level) + " "
            }
            if case .heading = style { return marker + line.rest }
            return line.indent + marker + line.rest
        }
        let replacement = rebuilt.joined(separator: "\n") + (trailingNewline ? "\n" : "")
        let updated = string.replacingCharacters(in: block, with: replacement)
        let length = (replacement as NSString).length - (trailingNewline ? 1 : 0)
        // One line and no selection: keep typing at its end. Several: select them all.
        if selection.length == 0, rebuilt.count == 1 {
            return Edit(text: updated, selection: NSRange(location: block.location + length, length: 0))
        }
        return Edit(text: updated, selection: NSRange(location: block.location, length: length))
    }

    /// Tab and Shift-Tab on list items: moves every selected item in or out by two spaces. Nil when the selection has a
    /// line that isn't a list item, so Tab keeps its usual meaning there.
    public static func indent(_ text: String, selection: NSRange, outdent: Bool) -> Edit? {
        let string = text as NSString
        let block = string.lineRange(for: selection)
        var lines = string.substring(with: block).components(separatedBy: "\n")
        let trailingNewline = lines.count > 1 && lines.last == ""
        if trailingNewline { lines.removeLast() }
        let isItem = try! NSRegularExpression(pattern: #"^[ \t]*(?:[-*+]|\d{1,9}[.)])[ \t]"#)
        guard !lines.isEmpty, lines.allSatisfy({ isItem.firstMatch(in: $0, range: NSRange(location: 0, length: ($0 as NSString).length)) != nil }) else { return nil }
        var firstShift = 0, total = 0
        let moved = lines.enumerated().map { index, line -> String in
            var shift: Int
            var result: String
            if outdent {
                if line.hasPrefix("\t") { result = String(line.dropFirst()); shift = -1 }
                else { let spaces = min(2, line.prefix { $0 == " " }.count); result = String(line.dropFirst(spaces)); shift = -spaces }
            } else {
                result = "  " + line; shift = 2
            }
            if index == 0 { firstShift = shift }
            total += shift
            return result
        }
        let replacement = moved.joined(separator: "\n") + (trailingNewline ? "\n" : "")
        let updated = string.replacingCharacters(in: block, with: replacement)
        let location = max(block.location, selection.location + firstShift)
        let length = selection.length == 0 ? 0 : max(0, selection.length + total - firstShift)
        return Edit(text: updated, selection: NSRange(location: location, length: length))
    }

    // MARK: Code blocks and tasks

    /// Fences the selected lines as a code block, or opens an empty one with the cursor inside.
    public static func insertCodeBlock(_ text: String, selection: NSRange) -> Edit {
        let string = text as NSString
        if selection.length == 0 {
            let line = string.lineRange(for: selection)
            let lineText = string.substring(with: line).trimmingCharacters(in: .newlines)
            if lineText.trimmingCharacters(in: .whitespaces).isEmpty {
                let lineContent = NSRange(location: line.location, length: (lineText as NSString).length)
                let updated = string.replacingCharacters(in: lineContent, with: "```\n\n```")
                return Edit(text: updated, selection: NSRange(location: line.location + 4, length: 0))
            }
            let insertAt = NSMaxRange(line) == string.length && !string.substring(with: line).hasSuffix("\n") ? string.length : NSMaxRange(line)
            let prefix = insertAt == string.length && !string.substring(with: line).hasSuffix("\n") ? "\n" : ""
            let updated = string.replacingCharacters(in: NSRange(location: insertAt, length: 0), with: prefix + "```\n\n```\n")
            return Edit(text: updated, selection: NSRange(location: insertAt + (prefix as NSString).length + 4, length: 0))
        }
        let block = string.lineRange(for: selection)
        var content = string.substring(with: block)
        let trailingNewline = content.hasSuffix("\n")
        if trailingNewline { content.removeLast() }
        let replacement = "```\n" + content + "\n```" + (trailingNewline ? "\n" : "")
        let updated = string.replacingCharacters(in: block, with: replacement)
        return Edit(text: updated, selection: NSRange(location: block.location + 4, length: (content as NSString).length))
    }

    /// Ticks or unticks the task whose checkbox is at `location` ("- [ ]" ↔ "- [x]"); nil when there is no task there.
    public static func toggleTask(_ text: String, at location: Int) -> Edit? {
        let string = text as NSString
        guard location >= 0, location <= string.length else { return nil }
        let line = string.lineRange(for: NSRange(location: min(location, max(0, string.length - 1)), length: 0))
        let content = string.substring(with: line)
        let box = try! NSRegularExpression(pattern: #"^[ \t]*[-*+][ \t]+\[([ xX])\]"#)
        guard let match = box.firstMatch(in: content, range: NSRange(location: 0, length: (content as NSString).length)) else { return nil }
        let mark = NSRange(location: line.location + match.range(at: 1).location, length: 1)
        let checked = string.substring(with: mark).lowercased() == "x"
        let updated = string.replacingCharacters(in: mark, with: checked ? " " : "x")
        return Edit(text: updated, selection: NSRange(location: mark.location, length: 0))
    }
}
