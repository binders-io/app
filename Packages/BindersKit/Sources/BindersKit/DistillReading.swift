import Foundation

/// What Binders asks the language model in Settings → AI when it distills a note, and how it reads what comes back: a
/// JSON list of work items, taken out of whatever the model wrapped it in, read an item at a time (`JSONItems`), with
/// repeats, a list cut off by the model's last token, sections it named loosely and waits that would go in a circle all
/// dealt with, so a small local model's answer still makes a list a person can review.
public enum DistillPrompt {
    /// How much of a note the model reads: about 6,000 words.
    public static let noteLimit = 36_000
    /// The most items the model is asked for.
    public static let maxItems = 25
    /// How long the model may write: enough for 25 items.
    public static let maxTokens = 3_000

    public static let system = """
        You turn a note, such as a spec a team wrote, into work items for the team's board. List the pieces of work the \
        note asks for: each one something a person or an AI agent could pick up, do and finish on its own. If the note asks \
        for nothing to be done, because it only explains how something works, records what happened or lists examples, \
        reply [] and nothing else.

        Reply with a JSON list and nothing else. For a note about a newsletter signup, a reply could be:
        [
          {"title": "Add the signup form to the footer", "brief": "Visitors can sign up from every page.", \
        "done_when": "The footer has a working signup form.", "section": "Signup form", \
        "quote": "Put a signup form in the footer of every page", "waits_for": [], "size": "small", "for": "agent"},
          {"title": "Send a welcome email after signup", "brief": "New subscribers get a welcome email.", \
        "done_when": "Signing up sends the welcome email.", "section": "Welcome email", \
        "quote": "Once someone signs up, send them a welcome email", "waits_for": [1], "size": "small", "for": "agent"},
          {"title": "Choose the email provider", "brief": "Someone decides who sends the emails.", \
        "done_when": "The provider is chosen and written down.", "section": "Decisions", \
        "quote": "We still need to pick an email provider", "waits_for": [], "size": "small", "for": "person"}
        ]

        - title: what to do, starting with a verb, at most 10 words.
        - brief: one or two sentences on what and why, using only what the note says. No new facts, names or numbers.
        - done_when: one sentence anyone can check.
        - section: the "## " heading the item comes from, copied exactly. Use "" for text before the first heading.
        - quote: the words of the note the item comes from, copied exactly as the note writes them: a phrase or one \
        line, at most 25 words.
        - waits_for: the numbers of the items that must be finished first (1 is the first item). Use [] unless the note \
        says one thing comes before another ("once", "after", "then", "when it's done").
        - size: "small" (a day or less), "medium" (a few days) or "large" (more).
        - for: "person" when it needs a human: a decision, a conversation, an approval, ordering or booking, money or a \
        signature. "agent" when an AI agent with code and documents could do it alone. "either" when you can't tell.

        Rules:
        - Only work the note asks for. Goals, background, what's out of scope, "not now" lists and open questions with \
        nothing to do are not items.
        - One item per piece of work. Never repeat an item, and don't break one task into its steps.
        - Keep the note's order. At most 25 items.
        """

    /// What the model reads: the note's title, its sections' headings, and the note.
    public static func user(title: String, sections: [String], text: String) -> String {
        let note = text.count > noteLimit ? String(text.prefix(noteLimit)) + "\n…" : text
        return "The note “\(title)”. \(headingsLine(sections))\n\n\(note)"
    }

    /// "Its sections: \"A\", \"B\"." as the prompts say it.
    public static func headingsLine(_ sections: [String]) -> String {
        sections.isEmpty ? "It has no \"## \" sections." : "Its sections: " + sections.map { "\"\($0)\"" }.joined(separator: ", ") + "."
    }

    /// What the model reads of a note too long to read well at once (`DistillParts`): the note's title and every heading,
    /// which part this is and what it holds, the titles of the items found in the parts before, so a wait across parts
    /// can name them, and the part's own text.
    public static func part(title: String, sections: [String], part: DistillParts.Part, earlier: [String]) -> String {
        var lines = ["The note “\(title)”. \(headingsLine(sections))", ""]
        lines.append("The note is long, so you read it in \(part.count) parts. This is part \(part.number) of \(part.count): \(part.holds). "
                     + "List only the work this part asks for.")
        if !earlier.isEmpty {
            let titles = earlier.prefix(maxItems).map { "\"\($0.count > 80 ? String($0.prefix(80)) : $0)\"" }
            lines.append("Work items from the parts before: " + titles.joined(separator: "; ") + ".")
        }
        lines.append("An item here that waits for work in another part names it in waits_for, by that item's title or by its section's heading.")
        lines.append("")
        lines.append(part.text)
        return lines.joined(separator: "\n")
    }

