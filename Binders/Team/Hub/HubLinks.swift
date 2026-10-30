import Foundation
import SwiftData
import BindersKit

/// Binders on this Mac linked to projects on the hub it's signed in to (HubAccount). Linking picks one of the hub's
/// Binders and a project in it, or makes a new project named as the binder is, and sends up the binder's folders, notes
/// and cards (HubLink.firstUpload), then reads the hub's state back to check they all arrived. A link that didn't finish
/// is kept, with Send Again: its changes have the same ids under the link's own client, so the hub puts none of them
/// twice. Unlinking keeps the binder here as it is, and the project on the hub as it is. Keeping them the same both ways
/// from then on builds on the link (`place(of:)`).
///
/// Notes from what you said to yourself stay on this Mac, as they do with a team folder; meetings and captures aren't the
/// hub's. A binder shared with a team folder or a team database isn't linked: it would go to the team twice.
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

    /// Why a binder can't be linked, in words, or nil when it can.
    func whyNot(_ binder: BinderRecord) -> String? {
        if binder.isTeamCopy { return "This binder is a teammate's copy. Only its owner can link it to a hub." }
        if binder.sharedWithTeam || !binder.teamDatabaseKey.isEmpty {
            return "This binder is shared with your team already. Stop sharing it first, so it doesn't reach the team twice."
        }
        if !account.isSignedIn { return "Sign in to a hub in Settings → Team first." }
        return nil
    }

    /// The hub's Binders you're in, and the one it opens first.
    func spaces() async throws -> (spaces: [HubLink.Space], current: String?) {
        let (data, _) = try await ask("api/me", space: nil)
        return HubLink.spaces(fromMe: data)
    }

    /// The projects in one of the hub's Binders.
    func projects(in space: String) async throws -> [HubLink.Project] {
        let (data, _) = try await ask("api/state", space: space)
        guard let projects = HubLink.projects(fromState: data) else { throw Problem("The hub sent something that isn't its state.") }
        return projects
    }

    // MARK: Linking

    /// What a binder sends the first time, to `project` (a new one when `newName` is given).
    func firstUpload(_ binder: BinderRecord, to project: String, newName: String?) -> [HubLink.Outgoing] {
        let binderID = binder.id
        let folders = store.folders(in: binderID).map { HubLink.LocalFolder(id: $0.id, parent: $0.parentID, name: $0.name) }
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

    /// Links a binder to `project` in `space`, or to a new project named as the binder is when `project` is nil, and
    /// sends up what's in it. True when everything arrived.
    @discardableResult
    func link(_ binder: BinderRecord, space: HubLink.Space, to project: HubLink.Project?) async -> Bool {
        guard Self.place(of: binder) == nil else { return false }
        if let why = whyNot(binder) {
            problems[binder.id] = why
            return false
        }
        guard let hub = account.address else { return false }
        let projectID = project?.id ?? HubLink.newProjectID()
        let place = HubLink.Place(hub: hub, space: space.id, spaceName: space.name, binder: projectID,
                                  binderName: project?.name ?? binder.name, client: HubLink.newClient(), newProject: project == nil)
        // Kept before anything goes, so a link cut short is finished by Send Again rather than made twice.
        binder.hubLink = place.json
        binder.updatedAt = Date()
        store.save()
        return await send(binder)
    }

    /// Sends what's left of a link that didn't finish. Nothing goes twice.
    @discardableResult
    func sendAgain(_ binder: BinderRecord) async -> Bool {
        guard let place = Self.place(of: binder), !place.uploaded else { return false }
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
                _ = try await ask("api/changes", space: place.space, body: HubLink.body(client: place.client, changes: batch))
            }
            working[id] = "Checking the hub has them…"
            let (state, _) = try await ask("api/state", space: place.space)
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
            problems[id] = (error as? Problem)?.words ?? "Couldn't reach \(place.hub.host ?? "the hub"): \(error.localizedDescription)"
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
    }

    // MARK: Asking the hub

    struct Problem: Error {
        let words: String
        init(_ words: String) { self.words = words }
    }

    /// A GET, or a POST of `body`, to the hub in one of its Binders; the hub's answer when it's 200, or its words for why not.
    private func ask(_ path: String, space: String?, body: Data? = nil) async throws -> (Data, Int) {
        guard var request = account.authorized(path) else { throw Problem("Sign in to a hub in Settings → Team first.") }
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
