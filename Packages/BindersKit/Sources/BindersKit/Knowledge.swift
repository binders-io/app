import Foundation

// MARK: - Documents and chunks

public enum KnowledgeKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case meeting, note, writing, dictation, command

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .meeting: "Meetings"
        case .note: "Notes"
        case .writing: "Writing"
        case .dictation: "Dictations"
        case .command: "Commands"
        }
    }
}

public struct KnowledgeChunk: Equatable, Sendable {
    public var text: String
    public var startTime: TimeInterval?
    public var speaker: String?

    public init(text: String, startTime: TimeInterval? = nil, speaker: String? = nil) {
        self.text = text
        self.startTime = startTime
        self.speaker = speaker
    }
}

/// Splits content into passages small enough to search and embed precisely.
public enum KnowledgeChunker {
    public static func chunks(_ text: String, maxWords: Int = 140, label: String? = nil) -> [KnowledgeChunk] {
        var output: [KnowledgeChunk] = []
        var current: [String] = []
        var count = 0
        func flush() {
            guard !current.isEmpty else { return }
            output.append(KnowledgeChunk(text: current.joined(separator: "\n"), speaker: label))
            current = []
            count = 0
        }
        for piece in pieces(text, maxWords: maxWords) {
            let words = wordCount(piece)
            if count + words > maxWords { flush() }
            current.append(piece)
            count += words
        }
        flush()
        return output
    }

    /// Groups transcript blocks, keeping the timestamp and speaker where each passage starts.
    public static func transcriptChunks(_ blocks: [TranscriptBlock], maxWords: Int = 140) -> [KnowledgeChunk] {
        var output: [KnowledgeChunk] = []
        var lines: [String] = []
        var count = 0
        var start: TimeInterval?
        var speaker: String?
        func flush() {
            guard !lines.isEmpty else { return }
            output.append(KnowledgeChunk(text: lines.joined(separator: "\n"), startTime: start, speaker: speaker))
            lines = []
            count = 0
        }
        for block in blocks {
            for piece in pieces(block.text, maxWords: maxWords) {
                let words = wordCount(piece)
                if count + words > maxWords { flush() }
                if lines.isEmpty {
                    start = block.start
                    speaker = block.speaker
                }
                lines.append("\(block.speaker): \(piece)")
                count += words
            }
        }
        flush()
        return output
    }

    /// Paragraphs; over-long paragraphs become sentences, over-long sentences become word windows.
    static func pieces(_ text: String, maxWords: Int) -> [String] {
        var result: [String] = []
        for paragraph in text.components(separatedBy: .newlines) {
            let trimmed = paragraph.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if wordCount(trimmed) <= maxWords {
                result.append(trimmed)
                continue
            }
            let sentences = trimmed.replacingOccurrences(of: "([.!?])\\s+", with: "$1\n", options: .regularExpression)
                .components(separatedBy: "\n")
            for sentence in sentences {
                let words = sentence.split(whereSeparator: \.isWhitespace)
                if words.count <= maxWords {
                    if !words.isEmpty { result.append(sentence) }
                } else {
                    for start in stride(from: 0, to: words.count, by: maxWords) {
                        result.append(words[start..<min(start + maxWords, words.count)].joined(separator: " "))
                    }
                }
            }
        }
        return result
    }

    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }
}

// MARK: - Retrieval math

public enum VectorMath {
    public static func normalized(_ vector: [Float]) -> [Float] {
        let norm = vector.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
        guard norm > 0 else { return vector }
        return vector.map { $0 / norm }
    }

    public static func dot(_ a: [Float], _ b: [Float]) -> Float {
        let count = min(a.count, b.count)
        var sum: Float = 0
        a.withUnsafeBufferPointer { pa in
            b.withUnsafeBufferPointer { pb in
                for index in 0..<count { sum += pa[index] * pb[index] }
            }
        }
        return sum
    }

    /// Candidates must already be normalized.
    public static func topMatches<ID>(query: [Float], candidates: [(id: ID, vector: [Float])], limit: Int,
                                      minScore: Float = -1) -> [(id: ID, score: Float)] {
        let normalizedQuery = normalized(query)
        return candidates
            .map { (id: $0.id, score: dot(normalizedQuery, $0.vector)) }
            .filter { $0.score >= minScore }
            .sorted { $0.score > $1.score }
            .prefix(limit)
            .map { $0 }
    }
}

