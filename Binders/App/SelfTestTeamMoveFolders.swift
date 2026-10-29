import Foundation
import SwiftData
import BindersKit

/// Lane DB6's self-test, on TeamDBTestBed's throwaway Postgres: a folder team moved to a team database whose binder has
/// notes in folders and notes an agent made or changed, as a founder's was, and what the window lists afterwards; then the
/// same Mac over a database where rows only this member wrote say otherwise, as an earlier Binders could have left them.
///
///     Binders --selftest-teamdb-move-folders   a folder team's binder with top-level folders full of notes, notes at its
///                                              top, agents' notes, notes from the team folder carrying this member's own
///                                              name, and flat note files: moved, then listed at the top and in each
///                                              folder, during catch-up, after it, and after quitting and opening again;
///                                              then notes moved, deleted, unmarked and made a teammate's in the
///                                              database: nothing changes here, and the database is put right
///
/// For the variants, BINDERS_SELFTEST_KNOBS (any of fresh, quit, drop, copy) and BINDERS_SELFTEST_LATENCY_MS.
extension SelfTest {
    /// What the notes list and the sidebar show for one binder, by the same rules as NotesView and its folders' query:
    /// the notes at each place (the top, each folder), with their words, and the folders.
    @MainActor
    struct MovedListing: Equatable {
        /// Note ids shown at each place: nil is the binder's top.
        var places: [UUID?: Set<UUID>] = [:]
        /// Notes shown with no words in them.
        var empty: Set<UUID> = []
        var folders: Set<UUID> = []

