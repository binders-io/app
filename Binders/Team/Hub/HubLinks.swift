import Foundation
import SwiftData
import BindersKit

/// Binders on this Mac linked to projects on the hub it's signed in to (HubAccount). Linking picks one of the hub's
/// Binders and a project in it, or makes a new project named as the binder is, and sends up the binder's folders, notes
/// and cards (HubLink.firstUpload), then reads the hub's state back to check they all arrived. A link that didn't finish
/// is kept, with Send Again: its changes have the same ids under the link's own client, so the hub puts none of them
/// twice, and what changed here since has new ones, so it goes as it is now. Everything a link sends and reads goes to
/// the hub it was made on, and only while this Mac is signed in to that hub: signed in to another one, it waits. Unlinking keeps the binder here as it is, and the project on the hub as it is. Keeping them the same both ways
/// from then on builds on the link (`place(of:)`).
///
/// Notes from what you said to yourself stay on this Mac, as they do with a team folder; meetings and captures aren't the
/// hub's. A binder shared with a team folder isn't linked: it would go to the team twice.
@MainActor
@Observable
final class HubLinks {
    static let shared = HubLinks()

    private var account: HubAccount { .shared }
    @ObservationIgnored private var store: Store { Store.shared }

    /// What's being done for a binder now, in words, by its id.
    private(set) var working: [UUID: String] = [:]
    /// What went wrong for a binder, in words, by its id.
    private(set) var problems: [UUID: String] = [:]
    /// What the last link or Send Again did, in words, by binder.
    private(set) var done: [UUID: String] = [:]

    /// At most this many changes go in one request (the self-tests send fewer, to stop between them).
    @ObservationIgnored var batchCount = 500

    // MARK: Reading

    static func place(of binder: BinderRecord) -> HubLink.Place? { HubLink.Place(json: binder.hubLink) }

    /// Why a binder can't be linked, in words, or nil when it can. `moving`: Move to a Hub (HubMove), which alone takes a
    /// binder an earlier Binders shared through a team database, to the project every teammate's Mac finds.
    func whyNot(_ binder: BinderRecord, moving: Bool = false) -> String? {
        if binder.isTeamCopy { return "This binder is a teammate's copy. Only its owner can link it to a hub." }
        if binder.sharedWithTeam {
            return "This binder is shared with your team already. Stop sharing it first, so it doesn't reach the team twice."
        }
        if !binder.teamDatabaseKey.isEmpty && !moving {
            return "This binder was on the team database. Move it with Move to a Hub… in Settings → Team, so teammates' Macs find the same project."
        }
        if !account.isSignedIn { return "Sign in to a hub in Settings → Team first." }
        return nil
    }

    /// Why a link that didn't finish can't be finished now, in words, or nil when Send Again can go.
    func whyNotSendAgain(_ binder: BinderRecord) -> String? {
        guard let place = Self.place(of: binder), !place.uploaded else { return nil }
        return whyNotOn(place.hub)
    }

    /// Why this Mac can't ask `hub` now: it isn't signed in, or it's signed in to another hub.
    private func whyNotOn(_ hub: URL) -> String? {
        let shown = HubSignInSection.shown(hub)
        guard account.isSignedIn, let address = account.address else { return "Sign in to \(shown) in Settings → Team first." }
        guard HubLink.sameHub(address, hub) else {
            return "This goes to \(shown), and this Mac is signed in to \(HubSignInSection.shown(address)) now. Sign in to \(shown) in Settings → Team first."
        }
        return nil
    }

    /// The hub's Binders you're in, the one it opens first, and the hub that said so: what's chosen from them is linked
    /// there, not on whichever hub this Mac is signed in to by then.
    func spaces() async throws -> (spaces: [HubLink.Space], current: String?, hub: URL) {
        guard let hub = account.address, account.isSignedIn else { throw Problem("Sign in to a hub in Settings → Team first.") }
        let (data, _) = try await ask("api/me", on: hub, space: nil)
        let found = HubLink.spaces(fromMe: data)
        return (found.spaces, found.current, hub)
    }

    /// The projects in one of `hub`'s Binders.
    func projects(in space: String, on hub: URL) async throws -> [HubLink.Project] {
        let (data, _) = try await ask("api/state", on: hub, space: space)
        guard let projects = HubLink.projects(fromState: data) else { throw Problem("The hub sent something that isn't its state.") }
        return projects
    }

