import Foundation
import Observation
import SwiftData
import BindersKit

/// Deleting a meeting or a capture still asks first, and Undo puts it back as it was: its notes, its transcript and its
/// recording, with the same id, so links and cards still find it. The recording waits in a folder of its own until Binders
/// quits (or, after a crash, until the next launch), then goes for good. One shared with the team doesn't come through
/// here: deleting it removes it for the team too, so that can't be undone (MeetingDeletes).
@MainActor
@Observable
final class MeetingTrash {
    static let shared = MeetingTrash()

    /// A deleted meeting or capture, everything it had.
    struct Entry: Identifiable, Equatable {
        let id: UUID
        let title: String
        let binderID: UUID?
        /// The folder it was in, which Undo puts it back in while that folder is still in its binder.
        let folderID: UUID?
        let createdAt: Date
        let endedAt: Date?
        let duration: Double
        let status: String
        let kind: String
        let routingReason: String?
        let suggestionsJSON: String
        let soloJSON: String
        let appName: String?
        let attendees: [String]
        let userNotes: String
        let summary: String
        let templateID: String
        let speakerNamesJSON: String
        let chatJSON: String
        let micAudioFile: String?
        let systemAudioFile: String?
        let errorMessage: String?
        let sharedWithTeam: Bool
        let teamAuthorName: String?
        let teamAuthorID: String?
        let segments: [TranscriptSegment]
        /// Its recordings, by their names in Meetings, and where each waits for Undo.
        let held: [Held]

        struct Held: Equatable {
            let name: String
            let waiting: URL
        }

        var isConversation: Bool { kind == MeetingRecord.conversationKind }

        init(_ meeting: MeetingRecord, segments: [TranscriptSegment], held: [Held]) {
            id = meeting.id
            title = meeting.title
            binderID = meeting.binderID
            folderID = meeting.folderID
            createdAt = meeting.createdAt
            endedAt = meeting.endedAt
            duration = meeting.duration
            status = meeting.status
            kind = meeting.kind
            routingReason = meeting.routingReason
            suggestionsJSON = meeting.suggestionsJSON
            soloJSON = meeting.soloJSON
            appName = meeting.appName
            attendees = meeting.attendees
            userNotes = meeting.userNotes
            summary = meeting.summary
            templateID = meeting.templateID
            speakerNamesJSON = meeting.speakerNamesJSON
            chatJSON = meeting.chatJSON
            micAudioFile = meeting.micAudioFile
            systemAudioFile = meeting.systemAudioFile
            errorMessage = meeting.errorMessage
            sharedWithTeam = meeting.sharedWithTeam
            teamAuthorName = meeting.teamAuthorName
            teamAuthorID = meeting.teamAuthorID
            self.segments = segments
            self.held = held
        }
    }

    /// The ones just deleted together, while their Undo button shows: one, or several deleted at once.
    private(set) var lastDeleted: [Entry] = []
    /// The one just deleted (the last of several), while its Undo button shows.
    var last: Entry? { lastDeleted.last }
    /// The ones Undo just put back, for the list to select.
    private(set) var restoredMeetings: Set<UUID> = []
    @ObservationIgnored private var hiding: Task<Void, Never>?

    /// Where recordings wait for Undo: a folder for each run of Binders, so the next launch knows which to let go.
    static var waitingRoom: URL { AppPaths.support.appendingPathComponent("Deleted recordings", isDirectory: true) }
    private static let thisRun = UUID().uuidString

