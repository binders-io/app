import AppKit

/// Text copied from a web page, Pages, Word, Mail or Notes, pasted into a note as Markdown: headings, lists, bold and
/// italic, links and code come along; fonts, colours and sizes stay behind. ⌥⇧⌘V pastes the words alone.
@MainActor
enum RichPaste {
    /// The Markdown for what's on `pasteboard`, when it carries formatting worth keeping; nil for plain words.
    static func markdown(from pasteboard: NSPasteboard) -> String? {
        let attributed: NSAttributedString?
        if let html = pasteboard.data(forType: .html) {
            attributed = NSAttributedString(html: html, options: [.characterEncoding: String.Encoding.utf8.rawValue], documentAttributes: nil)
        } else if let rtfd = pasteboard.data(forType: .rtfd) {
            attributed = NSAttributedString(rtfd: rtfd, documentAttributes: nil)
        } else if let rtf = pasteboard.data(forType: .rtf) {
            attributed = NSAttributedString(rtf: rtf, documentAttributes: nil)
        } else {
            return nil
        }
        guard let attributed, attributed.length > 0 else { return nil }
        let markdown = convert(attributed)
        let plain = (pasteboard.string(forType: .string) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !markdown.isEmpty, markdown != plain else { return nil }
        return markdown
    }

    private enum Kind: Equatable {
        case text, code, heading
        /// An item of a list, told apart from the items of another list.
        case item(ObjectIdentifier)
    }

    static func convert(_ text: NSAttributedString) -> String {
        let string = text.string as NSString
        let base = bodySize(of: text)
        var blocks: [(kind: Kind, markdown: String)] = []
        string.enumerateSubstrings(in: NSRange(location: 0, length: string.length), options: [.byParagraphs, .substringNotRequired]) { _, range, _, _ in
            guard range.length > 0 else { return }
            let paragraph = text.attributedSubstring(from: range)
            let words = paragraph.string.replacingOccurrences(of: "\u{FFFC}", with: "").trimmingCharacters(in: .whitespaces)
            guard !words.isEmpty else { return }
            let style = paragraph.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
            if isCode(paragraph) {
                blocks.append((.code, paragraph.string.replacingOccurrences(of: "\u{00A0}", with: " ")))
                return
            }
            // A list item: its marker comes from the list, not from the text, which repeats it ("\t•\t").
            if let lists = style?.textLists, let list = lists.last {
                let depth = String(repeating: "  ", count: max(0, lists.count - 1))
                let body = inline(trimmingListMarker(paragraph), plainStyle: false)
                let ordered = list.markerFormat.rawValue.contains("decimal") || list.markerFormat.rawValue.contains("alpha")
                    || list.markerFormat.rawValue.contains("roman")
                let number = ordered ? (list.startingItemNumber + itemIndex(of: range.location, list: list, in: text)) : 0
                let checklist = list.markerFormat.rawValue.contains("check") || list.markerFormat == .check
                let marker = checklist ? "- [ ] " : ordered ? "\(number). " : "- "
                blocks.append((.item(ObjectIdentifier(lists[0])), depth + marker + body))
                return
            }
            let size = fontSize(of: paragraph)
            let bold = isBold(paragraph)
            let short = words.count <= 160
            let level: Int? = !short ? nil : size >= base * 1.6 ? 1 : size >= base * 1.3 ? 2 : (size >= base * 1.1 && bold) ? 3 : nil
            if let level {
                blocks.append((.heading, String(repeating: "#", count: level) + " " + inline(paragraph, plainStyle: true)))
                return
            }
            let quoted = (style?.headIndent ?? 0) >= 24 && (style?.firstLineHeadIndent ?? 0) >= 24
            blocks.append((.text, (quoted ? "> " : "") + inline(paragraph, plainStyle: false)))
        }
        // Paragraphs apart; list items and lines of code together, code inside its fence.
        var output = ""
        var previous: Kind?
        for block in blocks {
            if block.kind == .code {
                if previous == .code {
                    output += "\n" + block.markdown
                } else {
                    output += (output.isEmpty ? "" : "\n\n") + "```\n" + block.markdown
                }
            } else {
                if previous == .code { output += "\n```" }
                let together = previous.map { if case .item = $0 { return $0 == block.kind } else { return false } } ?? false
                output += (output.isEmpty ? "" : together ? "\n" : "\n\n") + block.markdown
            }
            previous = block.kind
        }
        if previous == .code { output += "\n```" }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Within a paragraph

    /// Bold, italic, struck-through, code and links as Markdown. `plainStyle` leaves out bold and italic, for headings.
    private static func inline(_ paragraph: NSAttributedString, plainStyle: Bool) -> String {
        struct Run { var text: String; var bold: Bool; var italic: Bool; var code: Bool; var strike: Bool; var link: String? }
        var runs: [Run] = []
        let string = paragraph.string as NSString
        paragraph.enumerateAttributes(in: NSRange(location: 0, length: paragraph.length)) { attributes, range, _ in
            var text = string.substring(with: range).replacingOccurrences(of: "\u{FFFC}", with: "").replacingOccurrences(of: "\u{00A0}", with: " ")
            text = text.replacingOccurrences(of: "\n", with: " ")
            guard !text.isEmpty else { return }
            let font = attributes[.font] as? NSFont
            let traits = font.map { NSFontManager.shared.traits(of: $0) } ?? []
            let link: String? = (attributes[.link] as? URL)?.absoluteString ?? (attributes[.link] as? String)
            let run = Run(text: text, bold: !plainStyle && traits.contains(.boldFontMask), italic: !plainStyle && traits.contains(.italicFontMask),
                          code: font?.isFixedPitch == true, strike: (attributes[.strikethroughStyle] as? Int ?? 0) != 0, link: link)
            if var last = runs.last, last.bold == run.bold, last.italic == run.italic, last.code == run.code, last.strike == run.strike, last.link == run.link {
                last.text += run.text
                runs[runs.count - 1] = last
            } else {
                runs.append(run)
            }
        }
        return runs.map { run -> String in
            // Markers hug the words: the spaces around them stay outside.
            let leading = String(run.text.prefix { $0 == " " || $0 == "\t" })
            let trailing = String(run.text.reversed().prefix { $0 == " " || $0 == "\t" })
            var core = run.text.trimmingCharacters(in: .whitespaces)
            guard !core.isEmpty else { return run.text }
            if run.code { core = "`" + core + "`" } else {
                if run.bold { core = "**" + core + "**" }
                if run.italic { core = "*" + core + "*" }
            }
            if run.strike { core = "~~" + core + "~~" }
            if let link = run.link, !link.hasPrefix("#"), !link.hasPrefix("javascript:") {
                let label = run.text.trimmingCharacters(in: .whitespaces)
                core = label == link ? link : "[\(core)](\(link.replacingOccurrences(of: " ", with: "%20")))"
            }
            return leading + core + trailing
        }.joined().trimmingCharacters(in: .whitespaces)
    }

    private static let listMarker = try! NSRegularExpression(pattern: #"^\t?(?:[•◦▪‣⁃∙·–\-*]|\d{1,3}[.)]?|[a-zA-Z][.)]|[ivxIVX]{1,4}[.)])\t"#)

    /// A list item's text without the marker the importer wrote into it.
    private static func trimmingListMarker(_ paragraph: NSAttributedString) -> NSAttributedString {
        let string = paragraph.string
        guard let match = listMarker.firstMatch(in: string, range: NSRange(location: 0, length: (string as NSString).length)) else { return paragraph }
        return paragraph.attributedSubstring(from: NSRange(location: match.range.upperBound, length: paragraph.length - match.range.upperBound))
    }

    /// Which item of its list a paragraph is, counting from 0.
    private static func itemIndex(of location: Int, list: NSTextList, in text: NSAttributedString) -> Int {
        text.itemNumber(in: list, at: location) - list.startingItemNumber
    }

    // MARK: Fonts

    /// The size most of the text is in.
    private static func bodySize(of text: NSAttributedString) -> CGFloat {
        var counts: [CGFloat: Int] = [:]
        text.enumerateAttribute(.font, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            counts[(value as? NSFont)?.pointSize ?? 12, default: 0] += range.length
        }
        return counts.max { $0.value < $1.value }?.key ?? 12
    }

    private static func fontSize(of paragraph: NSAttributedString) -> CGFloat {
        var largest: CGFloat = 0
        paragraph.enumerateAttribute(.font, in: NSRange(location: 0, length: paragraph.length)) { value, range, _ in
            guard (paragraph.string as NSString).substring(with: range).contains(where: { !$0.isWhitespace }) else { return }
            largest = max(largest, (value as? NSFont)?.pointSize ?? 0)
        }
        return largest
    }

    private static func isBold(_ paragraph: NSAttributedString) -> Bool {
        var bold = true
        paragraph.enumerateAttribute(.font, in: NSRange(location: 0, length: paragraph.length)) { value, range, stop in
            guard (paragraph.string as NSString).substring(with: range).contains(where: { !$0.isWhitespace }) else { return }
            if let font = value as? NSFont, !NSFontManager.shared.traits(of: font).contains(.boldFontMask) {
                bold = false
                stop.pointee = true
            }
        }
        return bold
    }

    /// A whole paragraph in a fixed-width font: a line of code.
    private static func isCode(_ paragraph: NSAttributedString) -> Bool {
        var code = true
        var any = false
        paragraph.enumerateAttribute(.font, in: NSRange(location: 0, length: paragraph.length)) { value, range, stop in
            guard (paragraph.string as NSString).substring(with: range).contains(where: { !$0.isWhitespace }) else { return }
            any = true
            if (value as? NSFont)?.isFixedPitch != true {
                code = false
                stop.pointee = true
            }
        }
        return any && code
    }
}
