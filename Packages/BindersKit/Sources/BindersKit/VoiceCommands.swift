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

    // MARK: To-dos and calendar

    /// "Add to-do call Sam tomorrow", "remind me to send the deck by Friday", "add buy milk to my to-do list".
    /// Returns the to-do as spoken; `CommitmentDetection.splitDue` takes the time off the end.
    ///
    /// `explicitOnly` is for plain dictation, where only the forms nobody would type into a message count: "remind me to…"
    /// is something people write to each other, "add to-do…" is not.
    public static func parseTodo(_ instruction: String, explicitOnly: Bool = false) -> String? {
        let todo = "(?:to[- ]?do|task|reminder)"
        var patterns = [
            "(?i)^(?:hey\\s+)?(?:add|create|make|new)\\s+(?:a\\s+|another\\s+|new\\s+)?\(todo)(?:\\s+(?:to|on|in)\\s+(?:my\\s+|the\\s+)?(?:\(todo)\\s+)?list)?[,:]?\\s+(?:to\\s+)?(.+)$",
            "(?i)^(?:hey\\s+)?(?:add|put)\\s+(.+?)\\s+(?:to|on|in)\\s+(?:my\\s+|the\\s+)?\(todo)\\s+list$",
        ]
        if !explicitOnly {
            patterns += [
                "(?i)^(?:hey\\s+)?remind me to\\s+(.+)$",
                "(?i)^(?:hey\\s+)?note to self[,:]?\\s+(.+)$",
            ]
        }
        return firstCapture(in: trimmed(instruction), patterns: patterns)
    }

    public enum CalendarRequest: Equatable, Sendable {
        /// "Add it to my calendar", or just "add to my calendar": the event is in what was just dictated, or in the selected text.
        case fromContext
        /// "Add lunch with Sam tomorrow at noon to my calendar".
        case described(String)
    }

    /// "Add it to my calendar", "put lunch with Sam tomorrow at noon on my calendar", "schedule a call with Noah Friday at 2".
    /// With `explicitOnly` (plain dictation) "schedule…" and "calendar:…" don't count; they could be the start of a sentence.
    public static func parseCalendarAdd(_ instruction: String, explicitOnly: Bool = false) -> CalendarRequest? {
        let text = trimmed(instruction)
        let calendar = "(?:to|on|in|into|onto)\\s+(?:my\\s+|the\\s+)?calendar"
        if text.range(of: "(?i)^(?:hey\\s+)?(?:add|put|save|stick)\\s+(?:(?:it|that|this|these|those)\\s+)?\(calendar)$", options: .regularExpression) != nil {
            return .fromContext
        }
        var patterns = [
            "(?i)^(?:hey\\s+)?(?:add|put|create|schedule)\\s+\(calendar)[,:]?\\s+(.+)$",
            "(?i)^(?:hey\\s+)?(?:add|put)\\s+(.+?)\\s+\(calendar)$",
        ]
        if !explicitOnly {
            patterns.append("(?i)^(?:hey\\s+)?(?:schedule|calendar)[,:]?\\s+(.+)$")
        }
        return firstCapture(in: text, patterns: patterns).map { .described($0) }
    }

    private static func trimmed(_ instruction: String) -> String {
        instruction.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".!?")))
    }

    /// The first pattern's capture group 1, trimmed; nil when nothing matches or the capture is empty.
    private static func firstCapture(in text: String, patterns: [String]) -> String? {
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), match.numberOfRanges > 1 else { continue }
            let capture = (text as NSString).substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !capture.isEmpty { return capture }
        }
        return nil
    }
}
