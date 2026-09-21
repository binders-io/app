import Foundation

/// Adds or removes a leading space so consecutive dictations join naturally with existing text.
public enum SmartSpacing {
    private static let noSpaceAfter: Set<Character> = ["(", "[", "{", "\"", "'", "“", "‘", "/", "-", "@", "#", "`", "\n", "\t", " "]
    private static let attachesToPrevious: Set<Character> = [",", ".", ";", ":", "!", "?", ")", "]", "}", "…", "%"]

    public static func adjust(_ text: String, before: String?) -> String {
        guard let before, let last = before.last, let first = text.first else { return text }
        if last.isWhitespace || noSpaceAfter.contains(last) {
            // Avoid doubled spaces.
            return last == " " && first == " " ? String(text.drop(while: { $0 == " " })) : text
        }
        if first.isWhitespace || attachesToPrevious.contains(first) { return text }
        return " " + text
    }
}
