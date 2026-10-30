import Foundation
import BindersKit

/// A linked note's earlier versions come from the hub (lane HB8): the commits of its file in the hub's notes repo
/// (GET /api/notes/:id/history), each read as that commit had it (GET /api/notes/:id/at/:sha). What the hub commits
/// is every edit made anywhere, the web app's and the agents' as well as this Mac's, once typing pauses. A commit's
/// text never changes, so each is read once and kept while the app runs.
@MainActor
enum HubNoteHistory {
    struct Version: Equatable {
        let commit: HubHistory.Commit
        let text: String
    }

    /// The newest commits read whole; older ones aren't listed.
    static let limit = 60

    /// Each commit's text, by the hub Binder, the note and the commit.
    private static var texts: [String: String] = [:]

    static func keepsHistory(of note: NoteItem) -> Bool { HubNotesSync.shared.place(of: note) != nil }

    /// The note's versions on the hub, newest first. Throws what the hub said, in words, when it can't be asked or turns
    /// it down (a hub that doesn't keep notes in Git).
    static func versions(of note: NoteItem) async throws -> [Version] {
        let sync = HubNotesSync.shared
        guard let (space, hubID) = sync.place(of: note), let path = HubHistory.historyPath(of: hubID) else { return [] }
        let (data, _) = try await sync.ask(path, space: space)
        guard let commits = HubHistory.commits(from: data) else { throw HubNotesSync.Problem("The hub sent something that isn't a note's history.") }
        let listed = Array(commits.prefix(limit))
        let key = { (sha: String) in "\(space.id)|\(hubID)|\(sha)" }
        let missing = listed.filter { texts[key($0.sha)] == nil }
        // A few at a time: the hub reads each from Git.
        for start in stride(from: 0, to: missing.count, by: 6) {
            try await withThrowingTaskGroup(of: (String, String).self) { group in
                for commit in missing[start..<min(start + 6, missing.count)] {
                    guard let at = HubHistory.versionPath(of: hubID, at: commit.sha) else { continue }
                    group.addTask { @MainActor in
                        let (file, _) = try await sync.ask(at, space: space)
                        return (commit.sha, HubHistory.text(fromFile: String(decoding: file, as: UTF8.self)))
                    }
                }
                for try await (sha, text) in group { texts[key(sha)] = text }
            }
        }
        return listed.compactMap { commit in texts[key(commit.sha)].map { Version(commit: commit, text: $0) } }
    }

    /// History's list for the versions read: each one's own change from the one before it and the sections it touched,
    /// the note as it is now on top. The hub's commits all have its own Git author, so who made each isn't said.
    static func entries(of versions: [NoteHistory.Version], now text: String) -> [NoteVersions.Entry] {
        // Git dates to the second: two commits in the same one keep the hub's order.
        NoteVersions.entries(texts: versions.enumerated().map { (id: $1.stem, at: $1.date.addingTimeInterval(-Double($0) / 1000), text: $1.text) },
                             now: text, index: NoteVersionIndex())
    }
}
