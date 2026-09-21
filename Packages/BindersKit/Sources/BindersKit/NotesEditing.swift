import Foundation

/// Small edits to the notes Markdown that the UI makes directly, without the model.
public enum NotesEditing {
    /// Flips the checkbox on line `index` ("- [ ]" ↔ "- [x]"); every other line, and a non-task line, is left alone.
    public static func toggleCheckbox(in markdown: String, line index: Int) -> String {
        var lines = markdown.components(separatedBy: "\n")
        guard lines.indices.contains(index), let range = lines[index].range(of: taskPrefix, options: .regularExpression) else {
            return markdown
        }
        let line = lines[index]
        let prefix = String(line[range])
        let flipped = prefix.replacingOccurrences(of: #"\[( |x|X)\]$"#, with: isChecked(line) ? "[ ]" : "[x]", options: .regularExpression)
        lines[index] = flipped + line[range.upperBound...]
        return lines.joined(separator: "\n")
    }

    /// Whether a line is a task ("- [ ] …" or "- [x] …").
    public static func isTask(_ line: String) -> Bool {
        line.range(of: taskPrefix, options: .regularExpression) != nil
    }

    /// Whether a line is a task that has been checked off.
    public static func isChecked(_ line: String) -> Bool {
        line.range(of: #"^\s*[-*+]\s+\[[xX]\]"#, options: .regularExpression) != nil
    }

    static let taskPrefix = #"^\s*[-*+]\s+\[( |x|X)\]"#

    /// Reads a task line the way the notes write them: "- [ ] Noah — order stickers" has owner "Noah".
    /// Only a dash with spaces around it separates an owner, and a plain hyphen only after "You", so prose isn't misread.
    public static func task(from line: String) -> TaskLine? {
        guard let range = line.range(of: taskPrefix, options: .regularExpression) else { return nil }
        let text = String(line[range.upperBound...]).replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespaces)
        let done = isChecked(line)
        let dashed = #"^(You|[A-Z][\p{L}'.\-]*(?: [A-Z][\p{L}'.\-]*){0,2})\s+[—–]\s+"#
        let hyphenAfterYou = #"^You\s+-\s+"#
        if let match = text.range(of: dashed, options: .regularExpression) ?? text.range(of: hyphenAfterYou, options: .regularExpression) {
            let head = String(text[match])
            let owner = head.replacingOccurrences(of: #"\s+[—–-]\s+$"#, with: "", options: .regularExpression)
            let rest = String(text[match.upperBound...]).trimmingCharacters(in: .whitespaces)
            if !rest.isEmpty { return TaskLine(owner: owner, text: rest, done: done) }
        }
        return TaskLine(owner: nil, text: text, done: done)
    }
}

/// One task line: who it's for (when the line says), what it is, and whether it's ticked.
public struct TaskLine: Equatable, Sendable {
    public var owner: String?
    public var text: String
    public var done: Bool

    public init(owner: String?, text: String, done: Bool) {
        self.owner = owner
        self.text = text
        self.done = done
    }
}
