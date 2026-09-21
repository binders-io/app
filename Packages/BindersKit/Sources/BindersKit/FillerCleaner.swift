import Foundation

/// Rule-based cleanup used when AI formatting is off or the LLM is unavailable.
public enum FillerCleaner {
    private static let fillerPattern = "(?i)(?<![\\p{L}\\p{N}])(?:u+m+|u+h+m*|e+r+m+|hmm+|mm+)(?![\\p{L}\\p{N}])[,.]?"
    private static let keepDuplicates: Set<String> = ["that", "had", "is", "no", "bye", "very", "so", "ha", "knock"]

    public static func clean(_ text: String) -> String {
        var output = text.replacingOccurrences(of: fillerPattern, with: "", options: .regularExpression)
        output = removeStutters(output)
        // Tidy punctuation left behind by removed fillers.
        output = output.replacingOccurrences(of: "\\s*,\\s*,", with: ",", options: .regularExpression)
        output = output.replacingOccurrences(of: "^[\\s,.;]+", with: "", options: .regularExpression)
        output = output.replacingOccurrences(of: ",\\s*([.!?])", with: "$1", options: .regularExpression)
        output = TextNorm.collapseSpaces(output)
        if let first = output.first, first.isLowercase, text.first.map({ $0.isUppercase || !$0.isLetter }) ?? false {
            output = first.uppercased() + output.dropFirst()
        }
        return output
    }

    /// "the the thing" -> "the thing"
    static func removeStutters(_ text: String) -> String {
        let words = TextNorm.words(text)
        guard words.count > 1 else { return text }
        var kept: [String] = []
        for word in words {
            if let last = kept.last {
                let a = TextNorm.normalizeWord(last), b = TextNorm.normalizeWord(word)
                let lastHasTrailingPunct = last.last.map { $0.isPunctuation } ?? false
                if !a.isEmpty, a == b, !lastHasTrailingPunct, !keepDuplicates.contains(a) {
                    kept[kept.count - 1] = word
                    continue
                }
            }
            kept.append(word)
        }
        return kept.joined(separator: " ")
    }
}
