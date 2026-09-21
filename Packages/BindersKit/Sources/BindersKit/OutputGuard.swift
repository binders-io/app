import Foundation

/// Sanitizes LLM output and rejects responses that answered the transcript instead of cleaning it.
public enum OutputGuard {
    public static func sanitize(_ output: String) -> String {
        var text = output
        // Reasoning blocks from thinking models.
        text = text.replacingOccurrences(of: "(?s)<think>.*?</think>", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?s)^.*?</think>", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "</?(?:transcript|output|text|result|cleaned)>", with: "", options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Common preambles: "Here is the cleaned text:" on its own line or before a colon.
        let preamble = "(?i)^(?:sure[,!.]?\\s*)?(?:here(?:'s| is)(?: the)? (?:cleaned|corrected|edited|formatted|final|rewritten|revised)?\\s*(?:up\\s*)?(?:text|version|transcript|output)?)[^\\n]{0,20}:\\s*"
        text = text.replacingOccurrences(of: preamble, with: "", options: .regularExpression)

        // Whole response wrapped in a code fence.
        if text.hasPrefix("```"), text.hasSuffix("```"), text.count > 6 {
            var inner = String(text.dropFirst(3).dropLast(3))
            if let newline = inner.firstIndex(of: "\n"), !inner[..<newline].contains(" ") {
                inner = String(inner[inner.index(after: newline)...])
            }
            text = inner.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Whole response wrapped in quotes.
        for (open, close) in [("\"", "\""), ("“", "”")] where text.hasPrefix(open) && text.hasSuffix(close) && text.count > 2 {
            let inner = String(text.dropFirst().dropLast())
            if !inner.contains(open) && !inner.contains(close) { text = inner }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Heuristic: the cleaned text should mostly reuse the speaker's words and not grow much.
    public static func isPlausibleCleanup(raw: String, output: String) -> Bool {
        let rawWords = TextNorm.normalizedWords(FillerCleaner.clean(raw))
        let outWords = TextNorm.normalizedWords(output)
        guard !outWords.isEmpty else { return false }
        guard !rawWords.isEmpty else { return outWords.count <= 3 }

        if rawWords.count < 4 {
            return outWords.count <= rawWords.count * 3 + 4
        }
        if Double(outWords.count) > Double(rawWords.count) * 1.6 + 8 { return false }

        let rawSet = Set(rawWords.flatMap { [$0, TextNorm.compact($0)] })
        let outSet = Set(outWords)
        let precision = Double(outWords.filter { rawSet.contains($0) || rawSet.contains(TextNorm.compact($0)) }.count) / Double(outWords.count)
        let recall = Double(rawWords.filter { outSet.contains($0) }.count) / Double(rawWords.count)
        return precision >= 0.5 && recall >= 0.4
    }
}
