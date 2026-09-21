import Foundation

/// A personal-dictionary entry: the correct spelling plus optional misheard variants.
public struct VocabularyTerm: Hashable, Codable, Sendable {
    public var term: String
    public var aliases: [String]

    public init(term: String, aliases: [String] = []) {
        self.term = term
        self.aliases = aliases
    }
}

/// Deterministic, conservative dictionary replacement applied before and after the LLM.
public enum DictionaryMatcher {
    public struct Result: Equatable, Sendable {
        public var text: String
        public var replacements: Int
    }

    public static func apply(_ terms: [VocabularyTerm], to text: String) -> Result {
        var rules: [(pattern: String, term: String)] = []
        for entry in terms {
            let term = entry.term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty else { continue }
            var phrases = Set<String>()
            for alias in entry.aliases {
                let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty, trimmed != term { phrases.insert(trimmed) }
            }
            // Case-fix the term itself when it's distinctive enough not to clobber normal words.
            let lower = term.lowercased()
            if term.count >= 4, !TextNorm.commonWords.contains(lower) {
                phrases.insert(term)
                // "FluidAudio" spoken as "fluid audio".
                let parts = TextNorm.words(term).flatMap(TextNorm.splitCamelCase)
                if parts.count > 1, parts.count <= 4 {
                    phrases.insert(parts.joined(separator: " "))
                }
            }
            for phrase in phrases {
                if let pattern = TextNorm.phrasePattern(phrase) {
                    rules.append((pattern, term))
                }
            }
        }
        // Longest phrases first so multi-word matches win.
        rules.sort { $0.pattern.count > $1.pattern.count }

        var output = text
        var count = 0
        for rule in rules {
            guard let regex = try? NSRegularExpression(pattern: rule.pattern, options: [.caseInsensitive]) else { continue }
            let ns = output as NSString
            let matches = regex.matches(in: output, range: NSRange(location: 0, length: ns.length))
            guard !matches.isEmpty else { continue }
            let mutable = NSMutableString(string: output)
            for match in matches.reversed() {
                let found = ns.substring(with: match.range)
                if found == rule.term { continue }
                mutable.replaceCharacters(in: match.range, with: rule.term)
                count += 1
            }
            output = mutable as String
        }
        return Result(text: output, replacements: count)
    }
}