public enum RankFusion {
    /// Reciprocal rank fusion: merges keyword and semantic rankings without comparing their raw scores.
    public static func reciprocalRank<ID: Hashable>(_ rankings: [[ID]], k: Double = 60) -> [(id: ID, score: Double)] {
        var scores: [ID: Double] = [:]
        var firstSeen: [ID: Int] = [:]
        for ranking in rankings {
            for (rank, id) in ranking.enumerated() {
                scores[id, default: 0] += 1 / (k + Double(rank + 1))
                if firstSeen[id] == nil { firstSeen[id] = firstSeen.count }
            }
        }
        return scores
            .sorted { $0.value == $1.value ? firstSeen[$0.key]! < firstSeen[$1.key]! : $0.value > $1.value }
            .map { (id: $0.key, score: $0.value) }
    }
}

// MARK: - Entities

public struct ExtractedEntity: Codable, Equatable, Sendable {
    public var name: String
    public var type: String
    public var aliases: [String]

    public init(name: String, type: String, aliases: [String] = []) {
        self.name = name
        self.type = type
        self.aliases = aliases
    }

    private enum CodingKeys: String, CodingKey { case name, type, aliases }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        type = (try? container.decodeIfPresent(String.self, forKey: .type)) ?? "topic"
        aliases = (try? container.decodeIfPresent([String].self, forKey: .aliases)) ?? []
    }
}

public struct ExtractedRelation: Codable, Equatable, Sendable {
    public var from: String
    public var to: String
    public var label: String

    public init(from: String, to: String, label: String) {
        self.from = from
        self.to = to
        self.label = label
    }
}

public struct ExtractionResult: Codable, Equatable, Sendable {
    public var entities: [ExtractedEntity]
    public var relations: [ExtractedRelation]

    public init(entities: [ExtractedEntity] = [], relations: [ExtractedRelation] = []) {
        self.entities = entities
        self.relations = relations
    }

    private enum CodingKeys: String, CodingKey { case entities, relations }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        entities = (try? container.decodeIfPresent([ExtractedEntity].self, forKey: .entities)) ?? []
        relations = (try? container.decodeIfPresent([ExtractedRelation].self, forKey: .relations)) ?? []
    }
}

public enum EntityExtraction {
    public static let types = ["person", "project", "product", "company", "team", "place", "topic"]

    static let generic: Set<String> = [
        "meeting", "meetings", "call", "team", "teams", "project", "product", "company", "everyone", "someone", "you", "me",
        "we", "us", "today", "tomorrow", "yesterday", "next week", "last week", "update", "updates", "plan", "plans", "notes",
        "discussion", "topic", "topics", "thing", "things", "question", "questions", "issue", "issues", "idea", "ideas", "time",
        "work", "task", "tasks", "action items", "decision", "decisions", "user", "users", "people", "customer", "customers",
    ]

    public static func systemPrompt() -> String {
        """
        You build a knowledge graph from a user's meetings and notes. Extract the specific things they would want to look up later: \
        people (by name), companies, products, projects, teams, places, and specific topics (for example "Apple Pay", "Q3 roadmap", "beta program").
        - Skip generic words (meeting, plan, update, team, users), pronouns, dates, times and numbers.
        - Use the canonical, properly capitalized name; put other spellings used in the text in "aliases".
        - Relations connect two extracted names with a short verb phrase, e.g. {"from":"Daniel","to":"Q3 roadmap","label":"owns"}.
        - At most 20 entities and 20 relations.
        Reply with compact single-line JSON only:
        {"entities":[{"name":"","type":"person|project|product|company|team|place|topic","aliases":[]}],"relations":[{"from":"","to":"","label":""}]}
        """
    }