    /// A new binder on `hub`, named as this one is. The hub makes it, at an address from its name, with the one binder its
    /// notes and board go in, and this person its owner; linking then goes into that one.
    func newSpace(named name: String, on hub: URL) async throws -> (space: HubLink.Space, project: HubLink.Project?) {
        let body = try JSONSerialization.data(withJSONObject: ["name": name])
        let (data, _) = try await ask("api/spaces", on: hub, space: nil, body: body)
        struct Made: Decodable { let created: HubLink.Space? }
        guard let made = (try? JSONDecoder().decode(Made.self, from: data))?.created else { throw Problem("The hub didn't say where it made the binder.") }
        return (made, try await projects(in: made.id, on: hub).first)
    }

    // MARK: Linking

    /// What a binder sends the first time, to `project` (a new one when `newName` is given).
    func firstUpload(_ binder: BinderRecord, to project: String, newName: String?) -> [HubLink.Outgoing] {
        let binderID = binder.id
        let folders = store.folders(in: binderID).map { HubLink.LocalFolder(id: $0.id, parent: $0.parentID, name: $0.name, editedAt: $0.updatedAt) }
        let notes = ((try? store.context.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.binderID == binderID }))) ?? [])
            .filter { !$0.staysUnshared }
            .sorted { $0.createdAt < $1.createdAt }
            .map { HubLink.LocalNote(id: $0.id, title: $0.title, text: $0.text, folder: $0.folderID, editedAt: $0.updatedAt) }
        let cards = ((try? store.context.fetch(FetchDescriptor<TaskCard>(predicate: #Predicate { $0.binderID == binderID },
                                                                           sortBy: [SortDescriptor(\.position)]))) ?? [])
            .map { card in
                let id = card.id
                let events = (try? store.context.fetch(FetchDescriptor<TaskEvent>(predicate: #Predicate { $0.taskID == id },
                                                                                   sortBy: [SortDescriptor(\.createdAt)]))) ?? []
                return HubLink.LocalCard(
                    id: card.id, title: card.title, details: card.details, column: card.column, links: card.links,
                    createdBy: card.createdBy, createdAt: card.createdAt, updatedAt: card.updatedAt, waitsFor: card.waitsFor,
                    note: card.sourceKind == "note" ? card.sourceID.flatMap(UUID.init(uuidString:)) : card.groupNote,
                    events: events.map { HubLink.LocalEvent(kind: $0.kindRaw, author: $0.author, text: $0.text, at: $0.createdAt) })
            }
        return HubLink.firstUpload(binder: project, newName: newName, person: account.person?.login ?? "you", folders: folders,
                                   notes: notes, cards: cards)
    }

    /// Links a binder to `project` in `space` on `hub`, or to a new project named as the binder is when `project` is nil,
    /// and sends up what's in it. True when everything arrived.
    @discardableResult
    func link(_ binder: BinderRecord, on hub: URL, space: HubLink.Space, to project: HubLink.Project?) async -> Bool {
        guard Self.place(of: binder) == nil else { return false }
        if let why = whyNot(binder) ?? whyNotOn(hub) {
            problems[binder.id] = why
            return false
        }
        let projectID = project?.id ?? HubLink.newProjectID()
        let place = HubLink.Place(hub: hub, space: space.id, spaceName: space.name, binder: projectID,
                                  binderName: project?.name ?? binder.name, client: HubLink.newClient(), newProject: project == nil)
        // Kept before anything goes, so a link cut short is finished by Send Again rather than made twice.
        binder.hubLink = place.json
        binder.updatedAt = Date()
        store.save()
        let sent = await send(binder)
        // The tools set up for the hub's cards take this project's work too (HubAgentSetup).
        await HubAgentSetup.shared.refresh()
        return sent
    }

    /// Move to a Hub, for one binder on the team database: to its project in `space` on `hub` (`HubLink.movedProjectID`). The
    /// first Mac to move it makes the project and sends everything up; a teammate's Mac that finds the project there
    /// (`existing`) joins it, and from then on takes the hub's words and cards, sending only what the hub doesn't have.
    /// A move cut short goes on where it stopped. True when the binder is on the hub.
    @discardableResult
    func move(_ binder: BinderRecord, on hub: URL, space: HubLink.Space, existing: HubLink.Project?) async -> Bool {
        if let place = Self.place(of: binder) { return place.uploaded ? true : await send(binder) }
        if let why = whyNot(binder, moving: true) ?? whyNotOn(hub) {
            problems[binder.id] = why
            return false
        }
        let projectID = HubLink.movedProjectID(binder.id)
        var place = HubLink.Place(hub: hub, space: space.id, spaceName: space.name, binder: projectID,
                                  binderName: existing?.name ?? binder.name, client: HubLink.newClient(), newProject: existing == nil)
        problems[binder.id] = nil
        guard existing != nil else {
            binder.hubLink = place.json
            binder.updatedAt = Date()
            store.save()
            return await send(binder)
        }
        // Nothing is kept as linked until this Mac's words are merged with the hub's: Move Again starts it over.
        do {
            try await keepWrittenHere(binder, on: hub, project: projectID, space: space.id, since: place.linkedAt)
        } catch {
            problems[binder.id] = (error as? Problem)?.words ?? "Couldn't reach \(hub.host ?? "the hub"): \(error.localizedDescription)"
            return false
        }
        place.uploaded = true
        binder.hubLink = place.json
        binder.updatedAt = Date()
        store.save()
        done[binder.id] = "Joined \(place.binderName), which a teammate moved first."
        HubBoard.shared.follow()
        HubNotesSync.shared.refresh()
        return true
    }

    /// Joining a project a teammate's Mac moved first: the hub has the notes as that Mac had them, and they've changed there
    /// since. What was written here and never reached that Mac (offline, or on the team database after it moved) is kept:
    /// each note whose words differ from the hub's is merged with them, from the words the hub's document started from.
    /// One whose words still aren't the hub's is marked changed after `linkedAt`, so once linked it goes up as an edit
    /// rather than taking the hub's words (HubNotesSync.takeNewer); the rest take the hub's.
    // MARK: Linking back

    /// A binder this Mac had linked, found again: the hub's Binder and binder that hold its notes.
    struct LostLink {
        let binder: BinderRecord
        let space: HubLink.Space
        let project: HubLink.Project
        let hub: URL
        let notes: Int
    }

    /// Binders here whose link was lost (an older Binders opened the library and dropped what it didn't know), found by
    /// the hub binder that holds their notes: a note's id is the same here and on the hub. Only a clear match: one that
    /// holds at least half of a binder's notes, that no binder here is linked to, and that no other binder here matches.
    func lostLinks() async -> [LostLink] {
        guard let found = try? await spaces() else { return [] }
        let all = store.binders()
        let unlinked = all.filter { !$0.isTeamCopy && Self.place(of: $0) == nil }
        guard !unlinked.isEmpty else { return [] }
        let taken = Set(all.compactMap { Self.place(of: $0) }.map { "\($0.space)/\($0.binder)" })
        struct HubState: Decodable {
            struct Item: Decodable { let id: String; let binderId: String? }
            struct Project: Decodable { let id: String; let name: String }
            struct Inner: Decodable { let notes: [Item]?; let binders: [Project]? }
            let state: Inner
        }
        var noteHome: [UUID: (space: HubLink.Space, key: String)] = [:]
        var projects: [String: HubLink.Project] = [:]
        for space in found.spaces {
            guard let (data, _) = try? await ask("api/state", on: found.hub, space: space.id),
                  let state = try? JSONDecoder().decode(HubState.self, from: data) else { continue }
            for project in state.state.binders ?? [] { projects["\(space.id)/\(project.id)"] = HubLink.Project(id: project.id, name: project.name) }
            for note in state.state.notes ?? [] {
                if let project = note.binderId { noteHome[HubSync.localID(note.id)] = (space, "\(space.id)/\(project)") }
            }
        }
        var matches: [(binder: BinderRecord, space: HubLink.Space, key: String, notes: Int)] = []
        for binder in unlinked {
            let binderID = binder.id
            let ids = ((try? store.context.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.binderID == binderID }))) ?? []).filter { !$0.staysUnshared }.map(\.id)
            guard !ids.isEmpty else { continue }
            var counts: [String: (space: HubLink.Space, notes: Int)] = [:]
            for id in ids { if let home = noteHome[id] { counts[home.key, default: (home.space, 0)].notes += 1 } }
            guard let best = counts.max(by: { $0.value.notes < $1.value.notes }), best.value.notes * 2 >= ids.count, !taken.contains(best.key) else { continue }
            matches.append((binder, best.value.space, best.key, best.value.notes))
        }
        let claimed = Dictionary(grouping: matches, by: \.key)
        return matches.compactMap { match in
            guard claimed[match.key]?.count == 1, let project = projects[match.key] else { return nil }
            return LostLink(binder: match.binder, space: match.space, project: project, hub: found.hub, notes: match.notes)
        }
    }

    /// Link Back: joins the hub binder that holds its notes, as Move to a Hub joins one a teammate moved. What was written
    /// here since is merged with the hub's words; the rest, and where each note and folder is, are the hub's. Its cards
    /// are paired with the hub's again by their ids, and one the hub doesn't have goes from here: a linked binder's board
    /// is the hub's, and a card only here was taken off it or never reached it.
    @discardableResult
    func linkBack(_ lost: LostLink) async -> Bool {
        let binder = lost.binder
        guard Self.place(of: binder) == nil else { return true }
        if let why = whyNotOn(lost.hub) {
            problems[binder.id] = why
            return false
        }
        var place = HubLink.Place(hub: lost.hub, space: lost.space.id, spaceName: lost.space.name, binder: lost.project.id,
                                  binderName: lost.project.name, client: HubLink.newClient(), newProject: false)
        do {
            try await keepWrittenHere(binder, on: lost.hub, project: lost.project.id, space: lost.space.id, since: place.linkedAt)
            try await pairCards(binder, on: lost.hub, project: lost.project.id, space: lost.space.id)
        } catch {
            problems[binder.id] = (error as? Problem)?.words ?? "Couldn't reach \(lost.hub.host ?? "the hub"): \(error.localizedDescription)"
            return false
        }
        place.uploaded = true
        binder.hubLink = place.json
        binder.updatedAt = Date()
        store.save()
        done[binder.id] = "Linked back to \(place.binderName) in \(place.spaceName)."
        HubBoard.shared.follow()
        HubNotesSync.shared.refresh()
        return true
    }

    /// At launch, signed in to a hub: every binder whose link was lost and is found again, linked back.
    func linkBackLost() async {
        guard account.isSignedIn else { return }
        for lost in await lostLinks() { await linkBack(lost) }
    }

    /// A binder's cards paired with the hub's in its project again, by their ids; one the hub doesn't have goes from here.
    private func pairCards(_ binder: BinderRecord, on hub: URL, project: String, space: String) async throws {
        let (data, _) = try await ask("api/state", on: hub, space: space)
        struct HubState: Decodable {
            struct Card: Decodable { let id: String; let binderId: String }
            struct Inner: Decodable { let cards: [Card]? }
            let state: Inner
        }
        guard let state = try? JSONDecoder().decode(HubState.self, from: data) else { throw Problem("The hub sent something that isn't its state.") }
        var hubCards: [UUID: String] = [:]
        for card in state.state.cards ?? [] where card.binderId == project { hubCards[HubCards.localID(card.id)] = card.id }
        let binderID = binder.id
        for card in (try? store.context.fetch(FetchDescriptor<TaskCard>(predicate: #Predicate { $0.binderID == binderID }))) ?? [] {
            if let id = hubCards[card.id] {
                card.hubCard = id
                card.hubPut = ""
            } else if let board = HubBoard.shared.board {
                board.removeHere(card)
            } else {
                store.context.delete(card)
            }
        }
        store.save()
    }

    private func keepWrittenHere(_ binder: BinderRecord, on hub: URL, project: String, space: String, since linkedAt: Date) async throws {
        let (data, _) = try await ask("api/state", on: hub, space: space)
        guard let state = HubSync.State(hubState: data) else { throw Problem("The hub sent something that isn't its state.") }
        let binderID = binder.id
        let notes = ((try? store.context.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.binderID == binderID }))) ?? [])
            .filter { !$0.staysUnshared }
        for note in notes {
            guard let theirs = state.notes[HubLink.hubID(note.id)], theirs.binderId == project, theirs.text != note.text else { continue }
            working[binderID] = "Keeping what was written here in “\(note.title)”…"
            let (saved, _) = try await ask("api/notes/\(theirs.id)/doc", on: hub, space: space)
            let base = (try? HubNoteDocument(note: note.id, saved: saved))?.startingText ?? theirs.text
            let merged = HubNoteDocument.merge(base: base, theirs: theirs.text, ours: note.text)
            guard merged != theirs.text else { continue }
            if merged != note.text {
                NoteHistory.willChange(note, to: merged, always: true, by: .teammate(theirs.editors.last ?? "A teammate"))
                note.text = merged
            }
            note.updatedAt = max(Date(), linkedAt.addingTimeInterval(0.001))
        }
        working[binderID] = nil
        store.save()
    }

    /// Sends what's left of a link that didn't finish. Nothing goes twice.
    @discardableResult
    func sendAgain(_ binder: BinderRecord) async -> Bool {
        guard let place = Self.place(of: binder), !place.uploaded else { return false }
        if let why = whyNotOn(place.hub) {
            problems[binder.id] = why
            done[binder.id] = nil
            return false
        }
        return await send(binder)
    }

    private func send(_ binder: BinderRecord) async -> Bool {
        guard var place = Self.place(of: binder) else { return false }
        let id = binder.id
        problems[id] = nil
        done[id] = nil
        defer { working[id] = nil }
        // A new project's own change keeps its id: sent again, the hub has it already.
        let changes = firstUpload(binder, to: place.binder, newName: place.newProject ? place.binderName : nil)
        let batches = HubLink.batches(changes, maxCount: batchCount)
        do {
            for (index, batch) in batches.enumerated() {
                working[id] = batches.count == 1 ? "Sending \(HubLink.counted(changes))…" : "Sending \(index + 1) of \(batches.count)…"
                _ = try await ask("api/changes", on: place.hub, space: place.space, body: HubLink.body(client: place.client, changes: batch))
            }
            working[id] = "Checking the hub has them…"
            let (state, _) = try await ask("api/state", on: place.hub, space: place.space)
            guard let missing = HubLink.missing(changes, fromState: state, binder: place.binder) else {
                throw Problem("The hub sent something that isn't its state.")
            }
            guard missing.isEmpty else {
                throw Problem("The hub doesn't have \(missing.count) of them yet. Send Again sends what's left.")
            }
            place.uploaded = true
            binder.hubLink = place.json
            store.save()
            done[id] = "Sent \(HubLink.counted(changes)) to \(place.binderName)."
            // From now on its board follows the hub's, and its notes are kept the same both ways.
            HubBoard.shared.follow()
            HubNotesSync.shared.refresh()
            return true
        } catch {
            problems[id] = (error as? Problem)?.words ?? "Couldn't reach \(HubSignInSection.shown(place.hub)): \(error.localizedDescription)"
            return false
        }
    }

    /// Unlinks a binder: it stays here with everything in it, and the project stays on the hub.
    func unlink(_ binder: BinderRecord) {
        binder.hubLink = ""
        binder.updatedAt = Date()
        store.save()
        HubBoard.shared.follow()
        HubNotesSync.shared.refresh()
        problems[binder.id] = nil
        done[binder.id] = nil
        working[binder.id] = nil
        Task { await HubAgentSetup.shared.refresh() }
    }

    // MARK: Asking the hub

    struct Problem: Error {
        let words: String
        init(_ words: String) { self.words = words }
    }

    /// A GET, or a POST of `body`, to `hub` in one of its Binders; the hub's answer when it's 200, or its words for why not.
    /// Asked again for each request, so one that started on a hub never goes on to another: this Mac's token is only
    /// ever for the hub it's signed in to, and a link's notes and cards only for the hub it was made on.
    private func ask(_ path: String, on hub: URL, space: String?, body: Data? = nil) async throws -> (Data, Int) {
        // Checked and made with nothing in between, on the main actor: the request goes to `hub` with its own token.
        if let why = whyNotOn(hub) { throw Problem(why) }
        guard var request = account.authorized(path) else { throw Problem("Sign in to \(HubSignInSection.shown(hub)) in Settings → Team first.") }
        if let space { request.setValue(space, forHTTPHeaderField: "x-binders-space") }
        if let body {
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 60
        }
        let (data, response) = try await account.send(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 {
            // Signs this Mac out when the hub no longer takes its token.
            await account.refresh()
            throw Problem("The hub signed this Mac out. Sign in again in Settings → Team.")
        }
        guard status == 200 else { throw Problem(HubLink.error(in: data).map { "The hub said: \($0)" } ?? "The hub answered \(status).") }
        return (data, status)
    }
}
