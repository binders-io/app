import Foundation

/// #tags in a note, as Obsidian writes them: "#pricing", "#q4/launch". Not a heading's "# ", a "#1", or the "#part" of an
/// address.
public enum NoteTags {
    static let pattern = try! NSRegularExpression(pattern: #"(?<![\p{L}\p{N}_#/&:.\]])#(\p{L}[\p{L}\p{N}_/-]*)"#)
    private static let inlineCode = try! NSRegularExpression(pattern: "`[^`\n]*`")

    /// The tags in `text`, lowercased, in order, once each.
    public static func tags(in text: String) -> [String] {
        var seen = Set<String>()
        return ranges(in: text).map { (text as NSString).substring(with: $0).dropFirst().lowercased() }
            .filter { seen.insert($0).inserted }
    }

    /// Where each tag is, "#" included, outside code.
    public static func ranges(in text: String) -> [NSRange] {
        let string = text as NSString
        guard string.range(of: "#").location != NSNotFound else { return [] }
        let found = pattern.matches(in: text, range: NSRange(location: 0, length: string.length)).map(\.range)
        guard !found.isEmpty else { return [] }
        var code: [NSRange] = []
        var inFence = false
        string.enumerateSubstrings(in: NSRange(location: 0, length: string.length), options: [.byLines, .substringNotRequired]) { _, line, _, _ in
            let fence = MarkdownSyntax.isFence(string, line: line)
            if fence || inFence { code.append(line) }
            if fence { inFence.toggle() }
        }
        code += inlineCode.matches(in: text, range: NSRange(location: 0, length: string.length)).map(\.range)
        return found.filter { tag in !code.contains { NSIntersectionRange($0, tag).length > 0 } }
    }
}
