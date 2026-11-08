import Foundation
import BindersKit

/// A binder linked to a hub can send each new meeting there as soon as its notes are written, rather than waiting for
/// Send to Hub: the meeting's note goes to the binder's Meetings on the hub, where the hub's brain reads it and its
/// folder's rules (Distill) take it on. Off unless turned on for the binder; captures stay here unless you send them.
@MainActor
enum HubAutoSend {
    static let key = "hubAutoSendMeetings"
    /// Whether what it sends has the meeting's transcript too, word for word: off unless chosen, beside the switch.
    static let transcriptKey = "hubAutoSendTranscripts"

    static func isOn(_ binder: BinderRecord) -> Bool {
        (AppDefaults.store.stringArray(forKey: key) ?? []).contains(binder.id.uuidString)
    }

    static func set(_ binder: BinderRecord, _ on: Bool) {
        var ids = Set(AppDefaults.store.stringArray(forKey: key) ?? [])
        if on { ids.insert(binder.id.uuidString) } else { ids.remove(binder.id.uuidString) }
        AppDefaults.store.set(ids.sorted(), forKey: key)
    }

    /// A meeting's notes were written (or written again): sent to its binder's hub when the binder sends meetings as they
    /// finish, with the transcript only when that's chosen. A note someone changed since it was sent is left as they have it.
    static func meetingFinished(_ meeting: MeetingRecord) {
        guard MeetingNotes.canSend(meeting), let binder = Store.shared.binder(meeting.binderID), isOn(binder),
              HubLinks.place(of: binder)?.uploaded == true, !MeetingNotes.changedSince(meeting) else { return }
        HubSend.sendOne(meeting, to: binder, transcript: AppDefaults.store.bool(forKey: transcriptKey))
    }
}
