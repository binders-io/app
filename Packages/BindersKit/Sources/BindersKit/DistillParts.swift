import Foundation

/// How much of a note the language model reads at once, and how long it may write: from the model's context, in tokens,
/// where Binders knows it (`LLMClient.contextTokens`), else a size that fits a model with an 8,000-token context.
public struct DistillBudget: Equatable, Sendable {
    /// The model's context, in tokens, when Binders knows it.
    public var contextTokens: Int?
    /// The most of the note one part holds, in characters.
    public var partCharacters: Int
    /// How long the answer may be, in tokens.
    public var replyTokens: Int
    /// Room on top of the answer for a model that thinks before it answers, so its thinking doesn't use up the answer's.
    public var thinkingTokens: Int
    /// The context, not the reading's own limit, set how much a part holds: a note with many headings makes its parts
    /// smaller to match.
    public var contextBound: Bool
    /// The most items a part is asked for: fewer than `DistillPrompt.maxItems` for the smaller parts of a slow model
    /// (`paced`, lane DS7).
    public var maxItems: Int
    /// Sized from the model's speed (`paced`): smaller parts than its context allows, for a model that writes slowly.
    public var paced: Bool

    public init(contextTokens: Int?, partCharacters: Int, replyTokens: Int, thinkingTokens: Int, contextBound: Bool = false,
                maxItems: Int = DistillPrompt.maxItems, paced: Bool = false) {
        self.contextTokens = contextTokens
        self.partCharacters = partCharacters
        self.replyTokens = replyTokens
        self.thinkingTokens = thinkingTokens
        self.contextBound = contextBound
        self.maxItems = maxItems
        self.paced = paced
    }

    /// What the stream may write in all: the answer, and room to think first.
    public var streamTokens: Int { replyTokens + thinkingTokens }

    /// The most of a note a part holds however long the model's context: about 2,700 words. Past it, local models start to
    /// lose the instructions in the note (the list turns into a summary in prose).
    public static let readsWell = 16_000
    /// A part when Binders doesn't know the model's context: about 3,000 tokens of English, so with the instructions and a
    /// whole answer it fits a model that reads 8,000 tokens, as nearly all do.
    public static let unknown = 12_000
    /// The least a part holds, however small the context.
    static let smallest = 2_000
    /// Characters to a token, counted low (English is nearer 4; Markdown, numbers and other languages take more tokens).
    static let charactersPerToken = 3
    /// What the instructions, the part's framing, the headings and the titles before it take, in tokens.
    static let promptTokens = (DistillPrompt.system.count + 3_000) / charactersPerToken
    /// The same for `format` (lane DS8): v2's instructions are shorter, and its lines' numbers take a little.
    static func promptTokens(_ format: DistillFormat) -> Int {
        format == .v1 ? promptTokens : (DistillPrompt.systemV2.count + 3_000) / charactersPerToken
    }
    /// Left free in the context, in tokens.
    static let margin = 256
    public static let thinkingRoom = 2_000

    /// The budget for a model whose context is `tokens` (nil: not known).
    public static func forContext(_ tokens: Int?, format: DistillFormat = .v1) -> DistillBudget {
        let maxTokens = format.maxTokens, promptTokens = promptTokens(format)
        guard let tokens, tokens > 0 else {
            return DistillBudget(contextTokens: nil, partCharacters: unknown, replyTokens: maxTokens, thinkingTokens: thinkingRoom)
        }
        var reply = maxTokens
        let room = tokens - promptTokens - margin - reply
        if room * charactersPerToken >= readsWell {
            let thinking = min(thinkingRoom, room - readsWell / charactersPerToken)
            return DistillBudget(contextTokens: tokens, partCharacters: readsWell, replyTokens: reply, thinkingTokens: thinking)
        }
        if room * charactersPerToken >= smallest * 2 {
            return DistillBudget(contextTokens: tokens, partCharacters: room * charactersPerToken, replyTokens: reply, thinkingTokens: 0, contextBound: true)
        }
        // A small context: a shorter answer (fewer items a part), so a part still holds something.
        reply = min(maxTokens, max(min(1_000, maxTokens), tokens - promptTokens - margin - smallest / charactersPerToken))
        let left = tokens - promptTokens - margin - reply
        return DistillBudget(contextTokens: tokens, partCharacters: max(smallest, left * charactersPerToken), replyTokens: reply, thinkingTokens: 0,
                             contextBound: true)
    }

