import AppKit
import Foundation
import SwiftData
import BindersAutomerge
import BindersKit

/// Linked notes and folders kept the same here and on a running hub (HubNotesSync), in a throwaway folder
/// (BINDERS_DATA_DIR), with a teammate in the web app played by a second person's session on the same hub. A binder is
/// linked; an edit on this Mac shows on the hub within a couple of seconds and the teammate's here; a note and folder
/// the web app makes come here in their place, and this Mac's new folder, move and deletion go; two people typing in the
/// same paragraph both keep their words; edits made offline, kept through quitting, go when it's back without losing the
/// teammate's; a picture pasted on this Mac goes to the hub and the web app's comes here.
///
/// BINDERS_TEST_HUB (the hub's address), BINDERS_TEST_HUB_TOKEN (a bnp_ token there) and BINDERS_TEST_HUB_WEB_COOKIE (a
/// teammate's session cookie) are set by scripts/hub-sync-test.sh, which starts a hub of its own:
///
///     scripts/hub-sync-test.sh [path to binders-server]
extension SelfTest {
    @MainActor
    static func hubSyncSelfTest() async -> Int32 {
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
        /// Waits up to `seconds` for `condition`; how long it took, or nil.
        func until(_ seconds: Double = 5, _ condition: () -> Bool) async -> Double? {
            let start = Date()
            while Date().timeIntervalSince(start) < seconds {
                if condition() { return Date().timeIntervalSince(start) }
                try? await Task.sleep(for: .milliseconds(50))
            }
            return condition() ? Date().timeIntervalSince(start) : nil
        }
        func within(_ took: Double?) -> String { took.map { String(format: "%.2f s", $0) } ?? "never" }

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
        // Offline: nothing reaches the hub, the feed included.
        var offline = false
        account.send = { request in
            if offline { throw URLError(.notConnectedToInternet) }
            return try await URLSession.shared.data(for: request)
        }
        sync.openFeed = { request in offline ? DeadFeed() as HubFeed : HubWebSocketFeed(request) }

        account.signIn(to: hubAddress)
        await account.finish(URL(string: "binders://auth?token=\(token)&state=\(account.pending?.state ?? "")")!)
        check(account.isSignedIn, "signed in as \(account.person?.line ?? account.problem ?? "no one")")
        guard let hub = account.address, let (spaces, current) = try? await links.spaces(),
              let space = spaces.first(where: { $0.id == current }) ?? spaces.first else {
            print("FAIL: the hub's Binders")
            return 1
        }

        // The teammate, in the web app: their session, in the same Binder.
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
        var made = 0
        func webSend(_ change: [String: Any]) async -> Int {
            made += 1
            return await web("POST", "api/changes", ["client": "web-tab-dana", "changes": [["id": "web-\(made)-\(UUID().uuidString.prefix(8))", "change": change]]]).1
        }
        func webEdit(_ id: String, _ text: String, changes: [String]? = nil) async -> Int {
            var change: [String: Any] = ["type": "note.edit", "id": id, "text": text, "title": HubSync.title(of: text), "by": "dana-w",
                                         "at": HubLink.iso(Date())]
            if let changes { change["changes"] = changes }
            return await webSend(change)
        }
        var hubState = HubSync.State()
        func refreshHub() async { if let state = HubSync.State(hubState: await web("GET", "api/state").0) { hubState = state } }
        func onHub(_ seconds: Double = 5, _ condition: @escaping (HubSync.State) -> Bool) async -> Double? {
            let start = Date()
            while Date().timeIntervalSince(start) < seconds {
                await refreshHub()
                if condition(hubState) { return Date().timeIntervalSince(start) }
                try? await Task.sleep(for: .milliseconds(100))
            }
            return nil
        }
        func text(_ id: UUID) -> String { store.note(id)?.text ?? "" }

        // MARK: Linking, and the feed

        let binder = BinderRecord(name: "Synced from a Mac \(Int(Date().timeIntervalSince1970))", colorIndex: 3)
        store.insert(binder)
        let ideas = store.createFolder(named: "Ideas", in: binder.id)!
        func note(_ text: String, in folder: UUID? = nil) -> NoteItem {
            let note = NoteItem(text: text)
            note.binderID = binder.id
            note.folderID = folder
            store.insert(note)
            return note
        }
        let plan = note("# Plan\n\nFirst line from the Mac.", in: ideas.id)
        let doomed = note("# Old note\n\nDelete me.")
        let para = note("# Paragraph\n\nThe quick fox jumps.")
        let away = note("# Away\n\nWritten before going offline.")
        let pics = note("# Pictures\n\nFrom both sides.")
        store.save()
        let linked = await links.link(binder, space: space, to: nil)
        check(linked, "linked to a new project in \(space.name)")
        guard let place = HubLinks.place(of: binder) else { return 1 }
        let id = { (note: NoteItem) in HubLink.hubID(note.id) }
        let connected = await until(10) { sync.spaces[place.space]?.connected == true }
        check(connected != nil, "the live feed is open (\(within(connected)))")

        // MARK: Both ways within a couple of seconds

        plan.text += "\nAn edit on the Mac."
        store.save()
        var took = await onHub { $0.notes[id(plan)]?.text.contains("An edit on the Mac.") == true }
        check(took.map { $0 < 2.5 } ?? false, "an edit on the Mac is on the hub in \(within(took))")

        let planOnHub = hubState.notes[id(plan)]?.text ?? ""
        check(await webEdit(id(plan), planOnHub + "\nAn edit in the web app.") == 200, "the web app edits the note")
        took = await until { text(plan.id).contains("An edit in the web app.") }
        check(took.map { $0 < 2.5 } ?? false, "the web app's edit is on the Mac in \(within(took))")
        check(text(plan.id).contains("An edit on the Mac."), "the Mac's words are still there")

        // MARK: Folders and notes made, moved and deleted

        check(await webSend(["type": "folder.put", "folder": ["id": "folder-web-1", "binderId": place.binder, "name": "From the web",
                                                                "parentId": HubLink.hubID(ideas.id)]]) == 200, "the web app makes a folder")
        check(await webSend(["type": "note.put", "note": ["id": "note-web-1", "title": "Web note", "binderId": place.binder, "folderId": "folder-web-1",
                                                            "editedAt": HubLink.iso(Date()), "editors": ["dana-w"], "text": "# Web note\n\nFrom Dana."]]) == 200,
              "the web app makes a note in it")
        let webFolder = HubSync.localID("folder-web-1"), webNote = HubSync.localID("note-web-1")
        took = await until { store.note(webNote)?.folderID == webFolder && store.folder(webFolder)?.parentID == ideas.id }
        check(took != nil, "the web app's folder and note are on the Mac, in their place (\(within(took)))")

        let later = store.createFolder(named: "Later", in: binder.id, parent: ideas.id)!
        store.move(para, toFolder: later.id)
        NoteTrash.shared.delete(doomed, undoManager: nil)
        store.save()
        took = await onHub {
            $0.folders[HubLink.hubID(later.id)]?.parentId == HubLink.hubID(ideas.id) && $0.notes[id(para)]?.folderId == HubLink.hubID(later.id)
                && $0.notes[id(doomed)] == nil
        }
        check(took != nil, "the Mac's new folder, a move into it and a deletion are on the hub (\(within(took)))")

        check(await webSend(["type": "note.move", "id": "note-web-1", "binderId": place.binder]) == 200, "the web app moves its note to the top")
        check(await webSend(["type": "folder.delete", "id": "folder-web-1"]) == 200, "and deletes its folder")
        took = await until { store.folder(webFolder) == nil && store.note(webNote)?.folderID == nil }
        check(took != nil, "that's on the Mac too (\(within(took)))")

        // MARK: Two people in the same paragraph

        // Dana's editor has the note's document as the hub has it, and types into it while the Mac types too.
        let (saved, status) = await web("GET", "api/notes/\(id(para))/doc")
        let danaDoc = status == 200 ? try? NoteDocument(note: para.id, loading: saved, actor: UUID()) : nil
        check(danaDoc != nil, "the web app reads the note's document")
        para.text = text(para.id).replacingOccurrences(of: "jumps.", with: "jumps over the dog.")
        store.save()
        if let danaDoc, let fox = danaDoc.text.range(of: "fox") {
            let start = danaDoc.text.unicodeScalars.distance(from: danaDoc.text.startIndex, to: fox.lowerBound)
            if let change = try? danaDoc.change(splices: [NoteDocumentSplice(start: start, delete: 0, insert: "brown ")], props: [:]) {
                check(await webEdit(id(para), danaDoc.text, changes: [change.bytes.base64EncodedString()]) == 200,
                      "the web app sends its typing as Automerge changes")
            }
        }
        let both = { (text: String) in text.contains("quick brown fox jumps over the dog.") }
        took = await until(6) { both(text(para.id)) }
        check(took != nil, "on the Mac both people's words are in the paragraph (\(within(took))): \(text(para.id).debugDescription)")
        took = await onHub { $0.notes[id(para)].map { both($0.text) } ?? false }
        check(took != nil, "on the hub too: \(hubState.notes[id(para)]?.text.debugDescription ?? "none")")

        // Again, now that the Mac has the note's document: its typing goes as changes made on it.
        let edits = sync.counts["edit"] ?? 0
        let (again, _) = await web("GET", "api/notes/\(id(para))/doc")
        let danaAgain = try? NoteDocument(note: para.id, loading: again, actor: UUID())
        para.text = text(para.id).replacingOccurrences(of: "the dog.", with: "the sleepy dog.")
        store.save()
        if let danaAgain, let quick = danaAgain.text.range(of: "quick") {
            let start = danaAgain.text.unicodeScalars.distance(from: danaAgain.text.startIndex, to: quick.lowerBound)
            if let change = try? danaAgain.change(splices: [NoteDocumentSplice(start: start, delete: 5, insert: "swift")], props: [:]) {
                _ = await webEdit(id(para), danaAgain.text, changes: [change.bytes.base64EncodedString()])
            }
        }
        let twice = { (text: String) in text.contains("The swift brown fox jumps over the sleepy dog.") }
        took = await until(6) { twice(text(para.id)) }
        check(took != nil, "a second time, both keep their words on the Mac: \(text(para.id).debugDescription)")
        took = await onHub { $0.notes[id(para)].map { twice($0.text) } ?? false }
        check(took != nil, "and on the hub: \(hubState.notes[id(para)]?.text.debugDescription ?? "none")")
        check((sync.counts["edit"] ?? 0) > edits, "that went as changes made on the Mac's copy of the document")

        // MARK: Pictures, both ways

        /// A small picture of one colour, as PNG or TIFF.
        func picture(_ color: NSColor, as type: NSBitmapImageRep.FileType = .png) -> Data {
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 24, pixelsHigh: 16, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                       isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            color.setFill()
            NSRect(x: 0, y: 0, width: 24, height: 16).fill()
            NSGraphicsContext.restoreGraphicsState()
            return rep.representation(using: type, properties: [:])!
        }
        func hubFile(_ name: String) async -> Data? {
            let (data, status) = await web("GET", "api/files/\(name)")
            return status == 200 ? data : nil
        }
        let pictures = HubPictures.shared
        let pasted = picture(.systemOrange)
        let pastedLine = (try? Attachments.add(imageData: pasted, type: .png)) ?? ""
        // A TIFF, as some apps drop them: the hub takes it as a PNG.
        let tiff = FileManager.default.temporaryDirectory.appendingPathComponent("Scan \(UUID().uuidString.prefix(6)).tiff")
        try? picture(.systemTeal, as: .tiff).write(to: tiff)
        let droppedLine = (try? Attachments.add(tiff)) ?? ""
        check(pastedLine.hasPrefix("![](attachments/") && droppedLine.hasPrefix("![](attachments/"), "pictures pasted and dropped into a linked note on the Mac")
        pics.text = text(pics.id) + "\n\n" + pastedLine + "\n\nA scan:\n\n" + droppedLine
        store.save()
        let named = { (text: String) in HubFiles.hubNames(in: text).count == 2 && !text.contains("attachments/") }
        took = await onHub(8) { $0.notes[id(pics)].map { named($0.text) } ?? false }
        let picsOnHub = hubState.notes[id(pics)]?.text ?? ""
        check(took.map { $0 < 4 } ?? false, "on the hub (\(within(took))) the note names the hub's copies: \(picsOnHub.debugDescription)")
        let sentNames = HubFiles.hubNames(in: picsOnHub)
        let pastedName = sentNames.first { picsOnHub.range(of: "From both sides.\n\n![](/api/files/\($0))") != nil }
        let pastedOnHub = await hubFile(pastedName ?? "none")
        check(pastedOnHub == pasted, "the web app gets the pasted picture as it was")
        let scanName = sentNames.first { $0 != pastedName }
        check(scanName?.hasSuffix(".png") == true, "the TIFF went up as a PNG: \(scanName ?? "none")")
        if let scanName, let scan = await hubFile(scanName) { check(NSBitmapImageRep(data: scan)?.pixelsWide == 24, "and it's the picture") }
        check(named(text(pics.id)), "the note on the Mac names them too")
        check(sentNames.allSatisfy { FileManager.default.fileExists(atPath: Attachments.folder.appendingPathComponent($0).path) },
              "and the Mac keeps its copies under the hub's names, so it shows them")

        // The web app's picture: sent to the hub, then written into the note as the web app writes it.
        let theirs = picture(.systemPurple)
        var upload = URLRequest(url: hub.appendingPathComponent("api/files"))
        upload.url = URL(string: upload.url!.absoluteString + "?note=\(id(pics))")
        upload.httpMethod = "POST"
        upload.httpBody = theirs
        upload.setValue("image/png", forHTTPHeaderField: "Content-Type")
        upload.setValue(cookie, forHTTPHeaderField: "Cookie")
        upload.setValue("1", forHTTPHeaderField: "x-binders")
        upload.setValue(space.id, forHTTPHeaderField: "x-binders-space")
        let answer = try? await URLSession.shared.data(for: upload)
        let address = answer.flatMap { (try? JSONSerialization.jsonObject(with: $0.0)) as? [String: Any] }?["url"] as? String ?? ""
        check(HubFiles.hubName(in: address) != nil, "the web app sends a picture to the hub: \(address)")
        await refreshHub()
        check(await webEdit(id(pics), (hubState.notes[id(pics)]?.text ?? "") + "\n\n![From Dana](\(address))") == 200, "and puts it in the note")
        let theirName = HubFiles.hubName(in: address) ?? "none"
        let theirFile = Attachments.folder.appendingPathComponent(theirName)
        took = await until(6) { text(pics.id).contains("![From Dana](\(address))") && (try? Data(contentsOf: theirFile)) == theirs }
        check(took.map { $0 < 4 } ?? false, "the web app's picture is in the note on the Mac, fetched and kept here (\(within(took)))")
        check(Attachments.url(for: address) == theirFile, "the Mac's editor shows it from there")
        check(pictures.counts["fetched"] ?? 0 >= 1 && pictures.counts["sent"] == 2 && pictures.counts["refused"] == nil,
              "pictures: \(pictures.counts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))")

        // The same picture in another linked binder goes up again, to that binder: the hub keeps a picture with its
        // note's project, and a reader of only that one couldn't see the first copy.
        let other = BinderRecord(name: "Also from a Mac \(Int(Date().timeIntervalSince1970))", colorIndex: 5)
        store.insert(other)
        let reused = NoteItem(text: "# Reused\n\nThe same picture.\n\n" + pastedLine)
        reused.binderID = other.id
        store.insert(reused)
        store.save()
        check(await links.link(other, space: space, to: nil), "a second binder linked to a new project in \(space.name)")
        took = await onHub(8) { $0.notes[id(reused)].map { HubFiles.hubNames(in: $0.text) == [pastedName ?? "none"] } ?? false }
        check(took != nil, "on the hub the second binder's note names the picture (\(within(took))): \(hubState.notes[id(reused)]?.text.debugDescription ?? "nothing")")
        check(pictures.counts["sent"] == 3, "and it went up again for that binder, not taken from the first: sent \(pictures.counts["sent"] ?? 0)")

        // MARK: Offline, through quitting

        offline = true
        sync.dropFeeds()
        took = await until { sync.status(of: binder)?.hasPrefix("Offline") == true }
        check(took != nil, "offline, the binder says so: \(sync.status(of: binder) ?? "nothing")")
        away.text = text(away.id).replacingOccurrences(of: "Written before", with: "Written on the Mac before")
        // And one whose document the Mac has: its edit is made on it while offline.
        plan.text = text(plan.id).replacingOccurrences(of: "First line from the Mac.", with: "First line from the Mac, offline.")
        let fresh = note("# Made offline\n\nOn a plane.")
        store.save()
        try? await Task.sleep(for: .milliseconds(400))
        check(sync.status(of: binder)?.contains("to send") == true, "what waits is counted: \(sync.status(of: binder) ?? "nothing")")
        // Meanwhile the teammate types in the same paragraph.
        let awayOnHub = hubState.notes[id(away)]?.text ?? ""
        check(await webEdit(id(away), awayOnHub.replacingOccurrences(of: "going offline.", with: "going offline, said Dana.")) == 200,
              "the teammate edits the same paragraph meanwhile")
        let planHub = hubState.notes[id(plan)]?.text ?? ""
        _ = await webEdit(id(plan), planHub.replacingOccurrences(of: "An edit in the web app.", with: "An edit in the web app, again."))
        // Quitting keeps what waits on disk; opening again picks it up.
        sync.stopAll()
        offline = false
        sync.refresh()
        let merged = { (text: String) in text.contains("Written on the Mac before going offline, said Dana.") }
        took = await onHub(8) { $0.notes[id(away)].map { merged($0.text) } ?? false && $0.notes[id(fresh)] != nil }
        check(took != nil, "back online, the offline edit and new note are on the hub with the teammate's words: \(hubState.notes[id(away)]?.text.debugDescription ?? "none")")
        let planBoth = { (text: String) in text.contains("from the Mac, offline.") && text.contains("in the web app, again.") }
        took = await onHub(8) { $0.notes[id(plan)].map { planBoth($0.text) } ?? false }
        let planHere = await until(6) { planBoth(text(plan.id)) }
        check(took != nil && planHere != nil, "an offline edit on the Mac's copy of a document keeps the teammate's words too: \(text(plan.id).debugDescription)")
        took = await until(6) { merged(text(away.id)) }
        check(took != nil, "and on the Mac: \(text(away.id).debugDescription)")
        took = await until { sync.status(of: binder) == nil }
        check(took != nil, "nothing waits: \(sync.status(of: binder) ?? "all sent")")

        print("How the words went: \(sync.counts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))")
        check(sync.counts["refused"] == nil && sync.counts["reread"] == nil, "the hub turned nothing down and no note's words had to be read again")
        sync.stopAll()
        print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
        return failures == 0 ? 0 : 1
    }
}

/// A live feed that can't be opened: offline.
private final class DeadFeed: HubFeed {
    func next() async throws -> Data { throw URLError(.notConnectedToInternet) }
    func close() {}
}
