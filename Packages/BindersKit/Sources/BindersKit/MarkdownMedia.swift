import Foundation

/// A picture or video shown in a note: a line that is only `![caption](path)`, or Obsidian's `![[file.png]]`. The
/// caption may end in "|300", Obsidian's way of giving a width in points.
public struct MarkdownEmbed: Equatable, Sendable {
    /// As written: "attachments/photo.png", "https://…", or a bare file name in `![[ ]]`.
    public let source: String
    public let caption: String
    public let width: Int?
    /// The whole line, without its line break.
    public let range: NSRange
    /// The caption's words, which stay visible under the picture; nil when there are none.
    public let captionRange: NSRange?
}

public enum MarkdownMedia {
    /// Where a note's pictures, videos and files are kept, next to it: on this Mac, and in a team folder's Notes.
    public static let folder = "attachments"

    public enum Kind: Sendable { case image, video, other }

    public static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "tif", "tiff", "bmp"]
    public static let videoExtensions: Set<String> = ["mov", "mp4", "m4v"]

    public static func kind(of source: String) -> Kind {
        let path = source.split(separator: "?").first.map(String.init) ?? source
        let ext = (path as NSString).pathExtension.lowercased()
        if imageExtensions.contains(ext) { return .image }
        if videoExtensions.contains(ext) { return .video }
        return .other
    }

    private static let markdownImage = try! NSRegularExpression(pattern: #"^[ \t]*!\[([^\]\n]*)\]\((<[^>\n]+>|[^)\s]+)(?:[ \t]+"[^"\n]*")?\)[ \t]*$"#)
    private static let obsidianEmbed = try! NSRegularExpression(pattern: #"^[ \t]*!\[\[([^\[\]\|\n]+?)(?:\|([^\[\]\n]*?))?\]\][ \t]*$"#)
    private static let widthSuffix = try! NSRegularExpression(pattern: #"\|[ \t]*(\d{2,4})[ \t]*$"#)

    /// The picture or video `line` shows, if that's all it is. `offset` is where the line starts in the note.
    public static func embed(inLine line: String, at offset: Int) -> MarkdownEmbed? {
        let string = line as NSString
        let whole = NSRange(location: 0, length: string.length)
        guard string.length > 4, string.range(of: "![").location != NSNotFound else { return nil }
        func shifted(_ range: NSRange) -> NSRange { NSRange(location: range.location + offset, length: range.length) }
        if let match = markdownImage.firstMatch(in: line, range: whole) {
            var source = string.substring(with: match.range(at: 2))
            if source.hasPrefix("<"), source.hasSuffix(">") { source = String(source.dropFirst().dropLast()) }
            guard kind(of: source) != .other || source.hasPrefix("http") else { return nil }
            var captionRange = match.range(at: 1)
            var width: Int?
            if let suffix = widthSuffix.firstMatch(in: line, range: captionRange) {
                width = Int(string.substring(with: suffix.range(at: 1)))
                captionRange.length = suffix.range.location - captionRange.location
            }
            let caption = string.substring(with: captionRange).trimmingCharacters(in: .whitespaces)
            return MarkdownEmbed(source: source.removingPercentEncoding ?? source, caption: caption, width: width, range: shifted(whole),
                                 captionRange: caption.isEmpty ? nil : shifted(captionRange))
        }
        if let match = obsidianEmbed.firstMatch(in: line, range: whole) {
            let source = string.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
            guard kind(of: source) != .other else { return nil }
            var width: Int?
            var caption = ""
            var captionRange: NSRange?
            if match.range(at: 2).location != NSNotFound {
                let alias = string.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespaces)
                if let number = Int(alias) { width = number } else if !alias.isEmpty {
                    caption = alias
                    captionRange = shifted(match.range(at: 2))
                }
            }
            return MarkdownEmbed(source: source, caption: caption, width: width, range: shifted(whole), captionRange: captionRange)
        }
        return nil
    }

    /// The line for a file kept in the attachments folder: `![caption](attachments/name.png)`, or a plain link for
    /// anything that isn't a picture or a video.
    public static func markdown(forFile name: String, caption: String) -> String {
        let path = folder + "/" + (name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "()"))) ?? name)
        let shown = caption.replacingOccurrences(of: "[\\[\\]\\n]", with: " ", options: .regularExpression)
        switch kind(of: name) {
        case .image, .video: return "![\(shown)](\(path))"
        case .other: return "[\(shown.isEmpty ? name : shown)](\(path))"
        }
    }

    /// `line` showing its picture `width` points wide, or as it comes when nil.
    public static func resized(_ line: String, width: Int?) -> String {
        guard let embed = embed(inLine: line, at: 0) else { return line }
        let string = line as NSString
        let leading = String(line.prefix { $0 == " " || $0 == "\t" })
        if string.range(of: "![[").location != NSNotFound {
            let alias = width.map(String.init) ?? embed.caption
            return leading + "![[" + embed.source + (alias.isEmpty ? "" : "|" + alias) + "]]"
        }
        let open = string.range(of: "](")
        let rest = string.substring(from: open.location)
        let caption = embed.caption + (width.map { "|\($0)" } ?? "")
        return leading + "![" + caption + rest.trimmingCharacters(in: .whitespaces)
    }

    /// The attachment file names `text` refers to, as links or embeds, decoded.
    public static func attachmentNames(in text: String) -> Set<String> {
        guard text.contains(folder + "/") || text.contains("![[") else { return [] }
        var names = Set<String>()
        let string = text as NSString
        let whole = NSRange(location: 0, length: string.length)
        for match in attachmentLink.matches(in: text, range: whole) {
            let raw = string.substring(with: match.range(at: 1))
            names.insert(raw.removingPercentEncoding ?? raw)
        }
        for match in WikiLinks.pattern.matches(in: text, range: whole) where match.range.location > 0 {
            guard string.character(at: match.range.location - 1) == 0x21 else { continue }    // !
            names.insert(string.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces))
        }
        return names
    }

    private static let attachmentLink = try! NSRegularExpression(pattern: #"\]\(<?"# + folder + #"/([^)>\s]+)>?\)"#)
}
