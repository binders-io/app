import AppKit
import SwiftData
import SwiftUI
import BindersKit

extension SelfTest {
    /// Folders inside binders, in a throwaway folder (BINDERS_DATA_DIR): making, nesting, renaming and deleting one with
    /// things in it, moving each kind of item, several notes at once (into a folder, to a binder, dragged, deleted, each
    /// with one Undo), a template's folder, new notes, meetings and captures in the folder the window shows (lane RF3),
    /// several meetings and captures at once (lane RF3), ⌘O's folder paths, Tidy into Folders (the exact proposal, an
    /// unticked note, links that follow, Undo), search inside a folder, and the pages drawn to `directory` when one is
    /// given.
    @MainActor
    static func foldersSelfTest(drawingTo directory: URL?) async -> Int32 {
        guard AppPaths.isDemo else {
            print("ERROR: set BINDERS_DATA_DIR to an empty folder; this test makes binders, folders and notes")
            return 1
        }
        var failures = 0
        func check(_ passed: Bool, _ label: String) {
            print("\(passed ? "PASS" : "FAIL"): \(label)")
            if !passed { failures += 1 }
        }
        let store = Store.shared
        func note(_ text: String, in binder: BinderRecord, folder: UUID? = nil) -> NoteItem {
            let note = NoteItem(text: text)
            note.binderID = binder.id
            note.sharedWithTeam = binder.sharedWithTeam
            note.folderID = folder
            store.insert(note)
            return note
        }
        func meeting(_ title: String, in binder: BinderRecord, capture: Bool = false) -> MeetingRecord {
            let meeting = MeetingRecord(title: title, appName: capture ? "iPhone" : "Zoom", templateID: capture ? "conversation" : "general")
            if capture { meeting.kind = MeetingRecord.conversationKind }
            meeting.status = "ready"
            meeting.binderID = binder.id
            meeting.sharedWithTeam = binder.sharedWithTeam && !capture
            store.insert(meeting)
            return meeting
        }
        func undoManager() -> UndoManager {
            let manager = UndoManager()
            manager.groupsByEvent = false
            return manager
        }

        // Making and nesting.
        let work = BinderRecord(name: "Work", colorIndex: 1)
        store.insert(work)
        guard let devOps = store.createFolder(named: "  DevOps ", in: work.id) else {
            print("FOLDERS_FAILED: couldn't make a folder")
            return 1
        }
        check(devOps.name == "DevOps" && devOps.binderID == work.id && devOps.parentID == nil, "a folder is made at the top of its binder, its name tidied")
        check(store.createFolder(named: "devops", in: work.id)?.id == devOps.id, "one of that name there already is the one given back")
        let pipelines = store.createFolder(named: "Pipelines", in: work.id, parent: devOps.id)
        check(pipelines?.parentID == devOps.id && store.folderPath(pipelines?.id) == "DevOps/Pipelines", "a folder inside a folder: DevOps/Pipelines")
        let incidents = store.ensureFolder(path: ["Ops", "Incidents"], in: work.id)
        let ops = store.folder(incidents?.parentID)
        check(ops?.name == "Ops" && ops?.parentID == nil && store.folderPath(incidents?.id) == "Ops/Incidents", "a path makes every folder in it that's missing")
        check(store.ensureFolder(path: ["ops", "INCIDENTS"], in: work.id)?.id == incidents?.id, "and finds them again, ignoring case")
        check(store.createFolder(named: "Q3/Q4 plans", in: work.id)?.name == "Q3-Q4 plans", "a slash in a name becomes a dash")
        check(store.createFolder(named: "   ", in: work.id) == nil, "an empty name makes nothing")

        // Renaming.
        check(store.rename(devOps, to: "Platform") && store.folderPath(pipelines?.id) == "Platform/Pipelines", "a folder renamed: what's inside it follows")
        check(!store.rename(devOps, to: "   ") && devOps.name == "Platform", "an empty name isn't a rename")

        // Never into itself or one of its own folders.
        func refusal(_ move: () throws -> Void) -> FolderProblem? {
            do { try move(); return nil } catch { return error as? FolderProblem }
        }
        check(refusal { try store.move(devOps, into: devOps.id) } == .intoItself, "a folder can't go into itself")
        check(refusal { try store.move(devOps, into: pipelines?.id) } == .intoItself && devOps.parentID == nil, "nor into one of its own folders")
        let personal = BinderRecord(name: "Personal", colorIndex: 3)
        store.insert(personal)
        let elsewhere = store.createFolder(named: "Recipes", in: personal.id)
        check(refusal { try store.move(devOps, into: elsewhere?.id) } == .otherBinder, "nor into another binder")
        if let pipelines, let ops { check(refusal { try store.move(pipelines, into: ops.id) } == nil && pipelines.parentID == ops.id, "up and across is fine") }
        if let pipelines { try? store.move(pipelines, into: devOps.id) }

        // Moving each kind of item.
        let cleanup = note("# Pipeline cleanup\n\nOld runners go.", in: work)
        store.move(cleanup, toFolder: pipelines?.id)
        check(cleanup.folderID == pipelines?.id, "a note moves into a folder")
        store.move(cleanup, toFolder: nil)
        check(cleanup.folderID == nil, "and back to the top of its binder")
        let review = meeting("Platform review", in: work)
        check(refusal { try store.move(review, toFolder: devOps.id) } == nil && review.folderID == devOps.id, "a meeting moves into a folder")
        let chat = meeting("Hallway chat about runners", in: work, capture: true)
        check(refusal { try store.move(chat, toFolder: devOps.id) } == nil && chat.folderID == devOps.id && !chat.sharedWithTeam,
              "a capture moves into a folder, and stays unshared")
        let theirs = meeting("A teammate's sync", in: work)
        theirs.isTeamCopy = true
        theirs.teamAuthorName = "Dana"
        check(refusal { try store.move(theirs, toFolder: devOps.id) } == .teammatesMeeting("Dana") && theirs.folderID == nil, "a teammate's meeting is theirs to move")
        let soup = note("# Soup\n\nLeeks.", in: work)
        store.move(soup, toFolder: elsewhere?.id)
        check(soup.binderID == personal.id && soup.folderID == elsewhere?.id, "a note moved to a folder in another binder goes to that binder too")
        store.move(soup, to: work)
        check(soup.binderID == work.id && soup.folderID == nil, "moved to another binder, a note goes to its top")
        check(DraggedItem(DraggedItem.note(cleanup.id).string) == .note(cleanup.id) && DraggedItem(DraggedItem.folder(devOps.id).string) == .folder(devOps.id)
              && DraggedItem("Just some text dragged in") == nil, "what's dragged reads back, and text from elsewhere isn't taken for it")
        check(DraggedItem.drop([DraggedItem.note(cleanup.id).string], into: pipelines?.id, binder: work.id) && cleanup.folderID == pipelines?.id,
              "a note dropped on a folder goes into it")
        check(DraggedItem.drop([DraggedItem.meeting(review.id).string], into: nil, binder: work.id) && review.folderID == nil,
              "a meeting dropped on its binder goes to the top")
        check(!DraggedItem.drop([DraggedItem.folder(devOps.id).string], into: pipelines?.id, binder: work.id) && devOps.parentID == nil,
              "a folder dropped on one of its own folders stays where it was")
        if let ops { check(DraggedItem.drop([DraggedItem.folder(ops.id).string], into: devOps.id, binder: work.id) && ops.parentID == devOps.id, "a folder dropped on another goes in") }
        if let ops { try? store.move(ops, into: nil) }

        // Undo of a delete puts a note back in its folder.
        let draft = note("# Runner draft", in: work, folder: pipelines?.id)
        NoteTrash.shared.delete(draft, undoManager: nil)
        try? await Task.sleep(for: .milliseconds(100))
        let restored = NoteTrash.shared.last.flatMap { NoteTrash.shared.restore($0, undoManager: nil) }
        check(restored?.folderID == pipelines?.id, "a note deleted and put back is back in its folder")

        // Deleting a folder with things in it: they move up to where it was, and nothing is deleted.
        guard let crowded = store.createFolder(named: "Crowded", in: work.id, parent: devOps.id) else { return 1 }
        let inside = note("# Inside", in: work, folder: crowded.id)
        let insideMeeting = meeting("Crowded sync", in: work)
        try? store.move(insideMeeting, toFolder: crowded.id)
        let insideChat = meeting("Crowded hallway", in: work, capture: true)
        try? store.move(insideChat, toFolder: crowded.id)
        let nested = store.createFolder(named: "Nested", in: work.id, parent: crowded.id)
        let message = FolderPrompts.deleteMessage(crowded)
        check(message == "Its 1 note, 1 meeting, 1 capture and 1 folder move to Work › Platform. Nothing in it is deleted.", "asked first: \(message)")
        let manager = undoManager()
        manager.beginUndoGrouping()
        FolderPrompts.shared.remove(crowded, undoManager: manager)
        manager.endUndoGrouping()
        check(store.folder(crowded.id) == nil && inside.folderID == devOps.id && insideMeeting.folderID == devOps.id && insideChat.folderID == devOps.id
              && nested?.parentID == devOps.id && store.note(inside.id) != nil, "deleted, what it held moved up to Platform, and nothing went to the trash")
        manager.undo()
        check(store.folder(crowded.id)?.parentID == devOps.id && inside.folderID == crowded.id && insideMeeting.folderID == crowded.id
              && nested?.parentID == crowded.id, "Undo puts the folder back with what it held")
        let empty = store.createFolder(named: "Empty", in: work.id)
        if let empty { FolderPrompts.shared.delete(empty, undoManager: nil) }
        check(empty.map { store.folder($0.id) == nil } == true && FolderPrompts.shared.deleting == nil, "an empty folder goes without asking")
        FolderPrompts.shared.delete(crowded, undoManager: nil)
        check(FolderPrompts.shared.deleting == crowded.id && store.folder(crowded.id) != nil, "one with things in it asks first")
        FolderPrompts.shared.deleting = nil

        // ⌘N with a folder chosen: the new note goes in it.
        let navigation = HubWindowController.shared.navigation
        navigation.selection = .binder
        navigation.binderID = work.id
        navigation.folderID = pipelines?.id
        HubWindowController.shared.newNote(nil)
        check(navigation.pendingNoteID.flatMap { store.note($0) }?.folderID == pipelines?.id, "a new note goes in the folder chosen")
        navigation.folderID = nil

        // A template's folder.
        try? FileManager.default.createDirectory(at: TemplateStore.folder, withIntermediateDirectories: true)
        try? "---\nfolder: \"Social posts\"\n---\n# Social post · \n\nWhat it says".write(to: TemplateStore.folder.appendingPathComponent("Social post.md"),
                                                                                           atomically: true, encoding: .utf8)
        let social = TemplateStore.all.first { $0.name == "Social post" }
        check(social?.folder == "Social posts", "a template names a folder in its front matter")
        let post = social.map { TemplateStore.newNote(from: $0, in: work) }
        let posts = store.folder(post?.folderID)
        check(posts?.name == "Social posts" && posts?.parentID == nil && posts?.binderID == work.id && post?.text.hasPrefix("# Social post") == true
              && post?.text.contains("folder:") == false, "a note from it is filed there, the folder made as it was missing, and the front matter isn't in it")
        let again = social.map { TemplateStore.newNote(from: $0, in: work) }
        check(again?.folderID == posts?.id && store.folders(in: work.id).filter { $0.name == "Social posts" }.count == 1, "the next one goes in the same folder")
        let fromHere = TemplateStore.newNote(from: nil, in: work, folder: incidents?.id)
        check(fromHere.folderID == incidents?.id, "a blank note goes in the folder you're in")
        let reading = TemplateStore.all.first { $0.name == "Reading notes" }
        check(reading.map { TemplateStore.newNote(from: $0, in: work, folder: incidents?.id).folderID == incidents?.id } == true,
              "a template that names no folder goes where you are")
        let incident = note("# Incident review\n\n## What happened", in: work, folder: incidents?.id)
        let saved = TemplateStore.save(incident, folder: store.folderPath(incidents?.id))
        let savedFile = saved.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        check(savedFile.hasPrefix("---\nfolder: \"Ops/Incidents\"\n---\n# Incident review") && TemplateStore.all.first { $0.name == "Incident review" }?.folder == "Ops/Incidents",
              "a note saved as a template for its folder files its notes there")
        if let elsewhereTemplate = TemplateStore.all.first(where: { $0.name == "Incident review" }) {
            let made = TemplateStore.newNote(from: elsewhereTemplate, in: personal)
            check(store.folderPath(made.folderID) == "Ops/Incidents" && made.binderID == personal.id, "in another binder, it makes the folder there")
        }

        // Several notes at once (lane RF1): into a folder, to another binder, dragged, deleted, each with one Undo, and each
        // note keeping its own rules.
        let launch = BinderRecord(name: "Launch", colorIndex: 4)
        store.insert(launch)
        let team = BinderRecord(name: "Team plans", colorIndex: 2)
        team.sharedWithTeam = true
        store.insert(team)
        let chosen = (1...3).map { note("# Launch note \($0)", in: launch) }
        let spoken = note("# Said to myself: call the venue", in: launch)
        spoken.staysUnshared = true
        let teammates = note("# Dana's checklist", in: launch)
        teammates.isTeamCopy = true
        teammates.teamAuthorName = "Dana"
        let several = chosen + [spoken, teammates]
        guard let social = store.createFolder(named: "Social", in: launch.id) else { return 1 }
        let moves = undoManager()
        moves.beginUndoGrouping()
        let intoFolder = NoteMoves.move(several, toFolder: social.id, in: launch.id, undoManager: moves)
        moves.endUndoGrouping()
        check(intoFolder.moved.count == 5 && several.allSatisfy { $0.folderID == social.id }, "five notes go into a folder at once, a teammate's too, in its own binder")
        moves.undo()
        check(several.allSatisfy { $0.folderID == nil } && !moves.canUndo, "one Undo puts all five back")
        moves.redo()
        check(several.allSatisfy { $0.folderID == social.id }, "and Redo moves them again")
        moves.beginUndoGrouping()
        let toTeam = NoteMoves.move(several, to: team, undoManager: moves)
        moves.endUndoGrouping()
        check(toTeam.moved.count == 4 && toTeam.stayed.map(\.id) == [teammates.id] && teammates.binderID == launch.id
              && (toTeam.stayed.first?.why ?? "").contains("Dana"), "to another binder: four go, the teammate's note stays in theirs, and says why")
        check(chosen.allSatisfy { $0.binderID == team.id && $0.sharedWithTeam && $0.folderID == nil } && spoken.binderID == team.id && !spoken.sharedWithTeam,
              "each takes on the shared binder's sharing, but the one made from what you said stays unshared")
        moves.undo()
        check(chosen.allSatisfy { $0.binderID == launch.id && !$0.sharedWithTeam && $0.folderID == social.id } && spoken.folderID == social.id && !spoken.sharedWithTeam,
              "one Undo puts all four back in their binder, folder and sharing")
        let payload = DraggedItem.payload(chosen.map { .note($0.id) })
        check(payload.split(separator: "\n").count == 3 && payload.split(separator: "\n").allSatisfy { DraggedItem(String($0)) != nil },
              "several notes dragged together carry a line each")
        let drops = undoManager()
        drops.beginUndoGrouping()
        let dropped = DraggedItem.drop([payload], into: nil, binder: launch.id, undoManager: drops)
        drops.endUndoGrouping()
        check(dropped && chosen.allSatisfy { $0.folderID == nil }, "dropped on their binder, all three go to its top")
        drops.undo()
        check(chosen.allSatisfy { $0.folderID == social.id }, "and one Undo puts the drop back")
        let deletes = undoManager()
        deletes.beginUndoGrouping()
        NoteTrash.shared.delete(chosen, undoManager: deletes)
        deletes.endUndoGrouping()
        try? await Task.sleep(for: .milliseconds(150))
        check(chosen.allSatisfy { store.note($0.id) == nil } && NoteTrash.shared.lastDeleted.count == 3, "three deleted at once, said as three")
        deletes.undo()
        let back = chosen.compactMap { store.note($0.id) }
        check(back.count == 3 && back.allSatisfy { $0.folderID == social.id } && NoteTrash.shared.restoredNotes == Set(chosen.map(\.id)),
              "one Undo puts all three back, in their folder")

        // Lane RF3: new things in the folder you're in, several meetings and captures at once, and ⌘O's folder paths.
        await newThingsHereSelfTest(check: check)
        await severalMeetingsSelfTest(check: check, undoManager: undoManager)
        await switcherPlacesSelfTest(check: check, work: work, folder: pipelines, drawingTo: directory)

        await folderTreeSelfTest(check: check, drawingTo: directory)
        tidySelfTest(check: check, note: { note($0, in: $1) }, undoManager: undoManager)
        await folderSearchSelfTest(check: check, note: { note($0, in: $1, folder: $2) }, work: work, folder: pipelines)

        if let directory {
            await drawFolders(work: work, folder: pipelines, into: directory)
            await drawSeveralSelected(launch, folder: social, into: directory, check: check)
            await drawSeveralMeetings(into: directory, check: check)
        }
        print(failures == 0 ? "FOLDERS_OK" : "FOLDERS_FAILED: \(failures)")
        return failures == 0 ? 0 : 1
    }

