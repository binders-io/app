import Foundation

/// Colours for a line of code in a note: keywords, strings, numbers, comments and type names, for the languages people
/// paste into notes. It reads one line at a time, so a string or comment that runs over several lines is only coloured
/// on its first.
public enum CodeHighlighter {
    public enum Token: Equatable, Sendable { case keyword, string, number, comment, type }

    public struct Span: Equatable, Sendable {
        public let range: NSRange
        public let token: Token
    }

    private static let hashComments: Set<String> = ["sh", "bash", "zsh", "shell", "console", "python", "py", "ruby", "rb", "yaml", "yml", "toml",
                                                     "r", "perl", "make", "makefile", "dockerfile", "conf", "ini", "nix", "powershell", "ps1"]
    private static let dashComments: Set<String> = ["sql", "lua", "haskell", "hs", "elm"]

    private static let keywords: Set<String> = """
    let var func return if else for while repeat in guard switch case default break continue class struct enum protocol extension \
    import from as is try catch throw throws async await public private internal fileprivate static final override self Self super \
    init deinit true false nil null None True False undefined def lambda pass yield with elif except finally raise global and or not \
    const function new this typeof instanceof interface type implements extends export package void int string bool float double \
    fn mut use impl pub match mod crate where trait loop do end then fi esac echo local readonly select insert update delete into \
    values create table alter drop join on group order by having limit set begin commit
    """.split(whereSeparator: { $0 == " " || $0 == "\n" }).reduce(into: Set<String>()) { $0.insert(String($1)) }

    /// Each language's own words, for the ones notes see most; any other language gets them all.
    private static let languageKeywords: [Set<String>: Set<String>] = {
        func words(_ list: String) -> Set<String> { Set(list.split(separator: " ").map(String.init)) }
        return [
            ["sh", "bash", "zsh", "shell", "console"]: words("if then else elif fi for while until do done case esac in function return local export readonly unset exit true false source alias"),
            ["python", "py"]: words("def class return if elif else for while in not and or is import from as with try except finally raise pass break continue lambda yield global nonlocal assert del True False None async await self"),
            ["swift"]: words("let var func return if else guard for while repeat in switch case default break continue class struct enum protocol extension import as is try catch throw throws rethrows async await public private internal fileprivate open static final override mutating self Self super init deinit true false nil where some any inout defer do"),
            ["js", "javascript", "ts", "typescript", "jsx", "tsx"]: words("const let var function return if else for while do in of switch case default break continue class extends new this super import from export as async await try catch finally throw typeof instanceof true false null undefined interface type implements enum public private readonly static yield delete void"),
            ["sql"]: words("select from where and or not insert into values update set delete create table alter drop index join left right inner outer on group order by having limit offset as distinct union all null is in like between case when then else end primary key foreign references"),
            ["go"]: words("func package import return if else for range switch case default break continue type struct interface map chan go defer select var const true false nil"),
            ["rust", "rs"]: words("fn let mut const static struct enum impl trait pub use mod crate self super return if else match for while loop in break continue where as ref move async await true false"),
            ["ruby", "rb"]: words("def end class module return if elsif else unless while until for in do begin rescue ensure yield self nil true false and or not require"),
        ]
    }()

    private static let word = try! NSRegularExpression(pattern: #"[A-Za-z_][A-Za-z0-9_]*"#)
    private static let number = try! NSRegularExpression(pattern: #"(?<![A-Za-z0-9_.$])(?:0x[0-9A-Fa-f_]+|\d[\d_]*(?:\.\d+)?(?:[eE][+-]?\d+)?)(?![A-Za-z0-9_])"#)
    private static let string = try! NSRegularExpression(pattern: #""(?:[^"\\]|\\.)*"?|'(?:[^'\\]|\\.)*'?|`[^`]*`?"#)

    /// The coloured stretches of `line`, a line of code in `language` (the word after the fence; may be empty).
    public static func spans(in line: String, language: String) -> [Span] {
        let text = line as NSString
        let whole = NSRange(location: 0, length: text.length)
        guard whole.length > 0 else { return [] }
        let language = language.lowercased()
        var spans: [Span] = []
        var taken: [NSRange] = []
        func free(_ range: NSRange) -> Bool { !taken.contains { NSIntersectionRange($0, range).length > 0 } }

        // Strings first, so a "//" or "#" inside one isn't a comment.
        for match in string.matches(in: line, range: whole) {
            // A lone apostrophe in a comment or prose ("don't") isn't a string worth colouring.
            if text.character(at: match.range.location) == 0x27, match.range.length < 2 { continue }
            spans.append(Span(range: match.range, token: .string))
            taken.append(match.range)
        }
        let markers: [String] = hashComments.contains(language) ? ["#"] : dashComments.contains(language) ? ["--"]
            : language.isEmpty ? ["//", "#"] : ["//"]
        var comment: NSRange?
        for marker in markers {
            var from = 0
            while from < text.length {
                let found = text.range(of: marker, options: [], range: NSRange(location: from, length: text.length - from))
                guard found.location != NSNotFound else { break }
                let before: unichar? = found.location == 0 ? nil : text.character(at: found.location - 1)
                let isComment: Bool
                switch marker {
                case "#":
                    // After a space or at the start, not in a URL's "#part"; with no language named, only to begin a line.
                    let startsWord = before == nil || before == 0x20 || before == 0x09
                    let leading = text.substring(to: found.location).trimmingCharacters(in: .whitespaces).isEmpty
                    isComment = startsWord && (hashComments.contains(language) || leading)
                case "//":
                    isComment = before != 0x3A    // not the "//" of https://
                default:
                    isComment = true
                }
                if free(found), isComment {
                    comment = NSRange(location: found.location, length: text.length - found.location)
                    break
                }
                from = NSMaxRange(found)
            }
            if comment != nil { break }
        }
        if let comment {
            spans.removeAll { NSIntersectionRange($0.range, comment).length > 0 && $0.range.location >= comment.location }
            taken.removeAll { $0.location >= comment.location }
            spans.append(Span(range: comment, token: .comment))
            taken.append(comment)
        }
        for match in number.matches(in: line, range: whole) where free(match.range) {
            spans.append(Span(range: match.range, token: .number))
        }
        let known = languageKeywords.first { $0.key.contains(language) }?.value ?? keywords
        for match in word.matches(in: line, range: whole) where free(match.range) {
            let name = text.substring(with: match.range)
            // Part of a path, a flag, a "name-with-dashes" or a member ("x.import"): not a keyword.
            let before: unichar? = match.range.location > 0 ? text.character(at: match.range.location - 1) : nil
            let after: unichar? = NSMaxRange(match.range) < text.length ? text.character(at: NSMaxRange(match.range)) : nil
            let joined = [0x2D, 0x2F, 0x2E].contains(before ?? 0) || [0x2D, 0x2F].contains(after ?? 0)
            if !joined, known.contains(name) || (dashComments.contains(language) && known.contains(name.lowercased())) {
                spans.append(Span(range: match.range, token: .keyword))
            } else if let first = name.unicodeScalars.first, CharacterSet.uppercaseLetters.contains(first), name.count > 1,
                      name.contains(where: { $0.isLowercase }) {
                spans.append(Span(range: match.range, token: .type))
            }
        }
        return spans.sorted { $0.range.location < $1.range.location }
    }
}
