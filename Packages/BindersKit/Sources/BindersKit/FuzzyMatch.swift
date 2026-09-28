import Foundation

/// Matching a few typed letters to a title, the way quick switchers do: "lrr" finds "Launch readiness review".
public enum FuzzyMatch {
    /// How well `query` matches `text`, higher is better; nil when its letters don't all appear in `text`, in order.
    /// Case and accents don't matter. Letters that start words, run together, or come early count for more, and a title
    /// that contains the query as it was typed beats any scattered match.
    public static func score(_ query: String, in text: String) -> Int? {
        let typed = fold(query).trimmingCharacters(in: .whitespaces)
        let letters = Array(typed.filter { !$0.isWhitespace })
        guard !letters.isEmpty else { return 0 }
        let title = fold(text)
        let characters = Array(title)
        var score = 0, index = 0, matched = 0, previous = -2, first = -1
        while index < characters.count, matched < letters.count {
            if characters[index] == letters[matched] {
                var points = 1
                if index == previous + 1 { points += 5 }
                if index == 0 || !(characters[index - 1].isLetter || characters[index - 1].isNumber) { points += 8 }
                score += points
                if first < 0 { first = index }
                previous = index
                matched += 1
            }
            index += 1
        }
        guard matched == letters.count else { return nil }
        if title.hasPrefix(typed) {
            score += 30
        } else if title.contains(typed) {
            score += 20
        }
        return score - min(first, 10) - min((characters.count - letters.count) / 8, 10)
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