    /// Several at once: one Undo puts them all back. A teammate's isn't deleted from here.
    func delete(_ meetings: [MeetingRecord], undoManager: UndoManager?) {
        let meetings = meetings.filter { !$0.isTeamCopy }
        guard !meetings.isEmpty else { return }
        let entries = meetings.map { meeting in Entry(meeting, segments: Store.shared.segments(for: meeting.id), held: Self.setAside(meeting)) }
        // Let the page leave the hierarchy before the records go.
        DispatchQueue.main.async { for meeting in meetings where meeting.modelContext != nil { Store.shared.deleteMeeting(meeting) } }
        undoManager?.registerUndo(withTarget: self) { [weak undoManager] trash in trash.restore(entries, undoManager: undoManager) }
        undoManager?.setActionName(Self.actionName(entries))
        lastDeleted = entries
        hiding?.cancel()
        hiding = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled, self?.lastDeleted == entries else { return }
            self?.lastDeleted = []
        }
    }

    /// Puts deleted ones back, with their ids, transcripts and recordings, as one change Undo can take away again.
    @discardableResult
    func restore(_ entries: [Entry], undoManager: UndoManager?) -> [MeetingRecord] {
        if lastDeleted.contains(where: { entry in entries.contains(entry) }) { lastDeleted = [] }
        guard Store.shared.canSave else { return [] }
        var back: [MeetingRecord] = []
        for entry in entries where Store.shared.meeting(entry.id) == nil {
            let record = MeetingRecord(title: entry.title, appName: entry.appName, templateID: entry.templateID)
            record.id = entry.id
            let binder = Store.shared.binder(entry.binderID)
            record.binderID = binder?.id ?? Store.shared.defaultBinder().id
            record.folderID = Store.shared.shownFolder(entry.folderID, in: record.binderID)
            record.createdAt = entry.createdAt
            record.endedAt = entry.endedAt
            record.duration = entry.duration
            record.status = entry.status
            record.kind = entry.kind
            record.routingReason = entry.routingReason
            record.suggestionsJSON = entry.suggestionsJSON
            record.soloJSON = entry.soloJSON
            record.attendees = entry.attendees
            record.userNotes = entry.userNotes
            record.summary = entry.summary
            record.speakerNamesJSON = entry.speakerNamesJSON
            record.chatJSON = entry.chatJSON
            record.micAudioFile = entry.micAudioFile
            record.systemAudioFile = entry.systemAudioFile
            record.errorMessage = entry.errorMessage
            record.teamAuthorName = entry.teamAuthorName
            record.teamAuthorID = entry.teamAuthorID
            // Back in its own binder, shared as it was; one whose binder has gone comes back unshared, in General.
            record.sharedWithTeam = binder != nil && entry.sharedWithTeam
            for held in entry.held {
                let home = AppPaths.meetings.appendingPathComponent(held.name)
                if !FileManager.default.fileExists(atPath: home.path) { try? FileManager.default.moveItem(at: held.waiting, to: home) }
            }
            Store.shared.insert(record)
            if !entry.segments.isEmpty { Store.shared.replaceSegments(for: entry.id, with: entry.segments) }
            back.append(record)
        }
        guard !back.isEmpty else { return [] }
        let ids = back.map(\.id)
        undoManager?.registerUndo(withTarget: self) { [weak undoManager] trash in
            trash.delete(ids.compactMap { Store.shared.meeting($0) }, undoManager: undoManager)
        }
        undoManager?.setActionName(Self.actionName(entries))
        restoredMeetings = Set(ids)
        HubWindowController.shared.controller?.team.scheduleSync(after: 0.5)
        return back
    }

    /// Moves a meeting's recordings (and the backup a mic-track rescue leaves) to wait for Undo.
    private static func setAside(_ meeting: MeetingRecord) -> [Entry.Held] {
        let manager = FileManager.default
        let room = waitingRoom.appendingPathComponent(thisRun, isDirectory: true).appendingPathComponent(meeting.id.uuidString, isDirectory: true)
        var held: [Entry.Held] = []
        for url in meeting.audioURLs where manager.fileExists(atPath: url.path) {
            try? manager.createDirectory(at: room, withIntermediateDirectories: true)
            let waiting = room.appendingPathComponent(url.lastPathComponent)
            if (try? manager.moveItem(at: url, to: waiting)) != nil { held.append(.init(name: url.lastPathComponent, waiting: waiting)) }
        }
        return held
    }

    /// Lets go of the recordings that waited for Undo: at quit, all of them; at launch (`keepingThisRun`), what a run before
    /// this one left, as after a crash.
    static func forgetWaiting(keepingThisRun: Bool) {
        let manager = FileManager.default
        let runs = (try? manager.contentsOfDirectory(at: waitingRoom, includingPropertiesForKeys: nil)) ?? []
        for run in runs where !(keepingThisRun && run.lastPathComponent == thisRun) {
            try? manager.removeItem(at: run)
        }
    }

    private static func actionName(_ entries: [Entry]) -> String {
        let kind = !entries.isEmpty && entries.allSatisfy(\.isConversation) ? "Capture" : "Meeting"
        return entries.count == 1 ? "Delete \(kind)" : "Delete \(kind)s"
    }
}

