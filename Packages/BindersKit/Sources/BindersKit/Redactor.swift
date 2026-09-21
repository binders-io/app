import Foundation

/// Strips things that should never be kept from captured writing: labelled secrets, card numbers, long opaque
/// tokens, social security and bank account numbers. Prose, dates, times and ordinary numbers are left alone.
public enum Redactor {
    public struct Result: Equatable, Sendable {
        public var text: String
        public var count: Int
    }

    public static func redact(_ text: String) -> Result {
        var output = text
        var count = 0
        func apply(_ pattern: String, replacement: (NSTextCheckingResult, NSString) -> String?) {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
            let source = output as NSString
            var rebuilt = ""
            var cursor = 0
            for match in regex.matches(in: output, range: NSRange(location: 0, length: source.length)) {
                guard let replaced = replacement(match, source) else { continue }
                rebuilt += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor)) + replaced
                cursor = match.range.location + match.range.length
                count += 1
            }
            rebuilt += source.substring(from: cursor)
            output = rebuilt
        }
        // Labelled secrets: keep the label, drop the value.
        apply(#"(?i)\b(password|passcode|passwd|pwd|pin|secret|token|api[ _-]?key|access[ _-]?key)\b(\s*(?:[:=]|is)\s*)(\S+)"#) { match, source in
            source.substring(with: match.range(at: 1)) + source.substring(with: match.range(at: 2)) + "[redacted]"
        }
        // Card numbers: 13 to 19 digits with optional spaces or dashes that pass the Luhn check.
        apply(#"\b\d(?:[ -]?\d){12,18}\b"#) { match, source in
            let digits = source.substring(with: match.range).filter(\.isNumber)
            return (13...19).contains(digits.count) && luhn(digits) ? "[card]" : nil
        }
        apply(#"\b\d{3}-\d{2}-\d{4}\b"#) { _, _ in "[ssn]" }
        apply(#"\b[A-Z]{2}\d{2}[A-Z0-9]{11,30}\b"#) { _, _ in "[iban]" }
        // Long opaque tokens (keys, signed tokens): letters and digits mixed, 32+ characters, no spaces.
        apply(#"\b[A-Za-z0-9_\-\.]{32,}\b"#) { match, source in
            let token = source.substring(with: match.range)
            let hasLetter = token.contains { $0.isLetter }
            let hasDigit = token.contains { $0.isNumber }
            return hasLetter && hasDigit ? "[token]" : nil
        }
        return Result(text: output, count: count)
    }

    static func luhn(_ digits: String) -> Bool {
        var sum = 0
        for (offset, character) in digits.reversed().enumerated() {
            guard var value = character.wholeNumberValue else { return false }
            if offset % 2 == 1 {
                value *= 2
                if value > 9 { value -= 9 }
            }
            sum += value
        }
        return sum % 10 == 0
    }
}