    /// How much of the note a part holds, with `header` characters of title and headings before it: a context-bound
    /// budget gives up what the headings take past the allowance.
    public func capacity(header: Int) -> Int {
        guard contextBound else { return partCharacters }
        return max(Self.smallest, partCharacters - max(0, header - 1_000))
    }

    /// Half as much in each part: for a model that turned a part down as too long without saying how much it reads.
    public var halved: DistillBudget {
        var budget = self
        budget.partCharacters = max(Self.smallest, partCharacters / 2)
        budget.thinkingTokens = 0
        budget.contextBound = true
        return budget
    }

    /// Whether a server's error says the prompt was longer than the model's context.
    public static func isTooLong(_ message: String) -> Bool {
        let lower = message.lowercased()
        return ["exceed_context_size", "context length", "context size", "context window", "maximum context", "too many tokens",
                "prompt is too long", "input is too long", "reduce the length"].contains { lower.contains($0) }
    }

    /// The context, in tokens, a server's too-long error gives: llama.cpp's `"n_ctx": 4096`, vLLM's and hosted APIs'
    /// "maximum context length is 8192 tokens", LM Studio's "context length of only 4096 tokens".
    public static func context(fromError message: String) -> Int? {
        let patterns = [#""n_ctx"\s*:\s*(\d+)"#, #"(?i)maximum context length is\s*(\d+)"#, #"(?i)context length of only\s*(\d+)"#,
                        #"(?i)context (?:length|size|window) (?:is|of)\s*(\d+)"#]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: message, range: NSRange(message.startIndex..., in: message)),
                  let range = Range(match.range(at: 1), in: message), let tokens = Int(message[range]), tokens > 0 else { continue }
            return tokens
        }
        return nil
    }
}

/// A note too long to read well at once, read in parts: section by section ("## " headings, as `DistillSections` splits
/// it), in as few parts as fit, as even as they go; a section longer than a part is cut between its paragraphs, each piece
/// under its heading. The readings of the parts become one (`merge`).
public enum DistillParts {
    /// A section, or a piece of one, in a part.
    public struct Piece: Equatable, Sendable {
        /// Its heading; nil for the note's opening.
        public var heading: String?
        /// For a section cut in pieces: which this is, and how many there are.
        public var piece: Int?
        public var pieces: Int?

        public init(heading: String?, piece: Int? = nil, pieces: Int? = nil) {
            self.heading = heading
            self.piece = piece
            self.pieces = pieces
        }

        var name: String {
            let name = heading.map { "“\($0)”" } ?? "the opening"
            guard let piece, let pieces else { return name }
            return "\(name) (piece \(piece) of \(pieces))"
        }
    }

    public struct Part: Equatable, Sendable {
        public var number: Int
        public var count: Int
        /// What it holds, in the note's order.
        public var pieces: [Piece]
        /// What the model reads: each section under its "## " heading. The whole note's text when it's read in one part.
        public var text: String

        public init(number: Int, count: Int, pieces: [Piece], text: String) {
            self.number = number
            self.count = count
            self.pieces = pieces
            self.text = text
        }

        /// What it holds, as the prompt says it: `the sections "A" and "B"`, `the note's opening and the section "A"`,
        /// `the section "C" (piece 2 of 3, cut from a longer section)`.
        public var holds: String {
            func cut(_ piece: Piece) -> String {
                guard let number = piece.piece, let of = piece.pieces else { return "" }
                return " (piece \(number) of \(of), cut from a longer section)"
            }
            var said: [String] = []
            if let opening = pieces.first(where: { $0.heading == nil }) { said.append("the note's opening" + cut(opening)) }
            let named = pieces.compactMap { piece in piece.heading.map { "\"\($0)\"" + cut(piece) } }
            if !named.isEmpty {
                let list = named.count == 1 ? named[0] : named.dropLast().joined(separator: ", ") + " and " + named.last!
                said.append((named.count == 1 ? "the section " : "the sections ") + list)
            }
            return said.joined(separator: " and ")
        }

        /// Its first and last sections, for a person: `“A” to “D”`, `“A”`, `the opening to “B”`.
        public var span: String {
            guard let first = pieces.first, let last = pieces.last else { return "" }
            let a = first.heading.map { "“\($0)”" } ?? "the opening", b = last.heading.map { "“\($0)”" } ?? "the opening"
            return first.heading == last.heading ? (first.piece != nil ? first.name : a) : "\(a) to \(b)"
        }
    }