    /// What a second try adds, at the end, when the first reply had no list in it.
    public static let reminder = """
        Reply with only the JSON list of work items described at the start: begin with [ and end with ], with no words, \
        headings or thinking before or after it. Reply [] if this asks for no work.
        """

    /// A question asked again, with the reminder at its end, where a model that lost the instructions in a long note
    /// still reads it.
    public static func again(_ user: String) -> String { user + "\n\n" + reminder }
}

public enum DistillReading {
    /// One item as read: what the reader wrote, with its waits as positions in the list and its section matched to one of
    /// the note's headings.
    public struct Item: Equatable, Sendable {
        public var title: String
        public var brief: String
        public var doneWhen: String
        /// A heading of the note, or nil for the opening or one that matches none (`unknownSection`).
        public var section: String?
        /// What the reader named, when it matched no heading.
        public var unknownSection: String?
        /// The note's words it came from, as the reader copied them (`DistillQuote.clean`); nil when it gave none (a reply
        /// from before lane DS4, a stand-in, an agent that left it out).
        public var quote: String? = nil
        public var waitsFor: [Int]
        public var size: DistillItem.Size?
        public var hint: DistillItem.Hint?
        /// A name the reader gave in `for` that isn't agent, person or either: an agent's or a person's.
        public var forName: String?
        /// Waits it named by a title no item of this reply has, kept when the note is read in parts
        /// (`read(_:headings:elsewhere:)`): another part's item, or a section's heading, which the merge looks for.
        public var waitsElsewhere: [String] = []
    }

    /// What the reading made of a reply, and what it left out, for the review sheet and the measure.
    public struct Result: Equatable, Sendable {
        public var items: [Item]
        /// Items that didn't read as JSON objects with a title (`JSONItems`' reasons).
        public var skipped: [String] = []
        /// Repeats taken out.
        public var repeats = 0
        /// Items past `DistillPrompt.maxItems + 5`, left out.
        public var over = 0
        /// Waits left out: on the item itself, on one that isn't there, or closing a circle.
        public var droppedWaits = 0
        /// The list was cut off before its end; the items before the cut are kept.
        public var cutOff = false
        /// No JSON list was found at all.
        public var noList = false
        /// The reply had a thinking block (`ModelThinking`), which was left out of the reading.
        public var thought = false
        /// The reply was only thinking: the model never got to its answer.
        public var onlyThinking = false
        /// The first lines of the answer, its thinking left out, when it had no list: for showing what the model wrote.
        public var firstLines: String?

        /// For the review sheet: what was left out, in a sentence, or nil.
        public var note: String? {
            var parts: [String] = []
            if noList { return "The model's reply had no list of work items in it." }
            if cutOff { parts.append("the model's reply was cut off, so the last item may be missing") }
            if repeats > 0 { parts.append(repeats == 1 ? "1 repeat was left out" : "\(repeats) repeats were left out") }
            if over > 0 { parts.append(over == 1 ? "1 item past the first \(DistillPrompt.maxItems) was left out" : "\(over) items past the first \(DistillPrompt.maxItems) were left out") }
            if !skipped.isEmpty { parts.append(skipped.count == 1 ? "1 item couldn't be read" : "\(skipped.count) items couldn't be read") }
            if droppedWaits > 0 { parts.append(droppedWaits == 1 ? "1 wait that went in a circle was left out" : "\(droppedWaits) waits that went in a circle or nowhere were left out") }
            guard !parts.isEmpty else { return nil }
            let line = parts.joined(separator: "; ")
            return line.prefix(1).uppercased() + line.dropFirst() + "."
        }
    }

