import AppKit
import Foundation
import SwiftData
import BindersKit

/// Linking a binder to a hub (HubLinks), in a throwaway folder (BINDERS_DATA_DIR), with a stand-in hub that keeps changes
/// as binders-server does (one per client and id) and answers /api/me and /api/state: a binder with nested folders, notes
/// and cards links to a new project, and they're all on the hub, a note from what you said to yourself left out; a link
/// cut short is finished by Send Again with nothing put twice, and with what was edited here since as it is now; it waits
/// while this Mac is signed in to another hub with a Binder of the same id, and stops if that happens while it sends;
/// unlinking keeps everything here; a second binder links into a project the hub has already, with no binder.put. Draws Link to Hub… choosing and linked to `dir`, when one is given.
///
/// With BINDERS_TEST_HUB (a hub's address) and BINDERS_TEST_HUB_TOKEN (a bnp_ token there), it links a binder to a new
/// project on that hub for real and reads the hub's state back, as the web app does.
///
///     BINDERS_DATA_DIR=$(mktemp -d) Binders --selftest-hub-link [dir]
extension SelfTest {
    @MainActor
    static func hubLinkSelfTest(drawingTo directory: URL?) async -> Int32 {
        guard AppPaths.isDemo else {
            print("ERROR: set BINDERS_DATA_DIR to an empty folder; this test makes binders and links them to a hub")
            return 1
        }
        var failures = 0
        func check(_ condition: Bool, _ label: String) {
            print("\(condition ? "PASS" : "FAIL"): \(label)")
            if !condition { failures += 1 }
        }
        // The Keychain is this Mac's own: whatever token was there is put back at the end.
        let kept = Keychain.read(HubAccount.tokenKey)
        defer { Keychain.write(kept ?? "", for: HubAccount.tokenKey) }
        Keychain.write("", for: HubAccount.tokenKey)

        let controller = DictationController()
        let store = Store.shared
        let account = HubAccount.shared
        let links = HubLinks.shared
        account.openPage = { _ in }

        // A stand-in hub with two Binders: what's in each, the changes it kept, and every request. Another hub, with a Binder
        // called team too, keeps what reaches it apart.
        var other: [String] = []
        var states: [String: [String: [[String: Any]]]] = ["team": ["binders": [["id": "binder-old", "name": "Roadmap"]]], "lab": [:]]
        var log: Set<String> = []
        var asked: [String] = []
        var failNextChanges = false
        account.send = { request in
            let path = request.url?.path ?? ""
            let method = request.httpMethod ?? "GET"
            let space = request.value(forHTTPHeaderField: "x-binders-space") ?? "team"
            func answer(_ status: Int, _ json: Any) -> (Data, URLResponse) {
                (try! JSONSerialization.data(withJSONObject: json), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
            }
            if request.url?.host == "other.example.com" {
                other.append("\(method) \(path) \(space)")
                guard request.value(forHTTPHeaderField: "Authorization") == "Bearer bnp_robin00002" else { return answer(401, ["error": "Sign in again."]) }
                switch (method, path) {
                case ("GET", "/api/me"):
                    return answer(200, ["user": ["login": "robin-h", "name": "Robin Hale"], "space": "team", "spaces": [["id": "team", "name": "Team", "role": "owner"]]])
                case ("GET", "/api/state"):
                    return answer(200, ["version": 0, "state": ["binders": [], "folders": [], "notes": [], "cards": [], "agents": []]])
                default:
                    return answer(200, ["versions": [], "version": 0])
                }
            }
            asked.append("\(method) \(path) \(space)")
            guard request.value(forHTTPHeaderField: "Authorization") == "Bearer bnp_robin00001" else { return answer(401, ["error": "Sign in again."]) }
            switch (method, path) {
            case ("GET", "/api/me"):
                return answer(200, ["user": ["login": "robin-h", "name": "Robin Hale"], "space": "team",
                                    "spaces": [["id": "team", "name": "Team", "role": "owner"], ["id": "lab", "name": "Lab", "role": "member"]]])
            case ("GET", "/api/state"):
                let state = states[space] ?? [:]
                return answer(200, ["version": log.count, "state": ["binders": state["binders"] ?? [], "folders": state["folders"] ?? [],
                                                                      "notes": state["notes"] ?? [], "cards": state["cards"] ?? [], "agents": []]])
            case ("POST", "/api/spaces"):
                // A new binder on the hub, its address from its name, with the one binder its notes and board go in.
                guard let body = request.httpBody.flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }),
                      let name = body["name"] as? String else { return answer(422, ["error": "Give the binder a name."]) }
                let id = name.lowercased().replacingOccurrences(of: " ", with: "-")
                states[id, default: [:]]["binders"] = [["id": "main", "name": name]]
                return answer(200, ["spaces": [], "created": ["id": id, "name": name]])
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
                    guard log.insert("\(space):user:robin-h:\(client):\(id)").inserted else {
                        versions.append(0)
                        continue
                    }
                    let (list, key) = switch type {
                    case "binder.put": ("binders", "binder")
                    case "folder.put": ("folders", "folder")
                    case "note.put": ("notes", "note")
                    default: ("cards", "card")
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
        func onHub(_ space: String, _ list: String) -> [[String: Any]] { states[space]?[list] ?? [] }
        func onHub(_ space: String, _ list: String, in project: String) -> [[String: Any]] {
            onHub(space, list).filter { $0["binderId"] as? String == project }
        }

        // MARK: A binder with nested folders, notes and cards.
        let garden = BinderRecord(name: "Garden", colorIndex: 2)
        store.insert(garden)
        let plans = store.createFolder(named: "Plans", in: garden.id)!
        let beds = store.createFolder(named: "Beds", in: garden.id, parent: plans.id)!
        func note(_ text: String, folder: UUID? = nil, private hidden: Bool = false) -> NoteItem {
            let note = NoteItem(text: text)
            note.binderID = garden.id
            note.folderID = folder
            note.staysUnshared = hidden
            store.insert(note)
            return note
        }
        let tomatoes = note("# Tomatoes\n\nStake them in May.", folder: beds.id)
        let ideas = note("# Ideas\n\nA pond.", folder: plans.id)
        let top = note("# Watering\n\nTwice a week.")
        let moment = note("# Said to myself\n\nKeep this here.", private: true)
        let stakes = TaskCard(title: "Buy stakes", binderID: garden.id, column: .ready)
        stakes.details = "Bamboo, 2 m."
        stakes.sourceKind = "note"
        stakes.sourceID = tomatoes.id.uuidString
        let dig = TaskCard(title: "Dig the beds", binderID: garden.id, column: .backlog)
        dig.waitsFor = [stakes.id.uuidString]
        let done = TaskCard(title: "Order seeds", binderID: garden.id, column: .done)
        for card in [stakes, dig, done] { store.insert(card) }
        let comment = TaskEvent(taskID: stakes.id, kind: .comment, author: .you, text: "The long ones")
        store.insert(comment)
        store.save()

        // MARK: Signed out, nothing links.
        check(links.whyNot(garden) == "Sign in to a hub in Settings → Team first.", "a Mac that isn't signed in to a hub can't link: \(links.whyNot(garden) ?? "")")
        account.signIn(to: "hub.example.com")
        await account.finish(URL(string: "binders://auth?token=bnp_robin00001&state=\(account.pending?.state ?? "")")!)
        check(account.isSignedIn && account.person?.login == "robin-h", "signed in to the stand-in hub as robin-h")
        check(links.whyNot(garden) == nil, "now Garden can be linked")

        // MARK: Link to Hub…, choosing.
        let choosing = await drawnAlone(HubLinkSheet(binder: garden), controller: controller, name: "hub-link-choosing",
                                        size: NSSize(width: 520, height: 300), directory: directory)
        check(choosing["hubLink.space"] != nil && choosing["hubLink.project"] == nil && choosing["hubLink.link"] != nil,
              "Link to Hub… offers a new binder or one of the hub's, and Link, with no parts to pick: \(choosing.keys.sorted())")
        check(choosing["hubLink.counts"] != nil, "and says what goes up")
        let spaces = try? await links.spaces()
        check(spaces?.spaces.map(\.name) == ["Team", "Lab"] && spaces?.current == "team" && spaces?.hub.host == "hub.example.com",
              "the hub's Binders, from /api/me")
        let hub = URL(string: "https://hub.example.com")!
        let projects = (try? await links.projects(in: "team", on: hub)) ?? []
        check(projects.map(\.name) == ["Roadmap"], "the projects in Team, from /api/state: \(projects.map(\.name))")
        let made = try? await links.newSpace(named: "Garden Club", on: hub)
        check(made?.space.id == "garden-club" && made?.space.name == "Garden Club" && made?.project?.id == "main",
              "New binder makes one on the hub, and links into its one binder: \(String(describing: made))")

        // Signed in to another hub with a Binder of the same id, nothing chosen on this one is linked there.
        func signIn(_ address: String, _ token: String) async {
            account.signIn(to: address)
            await account.finish(URL(string: "binders://auth?token=\(token)&state=\(account.pending?.state ?? "")")!)
        }
        let team = HubLink.Space(id: "team", name: "Team")
        await signIn("other.example.com", "bnp_robin00002")
        let elsewhere = await links.link(garden, on: hub, space: team, to: nil)
        check(!elsewhere && HubLinks.place(of: garden) == nil && other.isEmpty == false && !other.contains { $0.hasPrefix("POST") }
                && links.problems[garden.id]?.contains("signed in to other.example.com") == true,
              "what was chosen on one hub isn't linked on another: \(links.problems[garden.id] ?? "")")
        await signIn("hub.example.com", "bnp_robin00001")
        other = []

        // MARK: Linked to a new project, cut short once, then Send Again.
        links.batchCount = 4
        asked = []
        var posts = 0
        let send = account.send
        account.send = { request in
            if request.httpMethod == "POST", request.url?.host == "hub.example.com" {
                posts += 1
                // The third request fails: the first eight changes are on the hub, with a card, the rest aren't.
                if posts == 3 { failNextChanges = true }
            }
            return try await send(request)
        }
        let first = await links.link(garden, on: hub, space: team, to: nil)
        let place = HubLinks.place(of: garden)
        check(!first && place != nil && place?.uploaded == false && links.problems[garden.id]?.contains("restarting") == true,
              "a link cut short is kept, not all sent, and says why: \(links.problems[garden.id] ?? "")")
        let project = place?.binder ?? ""
        check(project.hasPrefix("binder-") && place?.newProject == true && place?.binderName == "Garden" && place?.space == "team",
              "linked to a new project named Garden in Team")
        let stakesFirst = onHub("team", "cards", in: project).first { $0["id"] as? String == HubLink.hubID(stakes.id) }
        check(stakesFirst?["title"] as? String == "Buy stakes", "a card went up before it was cut short")

        // Edited here before Send Again: they go again as they are now, not as the hub first had them.
        stakes.title = "Buy bamboo stakes"
        stakes.updatedAt = Date()
        tomatoes.text = "# Tomatoes\n\nStake them in late May."
        tomatoes.updatedAt = Date()
        store.save()

        // Signed in to another hub with a Binder called team too: Send Again waits, and nothing goes there.
        await signIn("other.example.com", "bnp_robin00002")
        let why = links.whyNotSendAgain(garden)
        check(why?.contains("hub.example.com") == true && why?.contains("other.example.com") == true, "Send Again says which hub it's for: \(why ?? "")")
        let waits = await drawnAlone(HubLinkSheet(binder: garden), controller: controller, name: "hub-link-other-hub",
                                     size: NSSize(width: 520, height: 260), directory: directory)
        check(waits["hubLink.whyNotSendAgain"] != nil, "and Link to Hub… shows it: \(waits.keys.sorted())")
        let wrongHub = await links.sendAgain(garden)
        check(!wrongHub && other == ["GET /api/me team"] && HubLinks.place(of: garden)?.uploaded == false,
              "Send Again sends nothing to another hub, which was only asked who's signed in: \(other)")

        // Signed in to the other hub while it sends: it stops after the request under way, and nothing goes there.
        await signIn("hub.example.com", "bnp_robin00001")
        posts = 0
        account.send = { request in
            if request.httpMethod == "POST", request.url?.host == "hub.example.com" {
                posts += 1
                if posts == 1 { await signIn("other.example.com", "bnp_robin00002") }
            }
            return try await send(request)
        }
        let cutOff = await links.sendAgain(garden)
        check(!cutOff && posts == 1 && !other.contains { $0.hasPrefix("POST") || $0.hasPrefix("GET /api/state") }
                && links.problems[garden.id]?.contains("other.example.com") == true,
              "signed in to another hub while it sends, it stops: \(other) \(links.problems[garden.id] ?? "")")
        account.send = send
        await signIn("hub.example.com", "bnp_robin00001")
        other = []

        let again = await links.sendAgain(garden)
        check(again && HubLinks.place(of: garden)?.uploaded == true && links.done[garden.id] == "Sent 3 notes, 2 folders and 3 cards to Garden.",
              "Send Again sends what's left: \(links.done[garden.id] ?? links.problems[garden.id] ?? "")")
        check(other.isEmpty, "and only to the hub it's linked on")
        account.send = send
        links.batchCount = 500

        // MARK: What the web app now shows.
        let projectsNow = onHub("team", "binders")
        check(projectsNow.count == 2 && projectsNow.contains { $0["id"] as? String == project && $0["name"] as? String == "Garden" && $0["createdBy"] as? String == "robin-h" },
              "the hub has the new project Garden, made by robin-h")
        let folders = onHub("team", "folders", in: project)
        let bedsOnHub = folders.first { $0["name"] as? String == "Beds" }
        check(folders.count == 2 && bedsOnHub?["parentId"] as? String == HubLink.hubID(plans.id), "both folders, Beds inside Plans")
        let notes = onHub("team", "notes", in: project)
        let noteIDs = Set(notes.compactMap { $0["id"] as? String })
        check(noteIDs == Set([tomatoes, ideas, top].map { HubLink.hubID($0.id) }), "its three notes: \(notes.compactMap { $0["title"] as? String })")
        check(!noteIDs.contains(HubLink.hubID(moment.id)), "a note from what you said to yourself stays on this Mac")
        let tomatoesOnHub = notes.first { $0["id"] as? String == HubLink.hubID(tomatoes.id) }
        check(tomatoesOnHub?["folderId"] as? String == HubLink.hubID(beds.id) && tomatoesOnHub?["title"] as? String == "Tomatoes"
                && tomatoesOnHub?["text"] as? String == tomatoes.text && (tomatoesOnHub?["editors"] as? [String]) == ["robin-h"],
              "a note keeps its folder, title and words")
        let cards = onHub("team", "cards", in: project)
        func card(_ local: TaskCard) -> [String: Any]? { cards.first { $0["id"] as? String == HubLink.hubID(local.id) } }
        check(cards.count == 3 && card(stakes)?["stage"] as? String == "ready" && card(dig)?["stage"] as? String == "proposed"
                && card(done)?["stage"] as? String == "live", "its three cards, Backlog as proposed and Done as live")
        check(card(dig)?["waitsFor"] as? [String] == [HubLink.hubID(stakes.id)] && card(stakes)?["noteId"] as? String == HubLink.hubID(tomatoes.id)
                && card(stakes)?["brief"] as? String == "Bamboo, 2 m.", "a card keeps what it waits for, its note and its brief")
        let activity = (card(stakes)?["activity"] as? [[String: Any]])?.compactMap { $0["kind"] as? String }
        check(activity == ["created", "comment"], "and the comments on it: \(activity ?? [])")
        check(card(stakes)?["title"] as? String == "Buy bamboo stakes" && tomatoesOnHub?["text"] as? String == "# Tomatoes\n\nStake them in late May.",
              "a card and a note edited before Send Again are on the hub as they are now: \(card(stakes)?["title"] ?? "")")
        // Four, four, then four refused; one cut off (four, already kept); then four, four (already kept, but for the two
        // edited) and one.
        let requests = asked.filter { $0.hasPrefix("POST") }.count
        check(log.count == 1 + 2 + 3 + 3 + 2 && requests == 7, "nothing went twice: \(log.count) changes kept from \(requests) requests")

        let linked = await drawnAlone(HubLinkSheet(binder: garden), controller: controller, name: "hub-link-linked",
                                      size: NSSize(width: 520, height: 240), directory: directory)
        check(linked["hubLink.done"] != nil && linked["hubLink.link"] == nil && linked["hubLink.sendAgain"] == nil,
              "Link to Hub… on a linked binder says where it went: \(linked.keys.sorted())")
        let notTwice = await links.link(garden, on: hub, space: team, to: nil)
        check(!notTwice && HubLinks.place(of: garden)?.binder == project, "a linked binder isn't linked again")

        // MARK: Link Back: an older Binders opened the library and dropped the link and the cards' hub ids.
        garden.hubLink = ""
        for card in BoardService().cards(in: garden.id) { card.hubCard = ""; card.hubPut = "" }
        store.save()
        let lost = await links.lostLinks()
        check(lost.count == 1 && lost.first?.binder.id == garden.id && lost.first?.project.id == project && lost.first?.space.id == "team",
              "a binder whose link was lost is found again by the hub binder holding its notes: \(lost.map { "\($0.binder.name) → \($0.space.id)/\($0.project.id)" })")
        let postsBefore = asked.filter { $0.hasPrefix("POST") }.count
        let back = await links.linkBack(lost[0])
        check(back && HubLinks.place(of: garden)?.binder == project && HubLinks.place(of: garden)?.uploaded == true, "and linked back to it: \(links.problems[garden.id] ?? "")")
        check(asked.filter { $0.hasPrefix("POST") }.count == postsBefore, "sending nothing over the hub's")
        let paired = BoardService().cards(in: garden.id)
        check(paired.count == onHub("team", "cards", in: project).count && paired.allSatisfy { !$0.hubCard.isEmpty },
              "its cards paired with the hub's again, so none goes up twice: \(paired.map(\.hubCard))")
        check(await links.lostLinks().isEmpty, "and nothing is left to link back")

        // MARK: Unlinking keeps everything here, and on the hub.
        links.unlink(garden)
        check(HubLinks.place(of: garden) == nil && store.folders(in: garden.id).count == 2 && store.note(tomatoes.id)?.binderID == garden.id
                && BoardService().cards(in: garden.id).count == 3 && store.note(moment.id) != nil, "unlinking keeps the binder here with its folders, notes and cards")
        check(onHub("team", "notes", in: project).count == 3, "and the project on the hub as it is")

        // MARK: Another binder into a project the hub has, in another of its Binders.
        let shed = BinderRecord(name: "Shed", colorIndex: 3)
        store.insert(shed)
        let paint = NoteItem(text: "# Paint\n\nGreen.")
        paint.binderID = shed.id
        store.insert(paint)
        store.save()
        states["lab"] = ["binders": [["id": "binder-lab", "name": "Workshop"]]]
        let into = await links.link(shed, on: hub, space: HubLink.Space(id: "lab", name: "Lab"), to: HubLink.Project(id: "binder-lab", name: "Workshop"))
        check(into && onHub("lab", "binders").count == 1 && onHub("lab", "notes", in: "binder-lab").count == 1 && onHub("team", "notes", in: "binder-lab").isEmpty,
              "a binder links into a project the hub has, in the Binder chosen, with no new project")
        check(HubLinks.place(of: shed)?.binderName == "Workshop" && links.done[shed.id] == "Sent 1 note, 0 folders and 0 cards to Workshop.",
              "and says so: \(links.done[shed.id] ?? links.problems[shed.id] ?? "")")

        // MARK: A binder shared with a team folder isn't linked.
        let shared = BinderRecord(name: "Shared", colorIndex: 4)
        shared.sharedWithTeam = true
        store.insert(shared)
        check(links.whyNot(shared)?.hasPrefix("This binder is shared with your team already.") == true, "a binder shared with a team folder isn't linked")
        let refused = await links.link(shared, on: hub, space: team, to: nil)
        check(!refused && HubLinks.place(of: shared) == nil, "and Link does nothing for it")

        // MARK: A real hub, when one is given.
        if let hub = ProcessInfo.processInfo.environment["BINDERS_TEST_HUB"], let token = ProcessInfo.processInfo.environment["BINDERS_TEST_HUB_TOKEN"] {
            failures += await realHubLinkChecks(hub: hub, token: token)
        } else {
            print("SKIP: a real hub (set BINDERS_TEST_HUB and BINDERS_TEST_HUB_TOKEN)")
        }

        print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
        return failures == 0 ? 0 : 1
    }

    /// Links a binder with a folder, notes and cards to a new project on a running hub, and reads the hub's state back.
    @MainActor
    private static func realHubLinkChecks(hub: String, token: String) async -> Int {
        var failed = 0
        func check(_ condition: Bool, _ label: String) {
            print("\(condition ? "PASS" : "FAIL"): real hub: \(label)")
            if !condition { failed += 1 }
        }
        let account = HubAccount.shared
        let links = HubLinks.shared
        let store = Store.shared
        account.send = { try await URLSession.shared.data(for: $0) }
        account.signIn(to: hub)
        await account.finish(URL(string: "binders://auth?token=\(token)&state=\(account.pending?.state ?? "")")!)
        check(account.isSignedIn && account.person != nil, "signed in as \(account.person?.line ?? account.problem ?? "no one")")

        let stamp = Int(Date().timeIntervalSince1970)
        let binder = BinderRecord(name: "Linked from a Mac \(stamp)", colorIndex: 5)
        store.insert(binder)
        let folder = store.createFolder(named: "Ideas", in: binder.id)!
        let inner = store.createFolder(named: "Later", in: binder.id, parent: folder.id)!
        for (index, place) in [nil, folder.id, inner.id].enumerated() {
            let note = NoteItem(text: "# Mac note \(index + 1)\n\nWritten on a Mac at \(stamp).")
            note.binderID = binder.id
            note.folderID = place
            store.insert(note)
        }
        let card = TaskCard(title: "A card from the Mac", binderID: binder.id, column: .ready)
        card.details = "Linked at \(stamp)."
        store.insert(card)
        store.insert(TaskCard(title: "Another, in Backlog", binderID: binder.id, column: .backlog))
        store.save()

        guard let found = try? await links.spaces(), let first = found.spaces.first(where: { $0.id == found.current }) ?? found.spaces.first else {
            check(false, "the hub says which Binders you're in")
            return failed
        }
        let linked = await links.link(binder, on: found.hub, space: first, to: nil)
        check(linked, "linked to a new project in \(first.name): \(links.done[binder.id] ?? links.problems[binder.id] ?? "")")
        guard let place = HubLinks.place(of: binder), var request = account.authorized("api/state") else { return failed + 1 }
        request.setValue(place.space, forHTTPHeaderField: "x-binders-space")
        let state = (try? await URLSession.shared.data(for: request).0).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["state"] as? [String: Any]
        func items(_ list: String) -> [[String: Any]] { (state?[list] as? [[String: Any]] ?? []).filter { $0["binderId"] as? String == place.binder } }
        check((state?["binders"] as? [[String: Any]])?.contains { $0["id"] as? String == place.binder && $0["name"] as? String == binder.name } == true,
              "the hub's state has the project \(binder.name)")
        check(items("folders").count == 2 && items("notes").count == 3 && items("cards").count == 2,
              "and its 2 folders, 3 notes and 2 cards: \(items("folders").count), \(items("notes").count), \(items("cards").count)")
        // Not signed out: that would revoke the token the test was given.
        print("NOTE: real hub: open \(hub) and the project “\(binder.name)” in \(first.name) to see them in the web app")
        return failed
    }
}