    /// The parts of `text`, each at most `capacity` characters: one part, the note as it is, when it fits.
    public static func plan(_ text: String, capacity: Int) -> [Part] {
        let sections = DistillSections.sections(of: text)
        guard text.count > max(capacity, 500), !sections.isEmpty else {
            return [Part(number: 1, count: 1, pieces: sections.map { Piece(heading: $0.heading) }, text: text)]
        }
        return plan(sections: sections, capacity: capacity)
    }

    /// Parts made of `sections` alone, each under its heading, at most `capacity` characters each (lane DS8: Distill Again
    /// reads only the sections that changed). Nothing for none.
    public static func plan(sections: [DistillSections.Section], capacity: Int) -> [Part] {
        let capacity = max(capacity, 500)
        var atoms: [(piece: Piece, text: String)] = []
        for section in sections {
            let head = section.heading.map { "## \($0)\n\n" } ?? ""
            let whole = head + section.text
            guard whole.count > capacity else {
                atoms.append((Piece(heading: section.heading), whole))
                continue
            }
            let bodies = cut(section.text, limit: max(200, capacity - head.count))
            for (index, body) in bodies.enumerated() {
                atoms.append((Piece(heading: section.heading, piece: index + 1, pieces: bodies.count), head + body))
            }
        }
        let sizes = atoms.map(\.text.count)
        // Fewest parts at the capacity; then the smallest limit that still makes that few, so they come out even.
        let fewest = pack(sizes, limit: capacity).count
        var low = sizes.max() ?? capacity, high = capacity
        while low < high {
            let middle = (low + high) / 2
            if pack(sizes, limit: middle).count <= fewest { high = middle } else { low = middle + 1 }
        }
        let groups = pack(sizes, limit: low)
        return groups.enumerated().map { number, group in
            Part(number: number + 1, count: groups.count, pieces: group.map { atoms[$0].piece },
                 text: group.map { atoms[$0].text }.joined(separator: "\n\n"))
        }
    }

    /// Consecutive sizes into groups of at most `limit` (a blank line between each): each group as full as it goes, which
    /// makes the fewest groups.
    static func pack(_ sizes: [Int], limit: Int) -> [[Int]] {
        var groups: [[Int]] = []
        var current: [Int] = []
        var total = 0
        for (index, size) in sizes.enumerated() {
            if !current.isEmpty, total + 2 + size > limit {
                groups.append(current)
                current = []
                total = 0
            }
            total += current.isEmpty ? size : 2 + size
            current.append(index)
        }
        if !current.isEmpty { groups.append(current) }
        return groups
    }

    /// A section's text in pieces of at most `limit` characters: between paragraphs, else between lines, else between
    /// words.
    static func cut(_ text: String, limit: Int) -> [String] {
        func join(_ units: [String], separator: String, finer: ((String) -> [String])?) -> [String] {
            var pieces: [String] = []
            var current = ""
            for unit in units {
                if unit.count > limit, let finer {
                    if !current.isEmpty { pieces.append(current); current = "" }
                    pieces += finer(unit)
                    continue
                }
                if current.isEmpty {
                    current = unit
                } else if current.count + separator.count + unit.count <= limit {
                    current += separator + unit
                } else {
                    pieces.append(current)
                    current = unit
                }
            }
            if !current.isEmpty { pieces.append(current) }
            return pieces
        }
        func words(_ line: String) -> [String] {
            var pieces: [String] = []
            var rest = Substring(line)
            while rest.count > limit {
                let window = rest.prefix(limit)
                let end = window.lastIndex(of: " ").map { $0 } ?? window.endIndex
                let piece = rest[..<end]
                pieces.append(String(piece))
                rest = rest[end...].drop { $0 == " " }
            }
            if !rest.isEmpty { pieces.append(String(rest)) }
            return pieces
        }
        func lines(_ paragraph: String) -> [String] {
            join(paragraph.components(separatedBy: "\n"), separator: "\n", finer: words)
        }
        let paragraphs = text.components(separatedBy: "\n\n").filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return join(paragraphs, separator: "\n\n", finer: lines)
    }