    /// Whether a reply that's still coming has got stuck: the same title (as `LoopGuard.normalize` compares lines) three
    /// times, or far more items than were asked for. Pretty-printed JSON repeats lines such as `"size": "small",` on every
    /// item, so `LoopGuard.isLooping` on its lines would stop a good list after its third item; titles are what repeat
    /// when a model loops.
    /// Its thinking doesn't count: a model drafting its items while it thinks isn't stopped for it.
    public static func isLooping(_ partial: String, limit: Int = 3) -> Bool {
        let partial = ModelThinking.answer(partial)
        guard let regex = try? NSRegularExpression(pattern: #""(?:title|name|task)"\s*:\s*"((?:[^"\\]|\\.)*)""#) else { return false }
        let range = NSRange(partial.startIndex..., in: partial)
        var counts: [String: Int] = [:]
        var total = 0
        for match in regex.matches(in: partial, range: range) {
            guard let title = Range(match.range(at: 1), in: partial).map({ LoopGuard.normalize(String(partial[$0])) }), !title.isEmpty else { continue }
            total += 1
            counts[title, default: 0] += 1
            if counts[title]! >= limit || total > DistillPrompt.maxItems * 2 { return true }
        }
        return false
    }

    /// When to stop a reply that's still coming: it's looping (`isLooping`), or its answer, its thinking left out, is already
    /// longer than `replyTokens` would write. The stream itself may run longer, to leave a model that thinks first room to
    /// answer (`DistillBudget.thinkingTokens`).
    public static func stopWhen(replyTokens: Int) -> @Sendable (String) -> Bool {
        { partial in
            if isLooping(partial) { return true }
            return ModelThinking.answer(partial).count > replyTokens * 4
        }
    }

    /// The first lines of a reply's answer, its thinking and special tokens left out: at most three lines and about 240
    /// characters, for showing what a model wrote instead of a list. Nil when it wrote nothing but thinking.
    public static func firstLines(_ reply: String, limit: Int = 240) -> String? {
        let lines = ModelThinking.plain(ModelThinking.answer(reply)).components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }
        let joined = lines.prefix(3).joined(separator: " ")
        guard joined.count > limit else { return joined + (lines.count > 3 ? " …" : "") }
        let cut = joined.prefix(limit)
        let atWord = cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut
        return atWord.trimmingCharacters(in: .whitespaces.union(.punctuationCharacters)) + "…"
    }

    /// Reads a reply. `headings` are the note's "## " headings, in order. Its thinking is left out first, so a list the
    /// model drafted while thinking is never read. `elsewhere`: a wait by a title no item here has is kept in
    /// `waitsElsewhere` (the note was read in parts, and the item may be in another), rather than left out.
    public static func read(_ reply: String, headings: [String], elsewhere: Bool = false) -> Result {
        let split = ModelThinking.split(reply)
        let thought = !split.thought.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || split.stillThinking
        func none() -> Result {
            Result(items: [], noList: true, thought: thought, onlyThinking: split.onlyThinking, firstLines: firstLines(reply))
        }
        guard let extracted = list(in: split.answer) else { return none() }
        guard let read = JSONItems.decode(Raw.self, from: Data(extracted.json.utf8)) else { return none() }
        var result = Result(items: [], skipped: read.skipped.map(\.reason), cutOff: extracted.cutOff, thought: thought)
        // Positions in the reply, as its waits number them (from 1), to positions kept.
        var kept: [Int: Int] = [:]
        var byTitle: [String: Int] = [:]
        var raws: [Raw] = []
        var rawIndex = 0
        for raw in read.items {
            // Its number in the list as the model wrote it: skipped items still count.
            while read.skipped.contains(where: { $0.index == rawIndex }) { rawIndex += 1 }
            defer { rawIndex += 1 }
            let title = clean(raw.title)
            guard !title.isEmpty else {
                result.skipped.append("it has no title")
                continue
            }
            let key = LoopGuard.normalize(title)
            if let first = byTitle[key] {
                result.repeats += 1
                kept[rawIndex] = first
                continue
            }
            guard result.items.count < DistillPrompt.maxItems + 5 else {
                result.over += 1
                continue
            }
            let section = raw.section.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            let matched = section.flatMap { $0.isEmpty ? nil : DistillSections.match($0, in: headings) }
            let unknown = section.flatMap { $0.isEmpty || matched != nil || isOpening($0) ? nil : $0 }
            let hint = raw.forWord.flatMap(Self.hint(_:))
            let name = raw.forWord.flatMap { hint == nil && !$0.trimmingCharacters(in: .whitespaces).isEmpty ? $0.trimmingCharacters(in: .whitespaces) : nil }
            byTitle[key] = result.items.count
            kept[rawIndex] = result.items.count
            raws.append(raw)
            result.items.append(Item(title: title, brief: clean(raw.brief ?? "", lines: true), doneWhen: clean(raw.doneWhen ?? "", lines: true),
                                     section: matched, unknownSection: unknown, quote: DistillQuote.clean(raw.quote), waitsFor: [], size: raw.size.flatMap(DistillItem.Size.init(loose:)),
                                     hint: hint ?? (name == nil ? nil : .either), forName: name))
        }
        // Waits, by number first (the model's numbering, from 1), then by title.
        var waits: [[Int]] = Array(repeating: [], count: result.items.count)
        for (position, raw) in raws.enumerated() {
            for wait in raw.waits {
                switch wait {
                case .number(let number):
                    if let target = kept[number - 1] { waits[position].append(target) } else { result.droppedWaits += 1 }
                case .title(let title):
                    if let target = byTitle[LoopGuard.normalize(clean(title))] {
                        waits[position].append(target)
                    } else if elsewhere {
                        result.items[position].waitsElsewhere.append(clean(title))
                    } else {
                        result.droppedWaits += 1
                    }
                }
            }
        }
        let acyclic = CardWaits.acyclic(waits)
        result.droppedWaits += acyclic.dropped.count
        for index in result.items.indices { result.items[index].waitsFor = acyclic.waits[index] }
        return result
    }

