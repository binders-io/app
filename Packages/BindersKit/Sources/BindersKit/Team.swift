import CryptoKit
import Foundation

// MARK: - Exchange format for team spaces

public struct TeamAuthor: Codable, Hashable, Sendable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public struct TeamMember: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var lastSeen: Date

    public init(id: String, name: String, lastSeen: Date) {
        self.id = id
        self.name = name
        self.lastSeen = lastSeen
    }
}

public struct TeamManifest: Codable, Equatable, Sendable {
    public var version: Int
    public var name: String
    public var createdAt: Date

    public init(version: Int = 1, name: String, createdAt: Date) {
        self.version = version
        self.name = name
        self.createdAt = createdAt
    }
}

/// A shared meeting, stored as JSON in the team folder (the Markdown next to it is a readable copy).
public struct TeamMeetingFile: Codable, Equatable, Sendable {
    public var version: Int
    public var id: String
    public var author: TeamAuthor
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var duration: TimeInterval
    public var appName: String?
    public var attendees: [String]
    public var templateID: String
    public var summary: String
    public var notes: String
    public var speakerNames: [String: String]
    public var segments: [TranscriptSegment]
    /// The binder the author filed it in; absent in files from before binders existed.
    public var binderID: String?
    public var binderName: String?

    public init(version: Int = 1, id: String, author: TeamAuthor, title: String, createdAt: Date, updatedAt: Date,
                duration: TimeInterval, appName: String?, attendees: [String], templateID: String, summary: String, notes: String,
                speakerNames: [String: String], segments: [TranscriptSegment], binderID: String? = nil, binderName: String? = nil) {
        self.binderID = binderID
        self.binderName = binderName
        self.version = version
        self.id = id
        self.author = author
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.duration = duration
        self.appName = appName
        self.attendees = attendees
        self.templateID = templateID
        self.summary = summary
        self.notes = notes
        self.speakerNames = speakerNames
        self.segments = segments
    }
}

/// A shared binder's card in the team folder, so teammates see it by name and colour even before its items arrive.
public struct TeamBinderFile: Codable, Equatable, Sendable {
    public var version: Int
    public var id: String
    public var name: String
    public var colorIndex: Int
    public var author: TeamAuthor
    public var createdAt: Date
    public var updatedAt: Date

