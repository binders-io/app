import Foundation

/// Resolves the spoken self-corrections that swap one day, time, number or month for another, before any model sees the
/// text, so they work with the smallest model and with no model at all: "by Friday, actually make that Thursday
/// afternoon" -> "by Thursday afternoon"; "at two, no wait, three" -> "at three".
///
/// It only acts when the correction sits right after a word of one kind and is followed by a word of the same kind, so
/// "I actually think Friday works" and "the blue one, actually the red one" are left for the model.
public enum SelfCorrection {
    private static let days = #"(?:monday|tuesday|wednesday|thursday|friday|saturday|sunday|today|tomorrow|tonight)"#
    private static let months = #"(?:january|february|march|april|june|july|august|september|october|november|december)"#
    private static let numbers = #"(?:\d{1,4}(?::\d{2})?|zero|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety|hundred|thousand|noon|midnight)"#
    /// What can trail a value: "Friday afternoon", "Monday at 3 pm", "5pm", "3 o'clock", "March 3rd".
    private static let qualifier = #"(?:\s*(?:am|pm|a\.m\.|p\.m\.)|\s+o'clock|\s+(?:in\s+the\s+)?(?:morning|afternoon|evening|night)|\s+\d{1,2}(?:st|nd|rd|th)?|\s+at\s+"# + numbers + #"){0,2}"#
    /// The words people use to take something back.
    private static let cue = #"(?:actually(?:,?\s+(?:make\s+(?:that|it)|let's\s+say|no))?|make\s+(?:that|it)|no,?\s+wait|wait,?\s+no|no,?\s+sorry|sorry(?:,?\s+i\s+meant?)?|i\s+meant?|or\s+rather|rather|no)"#

    private static let patterns: [NSRegularExpression] = [days, months, numbers].map { kind in
        // The old value, then the cue, then (not consumed) a new value of the same kind. Commas may surround the cue;
        // a full stop or question mark may not, so a new sentence that starts with "Actually" is never touched.
        try! NSRegularExpression(pattern: #"(?i)(?<![\p{L}\p{N}])"# + kind + qualifier + #"[\s,]*"# + cue + #"[\s,]+(?="# + kind + qualifier + #"(?![\p{L}]))"#)
    }

    public static func resolve(_ text: String) -> String {
        var result = text
        // One correction per pass; a sentence rarely has more than two.
        for _ in 0..<4 {
            var changed = false
            for pattern in patterns {
                let whole = NSRange(result.startIndex..., in: result)
                if let match = pattern.firstMatch(in: result, range: whole), let range = Range(match.range, in: result) {
                    result.removeSubrange(range)
                    changed = true
                    break
                }
            }
            if !changed { break }
        }
        return result
    }
}
