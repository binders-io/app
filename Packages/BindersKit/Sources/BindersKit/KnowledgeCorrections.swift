import Foundation

/// A correction to the knowledge base: something that was recorded wrong, and what's right. It's kept as a note anyone
/// can read ("Wrong: … Right: …", tagged #correction); searching marks what still says the wrong thing, and answers use
/// the correction instead.
public struct KnowledgeCorrection: Equatable, Sendable {
    public var wrong: String
    public var right: String
    /// The title of where the wrong thing was, linked from the correction.
    public var source: String?
    public var reason: String?

    public init(wrong: String, right: String, source: String? = nil, reason: String? = nil) {
        self.wrong = wrong.trimmingCharacters(in: .whitespacesAndNewlines)
        self.right = right.trimmingCharacters(in: .whitespacesAndNewlines)
        self.source = source?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.reason = reason?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    public static let tag = "#correction"

    /// Long enough to recognise where it's said: a few words, not a number or a name on its own, which would mark
    /// passages that have nothing to do with it.
    public var isSpecific: Bool {
        KnowledgeCorrections.normalize(wrong).split(separator: " ").count >= 3
    }

    /// The note that keeps it.
    public var markdown: String {
        let headline = right.split(whereSeparator: \.isNewline).first.map(String.init) ?? right
        var lines = ["# Correction: \(headline.count > 70 ? String(headline.prefix(69)) + "…" : headline)", "",
                     "Wrong: \(Self.oneLine(wrong))", "Right: \(Self.oneLine(right))"]
        if let source { lines.append("Where: [[\(source)]]") }
        if let reason { lines.append("Why: \(Self.oneLine(reason))") }
        lines += ["", Self.tag]
        return lines.joined(separator: "\n")
    }

    /// The correction a note keeps, when it is one.
    public static func parse(_ note: String) -> KnowledgeCorrection? {
        guard note.range(of: tag, options: .caseInsensitive) != nil else { return nil }
        var wrong: String?, right: String?, source: String?, reason: String?
        for line in note.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            func value(_ key: String) -> String? {
                guard trimmed.lowercased().hasPrefix(key.lowercased() + ":") else { return nil }
                return String(trimmed.dropFirst(key.count + 1)).trimmingCharacters(in: .whitespaces)
            }
            if let found = value("Wrong") { wrong = found }
            if let found = value("Right") { right = found }
            if let found = value("Where") { source = found.replacingOccurrences(of: "[[", with: "").replacingOccurrences(of: "]]", with: "") }
            if let found = value("Why") { reason = found }
        }
        guard let wrong, let right, !wrong.isEmpty, !right.isEmpty else { return nil }
        return KnowledgeCorrection(wrong: wrong, right: right, source: source, reason: reason)
    }

    /// Whether `text` says what this correction says is wrong: the same words, whatever the case, accents or
    /// punctuation.
    public func corrects(_ text: String) -> Bool {
        guard isSpecific else { return false }
        let needle = KnowledgeCorrections.normalize(wrong)
        return !needle.isEmpty && (" " + KnowledgeCorrections.normalize(text) + " ").contains(" " + needle + " ")
    }

    private static func oneLine(_ text: String) -> String {
        text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
    }
}

public enum KnowledgeCorrections {
    /// Lowercased, without accents or punctuation, single-spaced: for telling whether two passages say the same.
    public static func normalize(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        let spaced = folded.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(spaced).split(separator: " ").joined(separator: " ")
    }

    /// `text` with `wrong` replaced by `right`, when it appears exactly once as written (case aside).
    public static func fixing(_ text: String, wrong: String, right: String) -> String? {
        let string = text as NSString
        let first = string.range(of: wrong, options: .caseInsensitive)
        guard first.location != NSNotFound else { return nil }
        let rest = NSRange(location: NSMaxRange(first), length: string.length - NSMaxRange(first))
        guard string.range(of: wrong, options: .caseInsensitive, range: rest).location == NSNotFound else { return nil }
        return string.replacingCharacters(in: first, with: right)
    }

    /// How many times `passage` appears in `text`, exactly as written.
    public static func occurrences(of passage: String, in text: String) -> Int {
        guard !passage.isEmpty else { return 0 }
        return text.components(separatedBy: passage).count - 1
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