    public init(version: Int = 1, id: String, name: String, colorIndex: Int, author: TeamAuthor, createdAt: Date, updatedAt: Date) {
        self.version = version
        self.id = id
        self.name = name
        self.colorIndex = colorIndex
        self.author = author
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct TeamTombstone: Codable, Equatable, Sendable {
    public var id: String
    public var deletedBy: TeamAuthor
    public var deletedAt: Date

    public init(id: String, deletedBy: TeamAuthor, deletedAt: Date) {
        self.id = id
        self.deletedBy = deletedBy
        self.deletedAt = deletedAt
    }
}

/// A shared note: a Markdown file whose front matter carries the Binders id, so it can also be edited in Obsidian.
public struct TeamNote: Equatable, Sendable {
    public var id: String?
    public var author: TeamAuthor?
    public var editedBy: String?
    public var createdAt: Date?
    public var updatedAt: Date?
    public var body: String
    /// Front matter written by other tools (Obsidian tags, aliases…), kept line for line.
    public var extraFrontmatter: [String]
    public var binderID: String?
    public var binderName: String?

    public init(id: String? = nil, author: TeamAuthor? = nil, editedBy: String? = nil, createdAt: Date? = nil, updatedAt: Date? = nil,
                body: String, extraFrontmatter: [String] = [], binderID: String? = nil, binderName: String? = nil) {
        self.binderID = binderID
        self.binderName = binderName
        self.id = id
        self.author = author
        self.editedBy = editedBy
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.body = body
        self.extraFrontmatter = extraFrontmatter
    }
}

public enum TeamCoding {
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

// MARK: - Markdown

public enum Frontmatter {
    /// Values are written as JSON strings (valid YAML), so any text round-trips. `extraLines` are written verbatim.
    public static func render(_ fields: [(String, String)], extraLines: [String] = [], body: String) -> String {
        guard !fields.isEmpty || !extraLines.isEmpty else { return body }
        let lines = fields.map { "\($0.0): \(quoted($0.1))" } + extraLines
        return "---\n" + lines.joined(separator: "\n") + "\n---\n" + body
    }

    /// Top-level fields, each key's raw lines in order (with indented or list continuation lines), and the body.
    public static func parse(_ text: String) -> (fields: [String: String], entries: [(key: String, lines: [String])], body: String) {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        guard let end = closingLine(normalized) else { return ([:], [], text) }
        let lines = normalized.components(separatedBy: "\n")
        var fields: [String: String] = [:]
        var entries: [(key: String, lines: [String])] = []
        for line in lines[1..<end] {
            let continues = line.isEmpty || line.hasPrefix(" ") || line.hasPrefix("\t") || line.hasPrefix("-")
            if continues, !entries.isEmpty {
                entries[entries.count - 1].lines.append(line)
                continue
            }
            guard let colon = line.firstIndex(of: ":") else {
                entries.append((key: "", lines: [line]))
                continue
            }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let raw = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { fields[key] = unquoted(raw) }
            entries.append((key: key, lines: [line]))
        }
        return (fields, entries, lines[(end + 1)...].joined(separator: "\n"))
    }

    /// Sets one top-level field in place, leaving the rest of the file untouched.
    public static func setting(_ key: String, to value: String, in text: String) -> String {
        let line = "\(key): \(quoted(value))"
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        guard let end = closingLine(normalized) else { return "---\n\(line)\n---\n" + text }
        var lines = normalized.components(separatedBy: "\n")
        if let index = lines[1..<end].firstIndex(where: { $0.hasPrefix(key + ":") }) {
            lines[index] = line
        } else {
            lines.insert(line, at: 1)
        }
        return lines.joined(separator: "\n")
    }

    static func closingLine(_ normalized: String) -> Int? {
        guard normalized.hasPrefix("---\n") else { return nil }
        let lines = normalized.components(separatedBy: "\n")
        return lines.indices.dropFirst().first { lines[$0].trimmingCharacters(in: .whitespaces) == "---" }
    }

    static func quoted(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes]),
              let string = String(data: data, encoding: .utf8) else { return "\"\"" }
        return string
    }

    static func unquoted(_ raw: String) -> String {
        if raw.hasPrefix("\""), let data = raw.data(using: .utf8),
           let string = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) as? String {
            return string
        }
        if raw.count >= 2, raw.hasPrefix("'"), raw.hasSuffix("'") {
            return String(raw.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        return raw
    }
}

public enum TeamFiles {
    public static let dataFolder = "_binders"
    public static let meetingsFolder = "Meetings"
    public static let notesFolder = "Notes"

    /// A filename safe on every sync service: "2026-09-13 Launch plan.md".
    public static func safeFileName(_ title: String, date: Date? = nil) -> String {
        var name = title.replacingOccurrences(of: "[/\\\\:*?\"<>|\\n\\r\\t]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: " {2,}", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: ".")))
        if name.isEmpty { name = "Untitled" }
        name = String(name.prefix(80)).trimmingCharacters(in: .whitespaces)
        if let date { name = dayString(date) + " " + name }
        return name + ".md"
    }

    public static func noteMarkdown(_ note: TeamNote) -> String {
        var fields: [(String, String)] = []
        if let id = note.id { fields.append(("binders_id", id)) }
        if let author = note.author {
            fields.append(("author", author.name))
            fields.append(("author_id", author.id))
        }
        if let editedBy = note.editedBy { fields.append(("edited_by", editedBy)) }
        if let binderID = note.binderID { fields.append(("binder_id", binderID)) }
        if let binderName = note.binderName { fields.append(("binder", binderName)) }
        if let createdAt = note.createdAt { fields.append(("created", createdAt.formatted(.iso8601))) }
        if let updatedAt = note.updatedAt { fields.append(("updated", updatedAt.formatted(.iso8601))) }
        return Frontmatter.render(fields, extraLines: note.extraFrontmatter, body: note.body)
    }

    static let noteFields: Set<String> = ["binders_id", "author", "author_id", "edited_by", "created", "updated", "binder_id", "binder"]

    public static func parseNote(_ text: String) -> TeamNote {
        let parsed = Frontmatter.parse(text)
        let fields = parsed.fields
        let author = fields["author"].map { TeamAuthor(id: fields["author_id"] ?? "", name: $0) }
        return TeamNote(id: fields["binders_id"].flatMap { $0.isEmpty ? nil : $0 }, author: author, editedBy: fields["edited_by"],
                        createdAt: fields["created"].flatMap { try? Date($0, strategy: .iso8601) },
                        updatedAt: fields["updated"].flatMap { try? Date($0, strategy: .iso8601) },
                        body: String(parsed.body.drop(while: { $0.isNewline })),
                        extraFrontmatter: parsed.entries.filter { !noteFields.contains($0.key) }.flatMap(\.lines),
                        binderID: fields["binder_id"].flatMap { $0.isEmpty ? nil : $0 }, binderName: fields["binder"])
    }

    /// The id for a note file added outside Binders (e.g. in Obsidian), derived from its path so every Mac picks the same one.
    public static func stableID(forPath path: String) -> String {
        let digest = Array(SHA256.hash(data: Data(("binders-note:" + path.precomposedStringWithCanonicalMapping).utf8)))
        var b = Array(digest.prefix(16))
        b[6] = (b[6] & 0x0F) | 0x50
        b[8] = (b[8] & 0x3F) | 0x80
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15])).uuidString
    }

