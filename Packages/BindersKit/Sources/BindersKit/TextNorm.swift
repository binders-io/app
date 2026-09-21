import Foundation

/// Small, dependency-free text helpers shared by the text pipeline.
public enum TextNorm {
    /// Splits on whitespace, keeping punctuation attached to words.
    public static func words(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    /// Lowercases and strips leading/trailing punctuation and symbols.
    public static func normalizeWord(_ word: String) -> String {
        let trimmed = word.trimmingCharacters(in: CharacterSet.punctuationCharacters
            .union(.symbols)
            .union(.whitespacesAndNewlines))
        return trimmed.lowercased()
    }

    /// Normalized, non-empty words.
    public static func normalizedWords(_ text: String) -> [String] {
        words(text).map(normalizeWord).filter { !$0.isEmpty }
    }

    /// Lowercased letters and digits only ("Fluid-Audio" -> "fluidaudio").
    public static func compact(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    public static func levenshtein(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }

    /// 1.0 for identical strings, 0.0 for completely different ones.
    public static func similarity(_ a: String, _ b: String) -> Double {
        let maxLen = max(a.count, b.count)
        guard maxLen > 0 else { return 1 }
        return 1 - Double(levenshtein(a, b)) / Double(maxLen)
    }

    /// Splits camel case and letter/digit boundaries: "FluidAudio" -> ["Fluid", "Audio"], "GPT4o" -> ["GPT", "4", "o"].
    public static func splitCamelCase(_ word: String) -> [String] {
        let chars = Array(word)
        guard chars.count > 1 else { return [word] }
        var parts: [String] = []
        var current = String(chars[0])
        for i in 1..<chars.count {
            let prev = chars[i - 1], ch = chars[i]
            let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil
            var boundary = false
            if prev.isLowercase && ch.isUppercase { boundary = true }
            if prev.isLetter && ch.isNumber || prev.isNumber && ch.isLetter { boundary = true }
            if prev.isUppercase && ch.isUppercase, let next, next.isLowercase { boundary = true }
            if !ch.isLetter && !ch.isNumber || !prev.isLetter && !prev.isNumber { boundary = true }
            if boundary {
                parts.append(current)
                current = ""
            }
            if ch.isLetter || ch.isNumber { current.append(ch) }
        }
        if !current.isEmpty { parts.append(current) }
        return parts.filter { !$0.isEmpty }
    }

    /// Regex fragment matching `phrase` word-by-word with flexible separators and unicode-aware boundaries.
    public static func phrasePattern(_ phrase: String, separators: String = "[\\s\\-]+") -> String? {
        let parts = words(phrase).map { NSRegularExpression.escapedPattern(for: $0) }
        guard !parts.isEmpty else { return nil }
        return "(?<![\\p{L}\\p{N}])" + parts.joined(separator: separators) + "(?![\\p{L}\\p{N}])"
    }

    public static func collapseSpaces(_ text: String) -> String {
        var result = text.replacingOccurrences(of: "[ \\t]{2,}", with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: " +([,.;:!?])", with: "$1", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Very common English words that should never be "case-fixed" into dictionary terms.
    public static let commonWords: Set<String> = [
        "a", "about", "after", "again", "all", "also", "am", "an", "and", "any", "are", "as", "at", "back", "be",
        "because", "been", "before", "being", "best", "but", "by", "call", "can", "come", "could", "day", "did", "do",
        "does", "done", "down", "each", "even", "every", "find", "first", "for", "from", "get", "give", "go", "going",
        "good", "got", "had", "has", "have", "he", "her", "here", "him", "his", "how", "i", "if", "in", "into", "is",
        "it", "its", "just", "know", "last", "let", "like", "look", "made", "make", "many", "may", "me", "more", "most",
        "much", "must", "my", "need", "new", "no", "not", "now", "of", "off", "on", "one", "only", "or", "other", "our",
        "out", "over", "people", "please", "put", "really", "right", "said", "same", "say", "see", "she", "should",
        "so", "some", "still", "such", "take", "than", "thank", "thanks", "that", "the", "their", "them", "then",
        "there", "these", "they", "thing", "think", "this", "those", "time", "to", "too", "two", "up", "us", "use",
        "very", "want", "was", "way", "we", "well", "went", "were", "what", "when", "where", "which", "while", "who",
        "why", "will", "with", "work", "would", "yeah", "year", "yes", "yet", "you", "your", "apple", "slack", "notion",
        "linear", "cursor", "code", "window", "mail", "message", "messages", "note", "notes", "chrome", "safari",
    ]
}
