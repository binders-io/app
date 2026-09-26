import Foundation

/// A note's digest: the local model's short take on a note (title, summary, key points, to-dos), kept next to the
/// note and indexed like a meeting summary.
public enum NoteDigest {
    /// Notes shorter than this speak for themselves; they only get a digest when asked.
    public static let minimumWords = 40
    /// How long a note has to sit unchanged before a digest is written, so dictation in progress isn't digested mid-sentence.
    public static let settleSeconds: TimeInterval = 90

    public static func isEligible(wordCount: Int, secondsSinceEdit: TimeInterval) -> Bool {
        wordCount >= minimumWords && secondsSinceEdit >= settleSeconds
    }
}

public enum NotePrompts {
    public static func digestSystemPrompt() -> String {
        """
        You write a short digest of one note the user wrote or dictated. Notes are often unedited speech: run-on sentences, misheard words, ideas in the order they came.

        Output Markdown in exactly this shape, leaving out any section that would be empty:
        - First line: "# " and a short, specific title for the note (at most 8 words).
        ## Summary
        One or two sentences on what the note is about.
        ## Key points
        Short bullets, only when the note holds more than one idea.
        ## To-dos
        - [ ] Something the note says should be done, one per line, each once.

        Rules:
        - Use only what is in the note. Never invent facts, names, numbers or tasks.
        - A to-do the note already shows as done (ticked "- [x]", marked "✓", or said to be done) is written "- [x] …".
        - Keep names and terms as written; fix obvious speech-recognition slips from context.
        - Write in the note's language. No preamble, no commentary.
        """
    }

    public static func digestUserPrompt(date: String?, text: String) -> String {
        var parts: [String] = []
        if let date { parts.append("Written: \(date)") }
        parts.append("The note:\n<note>\n\(text)\n</note>")
        return parts.joined(separator: "\n\n")
    }
}