    public static func meetingMarkdown(_ meeting: TeamMeetingFile) -> String {
        let fields: [(String, String)] = [
            ("binders_id", meeting.id),
            ("type", "meeting"),
            ("author", meeting.author.name),
            ("date", meeting.createdAt.formatted(.iso8601)),
            ("duration_minutes", "\(max(1, Int((meeting.duration / 60).rounded())))"),
            ("attendees", meeting.attendees.joined(separator: ", ")),
            ("note", "Shared from Binders. Edit this meeting in Binders; changes made here are overwritten."),
        ]
        let body = MeetingMarkdown.document(title: meeting.title, dateText: meeting.createdAt.formatted(date: .abbreviated, time: .shortened),
                                            duration: meeting.duration, appName: meeting.appName, attendees: meeting.attendees,
                                            summary: meeting.summary, notes: meeting.notes, segments: meeting.segments,
                                            names: meeting.speakerNames.merging([TranscriptSegment.you: meeting.author.name]) { current, _ in current })
        return Frontmatter.render(fields, body: body)
    }

    /// Content hash that ignores when the file was written and the order segments arrive in.
    public static func contentHash(_ meeting: TeamMeetingFile) -> String {
        var copy = meeting
        copy.updatedAt = Date(timeIntervalSince1970: 0)
        copy.segments.sort { ($0.start, $0.channel.rawValue, $0.id.uuidString) < ($1.start, $1.channel.rawValue, $1.id.uuidString) }
        return sha256((try? TeamCoding.encoder().encode(copy)) ?? Data())
    }

    public static func noteHash(_ body: String) -> String {
        sha256(Data(body.trimmingCharacters(in: .whitespacesAndNewlines).utf8))
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func dayString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

// MARK: - Sync decisions

public enum SyncDecision: Equatable, Sendable {
    case upToDate, pushLocal, pullRemote, conflict

    /// Three-way comparison against the version both sides last agreed on.
    public static func decide(local: String?, remote: String?, lastSynced: String?) -> SyncDecision {
        switch (local, remote) {
        case (nil, nil): return .upToDate
        case (nil, _): return .pullRemote
        case (_, nil): return .pushLocal
        case let (local?, remote?):
            if local == remote { return .upToDate }
            if lastSynced == local { return .pullRemote }
            if lastSynced == remote { return .pushLocal }
            return .conflict
        }
    }
}
