import Foundation

/// A fenced code block whose info string is `mermaid` (lane MM1): the Mac's note editor draws it as a diagram. The note's
/// text is never changed; agents, Distill, search, the MCP server and the iPhone read the Markdown as it is.
public struct MermaidBlock: Hashable, Sendable {
    /// The whole block as whole lines, both fences included, with the closing fence's line ending when it has one.
    public let range: NSRange
    /// The opening fence's line, without its line ending.
    public let opening: NSRange
    /// The closing fence's line, without its line ending.
    public let closing: NSRange
    /// The diagram's text: the lines between the fences, less the opening fence's indent, as Markdown reads them.
    public let source: String

    public init(range: NSRange, opening: NSRange, closing: NSRange, source: String) {
        self.range = range
        self.opening = opening
        self.closing = closing
        self.source = source
    }
}

/// Finding Mermaid diagrams in a note, and what the editor needs to keep their drawings.
public enum MarkdownDiagrams {
    /// Cheap first look: a note that doesn't say "mermaid" anywhere has no diagrams and costs nothing more.
    public static func mightContainMermaid(_ text: String) -> Bool {
        text.range(of: "mermaid", options: [.caseInsensitive]) != nil
    }

    /// The closed ```mermaid (or ~~~mermaid, any case) blocks in `text`, in order. Fences follow CommonMark: up to three
    /// spaces before them (four makes indented code), three or more backticks or tildes, and a block closes only at a
    /// fence of the same character at least as long, with nothing after it. A ```mermaid inside another fenced block is
    /// that block's text, not a diagram. A block that's never closed isn't drawn: it's still being written.
    public static func mermaidBlocks(in text: String) -> [MermaidBlock] {
        guard mightContainMermaid(text) else { return [] }
        let string = text as NSString
        var blocks: [MermaidBlock] = []
        // The fence that's open: its character, length and indent, whether it's a diagram, and where it started.
        var open: (mark: unichar, count: Int, indent: Int, mermaid: Bool, opening: NSRange, start: Int)?
        var lines: [String] = []
        string.enumerateSubstrings(in: NSRange(location: 0, length: string.length), options: [.byLines, .substringNotRequired]) { _, line, enclosing, _ in
            if let current = open {
                if let fence = fence(string, line: line), fence.mark == current.mark, fence.count >= current.count, fence.rest.isEmpty {
                    if current.mermaid {
                        let range = NSRange(location: current.start, length: NSMaxRange(enclosing) - current.start)
                        blocks.append(MermaidBlock(range: range, opening: current.opening, closing: line, source: lines.joined(separator: "\n")))
                    }
                    open = nil
                    lines = []
                } else if current.mermaid {
                    lines.append(dropIndent(string.substring(with: line), upTo: current.indent))
                }
                return
            }
            guard let fence = fence(string, line: line) else { return }
            // A backtick fence's info string can't hold a backtick: "```a`b" is inline code, not a fence.
            if fence.mark == 0x60, fence.rest.contains("`") { return }
            let language = fence.rest.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init) ?? ""
            open = (fence.mark, fence.count, fence.indent, language.lowercased() == "mermaid", line, enclosing.location)
            lines = []
        }
        return blocks
    }

    /// A fence line's parts: its character, how many, its indent and what follows (trimmed). Nil when it isn't one.
    static func fence(_ string: NSString, line: NSRange) -> (mark: unichar, count: Int, indent: Int, rest: String)? {
        var index = line.location
        let end = NSMaxRange(line)
        while index < end, string.character(at: index) == 0x20 { index += 1 }
        let indent = index - line.location
        guard indent <= 3, index < end else { return nil }
        let mark = string.character(at: index)
        guard mark == 0x60 || mark == 0x7E else { return nil }    // ` or ~
        var count = 0
        while index < end, string.character(at: index) == mark {
            count += 1
            index += 1
        }
        guard count >= 3 else { return nil }
        let rest = string.substring(with: NSRange(location: index, length: end - index)).trimmingCharacters(in: .whitespaces)
        return (mark, count, indent, rest)
    }

    private static func dropIndent(_ line: String, upTo indent: Int) -> String {
        guard indent > 0 else { return line }
        let spaces = line.prefix { $0 == " " }.count
        return String(line.dropFirst(min(spaces, indent)))
    }

    // MARK: Keeping drawings

    /// Drawings are kept per width in steps of this many points, so a window resized by a few points draws nothing again.
    public static let widthStep = 40

    /// The width a diagram is drawn for in `width` points of text: rounded down to a step, never under 160.
    public static func widthBucket(_ width: Double) -> Int {
        guard width.isFinite else { return 160 }
        return max(160, Int(width) / widthStep * widthStep)
    }

    /// What a drawing is kept under: the same text, theme and width step is the same picture.
    public static func cacheKey(source: String, theme: String, width: Double) -> String {
        "\(theme)|\(widthBucket(width))|\(source)"
    }

    // MARK: Mistakes

    /// The quiet line under a diagram Mermaid couldn't read: the first line of its message, in plain words.
    public static func errorLine(_ message: String) -> String {
        var first = message.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        if first.hasSuffix(":") { first.removeLast() }
        // Mermaid's own prefixes say nothing a reader needs.
        for prefix in ["Error: ", "UnknownDiagramError: "] where first.hasPrefix(prefix) { first.removeFirst(prefix.count) }
        if first.count > 160 { first = String(first.prefix(159)) + "…" }
        return first.isEmpty ? "Mermaid couldn't draw this." : "Mermaid couldn't draw this: \(first)"
    }
}
