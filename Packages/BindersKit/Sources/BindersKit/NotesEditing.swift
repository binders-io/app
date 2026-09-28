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

    // MARK: Keeping ticks

    /// Ticks every task in `new` that was ticked in `old`, matched by its words, so rewriting a digest or a meeting's notes
    /// doesn't undo what the user already checked off.
    public static func carryOverTicks(from old: String, into new: String) -> String {
        let ticked = old.components(separatedBy: "\n").compactMap(task(from:)).filter(\.done).map { words($0.text) }
        guard !ticked.isEmpty else { return new }
        var lines = new.components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            guard let task = task(from: line), !task.done else { continue }
            let mine = words(task.text)
            if ticked.contains(where: { similar($0, mine) }) { lines[index] = toggleCheckbox(in: line, line: 0) }
        }
        return lines.joined(separator: "\n")
    }

    private static let stopWords: Set<String> = ["the", "and", "for", "with", "you", "your", "our", "that", "this", "from", "into",
                                                 "will", "are", "was", "can", "not", "but", "all", "any", "its"]

    static func words(_ text: String) -> Set<String> {
        Set(text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count > 2 && !stopWords.contains($0) })
    }

    /// The same task in other words: at least three quarters of the words shared. "Send Jonas the deck" and "Send Jonas the
    /// invoice" are different tasks.
    static func similar(_ a: Set<String>, _ b: Set<String>) -> Bool {
        guard !a.isEmpty, !b.isEmpty else { return false }
        return Double(a.intersection(b).count) / Double(a.union(b).count) >= 0.75
    }

    // MARK: Finding a task again

    /// A short, stable name for a task's words, so a to-do can be found again after the lines around it change. FNV-1a.
    public static func fingerprint(_ text: String) -> String {
        var hash: UInt32 = 2_166_136_261
        for byte in text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ").utf8 {
            hash = (hash ^ UInt32(byte)) &* 16_777_619
        }
        return String(format: "%08x", hash)
    }

    /// Ticks or unticks the task with this fingerprint. Nil when no task in `markdown` has it.
    public static func setTask(fingerprint wanted: String, done: Bool, in markdown: String) -> (markdown: String, task: TaskLine)? {
        let lines = markdown.components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            guard let task = task(from: line), fingerprint(task.text) == wanted else { continue }
            let updated = task.done == done ? markdown : toggleCheckbox(in: markdown, line: index)
            return (updated, TaskLine(owner: task.owner, text: task.text, done: done))
        }
        return nil
    }

    /// A task's owner as this reader should see it in a teammate's meeting or note: the teammate's "You" is the teammate,
    /// and a task for the reader is "You". `author` is the teammate's name, nil for your own items, which stay as they are.
    public static func owner(_ owner: String?, author: String?, reader: String?) -> String? {
        guard let owner, let author, !author.trimmingCharacters(in: .whitespaces).isEmpty else { return owner }
        if owner.caseInsensitiveCompare("You") == .orderedSame { return firstName(author) }
        if let reader, isName(owner, of: reader) { return "You" }
        return owner
    }

    /// A teammate's Markdown with each task's owner as `owner(_:author:reader:)` puts it, for showing it on this Mac.
    /// Lines stay where they are, so ticking a task by its line still finds it.
    public static func renamingOwners(in markdown: String, author: String?, reader: String?) -> String {
        guard author != nil else { return markdown }
        return markdown.components(separatedBy: "\n").map { line in
            guard let task = task(from: line), let from = task.owner, let to = owner(from, author: author, reader: reader), to != from,
                  let prefix = line.range(of: taskPrefix, options: .regularExpression),
                  let at = line.range(of: from, range: prefix.upperBound..<line.endIndex) else { return line }
            return line.replacingCharacters(in: at, with: to)
        }.joined(separator: "\n")
    }

    private static func firstName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init) ?? name
    }

    /// "Sam" or "Sam Rivera" for Sam Rivera.
    private static func isName(_ owner: String, of person: String) -> Bool {
        let owner = owner.trimmingCharacters(in: .whitespaces), person = person.trimmingCharacters(in: .whitespaces)
        guard !owner.isEmpty, !person.isEmpty else { return false }
        return owner.caseInsensitiveCompare(person) == .orderedSame || owner.caseInsensitiveCompare(firstName(person)) == .orderedSame
    }

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

/// Where a checklist item on the board lives, written as "note:<id>:<fingerprint>" so tools can tick it later.
public struct BoardTaskReference: Hashable, Sendable {
    public enum Place: String, Sendable { case meeting, digest, note }

    public let place: Place
    public let id: UUID
    public let fingerprint: String

    public init(place: Place, id: UUID, text: String) {
        self.place = place
        self.id = id
        self.fingerprint = NotesEditing.fingerprint(text)
    }

    public init?(_ string: String) {
        let parts = string.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, let place = Place(rawValue: parts[0]), let id = UUID(uuidString: parts[1]),
              parts[2].count == 8, parts[2].allSatisfy(\.isHexDigit) else { return nil }
        self.place = place
        self.id = id
        self.fingerprint = parts[2].lowercased()
    }

    public var string: String { "\(place.rawValue):\(id.uuidString):\(fingerprint)" }
}