    /// Tolerates code fences and prose around the JSON, then cleans the result.
    public static func parse(_ output: String) -> ExtractionResult {
        if let start = output.firstIndex(of: "{"), let end = output.lastIndex(of: "}"), start < end,
           let decoded = try? JSONDecoder().decode(ExtractionResult.self, from: Data(output[start...end].utf8)),
           !(decoded.entities.isEmpty && output.contains("\"name\"")) {
            return clean(decoded)
        }
        return clean(salvage(output))
    }

    /// Local models occasionally emit one malformed object (e.g. `"aliases[]`); keep every well-formed one instead of losing the reply.
    static func salvage(_ output: String) -> ExtractionResult {
        guard let objectPattern = try? NSRegularExpression(pattern: "\\{[^{}]*\\}") else { return ExtractionResult() }
        var result = ExtractionResult()
        let text = output as NSString
        for match in objectPattern.matches(in: output, range: NSRange(location: 0, length: text.length)) {
            let object = text.substring(with: match.range)
            if let name = stringField("name", in: object) {
                result.entities.append(ExtractedEntity(name: name, type: stringField("type", in: object) ?? "topic",
                                                       aliases: stringArrayField("aliases", in: object)))
            } else if let from = stringField("from", in: object), let to = stringField("to", in: object),
                      let label = stringField("label", in: object) {
                result.relations.append(ExtractedRelation(from: from, to: to, label: label))
            }
        }
        return result
    }

    private static func stringField(_ key: String, in object: String) -> String? {
        let pattern = "\"\(key)\"\\s*:\\s*\"((?:[^\"\\\\]|\\\\.)*)\""
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: object, range: NSRange(object.startIndex..., in: object)),
              let range = Range(match.range(at: 1), in: object) else { return nil }
        return String(object[range]).replacingOccurrences(of: "\\\"", with: "\"")
    }

    private static func stringArrayField(_ key: String, in object: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: "\"\(key)\"\\s*:\\s*\\[([^\\]]*)\\]"),
              let match = regex.firstMatch(in: object, range: NSRange(object.startIndex..., in: object)),
              let range = Range(match.range(at: 1), in: object),
              let strings = try? NSRegularExpression(pattern: "\"((?:[^\"\\\\]|\\\\.)*)\"") else { return [] }
        let inner = String(object[range])
        return strings.matches(in: inner, range: NSRange(inner.startIndex..., in: inner)).compactMap { item in
            Range(item.range(at: 1), in: inner).map { String(inner[$0]) }
        }
    }

    public static func clean(_ result: ExtractionResult) -> ExtractionResult {
        var index: [String: Int] = [:]
        var entities: [ExtractedEntity] = []
        for entity in result.entities {
            let name = entity.name.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'“”‘’.,;:")))
            let key = normalize(name)
            guard key.count > 1, name.count <= 60, key.split(separator: " ").count <= 6, !generic.contains(key) else { continue }
            let type = types.contains(entity.type.lowercased()) ? entity.type.lowercased() : "topic"
            let aliases = entity.aliases
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && normalize($0) != key }
            if let existing = index[key] {
                entities[existing].aliases = Array(Set(entities[existing].aliases + aliases)).sorted()
                continue
            }
            guard entities.count < 30 else { break }
            index[key] = entities.count
            entities.append(ExtractedEntity(name: name, type: type, aliases: aliases))
        }
        let relations = result.relations.compactMap { relation -> ExtractedRelation? in
            let label = relation.label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let from = index[normalize(relation.from)], let to = index[normalize(relation.to)], from != to,
                  !label.isEmpty, label.count <= 40 else { return nil }
            return ExtractedRelation(from: entities[from].name, to: entities[to].name, label: label)
        }
        return ExtractionResult(entities: entities, relations: Array(relations.prefix(30)))
    }

    /// Case-, accent- and punctuation-insensitive key: "The Q3 Roadmap." -> "q3 roadmap".
    public static func normalize(_ name: String) -> String {
        var key = name.lowercased().folding(options: .diacriticInsensitive, locale: nil)
        key = key.replacingOccurrences(of: "[^\\p{L}\\p{N}+#&]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        if key.hasPrefix("the ") { key.removeFirst(4) }
        return key
    }

    /// Normalized text padded with spaces, for repeated whole-word lookups.
    public static func haystack(_ text: String) -> String {
        " " + normalize(text) + " "
    }

    public static func contains(haystack: String, key: String) -> Bool {
        key.count > 1 && haystack.contains(" " + key + " ")
    }
}

