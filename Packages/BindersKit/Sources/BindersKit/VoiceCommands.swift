import Foundation

public enum VoiceCommands {
    private static let trailingEnter = "(?i)[\\s,.;:!?]*(?<![\\p{L}])(?:press|hit)\\s+(?:enter|return)[\\s.!]*$"

    /// Detects a trailing "press enter" / "hit return" and strips it.
    public static func extractTrailingEnter(_ text: String) -> (text: String, pressEnter: Bool) {
        guard let range = text.range(of: trailingEnter, options: .regularExpression) else {
            return (text, false)
        }
        let stripped = String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (stripped, true)
    }

    public enum SearchProvider: String, Sendable {
        case google, perplexity, chatgpt, claude, youtube

        func url(for query: String) -> URL? {
            var components: URLComponents
            switch self {
            case .google: components = URLComponents(string: "https://www.google.com/search")!
            case .perplexity: components = URLComponents(string: "https://www.perplexity.ai/search")!
            case .chatgpt: components = URLComponents(string: "https://chatgpt.com/")!
            case .claude: components = URLComponents(string: "https://claude.ai/new")!
            case .youtube:
                components = URLComponents(string: "https://www.youtube.com/results")!
                components.queryItems = [URLQueryItem(name: "search_query", value: query)]
                return components.url
            }
            components.queryItems = [URLQueryItem(name: "q", value: query)]
            return components.url
        }
    }

    /// Parses Command Mode web searches like "search Google for X", "ask Perplexity X", "ask Claude about X".
    public static func parseWebSearch(_ instruction: String) -> URL? {
        let text = instruction.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".!?")))
        let providers = "(google|perplexity|chat\\s*gpt|claude|youtube)"
        let patterns: [(String, Bool)] = [
            ("(?i)^(?:hey\\s+)?ask\\s+\(providers)[,:]?\\s+(?:to\\s+|about\\s+)?(.+)$", true),
            ("(?i)^(?:hey\\s+)?search\\s+(?:on\\s+)?\(providers)\\s+(?:for\\s+)?(.+)$", true),
            ("(?i)^(?:hey\\s+)?(?:search\\s+(?:the\\s+web|online)\\s+for|search\\s+for|google|look\\s+up)\\s+(.+)$", false),
        ]
        for (pattern, hasProvider) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { continue }
            let ns = text as NSString
            let provider: SearchProvider
            let query: String
            if hasProvider {
                let name = ns.substring(with: match.range(at: 1)).lowercased().replacingOccurrences(of: " ", with: "")
                provider = SearchProvider(rawValue: name) ?? .google
                query = ns.substring(with: match.range(at: 2))
            } else {
                provider = .google
                query = ns.substring(with: match.range(at: 1))
            }
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return provider.url(for: trimmed)
        }
        return nil
    }
}