    /// The parts' readings, in order, as one: repeats left out (a later part's item with an earlier title), a wait across
    /// parts kept by the title it names (an item's, else a section heading's: every item from that section), in the note's
    /// order of sections, at most `DistillPrompt.maxItems` in all (the first, in that order), never waiting in a circle.
    /// Lane DS8: `limit` is the most kept (Distill Again's sections read before come on top of a new reading's), and an
    /// item whose quote and section are an earlier one's, with much the same title, is a repeat too: v2's quotes come
    /// from the lines an item names, so two items from the same line say so.
    public static func merge(_ reads: [DistillReading.Result], headings: [String], limit: Int = DistillPrompt.maxItems) -> DistillReading.Result {
        var result = DistillReading.Result(items: [])
        var items: [DistillReading.Item] = []
        /// Waits by position in `items`.
        var waits: [Set<Int>] = []
        var byTitle: [String: Int] = [:]
        for read in reads {
            result.skipped += read.skipped
            result.repeats += read.repeats
            result.over += read.over
            result.droppedWaits += read.droppedWaits
            result.cutOff = result.cutOff || read.cutOff
            result.thought = result.thought || read.thought
            var local: [Int] = []
            var first: [Bool] = []
            for item in read.items {
                let key = LoopGuard.normalize(item.title)
                let sameLine = item.quote.flatMap { quote in
                    items.indices.first { items[$0].quote == quote && items[$0].section == item.section && DistillAgain.similarity(items[$0].title, item.title) >= 0.5 }
                }
                if let earlier = byTitle[key] ?? sameLine {
                    result.repeats += 1
                    local.append(earlier)
                    first.append(false)
                    continue
                }
                byTitle[key] = items.count
                local.append(items.count)
                first.append(true)
                var kept = item
                kept.waitsFor = []
                items.append(kept)
                waits.append([])
            }
            for (index, item) in read.items.enumerated() where first[index] {
                let me = local[index]
                for wait in item.waitsFor where local[wait] != me { waits[me].insert(local[wait]) }
            }
        }
        // Waits across parts, now that every part is read: an item by its title, else the items of a section by its heading.
        for me in items.indices {
            for title in items[me].waitsElsewhere {
                if let target = byTitle[LoopGuard.normalize(DistillReading.clean(title))] {
                    if target != me { waits[me].insert(target) }
                } else if let heading = DistillSections.match(title, in: headings) {
                    let targets = items.indices.filter { $0 != me && items[$0].section == heading }
                    if targets.isEmpty { result.droppedWaits += 1 }
                    waits[me].formUnion(targets)
                } else {
                    result.droppedWaits += 1
                }
            }
            items[me].waitsElsewhere = []
        }
        // The note's order: by section; an item whose section matched none stays after the one read before it.
        let rank = Dictionary(headings.enumerated().map { ($1, $0 + 1) }, uniquingKeysWith: { a, _ in a })
        var ranks: [Int] = []
        for item in items {
            if let section = item.section, let place = rank[section] {
                ranks.append(place)
            } else if item.unknownSection != nil {
                ranks.append(ranks.last ?? 0)
            } else {
                ranks.append(0)
            }
        }
        let order = items.indices.sorted { ranks[$0] != ranks[$1] ? ranks[$0] < ranks[$1] : $0 < $1 }
        let kept = Array(order.prefix(limit))
        result.over += order.count - kept.count
        let position = Dictionary(kept.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        var lists: [[Int]] = []
        for old in kept {
            var list: [Int] = []
            for target in waits[old].sorted() {
                if let new = position[target] { list.append(new) } else { result.droppedWaits += 1 }
            }
            lists.append(list.sorted())
        }
        let acyclic = CardWaits.acyclic(lists)
        result.droppedWaits += acyclic.dropped.count
        result.items = kept.enumerated().map { new, old in
            var item = items[old]
            item.waitsFor = acyclic.waits[new]
            return item
        }
        return result
    }
}

/// Distill's reading of a note by the language model: the note in as few parts as the model reads well (`DistillBudget`,
/// `DistillParts`), each asked once more with a reminder when its reply has no list in it, the parts' items made one. The
/// model is asked through `ask`, so the Mac's clients, the self-tests' stand-ins and the kit's tests all go the same way.
public enum DistillRun {
    /// One question to the model. Its system prompt is `DistillPrompt.system(who:format:)`: `DistillPrompt.system` when no
    /// one is listed and it's asked as v1.
    public struct Ask: Equatable, Sendable {
        public var user: String
        /// What the stream may write in all (`DistillBudget.streamTokens`).
        public var maxTokens: Int
        /// The answer's own limit, its thinking left out: `DistillReading.stopWhen(replyTokens:)`.
        public var replyTokens: Int
        public var part: Int
        public var parts: Int
        /// 1, or 2 for the try with the reminder.
        public var attempt: Int
        /// The note's "## " headings, in order: the sections a reply held to `schema` may name (lane DS3).
        public var headings: [String] = []
        /// Who can take work in the note's binder (lane AS1): in the instructions, and the names `for` may be.
        public var who: DistillTakers? = nil
        /// The most items this part is asked for (`DistillBudget.maxItems`, lane DS7).
        public var maxItems: Int = DistillPrompt.maxItems
        /// How many items the parts read before it found, for "9 items so far".
        public var itemsBefore: Int = 0
        /// How it's asked (lane DS8).
        public var format: DistillFormat = .v1
        /// The start of `user` every part of the reading shares (v2: the title and the headings), which a model in Binders
        /// reads once for them all; "" for none.
        public var prefix: String = ""
        /// The part's numbered lines, for a v2 question: what its items' lines are read against.
        public var lines: DistillLines? = nil

