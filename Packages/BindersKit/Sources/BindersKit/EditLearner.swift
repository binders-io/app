import Foundation

public struct LearnedCorrection: Equatable, Sendable {
    public var heard: String
    public var corrected: String

    public init(heard: String, corrected: String) {
        self.heard = heard
        self.corrected = corrected
    }
}

/// Learns dictionary words from edits the user makes right after a dictation is pasted.
public enum EditLearner {
    /// Returns what the pasted region became, if the surrounding text is unchanged.
    public static func editedRegion(initialValue: String, inserted: String, finalValue: String) -> String? {
        guard !inserted.isEmpty, let range = initialValue.range(of: inserted, options: .backwards) else { return nil }
        let prefix = String(initialValue[..<range.lowerBound])
        let suffix = String(initialValue[range.upperBound...])
        guard finalValue.count >= prefix.count + suffix.count,
              finalValue.hasPrefix(prefix), finalValue.hasSuffix(suffix) else { return nil }
        let start = finalValue.index(finalValue.startIndex, offsetBy: prefix.count)
        let end = finalValue.index(finalValue.endIndex, offsetBy: -suffix.count)
        guard start <= end else { return nil }
        return String(finalValue[start..<end])
    }

    public static func corrections(inserted: String, edited: String, isKnownWord: (String) -> Bool) -> [LearnedCorrection] {
        let a = TextNorm.words(inserted)
        let b = TextNorm.words(edited)
        guard !a.isEmpty, !b.isEmpty, a.count <= 400, b.count <= 400 else { return [] }
        let na = a.map(TextNorm.normalizeWord)
        let nb = b.map(TextNorm.normalizeWord)

        // Exact-token LCS (case-sensitive on trimmed words so case fixes register as edits).
        let ta = a.map(trimPunctuation), tb = b.map(trimPunctuation)
        var dp = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                dp[i][j] = ta[i] == tb[j] ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
            }
        }

        var blocks: [(deleted: [Int], inserted: [Int])] = []
        var current: (deleted: [Int], inserted: [Int]) = ([], [])
        var i = 0, j = 0
        func flush() {
            if !current.deleted.isEmpty || !current.inserted.isEmpty { blocks.append(current) }
            current = ([], [])
        }
        while i < a.count || j < b.count {
            if i < a.count, j < b.count, ta[i] == tb[j] {
                flush()
                i += 1; j += 1
            } else if j < b.count, i == a.count || dp[i][j + 1] >= dp[i + 1][j] {
                current.inserted.append(j); j += 1
            } else {
                current.deleted.append(i); i += 1
            }
        }
        flush()

        // A heavy rewrite isn't a spelling correction.
        guard blocks.count <= 4 else { return [] }

        var results: [LearnedCorrection] = []
        for block in blocks {
            guard (1...2).contains(block.deleted.count), (1...3).contains(block.inserted.count) else { continue }
            let heard = block.deleted.map { na[$0] }.joined(separator: " ")
            let correctedWords = block.inserted.map { tb[$0] }.filter { !$0.isEmpty }
            let corrected = correctedWords.joined(separator: " ")
            guard !corrected.isEmpty, corrected.count <= 30, corrected.contains(where: { $0.isLetter }) else { continue }
            _ = nb

            let heardCompact = TextNorm.compact(heard)
            let correctedCompact = TextNorm.compact(corrected)
            guard !heardCompact.isEmpty else { continue }
            let caseOnly = heardCompact == correctedCompact
            if !caseOnly, TextNorm.similarity(heardCompact, correctedCompact) < 0.5 { continue }

            let hasInnerCapital = correctedWords.contains { $0.dropFirst().contains(where: { $0.isUppercase }) }
            let hasUnknownWord = correctedWords.contains { !isKnownWord($0.lowercased()) }
            if caseOnly {
                // "binders" -> "Binders" is useful; "the" -> "The" is not.
                guard hasUnknownWord || hasInnerCapital else { continue }
            } else {
                guard hasUnknownWord || hasInnerCapital || correctedWords.contains(where: { $0.first?.isUppercase == true }) else { continue }
            }
            let correction = LearnedCorrection(heard: heard, corrected: corrected)
            if !results.contains(correction) { results.append(correction) }
        }
        return results
    }

    static func trimPunctuation(_ word: String) -> String {
        word.trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.symbols).subtracting(CharacterSet(charactersIn: "#+@")))
    }
}
