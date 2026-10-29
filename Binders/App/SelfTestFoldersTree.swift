import AppKit
import SwiftData
import SwiftUI
import BindersKit

extension SelfTest {
    /// Part of --selftest-folders: a binder's lists as a tree, in the real window. Clicking a folder opens it in place,
    /// the rest of the list still there, and makes it where new notes go; Collapse All closes every folder; a note opened
    /// from elsewhere opens the folders it's in; what's open is kept across launches; the sidebar shows a folder in the
    /// tree instead of going into it; deleting the folder new things go in sends them where its things went; and the
    /// meetings list is a tree too. Drawn to `directory` when one is given.
    @MainActor
    static func folderTreeSelfTest(check: (Bool, String) -> Void, drawingTo directory: URL?) async {
        let store = Store.shared
        let atlas = BinderRecord(name: "Atlas", colorIndex: 5)
        store.insert(atlas)
        guard let research = store.createFolder(named: "Research", in: atlas.id),
              let interviews = store.createFolder(named: "Interviews", in: atlas.id, parent: research.id),
              let admin = store.createFolder(named: "Admin", in: atlas.id) else {
            return check(false, "the folders for the tree are made")
        }
        func note(_ text: String, _ folder: UUID?, age: TimeInterval) -> NoteItem {
            let note = NoteItem(text: text)
            note.binderID = atlas.id
            note.folderID = folder
            note.updatedAt = Date().addingTimeInterval(-age)
            store.insert(note)
            return note
        }
        let roadmap = note("# Atlas roadmap\n\nWhat ships when.", nil, age: 60)
        let survey = note("# Survey plan\n\nWho we ask, and how.", research.id, age: 120)
        let grower = note("# Interview with a grower\n\nThey water at dawn.", interviews.id, age: 180)
        let invoices = note("# Invoices\n\nPaid in full.", admin.id, age: 240)
        let sync = MeetingRecord(title: "Research sync", appName: "Zoom", templateID: "general")
        sync.status = "ready"
        sync.binderID = atlas.id
        sync.folderID = research.id
        store.insert(sync)
        let kickoff = MeetingRecord(title: "Atlas kickoff", appName: "Zoom", templateID: "general")
        kickoff.status = "ready"
        kickoff.binderID = atlas.id
        store.insert(kickoff)
        store.save()

        let expansion = FolderExpansion.shared
        expansion.collapseAll(in: atlas.id)
        OutlinePresses.isOn = true
        var rows: [OutlineEntry<NoteItem>] = []
        var meetingRows: [OutlineEntry<MeetingRecord>] = []
        NotesView.drawn = { rows = $0 }
        MeetingsView.drawn = { meetingRows = $0 }
        defer {
            NotesView.drawn = nil
            MeetingsView.drawn = nil
            OutlinePresses.isOn = false
        }
        func notesShown() -> [UUID] { OutlineEntry.items(in: rows).map(\.id) }
        func depth(of id: UUID) -> Int? {
            rows.lazy.compactMap { entry -> Int? in if case .item(let note, let depth) = entry, note.id == id { depth } else { nil } }.first
        }
        func foldersShown() -> [UUID] { rows.compactMap { if case .folder(let folder, _, _, _) = $0 { folder.id } else { nil } } }
        func count(of id: UUID) -> Int? {
            rows.lazy.compactMap { entry -> Int? in if case .folder(let folder, _, let count, _) = entry, folder.id == id { count } else { nil } }.first
        }

        let controller = DictationController()
        let navigation = HubNavigation()
        navigation.selection = .binder
        navigation.binderID = atlas.id
        navigation.pendingBinderTab = .notes
        let window = HubWindowController.makeWindow(HubView()
            .environment(controller).environment(controller.meetings).environment(controller.knowledge).environment(controller.team)
            .environment(controller.capture).environment(controller.commitments).environment(navigation).environment(AppSettings.shared)
            .modelContainer(store.container))
        window.alphaValue = 0
        window.orderFrontRegardless()
        defer { window.close() }
        try? await Task.sleep(for: .milliseconds(1500))

        // Everything closed: the folders at the top, by name, then the note at the top.
        check(foldersShown() == [admin.id, research.id] && notesShown() == [roadmap.id],
              "closed, the list shows the top's folders, then the notes at the top: \(rows.map(\.id))")
        check(count(of: research.id) == 2 && count(of: admin.id) == 1, "a folder's count takes in the folders inside it")

        // Clicking a folder, as the row's button does.
        func press(_ name: String) -> Bool { OutlinePresses.press(name) }
        check(press("folder:" + research.id.uuidString), "the Research row is a button")
        try? await Task.sleep(for: .milliseconds(600))
        check(expansion.isOpen(research.id) && navigation.folderID == research.id, "clicking a folder opens it and makes it where new notes go")
        check(Set(notesShown()) == [survey.id, roadmap.id] && depth(of: survey.id) == 1 && depth(of: roadmap.id) == 0
              && foldersShown() == [admin.id, research.id, interviews.id],
              "it opens in place: its note and folder under it, indented, and the rest of the list still there")
        check(!notesShown().contains(grower.id), "a folder inside it stays closed")

        // A new note goes in the folder chosen, and shows there.
        let made = QuickSwitcher.newNote(from: nil, in: atlas, navigation: navigation)
        try? await Task.sleep(for: .milliseconds(700))
        check(made?.folderID == research.id && made.map { depth(of: $0.id) == 1 } == true && navigation.currentNoteID == made?.id,
              "a new note goes in the folder chosen, and opens there in the tree")
        if let made { NoteTrash.shared.delete(made, undoManager: nil) }

        // Collapse All, from the list's header.
        check(press("collapse:" + atlas.id.uuidString), "the list has a Collapse All button")
        try? await Task.sleep(for: .milliseconds(600))
        check(!expansion.hasOpen(in: atlas.id) && notesShown() == [roadmap.id] && foldersShown() == [admin.id, research.id],
              "Collapse All closes every folder: \(rows.map(\.id))")

        // A note deep inside, opened from a link or a search.
        navigation.pendingNoteID = grower.id
        try? await Task.sleep(for: .milliseconds(800))
        check(expansion.isOpen(research.id) && expansion.isOpen(interviews.id) && depth(of: grower.id) == 2,
              "a note opened from elsewhere opens the folders it's in, and shows two deep")
        check(navigation.currentNoteID == grower.id && navigation.folderID == interviews.id, "it's selected, and new notes go where it is")
        if let directory {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if let content = window.contentView { capture(content, name: "folders-tree", directory: directory) }
        }
        check(FolderExpansion(defaults: AppDefaults.store).folders.isSuperset(of: [research.id, interviews.id]), "what's open is kept for the next launch")

        // The sidebar shows a folder in the tree.
        navigation.show(folder: admin)
        try? await Task.sleep(for: .milliseconds(700))
        check(expansion.isOpen(admin.id) && notesShown().contains(invoices.id) && navigation.folderID == admin.id && navigation.folderToShow == nil
              && navigation.selection == .binder, "a folder chosen in the sidebar opens in the page's tree, where new notes go")
        check(notesShown().contains(roadmap.id) && notesShown().contains(grower.id), "and the rest of the tree stays as it was")

        // The meetings list is a tree too.
        expansion.collapseAll(in: atlas.id)
        navigation.pendingBinderTab = .meetings
        try? await Task.sleep(for: .milliseconds(900))
        let meetingsShown = { OutlineEntry.items(in: meetingRows).map(\.id) }
        check(meetingsShown() == [kickoff.id] && meetingRows.contains { $0.id == OutlineEntry<MeetingRecord>.rowID(folder: research.id) },
              "meetings: closed, the one in Research is under its folder")
        check(press("folder:" + research.id.uuidString), "a folder in the meetings list is a button too")
        try? await Task.sleep(for: .milliseconds(600))
        check(Set(meetingsShown()) == [kickoff.id, sync.id] && navigation.folderID == research.id, "and opens in place")
        if let directory, let content = window.contentView { capture(content, name: "folders-tree-meetings", directory: directory) }

        // The sidebar's Collapse All.
        expansion.collapseEverything()
        check(expansion.binders.isEmpty && expansion.folders.isEmpty, "the sidebar's Collapse All closes every binder and folder")

        // Deleting the folder new things go in: they go where its things went.
        let shared = HubWindowController.shared.navigation
        let kept = (shared.selection, shared.binderID, shared.folderID)
        shared.selection = .binder
        shared.binderID = atlas.id
        shared.folderID = interviews.id
        FolderPrompts.shared.remove(interviews, undoManager: nil)
        check(shared.folderID == research.id && grower.folderID == research.id, "deleting the folder new notes go in sends them up a level")
        shared.selection = kept.0
        shared.binderID = kept.1
        shared.folderID = kept.2
    }
}