        public init(user: String, maxTokens: Int, replyTokens: Int, part: Int, parts: Int, attempt: Int, headings: [String] = [],
                    who: DistillTakers? = nil, maxItems: Int = DistillPrompt.maxItems, itemsBefore: Int = 0, format: DistillFormat = .v1,
                    prefix: String = "", lines: DistillLines? = nil) {
            self.user = user
            self.maxTokens = maxTokens
            self.replyTokens = replyTokens
            self.part = part
            self.parts = parts
            self.attempt = attempt
            self.headings = headings
            self.who = who
            self.maxItems = maxItems
            self.itemsBefore = itemsBefore
            self.format = format
            self.prefix = prefix
            self.lines = lines
        }

        /// The instructions this question goes with.
        public var system: String { DistillPrompt.system(who: who, format: format) }

        /// When to stop the reply early.
        public var stopWhen: @Sendable (String) -> Bool { DistillReading.stopWhen(replyTokens: replyTokens) }

        /// The JSON schema this question's reply is held to where the model allows it (`DistillSchema`): v1's sections are
        /// the note's headings, and a wait may name another part's item by its title when the note is read in parts; v2's
        /// is the same for every note (lane DS8).
        public func schema(bounded: Bool) -> String {
            switch format {
            case .v1: DistillSchema.json(headings: headings, waitsByTitle: parts > 1, bounded: bounded, names: who?.names ?? [])
            case .v2: DistillSchema.jsonV2(bounded: bounded, names: who?.names ?? [])
            }
        }

        /// When to stop a reply held to the schema early: only when it loops. Its length is the schema's to bring to a
        /// close (MLX), or the server's `max_tokens`.
        public var stopWhenHeld: @Sendable (String) -> Bool { { DistillReading.isLooping($0) } }

        /// A reply, or the part of one written so far, read as this question's: v2's items given their lines.
        public func read(_ reply: String) -> DistillReading.Result {
            var reading = DistillReading.read(reply, headings: headings, elsewhere: parts > 1, names: who?.others ?? [])
            if let lines { reading.resolve(lines: lines, headings: headings) }
            return reading
        }
    }

    /// Thrown by `ask` when the model turned the prompt down as longer than its context: the reading starts again in
    /// smaller parts, sized from the context it said, else half as big.
    public struct TooLong: Error, Equatable, Sendable {
        public var contextTokens: Int?
        public init(contextTokens: Int?) { self.contextTokens = contextTokens }
    }

    /// How one part went.
    public struct PartOutcome: Equatable, Sendable {
        public var number: Int
        public var count: Int
        public var pieces: [DistillParts.Piece]
        public var span: String
        /// How many times it was asked: 2 when the first reply had no list.
        public var tries: Int
        /// Its replies had no list, the second one too.
        public var noList: Bool
        /// They were only thinking.
        public var onlyThinking: Bool
        /// What the model wrote first, its thinking left out, when there was no list.
        public var firstLines: String?
        /// It couldn't be asked: the error, in words.
        public var error: String?
        public var items: Int
        /// Its reply stopped before it was done (lane DS7): why. The whole items written before the stop are kept.
        public var stop: StreamStop? = nil
        /// Why, in words: "the model stopped writing for 90 seconds".
        public var cutShort: String? = nil
        /// It wasn't asked: the reading ended before it (you stopped it, or the model didn't answer).
        public var notRead: Bool = false
        /// What it read, before the parts were made one (lane DS8): what's kept of each section it read whole.
        public var read: DistillReading.Result? = nil
    }

    public struct Outcome: Equatable, Sendable {
        /// Every part's items, made one.
        public var result: DistillReading.Result
        public var parts: [PartOutcome]
        /// How much of the note a part held, in characters.
        public var capacity: Int
        public var budget: DistillBudget
    }