public enum WikiLinks {
    /// Targets of `[[Name]]` and `[[Name|shown text]]`, in order, without duplicates.
    public static func targets(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: "\\[\\[([^\\[\\]|]+)(?:\\|[^\\[\\]]*)?\\]\\]") else { return [] }
        var seen = Set<String>()
        var result: [String] = []
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range(at: 1), in: text) else { continue }
            let name = text[range].trimmingCharacters(in: .whitespaces)
            if !name.isEmpty, seen.insert(name.lowercased()).inserted { result.append(name) }
        }
        return result
    }
}

// MARK: - Asking

public enum KnowledgeQueryIntent {
    /// When a spoken command is a lookup in the user's own meetings, notes or dictations, returns what to search for.
    public static func query(from instruction: String) -> String? {
        let text = instruction.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "?.!")))
        let lookup = "(?i)^(?:hey\\s+)?(?:look\\s*up|search\\s+(?:my|our)\\s+(?:notes|meetings|knowledge|history|dictations)(?:\\s+for)?|find\\s+(?:in\\s+)?(?:my|our)\\s+(?:notes|meetings)(?:\\s+for)?|remind\\s+me\\s+(?:about|of)|recall)\\s+(.+)$"
        if let regex = try? NSRegularExpression(pattern: lookup),
           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let range = Range(match.range(at: 1), in: text) {
            return String(text[range]).trimmingCharacters(in: .whitespaces)
        }
        let recallQuestion = "(?i)^(?:what|when|who|where|why|how|which|did)\\b.*\\b(?:we|i|they|he|she|you)\\s+(?:decide[ds]?|say|said|agree[ds]?|discuss(?:ed)?|talk(?:ed)?|mention(?:ed)?|plan(?:ned)?|promise[ds]?|commit(?:ted)?|dictate[ds]?|conclude[ds]?|note[ds]?)\\b"
        let meetingQuestion = "(?i)^(?:what|when|who|which)\\b.*\\b(?:meeting|call|notes?|standup|one on one|1:1)\\b"
        let ownershipQuestion = "(?i)^(?:who|when|what|which)\\b.*\\b(?:owns?|owner|responsible|in charge|assigned|due|deadline|following up|follow up|next steps?|action items?)\\b"
        for pattern in [recallQuestion, meetingQuestion, ownershipQuestion] where text.range(of: pattern, options: .regularExpression) != nil {
            return text
        }
        return nil
    }

    /// True for spoken questions ("who…", "…?") that might be about the user's own material; confirm with the index.
    public static func isQuestion(_ instruction: String) -> Bool {
        let text = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.hasSuffix("?") || text.range(of: "(?i)^(?:who|what|when|where|why|how|which|did|do|does|is|are|was|were)\\b", options: .regularExpression) != nil
    }
}

public struct KnowledgeContext: Equatable, Sendable {
    public var label: String
    public var text: String

    public init(label: String, text: String) {
        self.label = label
        self.text = text
    }
}

public enum KnowledgePrompts {
    public static func answerSystemPrompt(today: String) -> String {
        """
        You answer the user's questions from their own meetings, notes, dictations and voice commands, given as numbered sources. Today is \(today).
        - Use only the sources and cite them inline like [1] or [2][3]. Never invent details.
        - Answer directly in one to four sentences; add short bullets only when they help.
        - If the sources don't answer the question, say so plainly and mention the closest related information you found.
        - "You" in meeting transcripts is the user.
        """
    }

    public static func answerUserPrompt(question: String, contexts: [KnowledgeContext]) -> String {
        let sources = contexts.enumerated()
            .map { "[\($0.offset + 1)] \($0.element.label)\n\($0.element.text)" }
            .joined(separator: "\n\n")
        return "Sources:\n\(sources)\n\nQuestion: \(question)"
    }
}

// MARK: - Graph layout

public struct GraphNode: Equatable, Sendable {
    public var id: String
    public var weight: Double

    public init(id: String, weight: Double) {
        self.id = id
        self.weight = weight
    }
}

