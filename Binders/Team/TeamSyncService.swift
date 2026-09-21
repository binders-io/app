import AppKit
import Foundation
import Observation
import SwiftData
import BindersKit

enum TeamError: LocalizedError {
    case folderMissing(String)
    case notATeamSpace

    var errorDescription: String? {
        switch self {
        case .folderMissing(let path):
            "The team folder isn't available (\(path)). Make sure OneDrive, Dropbox, Google Drive or iCloud Drive is running."
        case .notATeamSpace:
            "That folder isn't a Binders team space yet. Pick the folder a teammate shared with you (wait for it to finish syncing), or create a new team space."
        }
    }
}

private struct TeamSyncState: Codable {
    struct Entry: Codable, Equatable {
        /// Content hash both sides agreed on at the last sync.
        var hash: String
        /// Markdown file path relative to the team folder.
        var path: String?
        /// When the file was first found missing; without a deletion record it counts as deleted only after a grace period.
        var missingSince: Date?
    }

    var meetings: [String: Entry] = [:]
    var notes: [String: Entry] = [:]
}

private struct RemoteMeeting: Sendable {
    let modified: Date
    let size: Int
    let file: TeamMeetingFile
    let hash: String
}

private struct RemoteNote: Sendable {
    let url: URL
    let path: String
    let note: TeamNote
    let modified: Date
}

private struct ScanRequest: Sendable {
    let folder: URL
    let meetingCache: [String: RemoteMeeting]
    /// Relative note path -> id, as of the last sync.
    let notePathIDs: [String: String]
    let indexMeetingMarkdown: Bool
    let idAssignmentAge: TimeInterval
}

/// Everything read from the team folder in one pass, gathered off the main thread.
private struct FolderScan: Sendable {
    var binders: [String: TeamBinderFile] = [:]
    var bindersFolderExists = false
    var meetings: [String: RemoteMeeting] = [:]
    var meetingCache: [String: RemoteMeeting] = [:]
    /// Meetings whose data file exists but isn't readable yet.
    var pendingMeetingIDs: Set<String> = []
    /// binders_id -> relative path of existing meeting Markdown.
    var meetingMarkdownPaths: [String: String] = [:]
    var notesFolderExists = false
    var notes: [String: RemoteNote] = [:]
    /// Note files that exist but can't be read yet (downloading, placeholders, mid-write).
    var unreadableNotePaths: Set<String> = []
    var tombstones: [String: TeamTombstone] = [:]
    var members: [TeamMember] = []
    var manifest: TeamManifest?
}

/// Shares meetings and notes with teammates through a folder synced by OneDrive, Dropbox, Google Drive or iCloud Drive.
///
/// Folder layout: `Meetings/*.md` and `Notes/*.md` (readable, and usable as an Obsidian vault) plus `_binders/` with
/// meeting data, members and deletion records. Meetings are edited only by their author; notes are editable by everyone.
/// Anything ambiguous (unreadable files, files that briefly vanish, edits on both sides) keeps data rather than deleting it.
@MainActor
@Observable
final class TeamSyncService {
    struct Status: Equatable {
        var teamName: String?
        var members: [TeamMember] = []
        var lastSync: Date?
        var error: String?
        var sharedMeetings = 0
        var sharedNotes = 0
        var teamMeetings = 0
        var teamNotes = 0
    }

    private struct Removals {
        var meetings: [MeetingRecord] = []
        var notes: [NoteItem] = []
        var isEmpty: Bool { meetings.isEmpty && notes.isEmpty }
    }

    /// Posted with `ids: Set<UUID>` just before synced-away meetings or notes are deleted, so views can let go of them.
    static let itemsWillBeRemoved = Notification.Name("BindersTeamItemsWillBeRemoved")

    private(set) var status = Status()
    /// What the last sync brought in, e.g. "Dana shared “Pricing sync”".
    @ObservationIgnored private(set) var lastAnnouncements: [String] = []
    /// Replaces the folder and identity from Settings; used by self-tests.
    @ObservationIgnored var identityOverride: (folder: URL, me: TeamAuthor)?
    /// How long a vanished file must stay gone, with no deletion record, before it counts as deleted.
    @ObservationIgnored var deletionGrace: TimeInterval = 120
    /// Notes added outside Binders get an id once they haven't changed for this long.
    @ObservationIgnored var idAssignmentAge: TimeInterval = 60

    @ObservationIgnored private let flowBar: FlowBarController?
    @ObservationIgnored private let store: Store
    @ObservationIgnored private let stateURL: URL
    @ObservationIgnored private var state: TeamSyncState
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var syncing = false
    @ObservationIgnored private var resyncRequested = false
    @ObservationIgnored private var writeError: String?
    @ObservationIgnored private var localCache: [String: (fingerprint: Int, file: TeamMeetingFile, hash: String)] = [:]
    @ObservationIgnored private var remoteCache: [String: RemoteMeeting] = [:]

    private var settings: AppSettings { AppSettings.shared }

    static var sharesNewMeetings: Bool { AppSettings.shared.teamFolderPath != nil && AppSettings.shared.shareMeetingsByDefault }
    static var sharesNewNotes: Bool { AppSettings.shared.teamFolderPath != nil && AppSettings.shared.shareNotesByDefault }

    init(flowBar: FlowBarController?, store: Store? = nil, stateURL: URL? = nil) {
        self.flowBar = flowBar
        self.store = store ?? .shared
        let stateURL = stateURL ?? AppPaths.support.appendingPathComponent("TeamSync.json")
        self.stateURL = stateURL
        state = (try? Data(contentsOf: stateURL)).flatMap { try? JSONDecoder().decode(TeamSyncState.self, from: $0) } ?? TeamSyncState()
    }