    /// Reads `text` (the note titled `title`). An error from `ask` is noted in its part's outcome and the rest go on; the
    /// reading fails with the first error only when every part asked failed (lane DS7). A reply stopped part way
    /// (`StreamStopped`) keeps the whole items it wrote, and its part is noted as cut short; the reading goes on, unless you
    /// stopped it. Two parts in a row that the model gave nothing for (an error, or no words at all) end it. `TooLong`
    /// starts again in smaller parts, twice at most. `who`: who can take work in the note's binder (lane AS1), which the
    /// instructions list, so a part holds that much less.
    /// Lane DS8: `format` is how it's asked. A part's question no longer lists the items the parts before it found, so
    /// parts may be asked `concurrent` at a time (a server that answers more than one; 1 for a model in Binders), their
    /// results made one in the note's order. `only`: the sections to read, the rest having been read before (Distill
    /// Again), each part cut from those alone. `onPart`: each part's reading as it's done.
    public static func read(title: String, text: String, budget: DistillBudget, who: DistillTakers? = nil, format: DistillFormat = .v1,
                            concurrent: Int = 1, only: [DistillSections.Section]? = nil,
                            onPart: (@Sendable (PartOutcome) async -> Void)? = nil,
                            ask: @escaping @Sendable (Ask) async throws -> String) async throws -> Outcome {
        let headings = DistillSections.sections(of: text).compactMap(\.heading)
        let who = who?.isEmpty == false ? who : nil
        let listed = DistillPrompt.system(who: who, format: format).count - DistillPrompt.system(who: nil, format: format).count
        var budget = budget
        var tries = 0
        while true {
            let header = title.count + DistillPrompt.headingsLine(headings).count + listed
            let capacity = budget.capacity(header: header)
            let parts = only.map { DistillParts.plan(sections: $0, capacity: capacity) } ?? DistillParts.plan(text, capacity: capacity)
            do {
                return try await readParts(parts, title: title, headings: headings, budget: budget, capacity: capacity, who: who, format: format,
                                           concurrent: max(1, concurrent), partial: only != nil, onPart: onPart, ask: ask)
            } catch let tooLong as TooLong where tries < 2 {
                tries += 1
                var smaller = tooLong.contextTokens.map { DistillBudget.forContext($0, format: format) } ?? budget.halved
                if smaller.capacity(header: header) >= capacity { smaller = budget.halved }
                // A slow model's smaller answer stays (lane DS7).
                smaller.maxItems = min(smaller.maxItems, budget.maxItems)
                smaller.replyTokens = min(smaller.replyTokens, budget.replyTokens)
                smaller.paced = budget.paced
                budget = smaller
            }
        }
    }

    /// What one part's asking came to.
    private struct PartRead: Sendable {
        var index: Int
        var outcome: PartOutcome
        var error: Error?
        var stopped: Bool { outcome.stop == .stopped }
    }

    private static func readParts(_ parts: [DistillParts.Part], title: String, headings: [String], budget: DistillBudget, capacity: Int,
                                  who: DistillTakers?, format: DistillFormat, concurrent: Int, partial: Bool,
                                  onPart: (@Sendable (PartOutcome) async -> Void)?,
                                  ask: @escaping @Sendable (Ask) async throws -> String) async throws -> Outcome {
        var outcomes: [PartOutcome?] = Array(repeating: nil, count: parts.count)
        var errors: [Error?] = Array(repeating: nil, count: parts.count)
        /// Parts in a row the model gave nothing for: an error, or no words at all.
        var silent = 0
        /// Why the parts left aren't read, once the reading has ended; nil words when you stopped it.
        var ended: (why: String?, at: Int)?
        let items = budget.maxItems
        try await withThrowingTaskGroup(of: PartRead.self) { group in
            var next = 0
            func launch() {
                let index = next
                next += 1
                let part = parts[index]
                let found = outcomes.compactMap { $0?.items }.reduce(0, +)
                let question = question(part, title: title, headings: headings, budget: budget, who: who, format: format, items: items,
                                        found: found, partial: partial)
                group.addTask { try await readPart(part, index: index, question: question, ask: ask) }
            }
            while next < min(concurrent, parts.count) { launch() }
            while let done = try await group.next() {
                outcomes[done.index] = done.outcome
                errors[done.index] = done.error
                await onPart?(done.outcome)
                silent = done.outcome.read == nil && (done.outcome.error != nil || done.outcome.stop == .noStart) ? silent + 1 : 0
                if done.stopped {
                    ended = (nil, done.outcome.number)
                } else if silent >= 2, ended == nil {
                    ended = ("the model didn't answer for two parts in a row", done.outcome.number)
                }
                if ended == nil, next < parts.count { launch() }
            }
        }
        let all: [PartOutcome] = parts.enumerated().map { index, part in
            if let outcome = outcomes[index] { return outcome }
            return PartOutcome(number: part.number, count: part.count, pieces: part.pieces, span: part.span, tries: 0, noList: false,
                               onlyThinking: false, firstLines: nil, error: nil, items: 0, cutShort: ended?.why, notRead: true)
        }
        let reads = all.compactMap(\.read)
        // Every part asked failed: the reading couldn't be done, as a reading in one part always said.
        let asked = all.filter { !$0.notRead }
        if reads.isEmpty, let firstError = errors.compactMap({ $0 }).first, asked.allSatisfy({ $0.error != nil }) { throw firstError }
        let cut = all.contains { $0.cutShort != nil }
        var result: DistillReading.Result
        if parts.count == 1 {
            result = reads.first ?? DistillReading.Result(items: [], noList: !cut)
        } else {
            // Every part's items: each reply holds to its own count, so a long note isn't cut to one reply's worth.
            result = DistillParts.merge(reads, headings: headings, limit: .max)
            result.noList = reads.isEmpty && !cut
        }
        if reads.isEmpty {
            result.onlyThinking = all.contains { $0.noList } && all.filter(\.noList).allSatisfy(\.onlyThinking)
            result.firstLines = all.compactMap(\.firstLines).first
        }
        return Outcome(result: result, parts: all, capacity: capacity, budget: budget)
    }