/// Deleting meetings and captures, each by its own rule as when one is deleted alone: a teammate's is theirs to delete;
/// one still recording, being written up or being asked about waits until that's done; one shared with the team is
/// removed for the team too, which can't be undone; the rest go to MeetingTrash, which Undo empties back.
@MainActor
enum MeetingDeletes {
    /// Why one can't be deleted now; nil when it can.
    static func staysPut(_ meeting: MeetingRecord, service: MeetingService?) -> String? {
        if meeting.isTeamCopy { return "Only \(meeting.teamAuthorName ?? "the author") can delete “\(meeting.title)”." }
        if MeetingMoves.isRecording(meeting) { return "“\(meeting.title)” is still recording." }
        if service?.busyMeetingIDs.contains(meeting.id) == true { return "Binders is still writing the notes for “\(meeting.title)”." }
        if service?.chattingMeetingIDs.contains(meeting.id) == true { return "Binders is still answering a question about “\(meeting.title)”." }
        return nil
    }

    /// Why the ones that can't go now stay, in a line: each one's reason, teammates' together. Nil when all of them can.
    static func whyStaying(_ meetings: [MeetingRecord], service: MeetingService?) -> String? {
        let theirs = meetings.filter(\.isTeamCopy)
        var parts: [String] = []
        if theirs.count > 1 {
            parts.append("\(MeetingMoves.titles(theirs)) are teammates' \(theirs.allSatisfy(\.isConversation) ? "captures" : "meetings"): only they can delete them.")
        } else if let one = theirs.first, let why = staysPut(one, service: service) {
            parts.append(why)
        }
        parts += meetings.filter { !$0.isTeamCopy }.compactMap { staysPut($0, service: service) }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// Whether deleting it removes it for the team too: a meeting in a binder shared with the team. Captures stay on this
    /// Mac.
    static func isShared(_ meeting: MeetingRecord, team: TeamSyncService?) -> Bool {
        !meeting.isConversation && team?.isConfigured == true && meeting.sharedWithTeam
    }

    /// What deleting one asks first: "Delete this meeting, its transcript and audio?", and whether the team loses it too.
    static func question(_ meeting: MeetingRecord, team: TeamSyncService?) -> String {
        let shared = isShared(meeting, team: team)
        if meeting.isConversation {
            return shared ? "Delete this capture and its transcript? It's also removed for your team." : "Delete this capture and its transcript?"
        }
        return shared ? "Delete this meeting, its transcript and audio? It's also removed for your team." : "Delete this meeting, its transcript and audio?"
    }

    /// Deletes them: those shared with the team at once, for everyone; the rest to the trash, which one Undo puts back.
    /// Those that can't go now stay, and come back.
    @discardableResult
    static func delete(_ meetings: [MeetingRecord], service: MeetingService?, team: TeamSyncService?, undoManager: UndoManager?) -> [MeetingRecord] {
        let staying = meetings.filter { staysPut($0, service: service) != nil }
        let going = meetings.filter { staysPut($0, service: service) == nil }
        let forTeam = going.filter { isShared($0, team: team) }
        // Let the page leave the hierarchy before the records go.
        if !forTeam.isEmpty { DispatchQueue.main.async { for meeting in forTeam where meeting.modelContext != nil { Store.shared.deleteMeeting(meeting) } } }
        MeetingTrash.shared.delete(going.filter { !isShared($0, team: team) }, undoManager: undoManager)
        return staying
    }
}