public struct GraphEdge: Equatable, Sendable {
    public var from: String
    public var to: String
    public var weight: Double

    public init(from: String, to: String, weight: Double = 1) {
        self.from = from
        self.to = to
        self.weight = weight
    }
}

public enum GraphLayout {
    /// Deterministic force-directed layout (Fruchterman–Reingold) normalized into the unit square.
    public static func layout(nodes: [GraphNode], edges: [GraphEdge], iterations: Int = 250) -> [String: SIMD2<Double>] {
        let count = nodes.count
        guard count > 0 else { return [:] }
        guard count > 1 else { return [nodes[0].id: SIMD2(0.5, 0.5)] }

        var index: [String: Int] = [:]
        for (offset, node) in nodes.enumerated() { index[node.id] = offset }
        // Golden-angle spiral start: deterministic and evenly spread.
        var positions = (0..<count).map { offset -> SIMD2<Double> in
            let angle = Double(offset) * 2.399963
            let radius = 0.45 * ((Double(offset) + 0.5) / Double(count)).squareRoot()
            return SIMD2(0.5 + radius * cos(angle), 0.5 + radius * sin(angle))
        }
        let links = edges.compactMap { edge -> (Int, Int, Double)? in
            guard let a = index[edge.from], let b = index[edge.to], a != b else { return nil }
            return (a, b, edge.weight)
        }
        let k = (1.0 / Double(count)).squareRoot()
        var temperature = 0.1

        for _ in 0..<iterations {
            var displacement = [SIMD2<Double>](repeating: .zero, count: count)
            for i in 0..<count {
                for j in (i + 1)..<count {
                    var delta = positions[i] - positions[j]
                    var distance = (delta.x * delta.x + delta.y * delta.y).squareRoot()
                    if distance < 1e-4 {
                        delta = SIMD2(1e-3 * Double((i + j) % 7 + 1), 1e-3)
                        distance = 1e-3
                    }
                    let push = delta / distance * (k * k / distance)
                    displacement[i] += push
                    displacement[j] -= push
                }
            }
            for (a, b, weight) in links {
                let delta = positions[a] - positions[b]
                let distance = max((delta.x * delta.x + delta.y * delta.y).squareRoot(), 1e-4)
                let pull = delta / distance * (distance * distance / k * min(2, 0.5 + weight * 0.25))
                displacement[a] -= pull
                displacement[b] += pull
            }
            for i in 0..<count {
                // Strong enough that disconnected groups settle near each other instead of in opposite corners.
                displacement[i] += (SIMD2(0.5, 0.5) - positions[i]) * 0.4
                let length = (displacement[i].x * displacement[i].x + displacement[i].y * displacement[i].y).squareRoot()
                if length > 0 { positions[i] += displacement[i] / length * min(length, temperature) }
            }
            temperature = max(0.002, temperature * 0.97)
        }

        let xs = positions.map(\.x), ys = positions.map(\.y)
        let minX = xs.min()!, maxX = xs.max()!, minY = ys.min()!, maxY = ys.max()!
        let span = max(maxX - minX, maxY - minY, 1e-6)
        var result: [String: SIMD2<Double>] = [:]
        for (offset, node) in nodes.enumerated() {
            // Center the layout and leave a margin for labels.
            let x = 0.5 + 0.76 * ((positions[offset].x - minX) - (maxX - minX) / 2) / span
            let y = 0.5 + 0.76 * ((positions[offset].y - minY) - (maxY - minY) / 2) / span
            result[node.id] = SIMD2(x, y)
        }
        return result
    }
}

/// A live force-directed layout for the graph view: call `step` once per frame. Nodes push apart, links pull
/// together, everything drifts toward the centre, and the energy cools so the layout settles instead of jittering.
public struct GraphSimulation: Sendable {
    public private(set) var positions: [SIMD2<Double>]
    public private(set) var velocities: [SIMD2<Double>]
    public let ids: [String]
    private let links: [(a: Int, b: Int, weight: Double)]
    private let index: [String: Int]
    private var pinned: Set<Int> = []
    /// Remaining energy 0...1; forces scale with it.
    public private(set) var alpha: Double
    private let k: Double