    /// Tidy into Folders on a binder of prefixed titles: the exact proposal, an unticked note, a title another note has,
    /// links that follow, and one Undo for all of it.
    @MainActor
    private static func tidySelfTest(check: (Bool, String) -> Void, note: (String, BinderRecord) -> NoteItem, undoManager: () -> UndoManager) {
        let store = Store.shared
        let tidy = BinderRecord(name: "Tidy", colorIndex: 2)
        store.insert(tidy)
        let other = BinderRecord(name: "Elsewhere", colorIndex: 4)
        store.insert(other)
        let cleanup = note("# DevOps | Pipeline cleanup\n\nOld runners go.", tidy)
        let alerts = note("# DevOps | Alert rules\n\nPage on errors only.", tidy)
        let launch = note("# Social post · Launch week\n\nThe week we ship.", tidy)
        let hiring = note("# Social post · Hiring\n\nWe're hiring.", tidy)
        let report = note("# SRE report · March\n\nQuiet month.", tidy)
        let plan = note("# Q3 - plan", tidy)
        let q3Review = note("# Q3 - review", tidy)
        let standup = note("# 2026-10-02 - standup", tidy)
        let plain = note("# Plain note", tidy)
        // Another note already has one of the new titles; another links to the notes being tidied.
        _ = note("# Hiring\n\nThe hiring plan, in another binder.", other)
        let linking = note("# Launch notes\n\nSee [[Social post · Launch week]], and [[Social post · Launch week|the week]] again.", other)

        let proposals = FolderTidyRun.proposals(in: tidy.id)
        check(proposals.map(\.folderName) == ["DevOps", "Social post"], "the proposal: one folder per prefix two notes share: \(proposals.map(\.folderName))")
        check(proposals.first?.items.map(\.id) == [alerts.id, cleanup.id] && proposals.last?.items.map(\.id) == [hiring.id, launch.id],
              "with their notes: \(proposals.map { $0.items.map(\.newTitle) })")
        check(proposals.allSatisfy { $0.existingFolder == nil }, "both folders are new")
        let untouched = [report, plan, q3Review, standup, plain].map(\.id)
        check(!proposals.flatMap(\.items).contains { untouched.contains($0.id) }, "a prefix one note has, dates and quarters, and plain titles are left out")
        let before = store.allFolders().count
        check(store.allFolders().count == before && cleanup.title == "DevOps | Pipeline cleanup", "nothing changes before Apply")

        // Untick Pipeline cleanup.
        let chosen = proposals.map { proposal in
            FolderTidy.Proposal(key: proposal.key, folderName: proposal.folderName, existingFolder: proposal.existingFolder,
                                items: proposal.items.filter { $0.id != cleanup.id })
        }
        let items = chosen.flatMap(\.items)
        let keeping = FolderTidy.keepingTitles(items, taken: FolderTidyRun.takenTitles(besides: Set(items.map(\.id))))
        check(keeping == [hiring.id], "a note whose new title another note has keeps its title")
        let manager = undoManager()
        manager.beginUndoGrouping()
        let change = FolderTidyRun.apply(chosen, in: tidy.id, keeping: keeping, undoManager: manager)
        manager.endUndoGrouping()
        let devOps = store.folders(in: tidy.id).first { $0.name == "DevOps" }
        let social = store.folders(in: tidy.id).first { $0.name == "Social post" }
        check(change != nil && devOps != nil && social != nil && store.folders(in: tidy.id).count == 2, "Apply makes the two folders")
        check(alerts.folderID == devOps?.id && alerts.title == "Alert rules" && alerts.text == "# Alert rules\n\nPage on errors only.",
              "a ticked note moves in and loses its prefix: \(alerts.title)")
        check(cleanup.folderID == nil && cleanup.title == "DevOps | Pipeline cleanup", "an unticked note stays as it was")
        check(launch.folderID == social?.id && launch.title == "Launch week", "Social post · Launch week is Launch week, in Social post")
        check(hiring.folderID == social?.id && hiring.title == "Social post · Hiring", "the one whose new title is taken moves, and keeps its title")
        check(linking.text == "# Launch notes\n\nSee [[Launch week]], and [[Launch week|the week]] again.", "links follow the new title: \(linking.text)")
        check(change.map { FolderTidyRun.summary(of: $0, keeping: keeping.count) } == "Moved 3 notes into 2 folders. 1 kept its title, as another note has that title.",
              "it says what it did: \(change.map { FolderTidyRun.summary(of: $0, keeping: keeping.count) } ?? "")")

        // One Undo puts it all back.
        manager.undo()
        check(alerts.folderID == nil && launch.folderID == nil && hiring.folderID == nil && alerts.title == "DevOps | Alert rules"
              && launch.title == "Social post · Launch week", "Undo puts the titles and the notes back")
        check(linking.text == "# Launch notes\n\nSee [[Social post · Launch week]], and [[Social post · Launch week|the week]] again.", "and the links")
        check(store.folders(in: tidy.id).isEmpty, "and takes away the folders it made")
        manager.redo()
        check(store.folders(in: tidy.id).count == 2 && alerts.title == "Alert rules" && linking.text.contains("[[Launch week]]"), "Redo tidies again")

        // Two tidied notes, one linking to the other: Undo takes both back, the link included.
        let launchWork = BinderRecord(name: "Launch work", colorIndex: 6)
        store.insert(launchWork)
        let planNote = note("# Launch · Plan\n\nShip on the 28th.", launchWork)
        let retro = note("# Launch · Retro\n\nWe kept to [[Launch · Plan]].", launchWork)
        let crossManager = undoManager()
        crossManager.beginUndoGrouping()
        FolderTidyRun.apply(FolderTidyRun.proposals(in: launchWork.id), in: launchWork.id, keeping: [], undoManager: crossManager)
        crossManager.endUndoGrouping()
        check(planNote.title == "Plan" && retro.text == "# Retro\n\nWe kept to [[Plan]].", "a tidied note's link to another tidied note follows it: \(retro.text)")
        crossManager.undo()
        check(planNote.text == "# Launch · Plan\n\nShip on the 28th." && retro.text == "# Launch · Retro\n\nWe kept to [[Launch · Plan]].",
              "and Undo puts both back, the link too: \(retro.text)")

        // Next time, a prefix naming a folder that's there needs only one note.
        let more = note("# DevOps | On-call rota", tidy)
        let next = FolderTidyRun.proposals(in: tidy.id)
        check(next.count == 1 && next.first?.existingFolder == store.folders(in: tidy.id).first { $0.name == "DevOps" }?.id
              && Set(next.first?.items.map(\.id) ?? []) == [more.id, cleanup.id], "a prefix naming a folder already there goes into it, one note or more")
    }

