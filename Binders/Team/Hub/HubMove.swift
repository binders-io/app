import Foundation
import BindersKit

/// Move to a Hub (Settings → Team, on a team database): once, every binder this Mac has on the team database goes to a
/// project in one of the hub's Binders, with its notes, folders and cards (HubLinks.move), and is linked to it; then this
/// Mac leaves the team database, keeping every binder (TeamBoard.leaveDatabaseKeepingBinders). Each binder's project is
/// made from its id, the same on every teammate's Mac: the first Mac to move a binder makes it, and the others join it.
/// Meetings, captures and to-dos that were shared stay on each Mac. The database keeps everything, for teammates who
/// haven't moved yet; retiring it is for later.
///
/// When a binder doesn't reach the hub, this Mac stays on the team database: Move Again sends what's left of it, and
/// what's already on the hub stays linked.
@MainActor
@Observable
final class HubMove {
    static let shared = HubMove()

    private var links: HubLinks { .shared }

    /// What's being done now, in words.
    private(set) var working: String?
    /// What went wrong, in words.
    private(set) var problem: String?
    /// What the move did, in words, once it's done.
    private(set) var done: String?

    /// The binders a move takes: every one this Mac has on the team database, by name.
    func binders(_ team: TeamBoard) -> [BinderRecord] {
        team.sharedBinders.compactMap { Store.shared.binder($0) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The projects in `space` that teammates' Macs made when they moved, by the binder they're for.
    func moved(_ binders: [BinderRecord], in space: String) async throws -> [UUID: HubLink.Project] {
        let projects = try await links.projects(in: space)
        var found: [UUID: HubLink.Project] = [:]
        for binder in binders {
            let id = HubLink.movedProjectID(binder.id)
            if let project = projects.first(where: { $0.id == id }) { found[binder.id] = project }
        }
        return found
    }

    /// Moves every binder on the team database to `space`, then leaves the team database. True when it's done.
    @discardableResult
    func move(_ team: TeamBoard, to space: HubLink.Space) async -> Bool {
        guard working == nil, team.server != nil else { return false }
        problem = nil
        done = nil
        defer { working = nil }
        let binders = binders(team)
        working = "Asking the hub…"
        let existing: [UUID: HubLink.Project]
        do {
            existing = try await moved(binders, in: space.id)
        } catch {
            problem = (error as? HubLinks.Problem)?.words ?? error.localizedDescription
            return false
        }
        var made = 0
        var joined = 0
        var left: [BinderRecord] = []
        for (index, binder) in binders.enumerated() {
            working = binders.count == 1 ? "Moving “\(binder.name)”…" : "Moving “\(binder.name)”, \(index + 1) of \(binders.count)…"
            guard await links.move(binder, space: space, existing: existing[binder.id]) else {
                left.append(binder)
                continue
            }
            // Counted by where it went, including a binder an earlier Move took.
            if HubLinks.place(of: binder)?.newProject == true { made += 1 } else { joined += 1 }
        }
        guard left.isEmpty else {
            let names = left.map { "“\($0.name)”" }.formatted(.list(type: .and))
            let why = left.compactMap { links.problems[$0.id] }.first.map { " \($0)" } ?? ""
            problem = "\(names) didn't reach the hub yet.\(why) This Mac stays on the team database until everything's there: Move Again sends what's left."
            return false
        }
        working = "Leaving the team database…"
        await team.leaveDatabaseKeepingBinders()
        HubBoard.shared.follow()
        HubNotesSync.shared.refresh()
        done = Self.line(made: made, joined: joined, space: space.name)
        return true
    }

    /// "Moved 2 binders to Team, and joined 1 that a teammate moved first. This Mac left the team database."
    static func line(made: Int, joined: Int, space: String) -> String {
        func count(_ number: Int) -> String { "\(number) \(number == 1 ? "binder" : "binders")" }
        let first = joined == 1 ? "that a teammate moved first" : "that teammates moved first"
        var parts: [String] = []
        if made > 0 { parts.append("Moved \(count(made)) to \(space)") }
        if joined > 0 { parts.append(parts.isEmpty ? "Joined \(count(joined)) in \(space) \(first)" : "joined \(joined) \(first)") }
        let moved = parts.isEmpty ? "No binders to move." : parts.joined(separator: ", and ") + "."
        return "\(moved) This Mac left the team database."
    }
}
