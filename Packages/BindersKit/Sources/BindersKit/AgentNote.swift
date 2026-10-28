import Foundation

/// A message to an agent as a card, on the Mac's Agents page and the iPhone's: its first line, cut to a title, and the whole
/// message as the details when there's more.
public enum AgentNote {
    public static let titleLimit = 80

    public static func card(from text: String) -> (title: String, details: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let first = trimmed.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? trimmed
        var title = first.trimmingCharacters(in: .whitespaces)
        if title.count > titleLimit {
            let cut = title.prefix(titleLimit)
            title = (cut.lastIndex(of: " ").map { String(cut[..<$0]) } ?? String(cut)) + "…"
        }
        return (title, title == trimmed ? "" : trimmed)
    }
}