    /// A part's question, its first try's.
    private static func question(_ part: DistillParts.Part, title: String, headings: [String], budget: DistillBudget, who: DistillTakers?,
                                 format: DistillFormat, items: Int, found: Int, partial: Bool) -> Ask {
        switch format {
        case .v1:
            let user = part.count == 1 && !partial ? DistillPrompt.user(title: title, sections: headings, text: part.text, items: items)
                : DistillPrompt.part(title: title, sections: headings, part: part, earlier: [], items: items)
            return Ask(user: user, maxTokens: budget.streamTokens, replyTokens: budget.replyTokens, part: part.number, parts: part.count, attempt: 1,
                       headings: headings, who: who, maxItems: items, itemsBefore: found, format: .v1)
        case .v2:
            let lines = DistillLines(part.text)
            let user = DistillPrompt.partV2(title: title, sections: headings, part: part, lines: lines, items: items, partial: partial)
            return Ask(user: user, maxTokens: budget.streamTokens, replyTokens: budget.replyTokens, part: part.number, parts: part.count, attempt: 1,
                       headings: headings, who: who, maxItems: items, itemsBefore: found, format: .v2,
                       prefix: DistillPrompt.prefix(title: title, sections: headings), lines: lines)
        }
    }

    /// Asks for one part: once more with the reminder when the first reply had no list. A reply cut short keeps its whole
    /// items and isn't asked again; an error is noted, and the reading goes on.
    private static func readPart(_ part: DistillParts.Part, index: Int, question: Ask, ask: @escaping @Sendable (Ask) async throws -> String) async throws -> PartRead {
        var outcome = PartOutcome(number: part.number, count: part.count, pieces: part.pieces, span: part.span, tries: 0, noList: false,
                                  onlyThinking: false, firstLines: nil, error: nil, items: 0)
        var read: DistillReading.Result?
        var failure: Error?
        for attempt in 1...2 {
            outcome.tries = attempt
            var asked = question
            asked.attempt = attempt
            if attempt == 2 { asked.user = DistillPrompt.again(question.user) }
            let reply: String
            do {
                reply = try await ask(asked)
            } catch let error as TooLong {
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch let stopped as StreamStopped {
                // Cut short: the whole items before the stop are kept, and it isn't asked again.
                outcome.stop = stopped.why
                outcome.cutShort = stopped.words
                var reading = asked.read(stopped.text)
                if !reading.items.isEmpty {
                    // The part's note says it was cut short.
                    reading.cutOff = false
                    read = reading
                }
                break
            } catch {
                // Noted, and on to the next part (lane DS7: the first part's error no longer ends the reading).
                failure = error
                outcome.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                break
            }
            let reading = asked.read(reply)
            if !reading.noList {
                read = reading
                break
            }
            outcome.noList = true
            outcome.onlyThinking = reading.onlyThinking
            outcome.firstLines = reading.firstLines ?? outcome.firstLines
        }
        if let read {
            outcome.noList = false
            outcome.onlyThinking = false
            outcome.firstLines = nil
            outcome.items = read.items.count
            outcome.read = read
        }
        return PartRead(index: index, outcome: outcome, error: failure)
    }

    /// What the Work bar says while a note is read: "Reading part 2 of 5 · 9 items so far", "Reading the note…".
    public static func readingLine(part: Int, of parts: Int, items: Int) -> String {
        let reading = parts > 1 ? "Reading part \(part) of \(parts)" : "Reading the note"
        guard items > 0 else { return reading + "…" }
        return reading + " · " + (items == 1 ? "1 item so far" : "\(items) items so far")
    }
}

extension DistillRun.Outcome {
    /// Read in more than one part.
    public var inParts: Bool { parts.count > 1 }
    /// No part's reply had a list in it, even asked again.
    public var noList: Bool { result.items.isEmpty && parts.contains { $0.noList } && parts.allSatisfy { $0.noList || $0.error != nil } }
    /// Parts that gave nothing: no list after two tries, or an error.
    public var missing: [DistillRun.PartOutcome] { parts.filter { $0.noList || $0.error != nil } }
    /// A part was cut short, or not read (lane DS7).
    public var cutShort: Bool { parts.contains { $0.cutShort != nil || $0.notRead } }
    /// You stopped the reading.
    public var stopped: Bool { parts.contains { $0.stop == .stopped } }
    /// What the model wrote first in the replies with no list, its thinking left out.
    public var firstLines: String? { parts.compactMap(\.firstLines).first }

