import Foundation

/// A linked note's history as the hub has it (lane HB8): the commits of its file in the hub's notes repo, from
/// GET /api/notes/:id/history, and its file as one of them had it, from GET /api/notes/:id/at/:sha.
public enum HubHistory {
    /// One commit of a note's file. `author` is the hub's Git author, the same for every commit, so it says little about
    /// who wrote what; `subject` is what the hub said it did ("Edit “Plan”").
    public struct Commit: Equatable, Sendable {
        public var sha: String
        public var short: String
        public var at: Date
        public var subject: String

        public init(sha: String, short: String, at: Date, subject: String) {
            self.sha = sha
            self.short = short
            self.at = at
            self.subject = subject
        }
    }

    /// The paths to ask, nil for an id or commit that would be more than one part of one (ids are UUIDs, or "note-…").
    public static func historyPath(of hubID: String) -> String? { isID(hubID) ? "api/notes/\(hubID)/history" : nil }
    public static func versionPath(of hubID: String, at sha: String) -> String? {
        isID(hubID) && isSHA(sha) ? "api/notes/\(hubID)/at/\(sha)" : nil
    }

    /// The commits /history lists, newest first as the hub sends them. Ones that can't be read (no sha, a date that isn't
    /// one) are left out; nil for an answer that isn't a list of commits.
    public static func commits(from data: Data) -> [Commit]? {
        struct Row: Decodable { let sha: String?; let short: String?; let at: String?; let subject: String? }
        struct Answer: Decodable { let commits: [Row] }
        guard let answer = try? JSONDecoder().decode(Answer.self, from: data) else { return nil }
        let dates = ISO8601DateFormatter()
        return answer.commits.compactMap { row in
            guard let sha = row.sha, isSHA(sha), let at = row.at.flatMap(dates.date(from:)) else { return nil }
            return Commit(sha: sha, short: row.short ?? String(sha.prefix(7)), at: at, subject: row.subject ?? "")
        }
    }

    /// A note's words from its file in the notes repo: the front matter the hub writes (id, binder, folder, work) taken
    /// off, and the one line ending it adds.
    public static func text(fromFile file: String) -> String {
        var body = Substring(file)
        if body.hasPrefix("---\n"), let end = body.range(of: "\n---\n", range: body.index(body.startIndex, offsetBy: 3)..<body.endIndex) {
            body = body[end.upperBound...]
        }
        if body.hasSuffix("\n") { body = body.dropLast() }
        return String(body)
    }

    /// What the hub takes as a commit (4 to 40 hex digits), so nothing else is put in a path.
    public static func isSHA(_ sha: String) -> Bool {
        (4...40).contains(sha.count) && sha.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    private static func isID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 100 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }
}
