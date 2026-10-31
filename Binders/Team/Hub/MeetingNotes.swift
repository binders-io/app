import Foundation
import BindersKit

/// Send to Binder: a meeting written as an ordinary note in a binder linked to a hub, so the team can read, link and
/// distill it there while the meeting itself stays on this Mac. The note has its title, when, who was there and its
/// summary (with its decisions and action items), and the transcript when asked for; your own notes on it stay here. It's
/// put in the binder here, and HubNotesSync takes it to the hub like any other note. The meeting keeps the note's id:
/// sending it again updates that note, wherever it has been moved, rather than making a second one.
@MainActor
enum MeetingNotes {
    /// Whether Send to Binder puts the transcript in the note.
    static let transcriptKey = "meetingNoteTranscript"

    /// The binders a meeting can go to: linked to a hub, with what was in them sent up.
    static func binders() -> [BinderRecord] {
        Store.shared.binders().filter { !$0.isTeamCopy && HubLinks.place(of: $0)?.uploaded == true }
    }

    /// A meeting of yours, not a capture: what you said to yourself and heard during the day stays on this Mac.
    static func canSend(_ meeting: MeetingRecord) -> Bool { !meeting.isTeamCopy && !meeting.isConversation }

    /// The note it was sent as, while that note is still here.
    static func note(of meeting: MeetingRecord) -> NoteItem? { meeting.sentNoteID.flatMap { Store.shared.note($0) } }

    /// The note was changed since the meeting was last sent, here or by a teammate on the hub: sending again replaces
    /// those changes.
    static func changedSince(_ meeting: MeetingRecord) -> Bool {
        guard let note = note(of: meeting) else { return false }
        return note.text != meeting.sentNoteText
    }

    /// What the note says.
    static func text(of meeting: MeetingRecord, transcript: Bool) -> String {
        MeetingMarkdown.note(title: meeting.title, dateText: meeting.createdAt.formatted(date: .abbreviated, time: .shortened),
                             duration: meeting.duration, appName: meeting.appName, attendees: meeting.attendees,
                             summary: meeting.summary, segments: transcript ? Store.shared.segments(for: meeting.id) : nil,
                             names: meeting.speakerNames)
    }

    /// Sends a meeting: the note it was sent as is updated, or a new one is made at the top of `binder`. The note, or nil
    /// when it couldn't be kept.
    @discardableResult
    static func send(_ meeting: MeetingRecord, to binder: BinderRecord?, transcript: Bool) -> NoteItem? {
        let store = Store.shared
        guard canSend(meeting), store.allowsSave() else { return nil }
        let words = text(of: meeting, transcript: transcript)
        let note: NoteItem
        if let sent = self.note(of: meeting) {
            note = sent
            if note.text != words {
                note.text = words
                note.updatedAt = Date()
            }
        } else {
            guard let binder else { return nil }
            note = NoteItem(text: words)
            note.binderID = binder.id
            note.sharedWithTeam = binder.sharedWithTeam
            store.insert(note)
        }
        meeting.sentNoteID = note.id
        meeting.sentNoteText = words
        store.save()
        return note
    }
}
