import Foundation

public struct SnippetDefinition: Hashable, Codable, Sendable {
    public var trigger: String
    public var expansion: String

    public init(trigger: String, expansion: String) {
        self.trigger = trigger
        self.expansion = expansion
    }
}

/// Replaces spoken snippet triggers with placeholders the LLM must preserve, then expands them afterwards.
public enum SnippetExpander {
    public struct Placeholdered: Equatable, Sendable {
        public var text: String
        /// placeholder token -> expansion
        public var placeholders: [String: String]
        /// True when the whole utterance was a single snippet trigger.
        public var isWholeMatch: Bool
    }

    public static func placeholder(_ index: Int) -> String { "⟦\(index)⟧" }

    public static func placeholderize(_ text: String, snippets: [SnippetDefinition]) -> Placeholdered {
        var output = text
        var placeholders: [String: String] = [:]
        let sorted = snippets
            .filter { !TextNorm.normalizedWords($0.trigger).isEmpty }
            .sorted { $0.trigger.count > $1.trigger.count }
        var index = 1
        for snippet in sorted {
            guard let pattern = TextNorm.phrasePattern(snippet.trigger, separators: "[\\s,.\\-!?]+"),
                  let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let ns = output as NSString
            let matches = regex.matches(in: output, range: NSRange(location: 0, length: ns.length))
            guard !matches.isEmpty else { continue }
            let token = placeholder(index)
            index += 1
            placeholders[token] = snippet.expansion
            let mutable = NSMutableString(string: output)
            for match in matches.reversed() {
                mutable.replaceCharacters(in: match.range, with: token)
            }
            output = mutable as String
        }
        var remainder = output
        for token in placeholders.keys { remainder = remainder.replacingOccurrences(of: token, with: "") }
        let leftover = remainder.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        let whole = placeholders.count == 1 && leftover.isEmpty
            && output.components(separatedBy: placeholders.keys.first!).count == 2
        return Placeholdered(text: output, placeholders: placeholders, isWholeMatch: whole)
    }

    /// Expands placeholders; returns the tokens that were expected but missing from `text`.
    public static func expand(_ text: String, placeholders: [String: String]) -> (text: String, missing: [String]) {
        var output = text
        var missing: [String] = []
        for (token, expansion) in placeholders {
            if output.contains(token) {
                output = output.replacingOccurrences(of: token, with: expansion)
            } else {
                missing.append(token)
            }
        }
        return (output, missing.sorted())
    }
}
