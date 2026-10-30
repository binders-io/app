import CryptoKit
import Foundation
import SwiftData
import BindersKit

/// The live feed of a hub's change log (/api/live): each message as it comes. A WebSocket, or a stand-in in the self-tests.
protocol HubFeed: AnyObject {
    func next() async throws -> Data
    func close()
}

/// /api/live over a WebSocket, with this Mac's token.
final class HubWebSocketFeed: HubFeed {
    private let task: URLSessionWebSocketTask
    private var pinging: Task<Void, Never>?

    init(_ request: URLRequest) {
        task = URLSession.shared.webSocketTask(with: request)
        // A Mac that was away catches up thousands of changes in one message.
        task.maximumMessageSize = 64 * 1024 * 1024
        task.resume()
        // A connection gone quiet (asleep, or a network that changed) is noticed, and opened again from where it got to.
        pinging = Task { [task] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(25))
                task.sendPing { error in if error != nil { task.cancel(with: .goingAway, reason: nil) } }
            }
        }
    }

    func next() async throws -> Data {
        switch try await task.receive() {
        case .string(let text): return Data(text.utf8)
        case .data(let data): return data
        @unknown default: return Data()
        }
    }

    func close() {
        pinging?.cancel()
        task.cancel(with: .goingAway, reason: nil)
    }
}

/// Linked binders' notes and folders kept the same here and on the hub, both ways, through its change log (lane HB3).
/// For each of the hub's Binders a linked binder is in: its state from GET /api/state the first time, then every change
/// after the version it's at from /api/live, applied as shared/notes.ts applies them (HubSync.State) and written to
/// the binders here; what changes here goes as changes on POST /api/changes, under the link's client.
///
/// - A save here is compared with the state (HubSync.plan): folders and notes put, moved and deleted go as they are.
/// - A note's words go as Automerge changes to its document as the hub has it (HubNoteDocument), so a teammate typing
///   in the same paragraph keeps their words too. The document is read from the hub the first time a note is edited
///   here, and kept on disk, in step with the feed. An edit made with no document (offline, or one the hub turned down
///   because its document was set aside) is made on the hub's document when it goes, merged from the hub's words it was
///   written on, so nothing anyone wrote is lost.
/// - What's waiting to go is kept on disk, in order, and goes when the hub can be reached; the feed starts again from the
///   last version taken in, so a Mac that was away catches up.
@MainActor
@Observable
final class HubNotesSync {
    static let shared = HubNotesSync()

    private var account: HubAccount { .shared }
    @ObservationIgnored private var store: Store { Store.shared }

    /// One of the hub's Binders, as this Mac follows it.
    final class Space {
        let id: String
        let hub: URL
        let folder: URL
        var state = HubSync.State()
        var started = false
        var outbox: [HubSync.Pending] = []
        /// Sent, and the hub has them, but not back in the feed yet: a note's words are checked against the hub's once
        /// none of its own are on their way.
        var unechoed: [String: String] = [:]
        var documents: [String: HubNoteDocument] = [:]
        /// Notes whose document is being read from the hub, and the changes to them the feed brought meanwhile.
        var reading: Set<String> = []
        var held: [String: [String]] = [:]
        var feed: HubFeed?
        var running: Task<Void, Never>?
        var connected = false
        var failures = 0
        var flushing = false
        var flushAgain = false
        var sending: Set<String> = []
        /// Back in the feed before the hub's answer to sending them.
        var echoed: Set<String> = []
        var problem: String?

        init(id: String, hub: URL, folder: URL) {
            self.id = id
            self.hub = hub
            self.folder = folder
        }
    }

    @ObservationIgnored private(set) var spaces: [String: Space] = [:]
    /// Bumped as what's shown changes (connected, waiting, a problem), for the views.
    private(set) var shown = 0
    @ObservationIgnored private var observer: NSObjectProtocol?
    @ObservationIgnored private var sweeping: Task<Void, Never>?
    @ObservationIgnored private var writing: Task<Void, Never>?