        static func read(_ binder: UUID) -> MovedListing {
            let notes = (try? Store.shared.context.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.binderID == binder }))) ?? []
            let folders = Store.shared.folders(in: binder)
            let known = Set(folders.map(\.id))
            var listing = MovedListing(folders: known)
            for place in [UUID?](arrayLiteral: nil) + folders.map({ Optional($0.id) }) {
                // NotesView's tree (FolderTree.outline): in this binder, under this folder (a folder that isn't the binder's reads as the top).
                let here = notes.filter { $0.binderID == binder && $0.folderID.flatMap { known.contains($0) ? $0 : nil } == place }
                listing.places[place] = Set(here.map(\.id))
                listing.empty.formUnion(here.filter { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.map(\.id))
            }
            return listing
        }

        func count(_ place: UUID?) -> Int { places[place]?.count ?? 0 }
        var all: Set<UUID> { places.values.reduce(into: Set<UUID>()) { $0.formUnion($1) } }
    }

    /// What the window listed at its worst while it was watched, every 20 ms.
    @MainActor
    final class MovedWatch {
        private(set) var fewest: [UUID?: Int] = [:]
        private(set) var sawEmpty = false
        private(set) var agentsGone = false
        private var task: Task<Void, Never>?

        init(binder: UUID, places: [UUID?], agents: @escaping (MovedListing) -> Bool) {
            task = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    let now = MovedListing.read(binder)
                    guard let self else { return }
                    for place in places { self.fewest[place] = min(self.fewest[place] ?? Int.max, now.count(place)) }
                    if !now.empty.isEmpty { self.sawEmpty = true }
                    if !agents(now) { self.agentsGone = true }
                    try? await Task.sleep(for: .milliseconds(20))
                }
            }
        }

        func end() async {
            task?.cancel()
            await task?.value
        }

        func held(_ expected: [UUID?: Set<UUID>]) -> Bool {
            expected.allSatisfy { (fewest[$0.key] ?? 0) >= $0.value.count } && !sawEmpty && !agentsGone
        }

        func line(_ expected: [UUID?: Set<UUID>]) -> String {
            "fewest listed " + expected.map { "\(fewest[$0.key] ?? 0)/\($0.value.count)" }.sorted().joined(separator: ", ")
                + (sawEmpty ? "; a note shown empty" : "") + (agentsGone ? "; an agent's note not listed" : "")
        }
    }

    @MainActor
    static func teamMoveFolderChecks(_ bed: TeamDBTestBed) async throws {
        let root = try await bed.root()
        func count(_ sql: String, _ values: [String?] = []) async throws -> Int64 { try await root.value(sql, values, as: Int64.self) ?? -1 }
        let fileManager = FileManager.default
        let base = AppPaths.support.appendingPathComponent("team-move-folders", isDirectory: true)
        let folder = base.appendingPathComponent("Team", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        try TeamSyncService.prepareTeamFolder(folder)
        // A teammate on a Binders from before folders: note files stay flat in Notes, each note's folder in its front
        // matter.
        let older = TeamMember(id: "folder-robin", name: "Robin", lastSeen: Date())
        try TeamCoding.encoder().encode(older).write(to: folder.appendingPathComponent("_binders/members/folder-robin.json"), options: .atomic)

        // MARK: A folder team's binder as the founder's was.
        let agent = BoardActor(name: "Agent A", kind: .agent)
        let knobs = ProcessInfo.processInfo.environment["BINDERS_SELFTEST_KNOBS"] ?? ""
        var server = bed.sam!
        var memberName = "Sam"
        if knobs.contains("fresh") {
            // A member whose Mac has no binder in the database yet, as one that just set it up from the Move sheet.
            let invite = try await bed.client(bed.sam).addMemberDirect(on: try await bed.link(bed.sam), login: "robin", name: "Robin")
            TeamDatabase.keep(password: invite.oneTimePassword, for: invite.server)
            server = invite.server
            memberName = "Robin"
        }
        let mac = try await TeamMac.start(bed, agents: [AgentProfile(id: knobs.contains("fresh") ? UUID() : bed.agentA, name: agent.name,
                                                                     wake: .webhook(url: "https://example.invalid/agent-a"), report: .mcp)],
                                          as: knobs.contains("fresh") ? server : nil)
        _ = await bed.eventually(20) { mac.team.directory.myName != nil }
        let notes = mac.team.notes
        notes.gather = .milliseconds(150)
        // A team database far away: each call and each read of the feed takes a while, as on a server across the internet.
        if let latency = ProcessInfo.processInfo.environment["BINDERS_SELFTEST_LATENCY_MS"].flatMap(Int.init) {
            mac.team.database?.testHooks.latency = .milliseconds(latency)
        }
        let sync = mac.controller.team
        // This member's name in the folder is the name the database knows them by (Settings → Team's name was left empty,
        // so both are the Mac's account name).
        let me = TeamAuthor(id: "folder-sam", name: memberName)
        sync.identityOverride = (folder, me)
        sync.deletionGrace = 0
        sync.idAssignmentAge = 0
        let binder = BinderRecord(name: "Team binder", colorIndex: 3)
        binder.sharedWithTeam = true
        if knobs.contains("copy") {
            // Came back from the folder as a binder of this member's earlier Binders: a copy here, by the same name.
            binder.isTeamCopy = true
            binder.teamAuthorID = "folder-sam-before"
            binder.teamAuthorName = me.name
        }
        Store.shared.insert(binder)
        let sizes = [("Design", 30), ("Plans", 21), ("Ops", 1), ("Ideas", 38)]
        let atTop = 30
        var places: [UUID?: [UUID]] = [nil: []]
        var folderIDs: [UUID] = []
        // Every note written first at the top, so its file is written flat in Notes; then filed in its folder, which a
        // team with an older Binders in it says in the file's front matter, leaving the file where it is.
        var filing: [(UUID, UUID)] = []
        for (name, size) in sizes {
            guard let made = Store.shared.createFolder(named: name, in: binder.id) else { throw TeamDatabase.Problem.refused("no folder \(name)") }
            folderIDs.append(made.id)
            places[made.id] = []
            for index in 1...size {
                let note = NoteItem(text: "# \(name) \(index)\n\nWhat \(name.lowercased()) \(index) says, at some length, so the note isn't tiny.\n\n- one\n- two\n")
                note.binderID = binder.id
                note.sharedWithTeam = true
                if index % 7 == 0 { note.status = "Draft"; note.owner = "Sam"; note.dueAt = Date().addingTimeInterval(86_400) }
                places[made.id, default: []].append(note.id)
                filing.append((note.id, made.id))
                Store.shared.context.insert(note)
            }
        }
        for index in 1...atTop {
            let note = NoteItem(text: "# Top \(index)\n\nAt the top of the binder.\n")
            note.binderID = binder.id
            note.sharedWithTeam = true
            places[nil, default: []].append(note.id)
            Store.shared.context.insert(note)
        }
        Store.shared.save()
        await sync.syncNow()
        for (id, folderID) in filing { Store.shared.note(id)?.folderID = folderID }
        Store.shared.save()
        await sync.syncNow()
        // From the team folder days: most notes came back from the folder as this member's own, with their name on them.
        let all = (try? Store.shared.context.fetch(FetchDescriptor<NoteItem>())) ?? []
        for (index, note) in all.filter({ $0.binderID == binder.id }).sorted(by: { $0.id.uuidString < $1.id.uuidString }).enumerated() where index % 6 != 0 {
            note.teamAuthorID = me.id
            note.teamAuthorName = me.name
        }
        Store.shared.save()
        // Notes an agent made, or changed, over MCP while the team was on its folder: at the top and in folders.
        func pick(_ place: UUID?, _ index: Int) -> NoteItem? { (places[place]?[index]).flatMap { Store.shared.note($0) } }
        let madeTop = pick(nil, 0)
        madeTop?.madeBy = "An AI agent"
        let added = await mac.mcp("add_note", ["text": "# Agent A's summary\n\nWhat the agent found.", "binder": binder.name, "folder": "Plans"], as: agent)
        let madeInFolder = (TeamMac.object(added.text)["id"] as? String).flatMap(UUID.init(uuidString:)).flatMap { Store.shared.note($0) }
            ?? (try? Store.shared.context.fetch(FetchDescriptor<NoteItem>()))?.first { $0.madeBy == agent.name }
        if let madeInFolder { places[folderIDs[1], default: []].append(madeInFolder.id) }
        let editedTop = pick(nil, 1), editedInFolder = pick(folderIDs[0], 2), editedInOps = pick(folderIDs[2], 0)
        var appended = 0
        for note in [editedTop, editedInFolder, editedInOps].compactMap({ $0 }) {
            if await mac.mcp("append_to_note", ["id": note.id.uuidString, "text": "Agent A: one more line."], as: agent).ok { appended += 1 }
        }
        Store.shared.save()
        await sync.syncNow()
        let agents = Set([madeTop, madeInFolder, editedTop, editedInFolder, editedInOps].compactMap { $0?.id })
        bed.check(added.ok && madeInFolder?.madeBy == agent.name && appended == 3 && editedInOps?.editedBy == agent.name,
                  "in the folder days, Agent A made a note in Plans and changed three (\(agents.count) agents' notes)")
        let expected = places.mapValues(Set.init)
        let total = expected.values.reduce(0) { $0 + $1.count }
        let noteFiles = (try? fileManager.contentsOfDirectory(at: folder.appendingPathComponent("Notes"), includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        let subfolders = noteFiles.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        // The agent's note, written new, went in its folder's subfolder (a new file does, which an older Binders reads too).
        let flat = noteFiles.filter { $0.pathExtension == "md" }.count
        bed.check(flat == total - 1 && subfolders.map(\.lastPathComponent) == ["Plans"],
                  "the team folder holds the notes flat (\(flat) files in Notes), each one's folder in its front matter; the agent's new one in Plans")

        func describe(_ listing: MovedListing) -> String {
            let parts = [("top", Optional<UUID>.none)] + zip(sizes.map(\.0), folderIDs.map(Optional.init)).map { ($0, $1) }
            return parts.map { "\($0.0) \(listing.count($0.1))/\(expected[$0.1]?.count ?? 0)" }.joined(separator: ", ")
                + (listing.empty.isEmpty ? "" : "; \(listing.empty.count) empty") + "; \(listing.folders.count) folders"
        }
        func listedRight(_ listing: MovedListing) -> Bool {
            expected.allSatisfy { listing.places[$0.key] == $0.value } && listing.empty.isEmpty && listing.folders == Set(folderIDs)
        }
        func agentsListed(_ listing: MovedListing) -> Bool {
            let shown = listing.all
            return agents.allSatisfy { id in shown.contains(id) && Store.shared.note(id).map { !$0.agentMark.isEmpty } == true }
        }
        let before = MovedListing.read(binder.id)
        bed.check(listedRight(before) && agentsListed(before), "before the move: \(describe(before))")

        // MARK: Moving, and what the window lists while the database is read and after.
        let watch = MovedWatch(binder: binder.id, places: Array(expected.keys), agents: agentsListed)
        if knobs.contains("drop") {
            var dropped = 0
            mac.team.database?.testHooks.dropAfterAnswer = { item in
                guard item.call.function == "create_note" || item.call.function == "put_folder" else { return false }
                dropped += 1
                return dropped % 9 == 0
            }
        }
        let summary = try await notes.moveFolderTeam(from: sync)
        if knobs.contains("quit") {
            // Quit at once, the outbox still full, and open again.
            await mac.team.stop()
            mac.team.run(server)
            _ = await bed.eventually(30) { mac.team.isConnected }
        }
        bed.check(summary.binders == 1 && summary.notes == total && summary.folders == 4, "moved: \(summary.line)")
        _ = await mac.drained(60)
        // The feed's echo of everything the move made, read back here.
        try? await Task.sleep(for: .seconds(3))
        _ = await mac.drained(30)
        await notes.engine?.saveDue(now: Date().addingTimeInterval(3_600))
        _ = await mac.drained(30)
        try? await Task.sleep(for: .seconds(2))
        await watch.end()
        let after = MovedListing.read(binder.id)
        bed.check(listedRight(after), "after the move, with the database on: \(describe(after))")
        bed.check(agentsListed(after), "the agents' notes are listed, marked as the agents'")
        bed.check(watch.held(expected), "while the move ran and the database was read: \(watch.line(expected))")

        // MARK: In the database: each note in its folder, by this member, with its agent's mark.
        var wrongFolder = 0
        for (place, ids) in expected {
            for id in ids {
                let rows = try await count("SELECT count(*) FROM binders.notes WHERE id = $1::uuid AND folder_id IS NOT DISTINCT FROM $2::uuid AND deleted_at IS NULL",
                                           [id.uuidString, place?.uuidString])
                if rows != 1 { wrongFolder += 1 }
            }
        }
        bed.check(wrongFolder == 0, "every note is in its folder in the database (\(wrongFolder) not)")
        bed.check(try await count("SELECT count(*) FROM binders.folders WHERE binder_id = $1::uuid AND deleted_at IS NULL AND id = ANY ($2::uuid[])",
                                  [binder.id.uuidString, "{\(folderIDs.map(\.uuidString).joined(separator: ","))}"]) == 4,
                  "the binder's four folders are in the database, with the Mac's ids")
        bed.check(try await count("SELECT count(*) FROM binders.notes WHERE binder_id = $1::uuid AND created_by = $2::uuid AND deleted_at IS NULL",
                                  [binder.id.uuidString, mac.team.directory.me?.uuidString]) == Int64(total), "every note is this member's in the database")
        let marked = try await count("SELECT count(*) FROM binders.notes WHERE binder_id = $1::uuid AND (properties ? 'made_by' OR properties ? 'edited_by')",
                                     [binder.id.uuidString])
        bed.check(marked == Int64(agents.count), "the agents' marks are in the database (\(marked) of \(agents.count))")

        // MARK: Quit and open again, the database still on.
        await mac.team.stop()
        let again = MovedListing.read(binder.id)
        bed.check(listedRight(again) && agentsListed(again), "quit: what this Mac keeps: \(describe(again))")
        let reopened = MovedWatch(binder: binder.id, places: Array(expected.keys), agents: agentsListed)
        mac.team.run(server)
        let caughtUp = await bed.eventually(30) { mac.team.isConnected }
        try? await Task.sleep(for: .seconds(3))
        await reopened.end()
        let open = MovedListing.read(binder.id)
        bed.check(caughtUp && listedRight(open), "opened again, the database on: \(describe(open))")
        bed.check(agentsListed(open), "opened again: the agents' notes are listed, marked as the agents'")
        bed.check(reopened.held(expected), "while it caught up: \(reopened.line(expected))")

        // MARK: What an earlier Binders could have left in the database, written as this member (lane DB6).
        // Design's notes at the top there, two of Ideas' in Plans, a note at the top deleted, Agent A's note without its
        // mark (a change by this member, not from this Mac), three notes as Alex's; and this Mac not yet checked against
        // the database, as an earlier Binders leaves it.
        _ = await mac.drained(30)
        await mac.team.stop()
        let own = try await bed.link(server)
        let design = Array(expected[folderIDs[0]] ?? [])
        for id in design { try await bed.expectOK(own, .moveNote(id, binder: binder.id, folder: nil)) }
        let ideas = Array((expected[folderIDs[3]] ?? []).sorted { $0.uuidString < $1.uuidString }.prefix(2))
        for id in ideas { try await bed.expectOK(own, .moveNote(id, binder: binder.id, folder: folderIDs[1])) }
        guard let gone = (expected[nil] ?? []).sorted(by: { $0.uuidString < $1.uuidString }).first(where: { !agents.contains($0) }),
              let unmarked = madeInFolder?.id else { throw TeamDatabase.Problem.refused("no notes to change") }
        try await bed.expectOK(own, .delete(gone, from: .notes))
        if let row = try await own.rows(.notes, ids: [unmarked]).first.flatMap(TeamNoteRow.init(row:)) {
            let list = (try await own.json(TeamQueries.noteChanges, [unmarked.uuidString.lowercased()])).array?
                .compactMap { $0.object.flatMap(TeamNoteChangeRow.init(row:)) } ?? []
            let document = try TeamNoteDocument(note: unmarked, saved: row.document, changes: list.map(\.change), actor: UUID())
            if let made = try document.change(splices: [], props: ["made_by": .null]) {
                try await bed.expectOK(own, .addNoteChanges(unmarked, changes: [TeamNoteChange(hash: made.hash, deps: made.deps, bytes: made.bytes)]))
            }
        }
        let alexs = Array((expected[folderIDs[1]] ?? []).filter { !agents.contains($0) }.sorted { $0.uuidString < $1.uuidString }.prefix(3))
        try await root.execute("UPDATE binders.notes SET created_by = $1::uuid WHERE id = ANY ($2::uuid[])",
                               [bed.alexID.uuidString, "{\(alexs.map(\.uuidString).joined(separator: ","))}"])
        bed.check(try await count("SELECT count(*) FROM binders.notes WHERE binder_id = $1::uuid AND folder_id IS NULL AND deleted_at IS NULL",
                                  [binder.id.uuidString]) == Int64(atTop - 1 + design.count),
                  "the database has Design's notes at the top, two of Ideas' in Plans, one note deleted and three as Alex's")
        notes.folders.checkedDatabase = nil
        notes.saveFolders()

        let repaired = MovedWatch(binder: binder.id, places: Array(expected.keys), agents: agentsListed)
        mac.team.run(server)
        _ = await bed.eventually(30) { mac.team.isConnected }
        let checkedOnce = await bed.eventually(30) { notes.folders.checkedDatabase == true }
        try? await Task.sleep(for: .seconds(2))
        _ = await mac.drained(30)
        await notes.engine?.saveDue(now: Date().addingTimeInterval(3_600))
        _ = await mac.drained(30)
        try? await Task.sleep(for: .seconds(2))
        await repaired.end()
        let shown = MovedListing.read(binder.id)
        bed.check(listedRight(shown) && agentsListed(shown) && Store.shared.note(gone) != nil && madeInFolder?.madeBy == agent.name,
                  "over that database, this Mac lists every note where it was, with its words and marks: \(describe(shown))")
        bed.check(repaired.held(expected), "while it read that database: \(repaired.line(expected))")
        var stillWrong = 0
        for (place, ids) in expected {
            for id in ids where try await count("SELECT count(*) FROM binders.notes WHERE id = $1::uuid AND folder_id IS NOT DISTINCT FROM $2::uuid AND deleted_at IS NULL",
                                                [id.uuidString, place?.uuidString]) != 1 {
                stillWrong += 1
            }
        }
        bed.check(checkedOnce && stillWrong == 0, "the database has every note in its folder again, the deleted one back (\(stillWrong) not)")
        // The note's document as a teammate's Mac reads it: its saved copy, then every change.
        var markThere = ""
        if let row = try await own.rows(.notes, ids: [unmarked]).first.flatMap(TeamNoteRow.init(row:)) {
            let list = (try await own.json(TeamQueries.noteChanges, [unmarked.uuidString.lowercased()])).array?
                .compactMap { $0.object.flatMap(TeamNoteChangeRow.init(row:)) } ?? []
            markThere = (try? TeamNoteDocument(note: unmarked, saved: row.document, changes: list.map(\.change), actor: UUID()))?.props["made_by"]?.string ?? ""
        }
        bed.check(markThere.hasPrefix(agent.name), "Agent A's note is marked as Agent A's in the database again (“\(markThere)”)")
        bed.check(try await count("SELECT count(*) FROM binders.notes WHERE id = ANY ($1::uuid[]) AND created_by = $2::uuid",
                                  ["{\(alexs.map(\.uuidString).joined(separator: ","))}", mac.team.directory.me?.uuidString]) == Int64(alexs.count),
                  "the three notes are this member's there again (\(notes.checked.claimed) claimed, \(notes.checked.misfiled) filed elsewhere, \(notes.checked.unmarked) without their mark)")

        // MARK: A teammate's move still moves the note here.
        let teammate = try await bed.link(bed.alex)
        if let moving = expected[folderIDs[2]]?.first {
            try await bed.expectOK(teammate, .moveNote(moving, binder: binder.id, folder: folderIDs[3]))
            let followed = await bed.eventually(15) { Store.shared.note(moving)?.folderID == folderIDs[3] }
            bed.check(followed, "Alex moves a note of this Mac's from Ops to Ideas: it moves here too")
        }
        await mac.stop()
    }
}
