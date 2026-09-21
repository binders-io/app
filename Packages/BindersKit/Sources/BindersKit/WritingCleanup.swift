import Foundation

/// Tidies captured writing before it is kept: signatures off the end of emails, junk out of names.
public enum WritingCleanup {
    private static let signOffs: Set<String> = [
        "thanks", "thank you", "many thanks", "thanks again", "thx", "ty", "best", "all the best", "best regards", "kind regards",
        "warm regards", "regards", "rgds", "cheers", "sincerely", "yours", "talk soon", "speak soon", "take care", "br", "--", "—", "–",
    ]

    /// Drops a trailing email signature: everything from a sign-off line ("Thanks,", "Best regards") or from the writer's
    /// own name line when either sits in the last dozen lines. The body must keep at least three words.
    public static func stripSignature(_ text: String, userName: String?) -> String {
        let lines = text.components(separatedBy: "\n")
        guard lines.count >= 2 else { return text }
        let tail = max(0, lines.count - 14)
        let name = userName?.trimmingCharacters(in: .whitespaces).lowercased()
        var cut: Int?
        for index in stride(from: lines.count - 1, through: tail, by: -1) {
            let line = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: ",.!:;"))
                .lowercased()
            if signOffs.contains(line) {
                cut = index
            } else if let name, !name.isEmpty, line == name || line.hasPrefix(name + " ") || line.hasSuffix(" " + name) || line == name.split(separator: " ").first.map(String.init) {
                cut = index
                // A sign-off just above the name belongs to the signature too.
                if index > 0, signOffs.contains(lines[index - 1].trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: ",.!:;")).lowercased()) { cut = index - 1 }
            }
        }
        guard let cut, cut > 0 else { return text }
        let body = lines[..<cut].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return body.split(whereSeparator: \.isWhitespace).count >= 3 ? body : text
    }

    /// A person's name or address as an app exposes it, without object-replacement or format characters, "(You)"
    /// tags or stray punctuation; nil when nothing readable is left.
    public static func cleanName(_ raw: String) -> String? {
        var name = raw.replacingOccurrences(of: "[\\p{Cf}\\uFFFC\\u00A0]", with: " ", options: .regularExpression)
        name = name.replacingOccurrences(of: #"(?i)\s*\((you|me)\)\s*"#, with: " ", options: .regularExpression)
        name = name.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ",;:<>"))
            .trimmingCharacters(in: .whitespaces)
        guard name.contains(where: { $0.isLetter || $0.isNumber }), name.count <= 80 else { return nil }
        return name
    }
}