    /// How often each way of keeping a note's words went, for the self-tests: "edit" (changes on the document here),
    /// "applied" (the feed's changes into it), "remade" (on the hub's document), "refused", "reread" (words that differed).
    @ObservationIgnored private(set) var counts: [String: Int] = [:]
    /// Opens the live feed (the self-tests answer it themselves).
    @ObservationIgnored var openFeed: (URLRequest) -> HubFeed = { HubWebSocketFeed($0) }
    /// How long to wait before trying the hub again (the self-tests wait less).
    @ObservationIgnored var retryDelay: (Int) -> TimeInterval = HubSync.retryDelay
    /// How long a save waits for more before it's compared (the self-tests wait less).
    @ObservationIgnored var gather: Duration = .milliseconds(400)
    /// Where each Binder's state, outbox and documents are kept.
    @ObservationIgnored var root: URL = AppPaths.support.appendingPathComponent("Hub", isDirectory: true)

    // MARK: Starting and stopping

    /// Follows every linked binder's hub Binder, and stops following the ones none is linked to any more. At launch, and
    /// whenever a binder is linked or unlinked, or this Mac signs in or out.
    func refresh() {
        if observer == nil {
            observer = NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: nil, queue: .main) { [weak self] note in
                guard !TaskCard.onlyBoards(note.userInfo) else { return }
                MainActor.assumeIsolated { self?.sweepSoon() }
            }
        }
        let wanted: Set<String> = account.isSignedIn && store.canSave ? Set(linked().map(\.place.space)) : []
        for (id, space) in spaces where !wanted.contains(id) {
            stop(space)
            spaces[id] = nil
        }
        guard let hub = account.address else { return }
        for id in wanted where spaces[id] == nil {
            let space = Space(id: id, hub: hub, folder: root.appendingPathComponent(Self.folderName(hub: hub, space: id), isDirectory: true))
            load(space)
            spaces[id] = space
            space.running = Task { [weak self] in await self?.run(space) }
        }
        shown += 1
    }

    /// Stops following every hub Binder, with what's waiting kept on disk.
    func stopAll() {
        for space in spaces.values { stop(space) }
        spaces = [:]
    }

    private func stop(_ space: Space) {
        space.running?.cancel()
        space.feed?.close()
        space.feed = nil
        space.connected = false
        write(space)
    }

    /// Drops every live feed, as losing the network does: each starts again from where it got to (the self-tests).
    func dropFeeds() {
        for space in spaces.values { space.feed?.close() }
    }

    /// Before quitting: what's waiting, and where each Binder is at, on disk now.
    func flushToDisk() {
        for space in spaces.values { write(space) }
    }

    static func folderName(hub: URL, space: String) -> String {
        let key = SHA256.hash(data: Data("\(hub.absoluteString)|\(space)".utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return "\(hub.host ?? "hub")-\(key)"
    }

    /// The binders here linked to the hub this Mac is signed in to, with everything sent up the first time.
    private func linked() -> [(binder: BinderRecord, place: HubLink.Place)] {
        guard let hub = account.address else { return [] }
        return ((try? store.context.fetch(FetchDescriptor<BinderRecord>(predicate: #Predicate { !$0.hubLink.isEmpty }))) ?? [])
            .compactMap { binder in HubLinks.place(of: binder).map { (binder, $0) } }
            .filter { $0.place.uploaded && $0.place.hub == hub }
    }

    private func linked(in space: Space) -> [(binder: BinderRecord, place: HubLink.Place)] {
        linked().filter { $0.place.space == space.id }
    }

    // MARK: What's shown

    /// How a linked binder's sync is, in words, or nil when all is well.
    func status(of binder: BinderRecord) -> String? {
        _ = shown
        guard let place = HubLinks.place(of: binder), place.uploaded, let space = spaces[place.space] else { return nil }
        if let problem = space.problem { return problem }
        let waiting = space.outbox.filter { $0.client == place.client }.count
        if !space.connected { return waiting > 0 ? "Offline · \(waiting) to send" : "Offline" }
        return waiting > 0 ? "Sending \(waiting)…" : nil
    }

    // MARK: Following the feed

    private func run(_ space: Space) async {
        while !Task.isCancelled {
            do {
                if !space.started { try await start(space) }
                reconcile(space)
                await flush(space)
                try await follow(space)
            } catch is CancellationError {
                return
            } catch {
                if Task.isCancelled { return }
                if (error as? Problem)?.signedOut == true {
                    space.problem = "The hub signed this Mac out. Sign in again in Settings → Team."
                    space.connected = false
                    shown += 1
                    return
                }
            }
            space.feed?.close()
            space.feed = nil
            space.connected = false
            space.failures += 1
            shown += 1
            try? await Task.sleep(for: .seconds(retryDelay(space.failures)))
        }
    }

    /// The first time: the hub's state, and the version the feed goes on from.
    private func start(_ space: Space) async throws {
        let (data, _) = try await ask("api/state", space: space)
        guard var state = HubSync.State(hubState: data) else { throw Problem("The hub sent something that isn't its state.") }
        state.shared = []
        space.state = state
        space.started = true
        // What changed on either side between linking and now: the hub's when it's newer than the link, else this Mac's.
        for (binder, place) in linked(in: space) { takeNewer(binder, place: place, space: space) }
        writeSoon(space)
    }

    private func follow(_ space: Space) async throws {
        guard var request = account.authorized("api/live"), let url = HubSync.liveURL(hub: space.hub, since: space.state.version)
        else { throw Problem("Sign in to a hub in Settings → Team first.", signedOut: true) }
        request.url = url
        request.setValue(space.id, forHTTPHeaderField: "x-binders-space")
        let feed = openFeed(request)
        space.feed = feed
        while !Task.isCancelled {
            let message = try await feed.next()
            if !space.connected {
                space.connected = true
                space.failures = 0
                space.problem = nil
                shown += 1
                // Back after being away: what waited goes now, pictures included.
                HubPictures.shared.backOnline()
                sweepSoon()
                Task { await self.flush(space) }
            }
            guard let entries = HubSync.entries(fromLive: message) else { continue }
            take(entries, in: space)
            // The hub sends at most 5000 at first: a Mac further behind asks again from where it got to.
            if entries.count >= 5000 { throw Problem("Catching up") }
        }
        throw CancellationError()
    }

    // MARK: Coming: the hub's changes

    private var person: String { account.person?.login ?? "you" }

    func take(_ entries: [HubSync.Entry], in space: Space) {
        let fresh = entries.filter { $0.version > space.state.version }.sorted { $0.version < $1.version }
        guard !fresh.isEmpty else { return }
        let binders = Dictionary(linked(in: space).map { ($0.place.binder, $0.binder.id) }, uniquingKeysWith: { first, _ in first })
        let clients = Set(linked(in: space).map { HubSync.logClient(login: person, client: $0.place.client) })
        // Whatever editors hold goes to its note first, so it's merged rather than written over.
        if fresh.contains(where: { if case .noteEdit = $0.change { true } else if case .notePut = $0.change { true } else { false } }) {
            MarkdownEditor.flushAll()
        }
        var touched: Set<String> = []
        for entry in fresh {
            let own = clients.contains(entry.client)
            if own, space.unechoed.removeValue(forKey: entry.id) == nil, space.sending.contains(entry.id) { space.echoed.insert(entry.id) }
            take(entry.change, own: own, binders: binders, space: space, touched: &touched)
            space.state.version = entry.version
        }
        store.save()
        check(touched, in: space)
        writeSoon(space)
        shown += 1
    }

    private func take(_ change: HubSync.Change, own: Bool, binders: [String: UUID], space: Space, touched: inout Set<String>) {
        switch change {
        case .folderPut(let folder):
            space.state.apply(change)
            guard let binder = binders[folder.binderId] else {
                if let here = store.folder(HubSync.localID(folder.id)) { store.deleteFolder(here) }
                return
            }
            let id = HubSync.localID(folder.id)
            let parent = folder.parentId.map(HubSync.localID)
            if let here = store.folder(id) {
                if here.name != folder.name || here.parentID != parent || here.binderID != binder {
                    here.name = folder.name
                    here.parentID = parent
                    here.binderID = binder
                    here.updatedAt = Date()
                }
            } else {
                let made = FolderRecord(name: folder.name, binderID: binder, parentID: parent)
                made.id = id
                store.context.insert(made)
            }
            space.state.shared.insert(folder.id)
        case .folderDelete(let id):
            space.state.apply(change)
            if let here = store.folder(HubSync.localID(id)) { store.deleteFolder(here) }
        case .notePut(let note):
            // Its words written whole: the hub sets its document aside, and so does this Mac.
            forgetDocument(note.id, in: space, keepingEdits: true)
            let before = space.state.notes[note.id]?.text
            space.state.apply(change)
            guard binders[note.binderId] != nil else { return removeNote(note.id) }
            if own, store.note(HubSync.localID(note.id)) != nil { return }
            write(note.id, from: before, to: note.text, by: own ? .you : .teammate(note.editors.last ?? "A teammate"), space: space,
                  binders: binders)
        case .noteEdit(let edit):
            let before = space.state.notes[edit.id]?.text
            let id = HubSync.localID(edit.id)
            if let note = store.note(id), binders[space.state.notes[edit.id]?.binderId ?? ""] != nil { capture(note, hubID: edit.id, space: space) }
            space.state.apply(change)
            guard let hub = space.state.notes[edit.id], binders[hub.binderId] != nil else { return }
            let author: NoteAuthor = own ? .you : .teammate(edit.by)
            if space.reading.contains(edit.id) {
                // Its document is on its way from the hub: these go into it when it comes, and the words here now.
                space.held[edit.id, default: []] += edit.changes ?? []
            } else if let changes = edit.changes, let document = document(edit.id, in: space) {
                do {
                    try document.apply(changes)
                    counts["applied", default: 0] += 1
                    writeDocumentSoon(edit.id, in: space)
                    show(document.text, in: edit.id, by: author, space: space, binders: binders)
                    touched.insert(edit.id)
                    return
                } catch {
                    forgetDocument(edit.id, in: space, keepingEdits: true)
                }
            } else if edit.changes == nil {
                // Written whole (an app from before Automerge): the hub's document starts again from these words.
                forgetDocument(edit.id, in: space, keepingEdits: true)
            }
            write(edit.id, from: before, to: hub.text, by: author, space: space, binders: binders)
        case .noteMove(let id, let binderId, let folderId):
            space.state.apply(change)
            guard let binder = binders[binderId] else { return removeNote(id) }
            if let note = store.note(HubSync.localID(id)) {
                let folder = folderId.map(HubSync.localID)
                if note.binderID != binder || note.folderID != folder {
                    note.binderID = binder
                    note.folderID = folder
                }
            } else if let hub = space.state.notes[id] {
                make(hub, in: binder, space: space)
            }
        case .noteDelete(let id):
            space.state.apply(change)
            forgetDocument(id, in: space, keepingEdits: false)
            removeNote(id)
        case .binderPut, .binderDelete, .noteLink, .noteSaved, .other:
            space.state.apply(change)
        }
    }

    /// A note here takes the hub's words: `to`, merged with whatever was written here since it last had the hub's
    /// (`from`). A note that isn't here yet is made.
    private func write(_ hubID: String, from base: String?, to text: String, by author: NoteAuthor, space: Space, binders: [String: UUID]) {
        guard let hub = space.state.notes[hubID], let binder = binders[hub.binderId] else { return }
        guard let note = store.note(HubSync.localID(hubID)) else { return make(hub, in: binder, space: space) }
        let merged = HubNoteDocument.merge(base: base ?? text, theirs: text, ours: note.text)
        set(note, to: merged, by: author)
        // What's left of this Mac's words goes when it can, on the hub's document.
        if merged != text { markEdited(hubID, in: space) }
    }

    /// The note here takes its document's words.
    private func show(_ text: String, in hubID: String, by author: NoteAuthor, space: Space, binders: [String: UUID]) {
        guard let note = store.note(HubSync.localID(hubID)) else {
            if let hub = space.state.notes[hubID], let binder = binders[hub.binderId] { make(hub, in: binder, space: space) }
            return
        }
        set(note, to: text, by: author)
    }

    private func set(_ note: NoteItem, to text: String, by author: NoteAuthor) {
        guard note.text != text else { return }
        HubPictures.shared.fetchMissing(in: text)
        NoteHistory.willChange(note, to: text, always: true, by: author)
        note.text = text
        note.updatedAt = Date()
    }

    private func make(_ hub: HubSync.Note, in binder: UUID, space: Space) {
        let note = NoteItem(text: hub.text)
        note.id = HubSync.localID(hub.id)
        HubPictures.shared.fetchMissing(in: hub.text, space: space.id)
        note.binderID = binder
        // In its folder, which may not have come yet: it shows at the top of its binder until it does.
        note.folderID = hub.folderId.map(HubSync.localID)
        store.context.insert(note)
        space.state.shared.insert(hub.id)
    }

    private func removeNote(_ hubID: String) {
        guard let note = store.note(HubSync.localID(hubID)) else { return }
        NotificationCenter.default.post(name: TeamSyncService.itemsWillBeRemoved, object: self, userInfo: ["ids": Set([note.id])])
        ScratchpadController.shared.noteWillBeDeleted(note)
        NotePopouts.shared.close(note.id)
        store.context.delete(note)
    }

    /// Edited notes whose own changes are all back from the hub: their words should be the hub's. One that isn't (a change
    /// missed, or one that waits for a change this Mac never had) reads its document again when it's next edited, and
    /// takes the hub's words now.
    private func check(_ notes: Set<String>, in space: Space) {
        let waiting = Set(space.outbox.compactMap(\.editedNote) + space.unechoed.values)
        for id in notes where !waiting.contains(id) {
            guard let document = space.documents[id], let hub = space.state.notes[id], document.text != hub.text else { continue }
            forgetDocument(id, in: space, keepingEdits: false)
            counts["reread", default: 0] += 1
            if let note = store.note(HubSync.localID(id)) { set(note, to: hub.text, by: .teammate(hub.editors.last ?? "A teammate")) }
        }
    }

    // MARK: Going: this Mac's changes

    /// Every linked binder is compared with the hub's state, soon (a save names nothing a sweep can use).
    func sweepSoon() {
        guard !spaces.isEmpty else { return }
        sweeping?.cancel()
        sweeping = Task { [weak self, gather] in
            try? await Task.sleep(for: gather)
            guard !Task.isCancelled, let self else { return }
            for space in self.spaces.values where space.started {
                self.reconcile(space)
                Task { await self.flush(space) }
            }
        }
    }

    /// The editor's typing in a linked note, once it pauses.
    func typed(_ note: UUID) { sweepSoon() }

    /// Each linked binder of a hub Binder against its state: what the hub doesn't have goes, what it has that isn't here
    /// comes, and edited notes go as edits.
    func reconcile(_ space: Space) {
        guard space.started, store.canSave else { return }
        let links = linked(in: space)
        var ids = HubSync.hubIDs(in: space.state)
        func hubID(_ id: UUID) -> String { ids[id] ?? HubLink.hubID(id) }
        var everywhere: [UUID: Set<String>] = [:]
        var notesHere: [UUID: [NoteItem]] = [:]
        for (binder, _) in links {
            let notes = notes(in: binder.id)
            notesHere[binder.id] = notes
            everywhere[binder.id] = Set(notes.map { hubID($0.id) })
            // Pictures only on this Mac go up first; the note's words follow, naming the hub's copies.
            for note in notes { HubPictures.shared.send(note, hubID: hubID(note.id), space: space.id) }
        }
        var changed = false
        for (binder, place) in links {
            let elsewhere = everywhere.filter { $0.key != binder.id }.values.reduce(into: Set<String>()) { $0.formUnion($1) }
            for pass in 0..<2 {
                let folders = store.folders(in: binder.id)
                let notes = pass == 0 ? notesHere[binder.id] ?? [] : notes(in: binder.id)
                let known = Set(folders.map(\.id))
                let plan = HubSync.plan(
                    project: place.binder, state: space.state,
                    folders: folders.map { .init(id: hubID($0.id), parent: $0.parentID.flatMap { known.contains($0) ? hubID($0) : nil }, name: $0.name) },
                    notes: notes.map { .init(id: hubID($0.id), folder: $0.folderID.flatMap { known.contains($0) ? hubID($0) : nil }, text: $0.text) },
                    person: person, elsewhere: elsewhere)
                // What the hub has that isn't here comes first, so what goes is compared with it here.
                if pass == 0, !plan.newFolders.isEmpty || !plan.newNotes.isEmpty {
                    for id in plan.newFolders {
                        guard let folder = space.state.folders[id] else { continue }
                        let made = FolderRecord(name: folder.name, binderID: binder.id, parentID: folder.parentId.map(HubSync.localID))
                        made.id = HubSync.localID(id)
                        store.context.insert(made)
                        space.state.shared.insert(id)
                    }
                    for id in plan.newNotes { if let note = space.state.notes[id] { make(note, in: binder.id, space: space) } }
                    store.save()
                    ids = HubSync.hubIDs(in: space.state)
                    changed = true
                    continue
                }
                for change in plan.changes {
                    space.state.apply(change)
                    switch change {
                    case .folderPut(let folder): space.state.shared.insert(folder.id)
                    case .notePut(let note): space.state.shared.insert(note.id)
                    default: break
                    }
                    space.outbox.append(.init(client: place.client, change: change))
                    changed = true
                }
                let byID = Dictionary(notes.map { (hubID($0.id), $0) }, uniquingKeysWith: { first, _ in first })
                for id in plan.edited {
                    if let note = byID[id], !HubPictures.shared.isSending(note.id), capture(note, hubID: id, space: space) { changed = true }
                }
                for note in notes { space.state.shared.insert(hubID(note.id)) }
                for folder in folders { space.state.shared.insert(hubID(folder.id)) }
                break
            }
        }
        if changed {
            writeSoon(space)
            shown += 1
        }
    }

    /// A linked binder's notes, but the ones from what you said to yourself, which stay on this Mac.
    private func notes(in binder: UUID) -> [NoteItem] {
        ((try? store.context.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.binderID == binder }))) ?? []).filter { !$0.staysUnshared }
    }

    /// The note's words here, as an edit when they aren't the ones its document (or the hub, when it has none here) has.
    /// True when something waits to go.
    @discardableResult
    private func capture(_ note: NoteItem, hubID: String, space: Space) -> Bool {
        guard let hub = space.state.notes[hubID], let client = linked(in: space).first(where: { $0.place.binder == hub.binderId })?.place.client
        else { return false }
        // A note on its way up takes its words with it.
        if let index = space.outbox.lastIndex(where: { if case .notePut(let put) = $0.change { put.id == hubID } else { false } }),
           !space.sending.contains(space.outbox[index].id), case .notePut(var put) = space.outbox[index].change {
            guard put.text != note.text else { return false }
            put.text = note.text
            put.title = HubSync.title(of: note.text)
            space.outbox[index].change = .notePut(put)
            space.state.notes[hubID]?.text = note.text
            return true
        }
        if space.reading.contains(hubID) { return markEdited(hubID, in: space, client: client) }
        guard let document = document(hubID, in: space) else {
            return note.text != hub.text && markEdited(hubID, in: space, client: client)
        }
        let base = document.text
        guard let change = try? document.change(to: note.text) else { return false }
        space.outbox.append(.init(client: client, change: .noteEdit(edit(hubID, text: note.text, changes: [change])), base: base))
        counts["edit", default: 0] += 1
        writeDocumentSoon(hubID, in: space)
        return true
    }

    private func edit(_ hubID: String, text: String, changes: [String]?) -> HubSync.Edit {
        HubSync.Edit(id: hubID, text: text, title: HubSync.title(of: text), by: person, at: HubLink.iso(Date()), changes: changes)
    }

    /// One edit of the note waits to go without its changes: they're made on the hub's document when it goes.
    @discardableResult
    private func markEdited(_ hubID: String, in space: Space, client: String? = nil) -> Bool {
        let client = client ?? space.state.notes[hubID].flatMap { hub in linked(in: space).first { $0.place.binder == hub.binderId }?.place.client }
        guard let client else { return false }
        if space.outbox.contains(where: { $0.editedNote == hubID && !space.sending.contains($0.id) && Self.isWhole($0) }) { return false }
        space.outbox.append(.init(client: client, change: .noteEdit(edit(hubID, text: "", changes: nil))))
        return true
    }

    private static func isWhole(_ pending: HubSync.Pending) -> Bool {
        if case .noteEdit(let edit) = pending.change { return edit.changes == nil }
        return false
    }

    // MARK: Sending

    /// What's waiting goes, in order, while the hub takes it.
    func flush(_ space: Space) async {
        guard !space.flushing else {
            space.flushAgain = true
            return
        }
        space.flushing = true
        defer { space.flushing = false }
        var oneByOne = false
        var remade: Set<String> = []
        repeat {
            space.flushAgain = false
            while true {
                let batch = HubSync.nextBatch(space.outbox, maxCount: oneByOne ? 1 : 100)
                guard !batch.isEmpty, !Task.isCancelled else { break }
                // An edit without its changes is made on the hub's document first.
                if let whole = batch.first(where: Self.isWhole), let note = whole.editedNote {
                    guard await remake(note, in: space) else { return }
                    continue
                }
                space.sending = Set(batch.map(\.id))
                let answer = try? await ask("api/changes", space: space, body: HubSync.body(batch), refusals: true)
                space.sending = []
                guard let (data, status) = answer else {
                    // Offline: it goes when the hub's back.
                    space.connected = false
                    shown += 1
                    return
                }
                switch status {
                case 200:
                    let sent = Set(batch.map(\.id))
                    for pending in batch {
                        if let note = pending.editedNote, space.echoed.remove(pending.id) == nil { space.unechoed[pending.id] = note }
                    }
                    space.outbox.removeAll { sent.contains($0.id) }
                    oneByOne = false
                    space.problem = nil
                case 401:
                    await account.refresh()
                    space.problem = "The hub signed this Mac out. Sign in again in Settings → Team."
                    shown += 1
                    return
                case 400, 422:
                    guard batch.count == 1 else {
                        // One of them was turned down: each goes on its own, to find it.
                        oneByOne = true
                        continue
                    }
                    let refused = batch[0]
                    counts["refused", default: 0] += 1
                    if let note = refused.editedNote, !remade.contains(note) {
                        // Its note's document was set aside on the hub, or this Mac's is behind: made again on the hub's.
                        remade.insert(note)
                        forgetDocument(note, in: space, keepingEdits: true)
                        continue
                    }
                    space.outbox.removeAll { $0.id == refused.id }
                    space.problem = "The hub turned down a change: \(HubLink.error(in: data) ?? "code \(status)")"
                    Log.app.error("Hub refused \(refused.id): \(HubLink.error(in: data) ?? String(status))")
                default:
                    space.connected = false
                    shown += 1
                    return
                }
                writeSoon(space)
                shown += 1
            }
        } while space.flushAgain
    }

    /// A note's edits made again on the hub's document as it is now: the words the hub had when they were written here,
    /// to the words here now, merged with what the hub has had since. True when it's done, or there was nothing to do.
    private func remake(_ hubID: String, in space: Space) async -> Bool {
        space.reading.insert(hubID)
        space.held[hubID] = []
        defer {
            space.reading.remove(hubID)
            space.held[hubID] = nil
        }
        let answer = try? await ask("api/notes/\(hubID)/doc", space: space, refusals: true)
        guard let (data, status) = answer else { return false }
        let indices = space.outbox.indices.filter { space.outbox[$0].editedNote == hubID && !space.sending.contains(space.outbox[$0].id) }
        guard status == 200, let document = try? HubNoteDocument(note: HubSync.localID(hubID), saved: data) else {
            // Gone from the hub: its edits go with it.
            if status == 404 { space.outbox.remove(atOffsets: IndexSet(indices)) }
            return status == 404
        }
        // What the feed brought meanwhile goes in too (ones it has already change nothing).
        try? document.apply(space.held[hubID] ?? [])
        space.documents[hubID] = document
        writeDocumentSoon(hubID, in: space)
        MarkdownEditor.flushAll()
        let note = store.note(HubSync.localID(hubID))
        // The hub's words since the note here last took them: from what the state says, merged with this Mac's.
        let hubText = space.state.notes[hubID]?.text ?? document.text
        let ours = note?.text ?? hubText
        let merged = HubNoteDocument.merge(base: hubText, theirs: document.text, ours: ours)
        let client = space.outbox[indices.first ?? 0].client
        let at = indices.first ?? space.outbox.count
        space.outbox.remove(atOffsets: IndexSet(indices))
        let before = document.text
        if let change = try? document.change(to: merged) {
            space.outbox.insert(.init(client: client, change: .noteEdit(edit(hubID, text: merged, changes: [change])), base: before),
                                at: min(at, space.outbox.count))
        }
        if let note { set(note, to: merged, by: .teammate(space.state.notes[hubID]?.editors.last ?? "A teammate")) }
        counts["remade", default: 0] += 1
        store.save()
        writeSoon(space)
        return true
    }

    // MARK: Documents

    private func documentURL(_ hubID: String, in space: Space) -> URL {
        let name = SHA256.hash(data: Data(hubID.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return space.folder.appendingPathComponent("docs", isDirectory: true).appendingPathComponent("\(name).automerge")
    }

    /// The note's document here, in memory or on disk; nil until it's been read from the hub.
    private func document(_ hubID: String, in space: Space) -> HubNoteDocument? {
        if let known = space.documents[hubID] { return known }
        guard let data = try? Data(contentsOf: documentURL(hubID, in: space)),
              let document = try? HubNoteDocument(note: HubSync.localID(hubID), saved: data) else { return nil }
        space.documents[hubID] = document
        return document
    }

    /// The note's document is set aside, here as on the hub. `keepingEdits`: this Mac's edits waiting to go are made again
    /// on the hub's document when they go, else they're dropped.
    private func forgetDocument(_ hubID: String, in space: Space, keepingEdits: Bool) {
        space.documents[hubID] = nil
        try? FileManager.default.removeItem(at: documentURL(hubID, in: space))
        let edits = space.outbox.filter { $0.editedNote == hubID && !space.sending.contains($0.id) }
        guard !edits.isEmpty else { return }
        let client = edits[0].client
        let at = space.outbox.firstIndex { $0.id == edits[0].id } ?? space.outbox.count
        let gone = Set(edits.map(\.id))
        space.outbox.removeAll { gone.contains($0.id) }
        if keepingEdits { space.outbox.insert(.init(client: client, change: .noteEdit(edit(hubID, text: "", changes: nil))), at: min(at, space.outbox.count)) }
    }

    @ObservationIgnored private var documentsDue: [String: Set<String>] = [:]

    private func writeDocumentSoon(_ hubID: String, in space: Space) {
        documentsDue[space.id, default: []].insert(hubID)
        writeSoon(space)
    }

    // MARK: On disk

    private struct Saved: Codable {
        var state: HubSync.State
        var started: Bool
        var outbox: [HubSync.Pending]
        var unechoed: [String: String]?
    }

    private func load(_ space: Space) {
        guard let data = try? Data(contentsOf: space.folder.appendingPathComponent("sync.json")),
              let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return }
        space.state = saved.state
        space.started = saved.started
        space.outbox = saved.outbox
        space.unechoed = saved.unechoed ?? [:]
    }

    private func writeSoon(_ space: Space) {
        writing?.cancel()
        writing = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }
            for space in self.spaces.values { self.write(space) }
        }
    }

    private func write(_ space: Space) {
        try? FileManager.default.createDirectory(at: space.folder.appendingPathComponent("docs", isDirectory: true), withIntermediateDirectories: true)
        let saved = Saved(state: space.state, started: space.started, outbox: space.outbox, unechoed: space.unechoed)
        if let data = try? JSONEncoder().encode(saved) { try? data.write(to: space.folder.appendingPathComponent("sync.json"), options: .atomic) }
        for id in documentsDue.removeValue(forKey: space.id) ?? [] {
            if let document = space.documents[id] { try? document.save().write(to: documentURL(id, in: space), options: .atomic) }
        }
    }

    // MARK: Between linking and following

    /// The first time a hub Binder is followed: a note or folder both have that differs is the hub's when it hasn't
    /// changed here since the binder was linked, else this Mac's, which then goes.
    private func takeNewer(_ binder: BinderRecord, place: HubLink.Place, space: Space) {
        let state = space.state
        for folder in store.folders(in: binder.id) where folder.updatedAt <= place.linkedAt {
            guard let hub = state.folders[HubLink.hubID(folder.id)], hub.binderId == place.binder else { continue }
            let parent = hub.parentId.map(HubSync.localID)
            if folder.name != hub.name || folder.parentID != parent {
                folder.name = hub.name
                folder.parentID = parent
            }
        }
        let binderID = binder.id
        for note in (try? store.context.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.binderID == binderID }))) ?? []
        where note.updatedAt <= place.linkedAt {
            guard let hub = state.notes[HubLink.hubID(note.id)], hub.binderId == place.binder else { continue }
            set(note, to: hub.text, by: .teammate(hub.editors.last ?? "A teammate"))
            note.folderID = hub.folderId.map(HubSync.localID)
        }
        store.save()
    }

    // MARK: Asking the hub

    struct Problem: Error {
        let words: String
        var signedOut = false
        init(_ words: String, signedOut: Bool = false) {
            self.words = words
            self.signedOut = signedOut
        }
    }

    /// A GET, or a POST of `body`, in one of the hub's Binders. With `refusals`, the hub's answer whatever its status;
    /// else only a 200's, and its words for why not.
    private func ask(_ path: String, space: Space, body: Data? = nil, refusals: Bool = false) async throws -> (Data, Int) {
        guard var request = account.authorized(path) else { throw Problem("Sign in to a hub in Settings → Team first.", signedOut: true) }
        request.setValue(space.id, forHTTPHeaderField: "x-binders-space")
        if let body {
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 60
        }
        let (data, response) = try await account.send(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if refusals { return (data, status) }
        if status == 401 {
            await account.refresh()
            throw Problem("The hub signed this Mac out.", signedOut: true)
        }
        guard status == 200 else { throw Problem(HubLink.error(in: data) ?? "The hub answered \(status).") }
        return (data, status)
    }
}