    /// Nodes start clustered near the centre (`seedRadius`) so the first frames bloom outward.
    public init(nodes: [GraphNode], edges: [GraphEdge], seedRadius: Double = 0.08) {
        ids = nodes.map(\.id)
        let count = nodes.count
        var index: [String: Int] = [:]
        for (offset, node) in nodes.enumerated() { index[node.id] = offset }
        self.index = index
        positions = (0..<count).map { offset in
            let angle = Double(offset) * 2.399963
            let radius = seedRadius * ((Double(offset) + 0.5) / Double(max(count, 1))).squareRoot()
            return SIMD2(0.5 + radius * cos(angle), 0.5 + radius * sin(angle))
        }
        velocities = Array(repeating: .zero, count: count)
        links = edges.compactMap { edge in
            guard let a = index[edge.from], let b = index[edge.to], a != b else { return nil }
            return (a, b, edge.weight)
        }
        k = count > 1 ? (0.9 / Double(count)).squareRoot() : 0.3
        alpha = count > 1 ? 1 : 0
    }

    public var isSettled: Bool { alpha <= 0 }
    public func index(of id: String) -> Int? { index[id] }

    /// Puts energy back so the layout moves again (after a drag, or to replay the bloom).
    public mutating func reheat(_ energy: Double = 0.6) { alpha = max(alpha, min(1, energy)) }

    /// Holds a node where the user is dragging it.
    public mutating func pin(_ node: Int, at position: SIMD2<Double>) {
        guard positions.indices.contains(node) else { return }
        pinned.insert(node)
        positions[node] = position
        velocities[node] = .zero
        reheat(0.4)
    }

    public mutating func release(_ node: Int) { pinned.remove(node) }

    /// Scatters the nodes back around the centre and restarts the bloom.
    public mutating func scatter() {
        let count = positions.count
        for offset in 0..<count where !pinned.contains(offset) {
            let angle = Double(offset) * 2.399963 + Double(count) * 0.37
            let radius = 0.08 * ((Double(offset) + 0.5) / Double(max(count, 1))).squareRoot()
            positions[offset] = SIMD2(0.5 + radius * cos(angle), 0.5 + radius * sin(angle))
            velocities[offset] = .zero
        }
        alpha = 1
    }

    /// Advances one frame; returns the mean speed, which is ~0 once settled.
    @discardableResult
    public mutating func step() -> Double {
        let count = positions.count
        guard count > 1, alpha > 0 else { return 0 }
        var force = [SIMD2<Double>](repeating: .zero, count: count)
        for i in 0..<count {
            for j in (i + 1)..<count {
                var delta = positions[i] - positions[j]
                var distance = (delta.x * delta.x + delta.y * delta.y).squareRoot()
                if distance < 1e-4 {
                    delta = SIMD2(1e-3 * Double((i + j) % 7 + 1), 1e-3)
                    distance = 1e-3
                }
                let push = delta / distance * (k * k / distance) * 0.3
                force[i] += push
                force[j] -= push
            }
        }
        for (a, b, weight) in links {
            let delta = positions[a] - positions[b]
            let distance = max((delta.x * delta.x + delta.y * delta.y).squareRoot(), 1e-4)
            let pull = delta / distance * ((distance - k * 0.55) * (2.5 + 0.5 * weight))
            force[a] -= pull
            force[b] += pull
        }
        var speed = 0.0
        for i in 0..<count where !pinned.contains(i) {
            force[i] += (SIMD2(0.5, 0.5) - positions[i]) * 0.35
            var velocity = (velocities[i] + force[i] * alpha * 0.1) * 0.82
            let magnitude = (velocity.x * velocity.x + velocity.y * velocity.y).squareRoot()
            if magnitude > 0.03 { velocity *= 0.03 / magnitude }
            velocities[i] = velocity
            positions[i] += velocity
            positions[i] = SIMD2(min(max(positions[i].x, 0.06), 0.94), min(max(positions[i].y, 0.06), 0.94))
            speed += magnitude
        }
        alpha = max(0, alpha - 0.005)
        return speed / Double(count)
    }
}
