import AppKit
import BindersAutomerge
import Foundation
import SwiftData
import BindersKit

/// Move to a Hub (HubMove), in a throwaway folder (BINDERS_DATA_DIR), with a stand-in team database (a server saved, not
/// connected) and a stand-in hub that keeps changes as binders-server does: a binder made here goes to a new project with
/// its folders, notes and cards; a teammate's binder that the teammate's Mac moved first is joined, with nothing sent
/// again, the hub's words taken, and what was written here that the teammate's Mac never had merged with them rather than
/// lost; a binder that isn't shared stays put. A move cut short keeps this Mac on the team database, and Move Again
/// finishes it. Then this Mac has left the team database, with every binder still here, teammates' notes ordinary notes,
/// and a teammate's meeting still here. Draws Move to a Hub… before and after to `dir`, when one is given.
///
///     BINDERS_DATA_DIR=$(mktemp -d) Binders --selftest-hub-move [dir]
extension SelfTest {
    @MainActor
    static func hubMoveSelfTest(drawingTo directory: URL?) async -> Int32 {
        guard AppPaths.isDemo else {
            print("ERROR: set BINDERS_DATA_DIR to an empty folder; this test makes binders and moves them to a hub")
            return 1
        }
        var failures = 0
        func check(_ condition: Bool, _ label: String) {
            print("\(condition ? "PASS" : "FAIL"): \(label)")
            if !condition { failures += 1 }
        }
        let kept = Keychain.read(HubAccount.tokenKey)
        defer { Keychain.write(kept ?? "", for: HubAccount.tokenKey) }
        Keychain.write("", for: HubAccount.tokenKey)

        let controller = DictationController()
        let store = Store.shared
        let account = HubAccount.shared
        let links = HubLinks.shared
        let move = HubMove.shared
        account.openPage = { _ in }
        // The feeds stay quiet: what's checked is what the move sends and keeps.
        HubNotesSync.shared.openFeed = { _ in QuietFeed() }
        HubBoard.shared.openLive = { _ in AsyncThrowingStream { _ in } }

        // The stand-in team database: saved on this Mac, never connected.
        let team = controller.teamBoard
        let server = TeamDatabaseServer(host: "db.example.com", database: "team", login: "robin")
        team.folderOverride = AppPaths.support.appendingPathComponent("TeamMoveTest", isDirectory: true)
        team.server = server

        // The stand-in hub: Dana's Mac moved her binder first.
        let theirs = BinderRecord(name: "Dana's Plans", colorIndex: 1)
        let theirProject = HubLink.movedProjectID(theirs.id)
        // Written here and never on the team database when Dana's Mac moved: "Bring cake." Edited on the hub since: ", on the hub".
        let theirNote = NoteItem(text: "# Launch\n\nIn May.\n\nBring cake.")
        // Not changed here since: it takes the hub's words.
        let theirBudget = NoteItem(text: "# Budget\n\nTen.")
        /// The hub's document of each note: begun from the words Dana's Mac sent (at time 0, as binders-server's noteDoc),
        /// then edited on the hub.
        func hubDocument(from start: String, to now: String) -> Data {
            let document = try! NoteDocument(new: UUID(), actor: UUID())
            _ = try! document.change(splices: [NoteDocumentSplice(start: 0, delete: 0, insert: start)], props: [:], at: Date(timeIntervalSince1970: 0))
            _ = try! document.change(splices: TextEdits.splices(from: start, to: now).map { NoteDocumentSplice(start: $0.start, delete: $0.delete, insert: $0.insert) },
                                     props: [:])
            return document.save()
        }
        let documents = [
            "/api/notes/\(HubLink.hubID(theirNote.id))/doc": hubDocument(from: "# Launch\n\nIn May.", to: "# Launch\n\nIn May, on the hub."),
            "/api/notes/\(HubLink.hubID(theirBudget.id))/doc": hubDocument(from: "# Budget\n\nTen.", to: "# Budget\n\nTwelve."),
        ]
        var states: [String: [String: [[String: Any]]]] = [
            "team": ["binders": [["id": theirProject, "name": "Dana's Plans"]],
                     "notes": [["id": HubLink.hubID(theirNote.id), "binderId": theirProject, "title": "Launch", "editedAt": "2026-10-29T09:00:00.000Z",
                               "editors": ["dana"], "text": "# Launch\n\nIn May, on the hub."],
                              ["id": HubLink.hubID(theirBudget.id), "binderId": theirProject, "title": "Budget", "editedAt": "2026-10-29T09:00:00.000Z",
                               "editors": ["dana"], "text": "# Budget\n\nTwelve."]]],
        ]
        var log: Set<String> = []
        var failNextChanges = false
        account.send = { request in
            let path = request.url?.path ?? ""
            let method = request.httpMethod ?? "GET"
            let space = request.value(forHTTPHeaderField: "x-binders-space") ?? "team"
            func answer(_ status: Int, _ json: Any) -> (Data, URLResponse) {
                (try! JSONSerialization.data(withJSONObject: json), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
            }
            guard request.value(forHTTPHeaderField: "Authorization") == "Bearer bnp_robin00001" else { return answer(401, ["error": "Sign in again."]) }
            switch (method, path) {
            case ("GET", "/api/me"):
                return answer(200, ["user": ["login": "robin-h", "name": "Robin Hale"], "space": "team",
                                    "spaces": [["id": "team", "name": "Team", "role": "owner"]]])
            case ("GET", "/api/state"):
                let state = states[space] ?? [:]
                return answer(200, ["version": log.count, "state": ["binders": state["binders"] ?? [], "folders": state["folders"] ?? [],
                                                                      "notes": state["notes"] ?? [], "cards": state["cards"] ?? [], "agents": []]])
            case ("GET", _) where documents[path] != nil:
                return (documents[path]!, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            case ("POST", "/api/changes"):
                if failNextChanges {
                    failNextChanges = false
                    return answer(503, ["error": "The hub is restarting."])
                }
                guard let body = request.httpBody.flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }),
                      let client = body["client"] as? String, let changes = body["changes"] as? [[String: Any]] else { return answer(400, ["error": "?"]) }
                var versions: [Int] = []
                for outgoing in changes {
                    guard let id = outgoing["id"] as? String, let change = outgoing["change"] as? [String: Any], let type = change["type"] as? String else { continue }
                    guard log.insert("\(space):\(client):\(id)").inserted else {
                        versions.append(0)
                        continue
                    }
                    let (list, key) = switch type {
                    case "binder.put": ("binders", "binder")
                    case "folder.put": ("folders", "folder")
                    case "note.put": ("notes", "note")
                    case "card.put": ("cards", "card")
                    default: ("other", "")
                    }
                    guard let item = change[key] as? [String: Any], let itemID = item["id"] as? String else { continue }
                    var items = states[space]?[list] ?? []
                    items.removeAll { $0["id"] as? String == itemID }
                    items.append(item)
                    states[space, default: [:]][list] = items
                    versions.append(log.count)
                }
                return answer(200, ["versions": versions, "version": log.count])
            default:
                return answer(404, ["error": "Not here."])
            }
        }
        func until(_ seconds: Double = 3, _ condition: () -> Bool) async {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end, !condition() { try? await Task.sleep(for: .milliseconds(25)) }
        }
        func onHub(_ list: String, in project: String) -> [[String: Any]] {
            (states["team"]?[list] ?? []).filter { $0["binderId"] as? String == project }
        }

        // MARK: This Mac on the team database.
        let garden = BinderRecord(name: "Garden", colorIndex: 2)
        garden.teamDatabaseKey = server.key
        store.insert(garden)
        theirs.teamDatabaseKey = server.key
        theirs.teamMadeBy = "Dana"
        store.insert(theirs)
        let solo = BinderRecord(name: "Mine Alone", colorIndex: 3)
        store.insert(solo)
        let plans = store.createFolder(named: "Plans", in: garden.id)!
        let mine = NoteItem(text: "# Tomatoes\n\nStake them in May.")
        mine.binderID = garden.id
        mine.folderID = plans.id
        let danas = NoteItem(text: "# Beans\n\nDana's.")
        danas.binderID = garden.id
        danas.isTeamCopy = true
        danas.teamAuthorName = "Dana"
        theirNote.binderID = theirs.id
        theirNote.isTeamCopy = true
        theirNote.teamAuthorName = "Dana"
        theirBudget.binderID = theirs.id
        theirBudget.isTeamCopy = true
        theirBudget.teamAuthorName = "Dana"
        let alone = NoteItem(text: "# Diary\n\nJust mine.")
        alone.binderID = solo.id
        for note in [mine, danas, theirNote, theirBudget, alone] { store.insert(note) }
        let stakes = TaskCard(title: "Buy stakes", binderID: garden.id, column: .ready)
        stakes.teamShadow = "{}"
        store.insert(stakes)
        let meeting = MeetingRecord(title: "Dana's standup", appName: nil, templateID: "")
        meeting.binderID = garden.id
        meeting.isTeamCopy = true
        meeting.teamAuthorName = "Dana"
        store.insert(meeting)
        store.save()

        check(Set(move.binders(team).map(\.name)) == ["Garden", "Dana's Plans"], "the move takes the binders on the team database: \(move.binders(team).map(\.name))")
        check(links.whyNot(garden)?.hasPrefix("This binder is shared with your team already.") == true && links.whyNot(garden, moving: true) == "Sign in to a hub in Settings → Team first.",
              "Link to Hub… still refuses a binder on the team database; only Move takes it, once signed in")

        // MARK: Signed out, Move to a Hub… says to sign in.
        let signedOut = await drawnAlone(HubMoveSheet(team: team), controller: controller, name: "hub-move-signed-out",
                                         size: NSSize(width: 540, height: 260), directory: directory)
        check(signedOut["hubMove.signIn"] != nil && signedOut["hubMove.move"] == nil, "signed out, Move to a Hub… says to sign in first: \(signedOut.keys.sorted())")
        account.signIn(to: "hub.example.com")
        await account.finish(URL(string: "binders://auth?token=bnp_robin00001&state=\(account.pending?.state ?? "")")!)
        check(account.isSignedIn, "signed in to the stand-in hub")

        let found = (try? await move.moved(move.binders(team), in: "team")) ?? [:]
        check(found.count == 1 && found[theirs.id]?.id == theirProject, "the hub has the project Dana's Mac made for her binder, found by its id")
        let choosing = await drawnAlone(HubMoveSheet(team: team), controller: controller, name: "hub-move-choosing",
                                        size: NSSize(width: 540, height: 340), directory: directory)
        check(choosing["hubMove.binders"] != nil && choosing["hubMove.move"] != nil, "Move to a Hub… lists the binders and offers Move: \(choosing.keys.sorted())")
        check(choosing["hubMove.caution"] != nil, "and says the team database can't be reached, so what goes is what this Mac has")

        // MARK: Cut short: this Mac stays on the team database.
        failNextChanges = true
        let space = HubLink.Space(id: "team", name: "Team")
        let first = await move.move(team, to: space)
        check(!first && team.server != nil && garden.teamDatabaseKey == server.key, "a move cut short leaves this Mac on the team database")
        check(move.problem?.hasPrefix("“Garden” didn't reach the hub yet.") == true && move.problem?.contains("restarting") == true,
              "and says which binder and why: \(move.problem ?? "")")
        check(HubLinks.place(of: theirs)?.uploaded == true && HubLinks.place(of: theirs)?.binder == theirProject,
              "Dana's binder joined her project anyway")

        // MARK: Move Again.
        let again = await move.move(team, to: space)
        check(again && move.problem == nil, "Move Again finishes it: \(move.done ?? move.problem ?? "")")
        check(move.done == "Moved 1 binder to Team, and joined 1 that a teammate moved first. This Mac left the team database.", "and says what it did: \(move.done ?? "")")
        let gardenProject = HubLinks.place(of: garden)?.binder ?? ""
        check(gardenProject == HubLink.movedProjectID(garden.id) && HubLinks.place(of: garden)?.uploaded == true, "Garden went to its own project, made from its id")
        check((states["team"]?["binders"] ?? []).contains { $0["id"] as? String == gardenProject && $0["name"] as? String == "Garden" },
              "the hub has the project Garden")
        let gardenNotes = Set(onHub("notes", in: gardenProject).compactMap { $0["id"] as? String })
        check(gardenNotes == Set([mine, danas].map { HubLink.hubID($0.id) }), "both its notes, the teammate's too")
        check(onHub("folders", in: gardenProject).count == 1 && onHub("cards", in: gardenProject).count == 1, "its folder and its card")
        check(!log.contains { $0.hasSuffix(":binder-\(theirProject)") || $0.hasSuffix(":note-\(HubLink.hubID(theirNote.id))") }
                && onHub("notes", in: theirProject).count == 2
                && onHub("notes", in: theirProject).contains { $0["text"] as? String == "# Launch\n\nIn May, on the hub." },
              "nothing of Dana's binder went again: the hub's words stay: \(log.filter { $0.contains(theirProject) || $0.contains(HubLink.hubID(theirNote.id)) }) \(onHub("notes", in: theirProject))")
        let bothKept = { (text: String) in text.contains("In May, on the hub.") && text.contains("Bring cake.") }
        _ = await until { store.note(theirBudget.id)?.text == "# Budget\n\nTwelve." }
        check(store.note(theirBudget.id)?.text == "# Budget\n\nTwelve.", "a note not changed here since takes the hub's words: \(store.note(theirBudget.id)?.text.debugDescription ?? "gone")")
        check(bothKept(store.note(theirNote.id)?.text ?? ""),
              "a note written here that Dana's Mac never had keeps those words, with the hub's: \(store.note(theirNote.id)?.text.debugDescription ?? "gone")")
        check((store.note(theirNote.id)?.updatedAt ?? .distantPast) > (HubLinks.place(of: theirs)?.linkedAt ?? .distantFuture),
              "marked changed after the link, so it goes up rather than taking the hub's words")
        check(HubLinks.place(of: solo) == nil && onHub("notes", in: HubLink.movedProjectID(solo.id)).isEmpty, "a binder that wasn't shared stays put")

        // MARK: Off the team database, everything kept.
        check(team.server == nil && TeamBoard.savedServer() == nil && team.sharedBinders.isEmpty, "this Mac left the team database")
        check(store.binder(garden.id) != nil && store.binder(theirs.id) != nil && garden.teamDatabaseKey.isEmpty && theirs.teamDatabaseKey.isEmpty
                && theirs.teamMadeBy.isEmpty, "every binder stays here, Dana's too, off the team database")
        check(store.note(danas.id)?.isTeamCopy == false && store.note(theirNote.id) != nil && store.note(mine.id)?.folderID == plans.id,
              "notes stay where they were, teammates' ordinary notes now, as on the hub")
        check(stakes.teamShadow.isEmpty && controller.board.cards(in: garden.id).count == 1, "the card stays, no longer the team database's")
        check(store.meeting(meeting.id)?.isTeamCopy == true && store.meeting(meeting.id)?.binderID == garden.id, "a teammate's meeting stays on this Mac")

        let movedSheet = await drawnAlone(HubMoveSheet(team: team), controller: controller, name: "hub-move-done",
                                          size: NSSize(width: 540, height: 240), directory: directory)
        check(movedSheet["hubMove.done"] != nil && movedSheet["hubMove.move"] == nil, "Move to a Hub… says what it did: \(movedSheet.keys.sorted())")

        HubNotesSync.shared.stopAll()
        HubBoard.shared.stop()
        print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
        return failures == 0 ? 0 : 1
    }
}

/// A live feed that never says anything.
private final class QuietFeed: HubFeed {
    func next() async throws -> Data {
        try await Task.sleep(for: .seconds(3600))
        throw CancellationError()
    }

    func close() {}
}