    /// Why a reading made no list at all, in words for the Work bar and the alert: for a note read in parts, that it may be
    /// too long for `model`, with the choice of an agent (`agents`: one of yours can read the note).
    public func noListWords(model: String, agents: Bool) -> String {
        let model = model.isEmpty ? "this model" : model
        let instead = agents ? "Distill it with one of your agents instead, or choose another model in Settings → AI."
            : "Choose another model in Settings → AI, or split the note into shorter ones."
        if result.onlyThinking {
            let each = inParts ? " for each of the \(parts.count) parts of this note" : ""
            return "\(model) spent its whole reply thinking\(each) and never wrote the list, even when asked again. "
                + (agents ? "Choose a model that doesn't think first in Settings → AI, or Distill with one of your agents."
                   : "Choose a model that doesn't think first in Settings → AI.")
        }
        if inParts {
            return "The model answered without a list of work items for each of the \(parts.count) parts of this note, even when asked again, "
                + "so the note may be too long for \(model). " + instead
        }
        return "The model answered without a list of work items, even when asked again. Try again, or "
            + (agents ? "choose another model in Settings → AI, or Distill with one of your agents." : "choose another model in Settings → AI.")
    }

    /// For the review sheet and the Work bar: the parts that gave nothing, were cut short or weren't read, and why, or nil
    /// when every part was read whole. A reading cut short says Distill Again reads the rest: it proposes only what's new.
    public var partsNote: String? {
        var lines: [String] = []
        var rest = false
        for part in parts where !part.notRead {
            let which = "Part \(part.number) of \(part.count) (\(part.span))"
            if let cut = part.cutShort {
                rest = true
                let kept = part.items == 0 ? "It hadn't finished an item."
                    : part.items == 1 ? "The 1 item it had finished is here." : "The \(part.items) items it had finished are here."
                if part.stop == .stopped {
                    lines.append((inParts ? "You stopped the reading in part \(part.number) of \(part.count) (\(part.span))." : "You stopped the reading.") + " " + kept)
                } else {
                    lines.append("\(inParts ? which : "The reading") was cut short: \(cut). \(kept)")
                }
                continue
            }
            guard inParts else { continue }
            if let error = part.error {
                lines.append("\(which) couldn't be read: \(error)")
            } else if part.noList {
                let wrote = part.onlyThinking ? " The model only thought." : part.firstLines.map { " The model wrote: “\($0)”" } ?? ""
                lines.append("\(which) had no list of work items, even when asked again, so its work isn't here.\(wrote)")
            }
        }
        let notRead = parts.filter(\.notRead)
        if let first = notRead.first, let last = notRead.last {
            rest = true
            let which = first.number == last.number ? "Part \(first.number) of \(first.count) wasn't read" : "Parts \(first.number) to \(last.number) of \(first.count) weren't read"
            lines.append(which + (first.cutShort.map { ": \($0)." } ?? "."))
        }
        guard !lines.isEmpty else { return nil }
        return lines.joined(separator: " ") + (rest ? " Distill Again to read the rest: it proposes only what's new." : " Distill Again to read the note again.")
    }

    /// "in 4 parts": how the review sheet says it read the note, or nil for one part.
    public var partsLine: String? { inParts ? "in \(parts.count) parts" : nil }
}
