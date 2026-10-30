import Foundation
import SwiftData
import BindersKit

/// Send to Binder (MeetingNotes) against a running hub, in a throwaway folder (BINDERS_DATA_DIR): a meeting filed in a
/// binder of its own here is sent to a linked binder and shows on the hub, as the web app reads it, as an ordinary note
/// with its title, date, attendees, summary, decisions and action items; sending it again, with the transcript, updates
/// that note rather than making a second; a teammate's change to it is noticed before it's replaced; a capture isn't
/// sent; a note deleted is made again.
///
/// Run by scripts/hub-sync-test.sh, which starts a hub of its own:
///
///     HUB_SELFTEST=--selftest-meeting-note scripts/hub-sync-test.sh [path to binders-server]
extension SelfTest {
    @MainActor
    static func meetingNoteSelfTest() async -> Int32 {
        guard AppPaths.isDemo else {
            print("ERROR: set BINDERS_DATA_DIR to an empty folder; this test makes binders and links them to a hub")
            return 1
        }
        let env = ProcessInfo.processInfo.environment
        guard let hubAddress = env["BINDERS_TEST_HUB"], let token = env["BINDERS_TEST_HUB_TOKEN"], let cookie = env["BINDERS_TEST_HUB_WEB_COOKIE"]
        else {
            print("ERROR: run it from scripts/hub-sync-test.sh, which starts a hub (BINDERS_TEST_HUB, _TOKEN, _WEB_COOKIE)")
            return 1
        }
        var failures = 0
        func check(_ condition: Bool, _ label: String) {
            print("\(condition ? "PASS" : "FAIL"): \(label)")
            if !condition { failures += 1 }
        }
        func until(_ seconds: Double = 5, _ condition: () -> Bool) async -> Bool {
            let start = Date()
            while Date().timeIntervalSince(start) < seconds {
                if condition() { return true }
                try? await Task.sleep(for: .milliseconds(50))
            }
            return condition()
        }

        let kept = Keychain.read(HubAccount.tokenKey)
        defer { Keychain.write(kept ?? "", for: HubAccount.tokenKey) }
        Keychain.write("", for: HubAccount.tokenKey)

        _ = DictationController()
        let store = Store.shared
        let account = HubAccount.shared
        let links = HubLinks.shared
        let sync = HubNotesSync.shared
        sync.gather = .milliseconds(100)
        sync.retryDelay = { _ in 0.3 }
        account.openPage = { _ in }

        account.signIn(to: hubAddress)
        await account.finish(URL(string: "binders://auth?token=\(token)&state=\(account.pending?.state ?? "")")!)
        check(account.isSignedIn, "signed in as \(account.person?.line ?? account.problem ?? "no one")")
        guard let hub = account.address, let (spaces, current) = try? await links.spaces(),
              let space = spaces.first(where: { $0.id == current }) ?? spaces.first else {
            print("FAIL: the hub's Binders")
            return 1
        }

        // The web app: a teammate's session, in the same Binder.
        func web(_ method: String, _ path: String, _ body: Any? = nil) async -> (Data, Int) {
            var request = URLRequest(url: hub.appendingPathComponent(path))
            request.httpMethod = method
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
            request.setValue("1", forHTTPHeaderField: "x-binders")
            request.setValue(space.id, forHTTPHeaderField: "x-binders-space")
            if let body {
                request.httpBody = try? JSONSerialization.data(withJSONObject: body)
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            guard let (data, response) = try? await URLSession.shared.data(for: request) else { return (Data(), 0) }
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        var hubState = HubSync.State()
        func onHub(_ seconds: Double = 5, _ condition: @escaping (HubSync.State) -> Bool) async -> Bool {
            let start = Date()
            while Date().timeIntervalSince(start) < seconds {
                if let state = HubSync.State(hubState: await web("GET", "api/state").0) { hubState = state }
                if condition(hubState) { return true }
                try? await Task.sleep(for: .milliseconds(100))
            }
            return false
        }

        // A binder linked to a new project on the hub, with a note in it; the meeting is filed in another binder here.
        let stamp = Int(Date().timeIntervalSince1970)
        let team = BinderRecord(name: "Team notes \(stamp)", colorIndex: 2)
        let mine = BinderRecord(name: "My meetings \(stamp)", colorIndex: 4)
        store.insert(team)
        store.insert(mine)
        let first = NoteItem(text: "# Already here\n\nA note of the team's.")
        first.binderID = team.id
        store.insert(first)
        check(await links.link(team, space: space, to: nil), "a binder is linked to a new project in \(space.name)")
        guard let place = HubLinks.place(of: team) else { return 1 }
        check(await until(10) { sync.spaces[place.space]?.connected == true }, "the live feed is open")
        let inProject = { (state: HubSync.State) in state.notes.values.filter { $0.binderId == place.binder } }

        let meeting = MeetingRecord(title: "Pricing review", appName: "Zoom", templateID: MeetingTemplate.general.id)
        meeting.binderID = mine.id
        meeting.status = "ready"
        meeting.duration = 1_800
        meeting.attendees = ["Dana", "Robin"]
        meeting.summary = """
            ## Summary
            We looked at the new prices.
            ## Decisions
            - Keep the free plan
            ## Action items
            - [ ] Dana — write the pricing page
            """
        store.insert(meeting)
        for (index, line) in ["Shall we keep the free plan?", "Yes, keep it."].enumerated() {
            store.context.insert(MeetingSegmentRecord(meetingID: meeting.id, segment: TranscriptSegment(
                channel: index == 0 ? .microphone : .system, start: Double(index * 10), end: Double(index * 10 + 5), text: line)))
        }
        store.save()

        check(MeetingNotes.binders().map(\.id) == [team.id], "only the linked binder is offered")
        check(MeetingNotes.canSend(meeting) && MeetingNotes.note(of: meeting) == nil, "the meeting can be sent, and hasn't been")
        let capture = MeetingRecord(title: "Hallway", appName: nil, templateID: MeetingTemplate.conversation.id)
        capture.kind = MeetingRecord.conversationKind
        check(!MeetingNotes.canSend(capture) && MeetingNotes.send(capture, to: team, transcript: true) == nil, "a capture isn't sent")

        // MARK: Sent

        guard let note = MeetingNotes.send(meeting, to: team, transcript: false) else {
            print("FAIL: the meeting wasn't sent")
            return 1
        }
        let id = HubLink.hubID(note.id)
        check(note.binderID == team.id && meeting.sentNoteID == note.id && meeting.binderID == mine.id,
              "it's a note in the linked binder, the meeting keeps its id and stays where it was")
        let firstWords = ["# Pricing review", "**Attendees:** Dana, Robin", "## Summary", "## Decisions\n- Keep the free plan",
                          "## Action items\n- [ ] Dana — write the pricing page"]
        var arrived = await onHub { state in state.notes[id].map { n in firstWords.allSatisfy { n.text.contains($0) } } ?? false }
        let onWeb = hubState.notes[id]
        check(arrived, "the web app shows it as a note: \(onWeb?.text.debugDescription ?? "none")")
        check(onWeb?.title == "Pricing review" && onWeb?.binderId == place.binder, "titled as the meeting, in the linked project")
        check(onWeb.map { !$0.text.contains("## Transcript") } ?? false, "without the transcript, as asked")
        check(inProject(hubState).count == 2, "the project has the team's note and the meeting's")

        // MARK: Sent again

        meeting.summary = meeting.summary.replacingOccurrences(of: "- Keep the free plan", with: "- Keep the free plan\n- Raise Pro to $12")
        store.save()
        check(!MeetingNotes.changedSince(meeting), "nobody changed the note since")
        let again = MeetingNotes.send(meeting, to: nil, transcript: true)
        check(again?.id == note.id, "sending again updates the same note here")
        arrived = await onHub { state in
            state.notes[id].map { $0.text.contains("- Raise Pro to $12") && $0.text.contains("Shall we keep the free plan?") } ?? false
        }
        check(arrived, "and on the hub, now with the transcript: \(hubState.notes[id]?.text.debugDescription ?? "none")")
        check(inProject(hubState).count == 2, "with no second note: \(inProject(hubState).map(\.title))")

        // MARK: A teammate's change, then deleted

        let onHubText = hubState.notes[id]?.text ?? ""
        let (_, status) = await web("POST", "api/changes", ["client": "web-tab-dana", "changes": [["id": "web-edit-\(stamp)", "change": [
            "type": "note.edit", "id": id, "text": onHubText + "\nDana: and tell sales.", "title": HubSync.title(of: onHubText), "by": "dana-w",
            "at": HubLink.iso(Date())] as [String: Any]]]])
        check(status == 200, "the web app edits the meeting's note")
        check(await until { store.note(note.id)?.text.contains("Dana: and tell sales.") == true }, "the edit comes to the Mac")
        check(MeetingNotes.changedSince(meeting), "and the meeting knows its note changed since it was sent")

        NoteTrash.shared.delete(note, undoManager: nil)
        store.save()
        check(await onHub { $0.notes[id] == nil }, "the note is deleted, here and on the hub")
        check(MeetingNotes.note(of: meeting) == nil, "the meeting no longer has a note")
        let remade = MeetingNotes.send(meeting, to: team, transcript: false)
        check(remade != nil && remade?.id != note.id, "sent again, it's made anew")
        if let remade {
            check(await onHub { $0.notes[HubLink.hubID(remade.id)] != nil }, "and that one's on the hub")
        }

        sync.stopAll()
        print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
        return failures == 0 ? 0 : 1
    }
}
