import Foundation

/// Catches a language model that has got stuck repeating itself, so generation can stop early and the repeats can be dropped.
public enum LoopGuard {
    /// True once any substantial line has appeared `limit` times. The last line only counts when the text ends with a
    /// newline, since it may still be streaming in.
    public static func isLooping(_ text: String, limit: Int = 3, minLength: Int = 12) -> Bool {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if !text.hasSuffix("\n") { lines.removeLast() }
        var counts: [String: Int] = [:]
        for line in lines {
            let key = normalize(line)
            guard key.count >= minLength else { continue }
            counts[key, default: 0] += 1
            if counts[key]! >= limit { return true }
        }
        return false
    }

    /// Comparison key for a line: list markers, checkboxes, numbering, case, spacing and end punctuation don't count.
    public static func normalize(_ line: String) -> String {
        var text = line.trimmingCharacters(in: .whitespaces)
        text = text.replacingOccurrences(of: #"^(?:[-*•+]|\d+[.)])\s*(?:\[[ xX]\]\s*)?"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: ".,;! "))
        return text.lowercased()
    }

    public static func isBullet(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).range(of: #"^(?:[-*•+]|\d+[.)])\s"#, options: .regularExpression) != nil
    }

    /// A bullet that stops right after its owner ("- [ ] Dana —") was cut off mid-way.
    public static func isCutOff(_ key: String) -> Bool {
        ["—", "–", "-", ":"].contains { key.hasSuffix($0) }
    }
}