    /// Search inside a folder keeps what's in it and in the folders inside it; results say where.
    @MainActor
    private static func folderSearchSelfTest(check: (Bool, String) -> Void, note: (String, BinderRecord, UUID?) -> NoteItem,
                                             work: BinderRecord, folder: FolderRecord?) async {
        let store = Store.shared
        guard let folder, let parent = store.folder(folder.parentID) else {
            check(false, "the folders to search in are there")
            return
        }
        let inside = note("# Zanzibarine runners\n\nThe zanzibarine pool needs new runners.", work, folder.id)
        let above = note("# Zanzibarine budget\n\nThe zanzibarine pool costs more.", work, parent.id)
        let outside = note("# Zanzibarine elsewhere\n\nA zanzibarine pool at the top.", work, nil)
        check(store.itemIDs(inFolder: parent.id).isSuperset(of: [inside.id.uuidString, above.id.uuidString])
              && !store.itemIDs(inFolder: parent.id).contains(outside.id.uuidString), "a folder's items include those in the folders inside it")
        check(store.folderNames(ofItem: inside.id) == ["Platform", "Pipelines"] && store.folderNames(ofItem: outside.id) == nil,
              "a result says the folder its item is in")
        let knowledge = KnowledgeService()
        await knowledge.indexNow()
        let all = await knowledge.search("zanzibarine", binder: work.id)
        let scoped = await knowledge.search("zanzibarine", binder: work.id, sources: store.itemIDs(inFolder: folder.id))
        check(Set(all.map(\.sourceID)).isSuperset(of: [inside.id.uuidString, above.id.uuidString, outside.id.uuidString]),
              "searching the binder finds all three (keyword index)")
        check(Set(scoped.map(\.sourceID)) == [inside.id.uuidString], "searching inside Pipelines finds only what's in it: \(scoped.map(\.title))")
    }

