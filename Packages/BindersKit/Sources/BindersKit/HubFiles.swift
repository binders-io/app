import Foundation

/// Pictures in a linked binder's notes, as the hub keeps them (lane HB3). The hub takes a picture on POST /api/files and
/// names it by its contents' hash ("3f2a…c1.png"); notes show it as `![caption](/api/files/<name>)`, which is what the
/// web app writes. A picture added on this Mac is in its attachments folder (`attachments/<name>`) until it's gone up;
/// then the note names the hub's copy, and this Mac keeps that copy in the attachments folder too, under the hub's name.
public enum HubFiles {
    /// Where the hub serves its files, as notes refer to them.
    public static let path = "/api/files/"

    /// The kinds of picture the hub takes, by extension, with what they're sent as.
    public static let types: [String: String] = [
        "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif", "webp": "image/webp",
        "svg": "image/svg+xml", "avif": "image/avif",
    ]

    /// The most the hub takes in one picture.
    public static let largest = 20 * 1024 * 1024

    /// What a file is sent to the hub as, by its name; nil for one the hub doesn't take as it is (HEIC, TIFF, a video…).
    public static func contentType(of name: String) -> String? {
        types[(name as NSString).pathExtension.lowercased()]
    }

    /// Whether `name` is one the hub gave: its hash, then a picture's extension.
    public static func isHubName(_ name: String) -> Bool {
        name.range(of: #"^[a-f0-9]{24}\.[a-z]+$"#, options: .regularExpression) != nil
    }

    /// The hub's name in a note's picture address, "/api/files/<name>"; nil for anything else.
    public static func hubName(in source: String) -> String? {
        guard source.hasPrefix(path) else { return nil }
        let name = String(source.dropFirst(path.count))
        return isHubName(name) ? name : nil
    }

    /// The hub's pictures `text` shows or links to.
    public static func hubNames(in text: String) -> Set<String> {
        guard text.contains(path) else { return [] }
        let string = text as NSString
        return Set(hubLink.matches(in: text, range: NSRange(location: 0, length: string.length)).map { string.substring(with: $0.range(at: 1)) })
    }

    /// The pictures in the attachments folder `text` shows, that could go to the hub: decoded file names, as in
    /// `MarkdownMedia.attachmentNames`, of pictures only (the hub takes no videos or other files).
    public static func localPictures(in text: String) -> Set<String> {
        MarkdownMedia.attachmentNames(in: text).filter { MarkdownMedia.kind(of: $0) == .image }
    }

    /// `text` with each picture in `sent` (a name in the attachments folder, to the hub's name for it) naming the hub's
    /// copy instead: `![caption](attachments/a%20b.png)` becomes `![caption](/api/files/<hub name>)`, and Obsidian's
    /// `![[a b.png|caption]]` the same. Anything else is left as it is.
    public static func pointing(_ text: String, to sent: [String: String]) -> String {
        guard !sent.isEmpty else { return text }
        var result = replacing(attachmentLink, in: text) { match, string in
            let raw = string.substring(with: match.range(at: 1))
            guard let hub = sent[raw.removingPercentEncoding ?? raw] else { return nil }
            return "](" + path + hub + ")"
        }
        result = replacing(obsidianEmbed, in: result) { match, string in
            let name = string.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
            guard let hub = sent[name] else { return nil }
            let alias = match.range(at: 2).location == NSNotFound ? "" : string.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespaces)
            // A width alone stays a width: "![|300](…)".
            let caption = Int(alias) != nil ? "|" + alias : alias.replacingOccurrences(of: "[\\[\\]\\n]", with: " ", options: .regularExpression)
            return "![" + caption + "](" + path + hub + ")"
        }
        return result
    }

    private static func replacing(_ pattern: NSRegularExpression, in text: String, with replacement: (NSTextCheckingResult, NSString) -> String?) -> String {
        let string = text as NSString
        let result = NSMutableString(string: text)
        for match in pattern.matches(in: text, range: NSRange(location: 0, length: string.length)).reversed() {
            if let new = replacement(match, string) { result.replaceCharacters(in: match.range, with: new) }
        }
        return result as String
    }

    private static let attachmentLink = try! NSRegularExpression(pattern: #"\]\(<?"# + MarkdownMedia.folder + #"/([^)>\s]+)>?\)"#)
    private static let obsidianEmbed = try! NSRegularExpression(pattern: #"!\[\[([^\[\]\|\n]+?)(?:\|([^\[\]\n]*?))?\]\]"#)
    private static let hubLink = try! NSRegularExpression(pattern: #"\]\(<?/api/files/([a-f0-9]{24}\.[a-z]+)>?\)"#)
}
