import AppKit
import Foundation
import SwiftUI
import BindersKit

/// A linked note's history comes from a running hub (HubNoteHistory), in a throwaway folder (BINDERS_DATA_DIR): a note
/// made on this Mac and edited twice in the web app, by a second person's session on the same hub, has those edits in
/// its history here, newest first, and the version from before them reads as the Mac wrote it. A note in a binder that
/// isn't linked keeps its history on this Mac. With a folder after the flag, the history sheet is drawn there.
///
/// BINDERS_TEST_HUB, BINDERS_TEST_HUB_TOKEN and BINDERS_TEST_HUB_WEB_COOKIE are set by scripts/hub-history-test.sh,
/// which starts a hub of its own that commits a note five seconds after its edits pause:
///
///     scripts/hub-history-test.sh [path to binders-server]
extension SelfTest {
    @MainActor
    static func hubHistorySelfTest(drawingTo directory: URL?) async -> Int32 {
        guard AppPaths.isDemo else {
            print("ERROR: set BINDERS_DATA_DIR to an empty folder; this test makes binders and links them to a hub")
            return 1
        }
        let env = ProcessInfo.processInfo.environment
        guard let hubAddress = env["BINDERS_TEST_HUB"], let token = env["BINDERS_TEST_HUB_TOKEN"], let cookie = env["BINDERS_TEST_HUB_WEB_COOKIE"]
        else {
            print("ERROR: run it from scripts/hub-history-test.sh, which starts a hub (BINDERS_TEST_HUB, _TOKEN, _WEB_COOKIE)")
            return 1
        }
        var failures = 0
        func check(_ condition: Bool, _ label: String) {
            print("\(condition ? "PASS" : "FAIL"): \(label)")
            if !condition { failures += 1 }
        }
        func until(_ seconds: Double = 20, _ condition: () async -> Bool) async -> Bool {
            let start = Date()
            while Date().timeIntervalSince(start) < seconds {
                if await condition() { return true }
                try? await Task.sleep(for: .milliseconds(200))
            }
            return await condition()
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

        // The teammate, in the web app.
        var made = 0
        func webEdit(_ id: String, _ text: String) async -> Int {
            made += 1
            var request = URLRequest(url: hub.appendingPathComponent("api/changes"))
            request.httpMethod = "POST"
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
            request.setValue("1", forHTTPHeaderField: "x-binders")
            request.setValue(space.id, forHTTPHeaderField: "x-binders-space")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let change: [String: Any] = ["type": "note.edit", "id": id, "text": text, "title": HubSync.title(of: text), "by": "dana-w", "at": HubLink.iso(Date())]
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["client": "web-tab-dana", "changes": [["id": "web-\(made)-\(UUID().uuidString.prefix(8))", "change": change]]])
            guard let (_, response) = try? await URLSession.shared.data(for: request) else { return 0 }
            return (response as? HTTPURLResponse)?.statusCode ?? 0
        }

        let binder = BinderRecord(name: "History from a hub \(Int(Date().timeIntervalSince1970))", colorIndex: 2)
        store.insert(binder)
        let first = "# Plan\n\nFirst line from the Mac."
        let plan = NoteItem(text: first)
        plan.binderID = binder.id
        store.insert(plan)
        let elsewhere = BinderRecord(name: "Not linked", colorIndex: 4)
        store.insert(elsewhere)
        let local = NoteItem(text: "# Mine\n\nStays here.")
        local.binderID = elsewhere.id
        store.insert(local)
        store.save()
        check(await links.link(binder, space: space, to: nil), "linked to a new project in \(space.name)")
        check(HubNoteHistory.keepsHistory(of: plan), "the linked note's history is the hub's")
        check(!HubNoteHistory.keepsHistory(of: local), "a note in a binder that isn't linked keeps its history here")
        let id = HubLink.hubID(plan.id)

        var versions: [HubNoteHistory.Version] = []
        var problem: String?
        func read() async -> [HubNoteHistory.Version] {
            do {
                versions = try await HubNoteHistory.versions(of: plan)
                problem = nil
            } catch {
                problem = (error as? HubNotesSync.Problem)?.words ?? error.localizedDescription
            }
            return versions
        }

        var ok = await until { await read().first?.text == first }
        check(ok, "the hub has the note as the Mac wrote it (\(versions.count) versions\(problem.map { ", \($0)" } ?? ""))")

        let once = first + "\nA line from the web app."
        check(await webEdit(id, once) == 200, "the web app edits the note")
        ok = await until { await read().first?.text == once }
        check(ok, "its edit is the newest version in the note's history here (\(versions.count) versions)")
        let twice = once + "\nAnd another, a little later."
        check(await webEdit(id, twice) == 200, "and edits it again")
        ok = await until { await read().first?.text == twice }
        check(ok, "that's the newest now")
        check(versions.map(\.text).prefix(3) == [twice, once, first], "newest first, each edit a version of its own")
        check(versions.dropFirst().allSatisfy { $0.commit.at <= versions[0].commit.at }, "dated as the hub committed them")
        check(versions.allSatisfy { $0.commit.subject.contains("Plan") || $0.commit.subject.hasPrefix("Notes as") }, "each says what the hub did: \(versions.first?.commit.subject ?? "")")
        check(await until { store.note(plan.id)?.text == twice }, "the note here has the web app's words")

        // Opening the older version: its text as the Mac wrote it, front matter and all taken off.
        let older = versions.first { $0.text == first }
        check(older?.text == first, "the version from before the web app's edits reads as it was")
        let entries = HubNoteHistory.entries(of: versions.map {
            NoteHistory.Version(url: URL(fileURLWithPath: "/hub-versions/\($0.commit.sha).md"), date: $0.commit.at, text: $0.text)
        }, now: plan.text)
        check(entries.first?.id == versions.first?.commit.sha && entries.first?.added == 1, "the newest version added a line")
        check(entries.allSatisfy { $0.id != NoteVersions.nowID }, "nothing is newer here than the hub's newest version")

        if let directory {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 560), styleMask: [.titled, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.alphaValue = 0
            let hosting = NSHostingView(rootView: NoteHistorySheet(note: plan))
            hosting.wantsLayer = true
            window.contentView = hosting
            window.orderFrontRegardless()
            try? await Task.sleep(for: .seconds(2))
            capture(hosting, name: "hub-history", directory: directory)
            window.close()
            print("Drew the history sheet in \(directory.path)")
        }

        print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
        return failures == 0 ? 0 : 1
    }
}
