import Foundation
import SwiftData
import BindersKit

/// Move to a Hub (Settings → Team, for a Mac that was on a team database): once, every binder an earlier Binders shared
/// through the team database (a `teamDatabaseKey` it left in the store) goes to a project in one of the hub's Binders,
/// with its notes, folders and cards (HubLinks.move), and is linked to it; then the binder is off the team database here,
/// kept with everything in it (`leaveDatabase`). Each binder's project is made from its id, the same on every teammate's
/// Mac: the first Mac to move a binder makes it, and the others join it. Meetings, captures and to-dos that were shared
/// stay on each Mac.
///
/// This Binders has no team database client: what goes is what this Mac has. The team database keeps everything, for
/// teammates who haven't moved yet; a teammate's Mac that moves later joins the project and sends what the hub lacks.
///
/// When a binder doesn't reach the hub, it stays as it was: Move Again sends what's left of it, and what's already on the
/// hub stays linked.
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

    /// The binders a move takes: every one an earlier Binders shared through a team database, by name.
    func binders() -> [BinderRecord] {
        Self.waiting().sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Binders still on a team database here, which only Move to a Hub takes off it.
    static func waiting() -> [BinderRecord] {
        (try? Store.shared.context.fetch(FetchDescriptor<BinderRecord>(predicate: #Predicate { !$0.teamDatabaseKey.isEmpty }))) ?? []
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

    /// Moves every binder on the team database to `space`, then takes them off it. True when it's done.
    @discardableResult
    func move(to space: HubLink.Space) async -> Bool {
        guard working == nil else { return false }
        problem = nil
        done = nil
        defer { working = nil }
        let binders = binders()
        guard !binders.isEmpty else { return false }
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
            problem = "\(names) didn't reach the hub yet.\(why) Move Again sends what's left."
            return false
        }
        working = "Leaving the team database…"
        Self.leaveDatabase(binders)
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

    /// Off the team database, everything kept: teammates' notes are ordinary notes here now, as they are on the hub, and
    /// cards lose the team database's copy of them; teammates' meetings and captures stay on this Mac as the copies they
    /// were. What an earlier Binders kept for the team database goes too: its saved server, passwords and outbox.
    static func leaveDatabase(_ binders: [BinderRecord]) {
        let store = Store.shared
        let keys = Set(binders.map(\.teamDatabaseKey).filter { !$0.isEmpty })
        for binder in binders {
            let binderID: UUID? = binder.id
            binder.teamDatabaseKey = ""
            binder.teamMadeBy = ""
            for card in (try? store.context.fetch(FetchDescriptor<TaskCard>(predicate: #Predicate { $0.binderID == binderID }))) ?? [] {
                card.teamShadow = ""
            }
            for note in (try? store.context.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.binderID == binderID && $0.isTeamCopy }))) ?? [] {
                note.isTeamCopy = false
            }
        }
        store.save()
        guard waiting().isEmpty else { return }
        for key in keys {
            Keychain.write("", for: AgentRegistry.keychainKey("team-database-password-\(key)"))
            Keychain.write("", for: AgentRegistry.keychainKey("team-database-password-next-\(key)"))
            try? FileManager.default.removeItem(at: AppPaths.support.appendingPathComponent("Team", isDirectory: true).appendingPathComponent(key, isDirectory: true))
        }
        AppDefaults.store.removeObject(forKey: "teamDatabaseServer")
        AppDefaults.store.removeObject(forKey: "teamDatabase")
    }
}