    /// "Intro", "opening", "none": what a reader writes for the text before the first heading.
    static func isOpening(_ section: String) -> Bool {
        ["", "intro", "introduction", "opening", "none", "null", "overview", "top", "preamble", "summary"]
            .contains(section.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces)))
    }

    /// What `for` says: agent, person or either, however it's written; nil for a name.
    static func hint(_ word: String) -> DistillItem.Hint? {
        switch word.lowercased().filter(\.isLetter) {
        case "agent", "ai", "aiagent", "bot", "agents", "codingagent", "machine": .agent
        case "person", "human", "you", "me", "user", "people", "team", "humans", "owner", "manager", "someone": .person
        case "", "either", "any", "anyone", "both", "unsure", "unknown", "eitherone": .either
        default: nil
        }
    }

    /// A title or brief as the card shows it: one line for a title, the space between words made plain.
    static func clean(_ text: String, lines: Bool = false) -> String {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !lines { text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression) }
        // A title written as a list item or a heading: "1. Add …", "- Add …", "## Add …".
        if !lines { text = text.replacingOccurrences(of: "^(?:[-*•]|\\d+[.)]|#+)\\s+", with: "", options: .regularExpression) }
        return text
    }

    // MARK: Finding the list

    /// The JSON list in a reply's answer (`ModelThinking.split` has taken its thinking out): inside code fences or prose,
    /// or as an object's list ("items": […]). One cut off before its end keeps every whole item before the cut. Commas
    /// left before a closing bracket go.
    static func list(in answer: String) -> (json: String, cutOff: Bool)? {
        let characters = Array(answer.unicodeScalars)
        // The first "[" that opens a list of objects (or an empty one).
        var start: Int?
        var index = 0
        while index < characters.count {
            if characters[index] == "[" {
                var next = index + 1
                while next < characters.count, CharacterSet.whitespacesAndNewlines.contains(characters[next]) { next += 1 }
                if next < characters.count, characters[next] == "{" || characters[next] == "]" {
                    start = index
                    break
                }
                // A list cut off right after its opening bracket.
                if next == characters.count { start = index; break }
            }
            index += 1
        }
        guard let start else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var lastWhole: Int?
        var out = String.UnicodeScalarView()
        var end: Int?
        for position in start..<characters.count {
            let c = characters[position]
            out.append(c)
            if inString {
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
                continue
            }
            switch c {
            case "\"": inString = true
            case "[", "{": depth += 1
            case "]", "}":
                depth -= 1
                if depth == 1, c == "}" { lastWhole = out.count }
                if depth == 0 { end = position }
            default: break
            }
            if end != nil { break }
        }
        var json: String
        var cutOff = false
        if end != nil {
            json = String(out)
        } else {
            cutOff = true
            guard let lastWhole else { return ("[]", true) }
            json = String(String.UnicodeScalarView(out.prefix(lastWhole))) + "]"
        }
        json = withoutTrailingCommas(json)
        return (json, cutOff)
    }

    /// Commas before a closing bracket or brace, outside strings, taken out: `[{…},]` reads as `[{…}]`.
    static func withoutTrailingCommas(_ json: String) -> String {
        var out = String.UnicodeScalarView()
        var inString = false
        var escaped = false
        var pendingComma: String.UnicodeScalarView?
        for c in json.unicodeScalars {
            if inString {
                out.append(c)
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
                continue
            }
            if pendingComma != nil {
                if CharacterSet.whitespacesAndNewlines.contains(c) {
                    pendingComma!.append(c)
                    continue
                }
                if c != "]" && c != "}" { out.append(contentsOf: pendingComma!) } else { out.append(contentsOf: pendingComma!.dropFirst()) }
                pendingComma = nil
            }
            if c == "," {
                pendingComma = String.UnicodeScalarView([c])
                continue
            }
            if c == "\"" { inString = true }
            out.append(c)
        }
        if let pendingComma { out.append(contentsOf: pendingComma) }
        return String(out)
    }

    // MARK: Reading an item

    /// A wait as a reader writes it: an item's number, or its title.
    enum Wait: Equatable {
        case number(Int)
        case title(String)
    }

    /// One item as the model wrote it, its keys read loosely: done_when, doneWhen or done; waits_for, depends_on…
    struct Raw: Decodable {
        var title: String
        var brief: String?
        var doneWhen: String?
        var section: String?
        var quote: String?
        var waits: [Wait]
        var size: String?
        var forWord: String?

        struct Key: CodingKey {
            var stringValue: String
            var intValue: Int? { nil }
            init(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { nil }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Key.self)
            func key(_ names: [String]) -> Key? {
                container.allKeys.first { key in names.contains(key.stringValue.lowercased().filter(\.isLetter)) }
            }
            func text(_ names: [String]) -> String? {
                guard let key = key(names) else { return nil }
                if let value = try? container.decode(String.self, forKey: key) { return value }
                if let list = try? container.decode([String].self, forKey: key) { return list.joined(separator: " ") }
                if let number = try? container.decode(Double.self, forKey: key) { return String(Int(number)) }
                return nil
            }
            // A title is words: a number alone isn't one.
            guard let titleKey = key(["title", "name", "task", "item", "workitem"]),
                  let title = (try? container.decode(String.self, forKey: titleKey)) else {
                throw DecodingError.keyNotFound(Key(stringValue: "title"), .init(codingPath: decoder.codingPath, debugDescription: "no title"))
            }
            self.title = title
            brief = text(["brief", "description", "details", "summary", "why", "what"])
            doneWhen = text(["donewhen", "done", "definitionofdone", "acceptance", "acceptancecriteria", "doneif"])
            section = text(["section", "heading", "from", "source"])
            quote = text(["quote", "quoted", "excerpt", "words", "fromtext", "sourcetext", "notewords"])
            size = text(["size", "effort", "estimate"])
            forWord = text(["for", "meantfor", "owner", "who", "assignee", "assignto", "by"])
            var waits: [Wait] = []
            if let key = key(["waitsfor", "dependson", "dependencies", "after", "needs", "blockedby", "requires", "waits"]) {
                func wait(_ string: String) -> Wait? {
                    let trimmed = string.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "#"))
                    guard !trimmed.isEmpty else { return nil }
                    return Int(trimmed).map(Wait.number) ?? .title(trimmed)
                }
                if let numbers = try? container.decode([Int].self, forKey: key) {
                    waits = numbers.map(Wait.number)
                } else if let strings = try? container.decode([String].self, forKey: key) {
                    waits = strings.compactMap(wait)
                } else if let number = try? container.decode(Int.self, forKey: key) {
                    waits = [.number(number)]
                } else if let string = try? container.decode(String.self, forKey: key) {
                    waits = string.split(whereSeparator: { $0 == "," }).compactMap { wait(String($0)) }
                } else if let mixed = try? container.decode([Mixed].self, forKey: key) {
                    waits = mixed.compactMap(\.wait)
                }
            }
            self.waits = waits
        }

        /// A number or a string in a list that has both.
        struct Mixed: Decodable {
            var wait: Wait?
            init(from decoder: Decoder) throws {
                let value = try decoder.singleValueContainer()
                if let number = try? value.decode(Int.self) {
                    wait = .number(number)
                } else if let string = try? value.decode(String.self) {
                    wait = Int(string).map(Wait.number) ?? (string.isEmpty ? nil : .title(string))
                } else {
                    wait = nil
                }
            }
        }
    }
}

extension DistillReading.Result {
    /// The items as a distill keeps them, each with its section's version as the note read: waits by item id.
    public func items(sections: [DistillSections.Section]) -> [DistillItem] {
        let ids = items.map { _ in UUID() }
        return items.enumerated().map { index, item in
            let hash = sections.first { $0.heading == item.section }?.hash
            return DistillItem(id: ids[index], title: item.title, brief: item.brief, doneWhen: item.doneWhen, section: item.section,
                               sectionHash: hash, quote: item.quote, waitsFor: item.waitsFor.map { ids[$0] }, size: item.size, hint: item.hint)
        }
    }
}