    var folderURL: URL? {
        if let identityOverride { return identityOverride.folder }
        return settings.teamFolderPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    var isConfigured: Bool { folderURL != nil }

    var me: TeamAuthor {
        if let identityOverride { return identityOverride.me }
        let name = settings.teamMemberName.trimmed
        let fallback = NSFullUserName().trimmed
        return TeamAuthor(id: settings.teamMemberID, name: name.isEmpty ? (fallback.isEmpty ? "Me" : fallback) : name)
    }

    func start() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: ModelContext.didSave, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.syncing { self.resyncRequested = true } else { self.scheduleSync(after: 3) }
            }
        })
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleSync(after: 0.5) }
        })
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleSync(after: 0) }
        }
        updateCounts()
        scheduleSync(after: 2)
    }

    func scheduleSync(after delay: TimeInterval) {
        guard isConfigured else { return }
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.syncNow()
        }
    }

    // MARK: Team membership

    /// Creates the folder layout and team manifest.
    static func prepareTeamFolder(_ folder: URL) throws {
        let fileManager = FileManager.default
        let data = folder.appendingPathComponent(TeamFiles.dataFolder)
        for directory in [data.appendingPathComponent("meetings"), data.appendingPathComponent("members"), data.appendingPathComponent("deleted"),
                          folder.appendingPathComponent(TeamFiles.meetingsFolder), folder.appendingPathComponent(TeamFiles.notesFolder)] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let manifestURL = data.appendingPathComponent("team.json")
        if !fileManager.fileExists(atPath: manifestURL.path) {
            try TeamCoding.encoder().encode(TeamManifest(name: folder.lastPathComponent, createdAt: Date())).write(to: manifestURL, options: .atomic)
        }
    }

    func createTeam(at folder: URL) throws {
        try Self.prepareTeamFolder(folder)
        connect(folder)
    }

    func join(folder: URL) throws {
        let manifest = folder.appendingPathComponent(TeamFiles.dataFolder).appendingPathComponent("team.json")
        guard FileManager.default.fileExists(atPath: manifest.path) else { throw TeamError.notATeamSpace }
        connect(folder)
    }

    /// Shares the latest edits, disconnects, and removes teammates' items from this Mac. What you shared stays in the team folder.
    func leave() async {
        while syncing { try? await Task.sleep(for: .milliseconds(100)) }
        await syncNow()
        pending?.cancel()
        settings.teamFolderPath = nil
        var removals = Removals()
        for meeting in (try? store.context.fetch(FetchDescriptor<MeetingRecord>())) ?? [] {
            if meeting.isTeamCopy { removals.meetings.append(meeting) } else { meeting.sharedWithTeam = false }
        }
        for note in (try? store.context.fetch(FetchDescriptor<NoteItem>())) ?? [] {
            if note.isTeamCopy { removals.notes.append(note) } else { note.sharedWithTeam = false }
        }
        for binder in store.binders(includeArchived: true) where !binder.isTeamCopy { binder.sharedWithTeam = false }
        store.save()
        await perform(removals)
        for binder in store.binders(includeArchived: true) where binder.isTeamCopy { store.context.delete(binder) }
        store.save()
        state = TeamSyncState()
        localCache = [:]
        remoteCache = [:]
        saveState()
        status = Status()
    }

    /// Sharing is decided per binder: everything in it syncs, and whatever lands in it later is shared too.
    func setShared(_ binder: BinderRecord, _ shared: Bool) {
        guard !binder.isTeamCopy else { return }
        binder.sharedWithTeam = shared
        binder.updatedAt = Date()
        let binderID = binder.id
        for meeting in (try? store.context.fetch(FetchDescriptor<MeetingRecord>(predicate: #Predicate { $0.binderID == binderID }))) ?? []
            where !meeting.isTeamCopy { meeting.sharedWithTeam = shared }
        for note in (try? store.context.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.binderID == binderID }))) ?? []
            where !note.isTeamCopy { note.sharedWithTeam = shared }
        store.save()
        scheduleSync(after: 0.5)
    }

    func setShared(_ meeting: MeetingRecord, _ shared: Bool) {
        guard !meeting.isTeamCopy else { return }
        meeting.sharedWithTeam = shared
        store.save()
        scheduleSync(after: 0.5)
    }

    func setShared(_ note: NoteItem, _ shared: Bool) {
        guard !note.isTeamCopy else { return }
        note.sharedWithTeam = shared
        store.save()
        scheduleSync(after: 0.5)
    }

    private func connect(_ folder: URL) {
        settings.teamFolderPath = folder.path
        state = TeamSyncState()
        remoteCache = [:]
        saveState()
        status = Status()
        scheduleSync(after: 0)
    }

    // MARK: Sync

    func syncNow() async {
        guard let folder = folderURL else { return }
        guard !syncing else {
            resyncRequested = true
            return
        }
        guard !store.isFallback else {
            status.error = "Team sync is paused because the Binders database couldn't be opened."
            return
        }
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: folder.appendingPathComponent(TeamFiles.dataFolder).appendingPathComponent("team.json").path) else {
            status.error = fileManager.fileExists(atPath: folder.path)
                ? "Waiting for the team folder to finish syncing to this Mac."
                : TeamError.folderMissing(folder.path).localizedDescription
            return
        }
        syncing = true
        writeError = nil
        defer {
            syncing = false
            if resyncRequested {
                resyncRequested = false
                scheduleSync(after: 3)
            }
        }

        var notePathIDs: [String: String] = [:]
        for (id, entry) in state.notes {
            if let path = entry.path { notePathIDs[path] = id }
        }
        let request = ScanRequest(folder: folder, meetingCache: remoteCache, notePathIDs: notePathIDs,
                                  indexMeetingMarkdown: needsMeetingMarkdownIndex(), idAssignmentAge: idAssignmentAge)
        let scan = await Task.detached(priority: .utility) { TeamSyncService.scan(request) }.value
        guard folderURL == folder else { return }
        remoteCache = scan.meetingCache

        lastAnnouncements = []
        var removals = Removals()
        var changed = syncMeetings(folder, scan: scan, removals: &removals)
        if scan.notesFolderExists, syncNotes(folder, scan: scan, removals: &removals) { changed = true }
        syncBinders(folder, scan: scan)
        if changed { store.save() }
        await perform(removals)

        var members = scan.members
        if !members.contains(where: { $0.id == me.id && $0.name == me.name && Date().timeIntervalSince($0.lastSeen) < 6 * 3600 }) {
            let member = publishMember(folder)
            members.removeAll { $0.id == member.id }
            members.append(member)
        }
        saveState()

        var next = status
        next.members = members.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        next.teamName = scan.manifest?.name ?? folder.lastPathComponent
        next.lastSync = Date()
        next.error = writeError
        status = next
        updateCounts()
        if let first = lastAnnouncements.first {
            flowBar?.toast(lastAnnouncements.count == 1 ? first : "\(first) and \(lastAnnouncements.count - 1) more", symbol: "person.2", duration: 4)
        }
    }

    private func syncMeetings(_ folder: URL, scan: FolderScan, removals: inout Removals) -> Bool {
        let all = (try? store.context.fetch(FetchDescriptor<MeetingRecord>())) ?? []
        var records: [String: MeetingRecord] = [:]
        for record in all { records[record.id.uuidString] = record }
        var remote = scan.meetings
        var changed = false

        // Your meetings. Only you edit them, so this Mac's version is always the one written.
        for (id, record) in records where !record.isTeamCopy {
            let entry = state.meetings[id]
            let remoteItem = remote.removeValue(forKey: id)
            guard record.sharedWithTeam else {
                if entry != nil { unshareMeeting(folder, id: id, entry: entry) }
                continue
            }
            guard record.status == "ready" || record.status == "failed" else { continue }
            let local = localVersion(record)
            let markdownPath = entry?.path ?? scan.meetingMarkdownPaths[id]
            let stillDownloading = remoteItem == nil && scan.pendingMeetingIDs.contains(id) && entry?.hash == local.hash
            if let markdownPath, remoteItem?.hash == local.hash || stillDownloading {
                state.meetings[id] = .init(hash: local.hash, path: markdownPath)
            } else {
                writeMeeting(folder, local.file, markdownPath: markdownPath)
            }
        }

        // Shared meetings deleted on this Mac. An empty store never unshares several at once.
        let deletedHere = state.meetings.keys.filter { records[$0] == nil }
        if !(all.isEmpty && deletedHere.count > 1) {
            for id in deletedHere {
                if let item = remote[id], item.file.author.id == me.id {
                    remote[id] = nil
                    unshareMeeting(folder, id: id, entry: state.meetings[id])
                } else if remote[id] == nil, !scan.pendingMeetingIDs.contains(id) {
                    state.meetings[id] = nil
                }
            }
        }

        // Teammates' meetings.
        for (id, item) in remote {
            if let record = records[id] {
                guard record.isTeamCopy, state.meetings[id]?.hash != item.hash else { continue }
                apply(item.file, to: record)
            } else {
                // A copy still syncing after its author stopped sharing it.
                if let tombstone = scan.tombstones[id], tombstone.deletedAt > item.file.updatedAt { continue }
                let record = MeetingRecord(title: item.file.title, appName: item.file.appName, templateID: item.file.templateID)
                record.id = UUID(uuidString: id) ?? UUID()
                record.isTeamCopy = item.file.author.id != me.id
                record.sharedWithTeam = true
                store.context.insert(record)
                apply(item.file, to: record)
                if record.isTeamCopy { lastAnnouncements.append("\(item.file.author.name) shared “\(item.file.title)”") }
            }
            state.meetings[id] = .init(hash: item.hash, path: nil)
            changed = true
        }

        // Teammates' meetings their author stopped sharing or deleted.
        for (id, record) in records where record.isTeamCopy && remote[id] == nil && scan.tombstones[id] != nil {
            removals.meetings.append(record)
            state.meetings[id] = nil
        }
        return changed
    }

    private func syncNotes(_ folder: URL, scan: FolderScan, removals: inout Removals) -> Bool {
        let all = (try? store.context.fetch(FetchDescriptor<NoteItem>())) ?? []
        var notes: [String: NoteItem] = [:]
        for note in all { notes[note.id.uuidString] = note }
        var remote = scan.notes
        // When files can't be read or the folder looks emptied, a missing file isn't evidence of a deletion.
        let trustsMissing = scan.unreadableNotePaths.isEmpty && !(scan.notes.isEmpty && !state.notes.isEmpty)
        var changed = false

        for (id, note) in notes {
            let entry = state.notes[id]
            let remoteItem = remote.removeValue(forKey: id)
            let tombstone = scan.tombstones[id]

            // Stopped sharing on this Mac.
            if !note.sharedWithTeam && !note.isTeamCopy {
                guard let entry else { continue }
                if let remoteItem {
                    let remoteHash = TeamFiles.noteHash(remoteItem.note.body)
                    let localHash = TeamFiles.noteHash(note.text)
                    if remoteHash != entry.hash, remoteHash != localHash {
                        // A teammate edited it after this Mac last synced: keep their text too.
                        if localHash == entry.hash {
                            note.text = remoteItem.note.body
                        } else {
                            store.context.insert(NoteItem(text: remoteItem.note.body))
                        }
                        changed = true
                    }
                    removeFile(remoteItem.url, ifItBelongsTo: id)
                    writeTombstone(folder, id: id)
                    state.notes[id] = nil
                } else if trustsMissing {
                    writeTombstone(folder, id: id)
                    state.notes[id] = nil
                }
                continue
            }

            guard let remoteItem else {
                if let entry {
                    if let path = entry.path, scan.unreadableNotePaths.contains(path) { continue }
                    if tombstone == nil {
                        guard trustsMissing else { continue }
                        let since = entry.missingSince ?? Date()
                        state.notes[id]?.missingSince = since
                        guard Date().timeIntervalSince(since) >= deletionGrace else { continue }
                    }
                    if note.isTeamCopy {
                        if TeamFiles.noteHash(note.text) != entry.hash {
                            makePrivate(note)
                            lastAnnouncements.append("“\(note.title)” was removed from the team space; your unsynced edits were kept as a private note")
                            changed = true
                        } else {
                            removals.notes.append(note)
                        }
                        state.notes[id] = nil
                    } else if let tombstone, tombstone.deletedBy.id != me.id {
                        note.sharedWithTeam = false
                        state.notes[id] = nil
                        lastAnnouncements.append("\(tombstone.deletedBy.name) removed “\(note.title)” from the team space; it's still on this Mac")
                        changed = true
                    } else {
                        // Your note vanished from the folder without anyone deleting it: put it back.
                        writeNote(folder, note: note, existing: nil)
                    }
                } else if let tombstone, tombstone.deletedBy.id != me.id, note.isTeamCopy || tombstone.deletedAt > note.updatedAt {
                    // Deleted from the team before this Mac tracked it (e.g. its sync state was lost).
                    if note.isTeamCopy {
                        removals.notes.append(note)
                    } else {
                        note.sharedWithTeam = false
                        changed = true
                    }
                } else if note.isTeamCopy {
                    // A teammate's note this Mac has no record of and can't find: keep it, privately.
                    if trustsMissing {
                        makePrivate(note)
                        changed = true
                    }
                } else if !note.text.trimmed.isEmpty {
                    writeNote(folder, note: note, existing: nil)
                }
                continue
            }

            let localHash = TeamFiles.noteHash(note.text)
            let remoteHash = TeamFiles.noteHash(remoteItem.note.body)
            switch SyncDecision.decide(local: localHash, remote: remoteHash, lastSynced: entry?.hash) {
            case .upToDate:
                state.notes[id] = .init(hash: localHash, path: remoteItem.path)
                if note.isTeamCopy { changed = fileBinder(of: note, from: remoteItem) || changed }
            case .pushLocal:
                writeNote(folder, note: note, existing: remoteItem)
            case .pullRemote:
                note.text = remoteItem.note.body
                note.updatedAt = remoteItem.note.updatedAt ?? Date()
                state.notes[id] = .init(hash: remoteHash, path: remoteItem.path)
                if note.isTeamCopy { _ = fileBinder(of: note, from: remoteItem) }
                changed = true
            case .conflict:
                // Keep the team's version and save this Mac's edit as a private note so nothing is lost.
                store.context.insert(NoteItem(text: note.text))
                note.text = remoteItem.note.body
                note.updatedAt = remoteItem.note.updatedAt ?? Date()
                state.notes[id] = .init(hash: remoteHash, path: remoteItem.path)
                let editor = remoteItem.note.editedBy ?? remoteItem.note.author?.name ?? "a teammate"
                lastAnnouncements.append("“\(note.title)” was also edited by \(editor); your version was saved as a private note")
                changed = true
            }
        }

        // Shared notes deleted on this Mac are deleted for the team, unless someone edited them since.
        let deletedHere = state.notes.keys.filter { notes[$0] == nil }
        if !(all.isEmpty && deletedHere.count > 1) {
            for id in deletedHere {
                guard let entry = state.notes[id] else { continue }
                if let remoteItem = remote[id] {
                    if TeamFiles.noteHash(remoteItem.note.body) == entry.hash {
                        remote[id] = nil
                        removeFile(remoteItem.url, ifItBelongsTo: id)
                        writeTombstone(folder, id: id)
                    } else {
                        let editor = remoteItem.note.editedBy ?? remoteItem.note.author?.name ?? "A teammate"
                        let title = remoteItem.note.body.split(separator: "\n").first.map { String($0.prefix(60)) } ?? "a note"
                        lastAnnouncements.append("\(editor) edited “\(title)” after you deleted it, so it stays in the team space")
                    }
                    state.notes[id] = nil
                } else if let path = entry.path, scan.unreadableNotePaths.contains(path) {
                    continue
                } else {
                    state.notes[id] = nil
                }
            }
        }

        // New notes from teammates.
        for (id, item) in remote {
            if let tombstone = scan.tombstones[id] {
                // A copy still syncing right after it was deleted. A file that's back later was restored on purpose.
                if Date().timeIntervalSince(tombstone.deletedAt) < 600, item.modified <= tombstone.deletedAt { continue }
                removeTombstone(folder, id: id)
            }
            let note = NoteItem(text: item.note.body)
            note.id = UUID(uuidString: id) ?? UUID()
            let mine = item.note.author?.id == me.id
            note.isTeamCopy = !mine
            note.sharedWithTeam = true
            note.teamAuthorID = item.note.author?.id
            note.teamAuthorName = item.note.author?.name
            note.createdAt = item.note.createdAt ?? item.modified
            note.updatedAt = item.note.updatedAt ?? item.modified
            note.binderID = binderForRemote(id: item.note.binderID, name: item.note.binderName,
                                            author: item.note.author ?? TeamAuthor(id: "", name: "Team"), mine: mine)
            store.context.insert(note)
            state.notes[id] = .init(hash: TeamFiles.noteHash(item.note.body), path: item.path)
            if !mine { lastAnnouncements.append("\(item.note.author?.name ?? "A teammate") shared the note “\(note.title)”") }
            changed = true
        }
        return changed
    }

    /// Lets views showing these items move away, then deletes them.
    private func perform(_ removals: Removals) async {
        guard !removals.isEmpty else { return }
        let ids = Set(removals.meetings.map(\.id) + removals.notes.map(\.id))
        NotificationCenter.default.post(name: Self.itemsWillBeRemoved, object: self, userInfo: ["ids": ids])
        if store === Store.shared {
            removals.notes.forEach { ScratchpadController.shared.noteWillBeDeleted($0) }
        }
        try? await Task.sleep(for: .milliseconds(250))
        for meeting in removals.meetings where meeting.modelContext != nil && !meeting.isDeleted {
            store.deleteMeeting(meeting)
        }
        for note in removals.notes where note.modelContext != nil && !note.isDeleted {
            store.context.delete(note)
        }
        store.save()
    }

    // MARK: Folder scan (off the main thread)

    nonisolated private static func scan(_ request: ScanRequest) -> FolderScan {
        let fileManager = FileManager.default
        let folder = request.folder
        let data = folder.appendingPathComponent(TeamFiles.dataFolder)
        var result = FolderScan()

        // Meetings: only `<id>.json`, so sync-provider conflict copies are ignored.
        let meetingKeys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey, .ubiquitousItemDownloadingStatusKey]
        for url in listing(data.appendingPathComponent("meetings"), keys: meetingKeys) {
            if let real = placeholderTarget(url) {
                result.pendingMeetingIDs.insert(real.deletingPathExtension().lastPathComponent)
                continue
            }
            let id = url.deletingPathExtension().lastPathComponent
            guard url.pathExtension == "json", UUID(uuidString: id) != nil else { continue }
            let values = try? url.resourceValues(forKeys: meetingKeys)
            guard isDownloaded(values) else {
                try? fileManager.startDownloadingUbiquitousItem(at: url)
                result.pendingMeetingIDs.insert(id)
                continue
            }
            let modified = values?.contentModificationDate ?? .distantPast
            let size = values?.fileSize ?? -1
            if let cached = request.meetingCache[url.path], cached.modified == modified, cached.size == size {
                result.meetings[id] = cached
                result.meetingCache[url.path] = cached
                continue
            }
            guard let raw = try? Data(contentsOf: url), let file = try? TeamCoding.decoder().decode(TeamMeetingFile.self, from: raw),
                  file.id == id else {
                result.pendingMeetingIDs.insert(id)
                continue
            }
            let meeting = RemoteMeeting(modified: modified, size: size, file: file, hash: TeamFiles.contentHash(file))
            result.meetings[id] = meeting
            result.meetingCache[url.path] = meeting
        }

        for url in listing(data.appendingPathComponent("deleted"), keys: []) where url.pathExtension == "json" {
            guard let raw = try? Data(contentsOf: url), let tombstone = try? TeamCoding.decoder().decode(TeamTombstone.self, from: raw) else { continue }
            if Date().timeIntervalSince(tombstone.deletedAt) > 60 * 86_400 {
                try? fileManager.removeItem(at: url)
            } else {
                result.tombstones[tombstone.id] = tombstone
            }
        }
        let bindersFolder = data.appendingPathComponent("binders")
        var bindersIsDirectory: ObjCBool = false
        result.bindersFolderExists = fileManager.fileExists(atPath: bindersFolder.path, isDirectory: &bindersIsDirectory) && bindersIsDirectory.boolValue
        for url in listing(bindersFolder, keys: []) where url.pathExtension == "json" {
            if let raw = try? Data(contentsOf: url), let file = try? TeamCoding.decoder().decode(TeamBinderFile.self, from: raw) {
                result.binders[file.id] = file
            }
        }
        for url in listing(data.appendingPathComponent("members"), keys: []) where url.pathExtension == "json" {
            if let raw = try? Data(contentsOf: url), let member = try? TeamCoding.decoder().decode(TeamMember.self, from: raw) {
                result.members.append(member)
            }
        }
        result.manifest = (try? Data(contentsOf: data.appendingPathComponent("team.json")))
            .flatMap { try? TeamCoding.decoder().decode(TeamManifest.self, from: $0) }

        if request.indexMeetingMarkdown {
            for url in listing(folder.appendingPathComponent(TeamFiles.meetingsFolder), keys: []) where url.pathExtension == "md" {
                guard let text = try? String(contentsOf: url, encoding: .utf8), let id = Frontmatter.parse(text).fields["binders_id"] else { continue }
                let path = relative(url, to: folder)
                if let existing = result.meetingMarkdownPaths[id], existing.count <= path.count { continue }
                result.meetingMarkdownPaths[id] = path
            }
        }

        let notesURL = folder.appendingPathComponent(TeamFiles.notesFolder)
        var isDirectory: ObjCBool = false
        result.notesFolderExists = fileManager.fileExists(atPath: notesURL.path, isDirectory: &isDirectory) && isDirectory.boolValue
        guard result.notesFolderExists else { return result }

        let noteKeys: Set<URLResourceKey> = [.contentModificationDateKey, .ubiquitousItemDownloadingStatusKey, .isDirectoryKey]
        var candidates: [RemoteNote] = []
        let enumerator = fileManager.enumerator(at: notesURL, includingPropertiesForKeys: Array(noteKeys))
        while let url = enumerator?.nextObject() as? URL {
            let values = try? url.resourceValues(forKeys: noteKeys)
            if url.lastPathComponent.hasPrefix(".") {
                if values?.isDirectory == true {
                    enumerator?.skipDescendants()
                } else if let real = placeholderTarget(url), real.pathExtension.lowercased() == "md" {
                    try? fileManager.startDownloadingUbiquitousItem(at: real)
                    result.unreadableNotePaths.insert(relative(real, to: folder))
                }
                continue
            }
            guard values?.isDirectory != true, url.pathExtension.lowercased() == "md" else { continue }
            let path = relative(url, to: folder)
            guard isDownloaded(values), let text = try? String(contentsOf: url, encoding: .utf8) else {
                try? fileManager.startDownloadingUbiquitousItem(at: url)
                result.unreadableNotePaths.insert(path)
                continue
            }
            let modified = values?.contentModificationDate ?? .distantPast
            var note = TeamFiles.parseNote(text)
            if note.id == nil {
                // Added outside Binders, e.g. in Obsidian. Once it has settled, add an id every Mac derives the same way.
                let knownID = request.notePathIDs[path]
                let id = knownID ?? TeamFiles.stableID(forPath: path)
                let settled = Date().timeIntervalSince(modified) >= request.idAssignmentAge
                let unchanged = ((try? fileManager.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date)
                    .map { abs($0.timeIntervalSince(modified)) < 0.001 } ?? false
                guard settled, unchanged, !text.trimmed.isEmpty,
                      (try? Frontmatter.setting("binders_id", to: id, in: text).write(to: url, atomically: true, encoding: .utf8)) != nil else {
                    if knownID != nil { result.unreadableNotePaths.insert(path) }
                    continue
                }
                note.id = id
            }
            candidates.append(RemoteNote(url: url, path: path, note: note, modified: modified))
        }

        // Sync-provider conflict copies share an id: keep the file this Mac tracks (or the shortest name); each other copy becomes its own note.
        var trackedPaths: [String: String] = [:]
        for (path, id) in request.notePathIDs { trackedPaths[id] = path }
        for (id, group) in Dictionary(grouping: candidates, by: { $0.note.id ?? "" }) {
            let ordered = group.sorted { lhs, rhs in
                let lhsTracked = lhs.path == trackedPaths[id]
                let rhsTracked = rhs.path == trackedPaths[id]
                if lhsTracked != rhsTracked { return lhsTracked }
                return lhs.path.count != rhs.path.count ? lhs.path.count < rhs.path.count : lhs.path < rhs.path
            }
            result.notes[id] = ordered[0]
            for copy in ordered.dropFirst() {
                let copyID = TeamFiles.stableID(forPath: copy.path)
                guard result.notes[copyID] == nil, let text = try? String(contentsOf: copy.url, encoding: .utf8),
                      (try? Frontmatter.setting("binders_id", to: copyID, in: text).write(to: copy.url, atomically: true, encoding: .utf8)) != nil else {
                    result.unreadableNotePaths.insert(copy.path)
                    continue
                }
                var note = copy.note
                note.id = copyID
                result.notes[copyID] = RemoteNote(url: copy.url, path: copy.path, note: note, modified: copy.modified)
            }
        }
        return result
    }

    nonisolated private static func listing(_ directory: URL, keys: Set<URLResourceKey>) -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys))) ?? []
        for url in urls {
            if let real = placeholderTarget(url) { try? FileManager.default.startDownloadingUbiquitousItem(at: real) }
        }
        return urls
    }

    /// The real file behind an iCloud Drive placeholder (`.name.icloud`).
    nonisolated private static func placeholderTarget(_ url: URL) -> URL? {
        let name = url.lastPathComponent
        guard name.hasPrefix("."), name.hasSuffix(".icloud"), name.count > ".icloud".count + 1 else { return nil }
        return url.deletingLastPathComponent().appendingPathComponent(String(name.dropFirst().dropLast(".icloud".count)))
    }

    /// Online-only files (OneDrive, Dropbox, Google Drive, iCloud) are skipped until downloaded, instead of blocking on them.
    nonisolated private static func isDownloaded(_ values: URLResourceValues?) -> Bool {
        guard let status = values?.ubiquitousItemDownloadingStatus else { return true }
        return status == .current || status == .downloaded
    }

    nonisolated private static func relative(_ url: URL, to folder: URL) -> String {
        let base = folder.resolvingSymlinksInPath().path + "/"
        let path = url.resolvingSymlinksInPath().path
        return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : url.lastPathComponent
    }

    // MARK: Meetings

    private func needsMeetingMarkdownIndex() -> Bool {
        let meetings = (try? store.context.fetch(FetchDescriptor<MeetingRecord>())) ?? []
        return meetings.contains {
            $0.sharedWithTeam && !$0.isTeamCopy && ($0.status == "ready" || $0.status == "failed") && state.meetings[$0.id.uuidString]?.path == nil
        }
    }

    /// The exchange file for one of your meetings, rebuilt only when something about the meeting changed.
    private func localVersion(_ record: MeetingRecord) -> (file: TeamMeetingFile, hash: String) {
        let meetingID = record.id
        var hasher = Hasher()
        let binder = store.binder(record.binderID)
        for part in [record.title, record.summary, record.userNotes, record.speakerNamesJSON, record.attendees.joined(separator: "\u{1}"),
                     record.appName ?? "", record.templateID, me.id, me.name, binder?.id.uuidString ?? "", binder?.name ?? ""] {
            hasher.combine(part)
        }
        hasher.combine(record.duration)
        hasher.combine(record.createdAt)
        hasher.combine(store.segmentRevisions[meetingID] ?? 0)
        let fingerprint = hasher.finalize()
        let key = meetingID.uuidString
        if let cached = localCache[key], cached.fingerprint == fingerprint { return (cached.file, cached.hash) }

        let file = TeamMeetingFile(id: key, author: me, title: record.title, createdAt: record.createdAt, updatedAt: Date(),
                                   duration: record.duration, appName: record.appName, attendees: record.attendees,
                                   templateID: record.templateID, summary: record.summary, notes: record.userNotes,
                                   speakerNames: record.speakerNames, segments: store.segments(for: meetingID),
                                   binderID: binder?.id.uuidString, binderName: binder?.name)
        let hash = TeamFiles.contentHash(file)
        localCache[key] = (fingerprint, file, hash)
        return (file, hash)
    }

    private func apply(_ file: TeamMeetingFile, to record: MeetingRecord) {
        record.title = file.title
        record.createdAt = file.createdAt
        record.endedAt = file.createdAt.addingTimeInterval(file.duration)
        record.duration = file.duration
        record.appName = file.appName
        record.attendees = file.attendees
        record.templateID = file.templateID
        record.summary = file.summary
        record.userNotes = file.notes
        var names = file.speakerNames
        if record.isTeamCopy {
            record.teamAuthorID = file.author.id
            record.teamAuthorName = file.author.name
            // "You" in a teammate's transcript is the teammate.
            if names[TranscriptSegment.you]?.trimmed.isEmpty ?? true { names[TranscriptSegment.you] = file.author.name }
        }
        record.speakerNames = names
        record.status = "ready"
        record.errorMessage = nil
        record.binderID = binderForRemote(id: file.binderID, name: file.binderName, author: file.author, mine: !record.isTeamCopy)
        store.replaceSegments(for: record.id, with: file.segments)
    }

    /// The local binder a synced item belongs in: the author's binder (kept here as a read-only copy), your own binder
    /// when it's yours, or, for files from before binders existed, one binder per teammate.
    private func binderForRemote(id: String?, name: String?, author: TeamAuthor, mine: Bool) -> UUID {
        if let id, let uuid = UUID(uuidString: id) {
            if let existing = store.binder(uuid) {
                if existing.isTeamCopy, let name, existing.name != name { existing.name = name }
                return uuid
            }
            if mine { return store.defaultBinder().id }
            let binder = BinderRecord(name: name ?? "From \(author.name)", colorIndex: abs(id.hashValue) % BinderRecord.paletteSize)
            binder.id = uuid
            binder.isTeamCopy = true
            binder.sharedWithTeam = true
            binder.teamAuthorID = author.id
            binder.teamAuthorName = author.name
            store.context.insert(binder)
            return uuid
        }
        if mine { return store.defaultBinder().id }
        let authorID = author.id
        if let existing = store.binders(includeArchived: true).first(where: { $0.isTeamCopy && $0.teamAuthorID == authorID && $0.name.hasPrefix("From ") }) {
            return existing.id
        }
        let binder = BinderRecord(name: "From \(author.name)", colorIndex: 5)
        binder.isTeamCopy = true
        binder.sharedWithTeam = true
        binder.teamAuthorID = author.id
        binder.teamAuthorName = author.name
        store.context.insert(binder)
        return binder.id
    }

    /// Writes a card for each of your shared binders, keeps teammates' binders in step with theirs, and drops
    /// teammates' binder copies that are empty and no longer offered.
    private func syncBinders(_ folder: URL, scan: FolderScan) {
        let binders = store.binders(includeArchived: true)
        let cards = dataURL(folder, "binders")
        for binder in binders where !binder.isTeamCopy {
            let id = binder.id.uuidString
            let url = cards.appendingPathComponent("\(id).json")
            if binder.sharedWithTeam {
                let file = TeamBinderFile(id: id, name: binder.name, colorIndex: binder.colorIndex, author: me,
                                          createdAt: binder.createdAt, updatedAt: binder.updatedAt)
                let current = scan.binders[id]
                if current == nil || current!.name != file.name || current!.colorIndex != file.colorIndex {
                    try? ensureDirectory(cards)
                    try? TeamCoding.encoder().encode(file).write(to: url, options: .atomic)
                }
            } else if let current = scan.binders[id], current.author.id == me.id {
                try? FileManager.default.removeItem(at: url)
            }
        }
        for (id, file) in scan.binders where file.author.id != me.id {
            guard let uuid = UUID(uuidString: id) else { continue }
            if let binder = store.binder(uuid) {
                guard binder.isTeamCopy else { continue }
                if binder.name != file.name { binder.name = file.name }
                if binder.colorIndex != file.colorIndex { binder.colorIndex = file.colorIndex }
                binder.teamAuthorName = file.author.name
            } else {
                let binder = BinderRecord(name: file.name, colorIndex: file.colorIndex)
                binder.id = uuid
                binder.isTeamCopy = true
                binder.sharedWithTeam = true
                binder.teamAuthorID = file.author.id
                binder.teamAuthorName = file.author.name
                store.context.insert(binder)
                lastAnnouncements.append("\(file.author.name) shared the binder “\(file.name)”")
            }
        }
        guard scan.bindersFolderExists else { return }
        for binder in binders where binder.isTeamCopy && scan.binders[binder.id.uuidString] == nil {
            let counts = store.counts(in: binder.id)
            if counts.meetings == 0, counts.notes == 0 { store.context.delete(binder) }
        }
    }

    private func writeMeeting(_ folder: URL, _ file: TeamMeetingFile, markdownPath: String?) {
        var file = file
        file.updatedAt = Date()
        do {
            let dataFolder = dataURL(folder, "meetings")
            try ensureDirectory(dataFolder)
            try TeamCoding.encoder().encode(file).write(to: dataFolder.appendingPathComponent("\(file.id).json"), options: .atomic)
            let markdownFolder = folder.appendingPathComponent(TeamFiles.meetingsFolder)
            try ensureDirectory(markdownFolder)
            let markdownURL = uniqueURL(in: markdownFolder, fileName: TeamFiles.safeFileName(file.title, date: file.createdAt),
                                        previousPath: markdownPath, root: folder)
            try TeamFiles.meetingMarkdown(file).write(to: markdownURL, atomically: true, encoding: .utf8)
            let path = Self.relative(markdownURL, to: folder)
            if let markdownPath, markdownPath != path { removeFile(folder.appendingPathComponent(markdownPath), ifItBelongsTo: file.id) }
            state.meetings[file.id] = .init(hash: TeamFiles.contentHash(file), path: path)
            removeTombstone(folder, id: file.id)
        } catch {
            writeError = "Couldn't write “\(file.title)” to the team folder: \(error.localizedDescription)"
        }
    }

    private func unshareMeeting(_ folder: URL, id: String, entry: TeamSyncState.Entry?) {
        try? FileManager.default.removeItem(at: dataURL(folder, "meetings").appendingPathComponent("\(id).json"))
        if let path = entry?.path { removeFile(folder.appendingPathComponent(path), ifItBelongsTo: id) }
        writeTombstone(folder, id: id)
        state.meetings[id] = nil
    }

    // MARK: Notes

    private func writeNote(_ folder: URL, note: NoteItem, existing: RemoteNote?) {
        let fileManager = FileManager.default
        if let existing, let current = (try? fileManager.attributesOfItem(atPath: existing.url.path))?[.modificationDate] as? Date,
           abs(current.timeIntervalSince(existing.modified)) >= 0.001 {
            return  // Changed since it was read (e.g. in Obsidian); the next pass merges it.
        }
        let id = note.id.uuidString
        let author = existing?.note.author
            ?? (note.isTeamCopy ? TeamAuthor(id: note.teamAuthorID ?? "", name: note.teamAuthorName ?? "Team") : me)
        let binder = store.binder(note.binderID)
        let teamNote = TeamNote(id: id, author: author, editedBy: author.id == me.id ? nil : me.name,
                                createdAt: existing?.note.createdAt ?? note.createdAt, updatedAt: Date(), body: note.text,
                                extraFrontmatter: existing?.note.extraFrontmatter ?? [],
                                binderID: binder?.id.uuidString ?? existing?.note.binderID, binderName: binder?.name ?? existing?.note.binderName)
        do {
            let notesFolder = folder.appendingPathComponent(TeamFiles.notesFolder)
            try ensureDirectory(notesFolder)
            let url = existing?.url ?? uniqueURL(in: notesFolder, fileName: TeamFiles.safeFileName(note.title), previousPath: nil, root: folder)
            try TeamFiles.noteMarkdown(teamNote).write(to: url, atomically: true, encoding: .utf8)
            state.notes[id] = .init(hash: TeamFiles.noteHash(note.text), path: Self.relative(url, to: folder))
            removeTombstone(folder, id: id)
        } catch {
            writeError = "Couldn't write “\(note.title)” to the team folder: \(error.localizedDescription)"
        }
    }

    /// Moves a teammate's note into the binder their file names; true when it moved.
    private func fileBinder(of note: NoteItem, from remote: RemoteNote) -> Bool {
        guard let remoteBinder = remote.note.binderID, let uuid = UUID(uuidString: remoteBinder), note.binderID != uuid else { return false }
        note.binderID = binderForRemote(id: remoteBinder, name: remote.note.binderName,
                                        author: remote.note.author ?? TeamAuthor(id: note.teamAuthorID ?? "", name: note.teamAuthorName ?? "Team"), mine: false)
        return true
    }

    private func makePrivate(_ note: NoteItem) {
        note.isTeamCopy = false
        note.sharedWithTeam = false
        note.teamAuthorID = nil
        note.teamAuthorName = nil
    }

    // MARK: Files

    /// Deletes a Markdown file only if it still belongs to that item (it may have been renamed or replaced since).
    private func removeFile(_ url: URL, ifItBelongsTo id: String) {
        guard let text = try? String(contentsOf: url, encoding: .utf8), Frontmatter.parse(text).fields["binders_id"] == id else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private func writeTombstone(_ folder: URL, id: String) {
        let directory = dataURL(folder, "deleted")
        try? ensureDirectory(directory)
        let tombstone = TeamTombstone(id: id, deletedBy: me, deletedAt: Date())
        try? TeamCoding.encoder().encode(tombstone).write(to: directory.appendingPathComponent("\(id).json"), options: .atomic)
    }

    private func removeTombstone(_ folder: URL, id: String) {
        let url = dataURL(folder, "deleted").appendingPathComponent("\(id).json")
        if FileManager.default.fileExists(atPath: url.path) { try? FileManager.default.removeItem(at: url) }
    }

    private func publishMember(_ folder: URL) -> TeamMember {
        let directory = dataURL(folder, "members")
        let member = TeamMember(id: me.id, name: me.name, lastSeen: Date())
        try? ensureDirectory(directory)
        try? TeamCoding.encoder().encode(member).write(to: directory.appendingPathComponent("\(me.id).json"), options: .atomic)
        return member
    }

    /// Folders are created only when something is written, so a Mac that just joined doesn't race the provider's download.
    private func ensureDirectory(_ url: URL) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private func uniqueURL(in directory: URL, fileName: String, previousPath: String?, root: URL) -> URL {
        let base = (fileName as NSString).deletingPathExtension
        var candidate = directory.appendingPathComponent(fileName)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path), Self.relative(candidate, to: root) != previousPath {
            candidate = directory.appendingPathComponent("\(base) \(counter).md")
            counter += 1
        }
        return candidate
    }

    private func dataURL(_ folder: URL, _ subfolder: String) -> URL {
        folder.appendingPathComponent(TeamFiles.dataFolder).appendingPathComponent(subfolder)
    }

    private func updateCounts() {
        let meetings = (try? store.context.fetch(FetchDescriptor<MeetingRecord>())) ?? []
        let notes = (try? store.context.fetch(FetchDescriptor<NoteItem>())) ?? []
        var next = status
        next.sharedMeetings = meetings.filter { $0.sharedWithTeam && !$0.isTeamCopy }.count
        next.teamMeetings = meetings.filter(\.isTeamCopy).count
        next.sharedNotes = notes.filter { $0.sharedWithTeam && !$0.isTeamCopy }.count
        next.teamNotes = notes.filter(\.isTeamCopy).count
        if next != status { status = next }
    }

    private func saveState() {
        do {
            try JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
        } catch {
            Log.app.error("Couldn't save team sync state: \(error.localizedDescription)")
        }
    }
}
