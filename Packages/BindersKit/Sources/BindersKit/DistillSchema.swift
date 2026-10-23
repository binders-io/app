import Foundation

/// The JSON schema a Distill reply is held to where the model allows it (lane DS3): an object whose `items` is the list of
/// work items, each with the fields `DistillPrompt.system` asks for, in its order, the section one of the note's own
/// headings (or "" for the text before the first) and the quote the note's own words it came from (lane DS4). MLX holds
/// the reply to it token by token (xgrammar), Ollama takes it as `format` and an OpenAI-compatible server as
/// `response_format`, so the model can't answer in prose or think aloud instead of listing. `DistillReading.read` still reads the reply, as it reads a bare list.
public enum DistillSchema {
    /// The name an OpenAI-compatible server's `json_schema` carries.
    public static let name = "work_items"
    public static let sizes = ["small", "medium", "large"]
    public static let fors = ["agent", "person", "either"]
    /// The most waits one item may have.
    public static let maxWaits = 10

    /// The section names the schema allows: the note's headings in order, empty ones and repeats left out, then "".
    public static func sections(_ headings: [String]) -> [String] {
        var seen: Set<String> = []
        var out: [String] = []
        for heading in headings where !heading.isEmpty && seen.insert(heading).inserted { out.append(heading) }
        out.append("")
        return out
    }

    /// The schema as JSON text, its properties in the prompt's order (a grammar writes them in the order given).
    /// - Parameters:
    ///   - headings: the note's "## " headings, in order.
    ///   - waitsByTitle: the note is read in parts, so a wait may name another part's item by its title, or a heading,
    ///     as well as an item here by its number.
    ///   - bounded: with counts (`maxItems`, `minimum`, `maximum`), which MLX and Ollama hold to; without them for an
    ///     OpenAI-compatible server, whose strict mode may turn them down.
    ///
    /// Strings have no `maxLength`: xgrammar compiles one as a repetition a character at a time, which on a 248,000-token
    /// vocabulary (Qwen's) took 70 to 210 seconds in a debug build against under one without (lane DS3). A string that runs
    /// on is brought to its end by the guided loop's closing bias near the token limit, and a reply that repeats itself by
    /// the loop guard.
    public static func json(headings: [String], waitsByTitle: Bool = false, bounded: Bool = true) -> String {
        let text = #"{"type":"string"}"#
        func choice(_ values: [String]) -> String {
            #"{"type":"string","enum":[\#(values.map(quoted).joined(separator: ","))]}"#
        }
        let number = bounded ? #"{"type":"integer","minimum":1,"maximum":\#(DistillPrompt.maxItems)}"# : #"{"type":"integer"}"#
        let wait = waitsByTitle ? #"{"anyOf":[\#(number),\#(text)]}"# : number
        let waits = #"{"type":"array","items":\#(wait)\#(bounded ? #","maxItems":\#(maxWaits)"# : "")}"#
        let fields: [(String, String)] = [
            ("title", text),
            ("brief", text),
            ("done_when", text),
            ("section", choice(sections(headings))),
            // The note's own words the item comes from, so the note can show where each card came from (lane DS4).
            ("quote", text),
            ("waits_for", waits),
            ("size", choice(sizes)),
            ("for", choice(fors)),
        ]
        let properties = fields.map { "\(quoted($0.0)):\($0.1)" }.joined(separator: ",")
        let required = fields.map { quoted($0.0) }.joined(separator: ",")
        let item = #"{"type":"object","properties":{\#(properties)},"required":[\#(required)],"additionalProperties":false}"#
        let list = #"{"type":"array","items":\#(item)\#(bounded ? #","maxItems":\#(DistillPrompt.maxItems)"# : "")}"#
        return #"{"type":"object","properties":{"items":\#(list)},"required":["items"],"additionalProperties":false}"#
    }

    /// A string as JSON writes it: quotes, backslashes and control characters escaped.
    static func quoted(_ text: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(text), let json = String(data: data, encoding: .utf8) else { return "\"\"" }
        return json
    }
}