    /// The notes page with several notes selected, in the real window at its default size and at its smallest; then one
    /// note selected, and Select All (⌘A) from the Edit menu selects them all.
    @MainActor
    private static func drawSeveralSelected(_ binder: BinderRecord, folder: FolderRecord, into directory: URL,
                                            check: (Bool, String) -> Void) async {
        FitProbe.isOn = true
        defer { FitProbe.isOn = false }
        let controller = DictationController()
        let navigation = HubNavigation()
        navigation.selection = .binder
        navigation.binderID = binder.id
        navigation.folderID = folder.id
        navigation.pendingBinderTab = .notes
        let here = Store.shared.folders(in: binder.id).isEmpty ? [] : (try? Store.shared.context.fetch(FetchDescriptor<NoteItem>()))?
            .filter { $0.binderID == binder.id && $0.folderID == folder.id }.map(\.id) ?? []
        NotesView.selectOnOpen = Set(here.prefix(4))
        defer { NotesView.selectOnOpen = nil }
        let window = HubWindowController.makeWindow(HubView()
            .environment(controller).environment(controller.meetings).environment(controller.knowledge).environment(controller.team)
            .environment(controller.capture).environment(controller.commitments).environment(navigation).environment(AppSettings.shared)
            .modelContainer(Store.shared.container))
        window.alphaValue = 0
        window.orderFrontRegardless()
        try? await Task.sleep(for: .milliseconds(1800))
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let content = window.contentView { capture(content, name: "folders-several-1020", directory: directory) }
        window.setContentSize(HubWindowController.smallestSize)
        try? await Task.sleep(for: .milliseconds(900))
        if let content = window.contentView { capture(content, name: "folders-several-840", directory: directory) }
        check(!FitProbe.frames("notes.several", in: window).isEmpty, "with several selected, the page says how many and offers what to do with them")
        // One note, then Select All, as ⌘A sends it to the list.
        func tables(_ view: NSView) -> [NSTableView] { ((view as? NSTableView).map { [$0] } ?? []) + view.subviews.flatMap(tables) }
        navigation.pendingNoteID = here.first
        try? await Task.sleep(for: .milliseconds(700))
        check(FitProbe.frames("notes.several", in: window).isEmpty, "one note selected opens it, as before")
        if let list = window.contentView.map(tables)?.first {
            window.makeFirstResponder(list)
            NSApp.sendAction(#selector(NSText.selectAll(_:)), to: list, from: nil)
            try? await Task.sleep(for: .milliseconds(700))
            check(!FitProbe.frames("notes.several", in: window).isEmpty && list.selectedRowIndexes.count >= here.count,
                  "Select All (⌘A) in the list selects every note in it: \(list.selectedRowIndexes.count) rows")
        } else {
            check(false, "the notes list is there to select in")
        }
        window.close()
    }

    /// The sidebar with a binder's folders open and the binder page's tree open at one, drawn to `directory`.
    @MainActor
    private static func drawFolders(work: BinderRecord, folder: FolderRecord?, into directory: URL) async {
        let controller = DictationController()
        let navigation = HubNavigation()
        navigation.selection = .binder
        navigation.binderID = work.id
        // Shown from the sidebar: open in the tree, with the folders it's in.
        if let folder { navigation.show(folder: folder) }
        navigation.pendingBinderTab = .notes
        let hosting = NSHostingView(rootView: HubView()
            .environment(controller).environment(controller.meetings).environment(controller.knowledge).environment(controller.team)
            .environment(controller.capture).environment(controller.commitments).environment(navigation).environment(AppSettings.shared)
            .modelContainer(Store.shared.container))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1300, height: 820), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        hosting.wantsLayer = true
        window.contentView = hosting
        window.orderFrontRegardless()
        try? await Task.sleep(for: .milliseconds(1500))
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        capture(hosting, name: "folders-notes", directory: directory)
        navigation.pendingBinderTab = .meetings
        try? await Task.sleep(for: .milliseconds(800))
        capture(hosting, name: "folders-meetings", directory: directory)
        window.close()
        // The sidebar on its own, as the window's column draws blank offscreen: the binder open, with its folders.
        let sidebar = NSHostingView(rootView: HubSidebar()
            .environment(controller).environment(navigation).environment(AppSettings.shared)
            .modelContainer(Store.shared.container)
            .frame(width: 260, height: 820))
        let side = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 820), styleMask: [.titled], backing: .buffered, defer: false)
        side.isReleasedWhenClosed = false
        side.alphaValue = 0
        sidebar.wantsLayer = true
        side.contentView = sidebar
        side.orderFrontRegardless()
        try? await Task.sleep(for: .milliseconds(1000))
        capture(sidebar, name: "folders-sidebar", directory: directory)
        side.close()
        // Tidy into Folders' sheet, on the binder left with prefixed titles.
        if let tidy = Store.shared.binders().first(where: { $0.name == "Tidy" }) {
            let sheet = NSHostingView(rootView: TidyFoldersSheet(binder: tidy, undoManager: nil) { _ in })
            let tidyWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 480), styleMask: [.titled], backing: .buffered, defer: false)
            tidyWindow.isReleasedWhenClosed = false
            tidyWindow.alphaValue = 0
            sheet.wantsLayer = true
            tidyWindow.contentView = sheet
            tidyWindow.orderFrontRegardless()
            try? await Task.sleep(for: .milliseconds(800))
            capture(sheet, name: "folders-tidy", directory: directory)
            tidyWindow.close()
        }
        print("DRAWN: \(directory.path)")
    }
}
