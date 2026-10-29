import AppKit
import SwiftData
import SwiftUI
import BindersKit

// MARK: - Dragging

/// What's dragged onto a folder or a binder: a note, a meeting or capture, or a folder, by its id, as plain text with a
/// mark of its own, so text dragged in from elsewhere is never taken for one.
enum DraggedItem: Equatable {
    case note(UUID), meeting(UUID), folder(UUID)

    static let mark = "binders-item:"

    var string: String {
        switch self {
        case .note(let id): Self.mark + "note:" + id.uuidString
        case .meeting(let id): Self.mark + "meeting:" + id.uuidString
        case .folder(let id): Self.mark + "folder:" + id.uuidString
        }
    }

    init?(_ string: String) {
        guard string.hasPrefix(Self.mark) else { return nil }
        let parts = string.dropFirst(Self.mark.count).split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let id = UUID(uuidString: parts[1]) else { return nil }
        switch parts[0] {
        case "note": self = .note(id)
        case "meeting": self = .meeting(id)
        case "folder": self = .folder(id)
        default: return nil
        }
    }

    /// Several notes, meetings or captures dragged together, as one piece of text: a line each.
    static func payload(_ items: [DraggedItem]) -> String {
        items.map(\.string).joined(separator: "\n")
    }

    /// Moves what was dropped into `folder`, or to the top of `binderID` when it's nil. A note or meeting dropped on
    /// another binder goes there; a folder stays in its binder. Notes dropped together move as one, and so do meetings
    /// and captures: one Undo puts them back. Each keeps its own rules, and what stays says why. True when anything moved;
    /// a refusal beeps.
    @MainActor
    static func drop(_ strings: [String], into folder: UUID?, binder binderID: UUID, undoManager: UndoManager? = nil) -> Bool {
        let items = strings.flatMap { $0.split(separator: "\n").map(String.init) }.compactMap(DraggedItem.init)
        guard !items.isEmpty, Store.shared.allowsSave() else { return false }
        MarkdownEditor.flushAll()
        let store = Store.shared
        let undoManager = undoManager ?? HubWindowController.shared.undoManager
        var moved = false
        func refuse(_ why: String) {
            NSSound.beep()
            HubWindowController.shared.controller?.flowBar.toast(why, symbol: BindersTheme.problemSymbol, duration: 5)
        }
        let notes = items.compactMap { item -> NoteItem? in
            if case .note(let id) = item { return store.note(id) }
            return nil
        }
        let meetings = items.compactMap { item -> MeetingRecord? in
            if case .meeting(let id) = item { return store.meeting(id) }
            return nil
        }
        if let folder, store.folder(folder) == nil, !notes.isEmpty || !meetings.isEmpty {
            refuse(FolderProblem.gone.localizedDescription)
        } else {
            if !notes.isEmpty {
                let outcome = NoteMoves.move(notes, toFolder: folder, in: binderID, undoManager: undoManager)
                moved = !outcome.moved.isEmpty
                if let stayed = outcome.stayed.first { refuse(stayed.why) }
            }
            if !meetings.isEmpty {
                let outcome = MeetingMoves.move(meetings, toFolder: folder, in: binderID, undoManager: undoManager)
                moved = moved || !outcome.moved.isEmpty
                if let why = MeetingMoves.whyStayed(outcome.stayed) { refuse(why) }
            }
        }
        for item in items {
            guard case .folder = item else { continue }
            do {
                try FolderMoves.move(item, to: folder, in: binderID)
                moved = true
            } catch {
                refuse(error.localizedDescription)
            }
        }
        if moved {
            store.save()
            HubWindowController.shared.controller?.team.scheduleSync(after: 0.5)
        }
        return moved
    }
}

// MARK: - Moving one or several

/// What moving notes, meetings or captures did: the ones that moved, and the ones that stayed, with why.
struct MoveOutcome {
    struct Stay {
        let id: UUID
        let why: String
    }

    var moved: [UUID] = []
    var stayed: [Stay] = []

    /// What to say after moving `asked` of them to `place`: "Moved 4 notes to Work › DevOps." and why any stayed
    /// (`whyStayed`). Nil when the one asked for simply moved: the list shows that.
    func line(asked: Int, noun: (one: String, many: String), place: String, whyStayed: String?) -> String? {
        guard asked > 1 || !stayed.isEmpty else { return nil }
        var line = moved.isEmpty ? "" : "Moved \(moved.count == 1 ? "1 \(noun.one)" : "\(moved.count) \(noun.many)") to \(place)."
        if let whyStayed { line += (line.isEmpty ? "" : " ") + whyStayed }
        return line.isEmpty ? nil : line
    }
}

/// A note, meeting or capture, as moving it into a folder or to another binder sees it.
@MainActor
protocol FiledItem: AnyObject {
    var id: UUID { get }
    var binderID: UUID? { get set }
    var folderID: UUID? { get set }
    var sharedWithTeam: Bool { get set }
    var isTeamCopy: Bool { get }
    /// Into a folder (nil: the top of its binder), as one moved alone goes: a folder in another binder takes it there.
    func file(inFolder folder: UUID?)
    /// To the top of another binder, whose sharing it takes on as one moved alone does.
    func file(in binder: BinderRecord)
    /// The one with this id, while it's there.
    static func filed(_ id: UUID) -> Self?
}

extension NoteItem: FiledItem {
    @MainActor func file(inFolder folder: UUID?) { Store.shared.move(self, toFolder: folder) }
    @MainActor func file(in binder: BinderRecord) { Store.shared.move(self, to: binder) }
    @MainActor static func filed(_ id: UUID) -> NoteItem? { Store.shared.note(id) }
}

extension MeetingRecord: FiledItem {
    /// A teammate's never gets here: MeetingMoves keeps it where it is.
    @MainActor func file(inFolder folder: UUID?) { try? Store.shared.move(self, toFolder: folder) }
    @MainActor func file(in binder: BinderRecord) { Store.shared.move(self, to: binder) }
    @MainActor static func filed(_ id: UUID) -> MeetingRecord? { Store.shared.meeting(id) }
}

/// Moving notes, meetings or captures, one or several, into a folder or to another binder, as one change one Undo puts
/// back. Each keeps its own rules (`staysPut`, NoteMoves' and MeetingMoves'): those that can't go stay, with why, and the
/// rest move.
@MainActor
enum FiledMoves {
    /// Where one was, and whether it was shared: what Undo puts back.
    struct Place: Equatable {
        let id: UUID
        let binderID: UUID?
        let folderID: UUID?
        let shared: Bool

        @MainActor
        init(_ item: some FiledItem) {
            id = item.id
            binderID = item.binderID
            folderID = item.folderID
            shared = item.sharedWithTeam
        }
    }

    /// Into `folder`, or to the top of `binderID` when it's nil. A folder in another binder takes them there too, which
    /// then decides their sharing. `noun` names one and several for the Undo menu: ("Note", "Notes").
    static func move<Item: FiledItem>(_ items: [Item], toFolder folder: UUID?, in binderID: UUID, noun: (String, String), undoManager: UndoManager?,
                                      staysPut: (Item, UUID) -> String?) -> MoveOutcome {
        let store = Store.shared
        let destination = folder.flatMap { store.folder($0)?.binderID } ?? binderID
        var outcome = MoveOutcome()
        var before: [Place] = []
        for item in items {
            if let why = staysPut(item, destination) {
                outcome.stayed.append(.init(id: item.id, why: why))
                continue
            }
            let place = Place(item)
            if folder == nil, item.binderID != binderID, let binder = store.binder(binderID) { item.file(in: binder) }
            item.file(inFolder: folder)
            if Place(item) != place {
                before.append(place)
                outcome.moved.append(item.id)
            }
        }
        done(before, as: Item.self, noun: noun, undoManager: undoManager)
        return outcome
    }

    /// To the top of another binder, whose sharing each takes on as one moved alone does.
    static func move<Item: FiledItem>(_ items: [Item], to binder: BinderRecord, noun: (String, String), undoManager: UndoManager?,
                                      staysPut: (Item, UUID) -> String?) -> MoveOutcome {
        var outcome = MoveOutcome()
        var before: [Place] = []
        for item in items {
            if let why = staysPut(item, binder.id) {
                outcome.stayed.append(.init(id: item.id, why: why))
                continue
            }
            let place = Place(item)
            item.file(in: binder)
            if Place(item) != place {
                before.append(place)
                outcome.moved.append(item.id)
            }
        }
        done(before, as: Item.self, noun: noun, undoManager: undoManager)
        return outcome
    }

    private static func done<Item: FiledItem>(_ before: [Place], as type: Item.Type, noun: (String, String), undoManager: UndoManager?) {
        guard !before.isEmpty else { return }
        Store.shared.save()
        HubWindowController.shared.controller?.team.scheduleSync(after: 0.5)
        registerUndo(before, as: type, noun: noun, undoManager: undoManager)
    }

    /// Undo puts every one back where it was; Redo moves them again.
    private static func registerUndo<Item: FiledItem>(_ places: [Place], as type: Item.Type, noun: (String, String), undoManager: UndoManager?) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: Store.shared) { [weak undoManager] _ in
            let now = places.compactMap { Item.filed($0.id).map(Place.init) }
            put(places, as: type)
            FiledMoves.registerUndo(now, as: type, noun: noun, undoManager: undoManager)
        }
        undoManager.setActionName(places.count == 1 ? "Move \(noun.0)" : "Move \(noun.1)")
    }

    private static func put<Item: FiledItem>(_ places: [Place], as type: Item.Type) {
        for place in places {
            guard let item = Item.filed(place.id) else { continue }
            item.binderID = place.binderID
            item.folderID = Store.shared.shownFolder(place.folderID, in: place.binderID)
            if !item.isTeamCopy { item.sharedWithTeam = place.shared }
        }
        Store.shared.save()
        HubWindowController.shared.controller?.team.scheduleSync(after: 0.5)
    }
}

/// Moving notes, one or several, into a folder or to another binder (FiledMoves). Each keeps its own rules: a teammate's
/// note stays in its binder (any folder in it will do), and one made from what you said stays unshared wherever it goes.
/// One Undo puts the whole move back.
@MainActor
enum NoteMoves {
    /// What a move did: the notes it moved, and the ones that stayed, with why.
    typealias Outcome = MoveOutcome

    /// Into `folder`, or to the top of `binderID` when it's nil. A folder in another binder takes a note there too, which
    /// then decides its sharing.
    @discardableResult
    static func move(_ notes: [NoteItem], toFolder folder: UUID?, in binderID: UUID, undoManager: UndoManager?) -> Outcome {
        FiledMoves.move(notes, toFolder: folder, in: binderID, noun: ("Note", "Notes"), undoManager: undoManager, staysPut: staysPut)
    }

    /// To the top of another binder, whose sharing each takes on (one made from what you said stays unshared).
    @discardableResult
    static func move(_ notes: [NoteItem], to binder: BinderRecord, undoManager: UndoManager?) -> Outcome {
        FiledMoves.move(notes, to: binder, noun: ("Note", "Notes"), undoManager: undoManager, staysPut: staysPut)
    }

    /// Why a note can't go to `binderID`: a teammate's stays in theirs. Nil when it can.
    static func staysPut(_ note: NoteItem, going binderID: UUID) -> String? {
        guard note.isTeamCopy, note.binderID != binderID else { return nil }
        return "“\(note.title)” is \(note.teamAuthorName ?? "a teammate")'s, so it stays in their binder. Any folder in it will do."
    }
}

/// Moving meetings and captures, one or several, into a folder or to another binder (FiledMoves), each by the rules it
/// has moved alone: a teammate's is theirs to move, and one still recording stays in its binder until it stops (any
/// folder in it will do). A capture stays unshared wherever it goes, except in a binder shared through a team database,
/// where putting it yourself shares it with the team (Store.move). One Undo puts the whole move back.
@MainActor
enum MeetingMoves {
    /// Into `folder`, or to the top of `binderID` when it's nil. A folder in another binder takes them there too.
    @discardableResult
    static func move(_ meetings: [MeetingRecord], toFolder folder: UUID?, in binderID: UUID, undoManager: UndoManager?) -> MoveOutcome {
        FiledMoves.move(meetings, toFolder: folder, in: binderID, noun: undoNoun(meetings), undoManager: undoManager, staysPut: staysPut)
    }

    /// To the top of another binder, whose sharing each takes on as one moved alone does.
    @discardableResult
    static func move(_ meetings: [MeetingRecord], to binder: BinderRecord, undoManager: UndoManager?) -> MoveOutcome {
        FiledMoves.move(meetings, to: binder, noun: undoNoun(meetings), undoManager: undoManager, staysPut: staysPut)
    }

    /// Why one can't go to `binderID`; nil when it can.
    static func staysPut(_ meeting: MeetingRecord, going binderID: UUID) -> String? {
        if meeting.isTeamCopy {
            return "Only \(meeting.teamAuthorName ?? "the person who shared it") can move “\(meeting.title)”: it's theirs, shared with you."
        }
        if meeting.binderID != binderID, isRecording(meeting) {
            return "“\(meeting.title)” is still recording, so it stays in \(Store.shared.binder(meeting.binderID)?.name ?? "its binder") until it stops. Any folder in it will do."
        }
        return nil
    }

    /// Being recorded on this Mac now.
    static func isRecording(_ meeting: MeetingRecord) -> Bool {
        !meeting.isTeamCopy && (meeting.status == "recording" || HubWindowController.shared.controller?.meetings.recordingMeetingID == meeting.id)
    }

    /// Why the ones that stayed stayed, in a line: one's own reason, or teammates' together, naming them. Nil when none
    /// stayed.
    static func whyStayed(_ stayed: [MoveOutcome.Stay]) -> String? {
        guard stayed.count > 1 else { return stayed.first?.why }
        let theirs = stayed.compactMap { Store.shared.meeting($0.id) }.filter(\.isTeamCopy)
        guard theirs.count > 1 else { return stayed.map(\.why).joined(separator: " ") }
        let kind = theirs.allSatisfy(\.isConversation) ? "captures" : "meetings"
        let others = stayed.filter { stay in !theirs.contains { $0.id == stay.id } }.map(\.why)
        return (["\(titles(theirs)) are teammates' \(kind): only they can move them."] + others).joined(separator: " ")
    }

    /// What moving captures into a shared binder did to their sharing: the team has them now (a binder shared through a
    /// team database), or they stay on this Mac (one shared through a team folder). Nil when none of them is a capture,
    /// or the binder isn't shared.
    static func captureSharing(_ moved: [UUID], in binder: BinderRecord) -> String? {
        let captures = moved.compactMap { Store.shared.meeting($0) }.filter(\.isConversation)
        guard !captures.isEmpty else { return nil }
        let shared = captures.filter { TeamContent.current?.isShared($0) == true }.count
        if shared > 0 { return shared == 1 ? "Your team can read its notes and transcript now." : "Your team can read their notes and transcripts now." }
        guard binder.sharedWithTeam else { return nil }
        return captures.count == 1 ? "It stays on this Mac: captures aren't shared." : "They stay on this Mac: captures aren't shared."
    }

    /// "“Standup”, “Retro” and 2 more".
    static func titles(_ meetings: [MeetingRecord]) -> String {
        let named = meetings.prefix(meetings.count > 3 ? 2 : 3).map { "“\($0.title)”" }
        let rest = meetings.count - named.count
        if rest > 0 { return named.joined(separator: ", ") + " and \(rest) more" }
        return named.count > 1 ? named.dropLast().joined(separator: ", ") + " and " + named.last! : named.joined()
    }

    private static func undoNoun(_ meetings: [MeetingRecord]) -> (String, String) {
        !meetings.isEmpty && meetings.allSatisfy(\.isConversation) ? ("Capture", "Captures") : ("Meeting", "Meetings")
    }
}

/// Moving anything into a folder or to the top of a binder: what Move to… and dragging do.
@MainActor
enum FolderMoves {
    /// `folder` nil is the top of `binderID`.
    static func move(_ item: DraggedItem, to folder: UUID?, in binderID: UUID) throws {
        let store = Store.shared
        if let folder, store.folder(folder) == nil { throw FolderProblem.gone }
        switch item {
        case .note(let id):
            guard let note = store.note(id) else { return }
            if folder == nil, note.binderID != binderID, let binder = store.binder(binderID) { store.move(note, to: binder) }
            store.move(note, toFolder: folder)
        case .meeting(let id):
            guard let meeting = ((try? store.context.fetch(FetchDescriptor<MeetingRecord>(predicate: #Predicate { $0.id == id }))) ?? []).first else { return }
            if meeting.isTeamCopy { throw FolderProblem.teammatesMeeting(meeting.teamAuthorName ?? "the person who shared it") }
            if folder == nil, meeting.binderID != binderID, let binder = store.binder(binderID) { store.move(meeting, to: binder) }
            try store.move(meeting, toFolder: folder)
        case .folder(let id):
            guard let moving = store.folder(id) else { throw FolderProblem.gone }
            if folder == nil, moving.binderID != binderID { throw FolderProblem.otherBinder }
            try store.move(moving, into: folder)
        }
    }
}

extension View {
    /// Drags `item` onto a folder or a binder; nothing to drag when it's nil (a teammate's meeting, theirs to move).
    @ViewBuilder
    func draggableItem(_ item: DraggedItem?) -> some View {
        if let item { draggable(item.string) } else { self }
    }

    /// Drags several at once (`DraggedItem.payload`); nothing to drag when it's nil.
    @ViewBuilder
    func draggableItems(_ payload: String?) -> some View {
        if let payload { draggable(payload) } else { self }
    }
}

// MARK: - New, Rename, Delete

/// The folder dialogs, asked for from anywhere (the sidebar, a binder's lists, a folder's menu) and shown once, over the
/// Binders window (`folderPrompts()`).
@MainActor
@Observable
final class FolderPrompts {
    static let shared = FolderPrompts()

    /// A new folder: in which binder, inside which folder (nil: the top).
    var creating: (binderID: UUID, parent: UUID?)?
    var renaming: UUID?
    /// A folder with something in it, waiting for a yes.
    var deleting: UUID?
    var draft = ""
    /// The folder just made, for whoever asked to open or show it.
    private(set) var made: UUID?
    /// What to do with the folder once it's made, such as moving the notes you chose into it.
    @ObservationIgnored private var then: ((UUID) -> Void)?

    func create(in binderID: UUID, parent: UUID?, then: ((UUID) -> Void)? = nil) {
        guard Store.shared.allowsSave() else { return }
        draft = ""
        self.then = then
        creating = (binderID, parent)
    }

    func rename(_ folder: FolderRecord) {
        guard Store.shared.allowsSave() else { return }
        draft = folder.name
        renaming = folder.id
    }

    /// Asks first when it holds anything; an empty one goes at once, with Undo.
    func delete(_ folder: FolderRecord, undoManager: UndoManager?) {
        guard Store.shared.allowsSave() else { return }
        let held = Store.shared.contents(of: folder)
        if held.notes + held.meetings + held.captures + held.folders > 0 {
            deleting = folder.id
        } else {
            remove(folder, undoManager: undoManager)
        }
    }

    func finishCreating() {
        guard let creating, let made = Store.shared.createFolder(named: draft, in: creating.binderID, parent: creating.parent) else { return }
        self.made = made.id
        self.creating = nil
        // It shows where it was made: in the sidebar, and on its binder's page, open, where new things go now.
        let navigation = HubWindowController.shared.navigation
        if navigation.selection == .binder, navigation.binderID == made.binderID {
            navigation.show(folder: made)
        } else {
            FolderExpansion.shared.reveal(made.id, in: made.binderID)
        }
        HubWindowController.shared.controller?.team.scheduleSync(after: 0.5)
        let then = self.then
        self.then = nil
        then?(made.id)
    }

    func finishRenaming() {
        guard let id = renaming, let folder = Store.shared.folder(id) else { return }
        if Store.shared.rename(folder, to: draft) { HubWindowController.shared.controller?.team.scheduleSync(after: 0.5) }
        renaming = nil
    }

    func remove(_ folder: FolderRecord, undoManager: UndoManager?) {
        let navigation = HubWindowController.shared.navigation
        // New things went in it, or in a folder inside it: now they go where its things went.
        if let open = navigation.folderID, FolderTree.subtree(of: folder.id, in: Store.shared.folderNodes(in: folder.binderID)).contains(open) {
            navigation.folderID = Store.shared.shownFolder(folder.parentID, in: folder.binderID)
        }
        let removal = Store.shared.deleteFolder(folder)
        registerUndo(of: removal, undoManager: undoManager)
        HubWindowController.shared.controller?.team.scheduleSync(after: 0.5)
    }

    private func registerUndo(of removal: FolderRemoval, undoManager: UndoManager?) {
        undoManager?.registerUndo(withTarget: self) { [weak undoManager] prompts in
            Store.shared.restore(removal)
            HubWindowController.shared.controller?.team.scheduleSync(after: 0.5)
            undoManager?.registerUndo(withTarget: prompts) { [weak undoManager] prompts in
                if let folder = Store.shared.folder(removal.id) { prompts.remove(folder, undoManager: undoManager) }
            }
            undoManager?.setActionName("Delete Folder")
        }
        undoManager?.setActionName("Delete Folder")
    }

    /// "New Folder…" at the top of a binder; "New Folder in “Pipelines”…" with a folder chosen.
    static func newFolderTitle(in folder: UUID?) -> String {
        Store.shared.folder(folder).map { "New Folder in “\($0.name)”…" } ?? "New Folder…"
    }

    /// Where a new folder goes, or a deleted one's things: "Work", "Work › DevOps".
    static func place(binderID: UUID, folder: UUID?) -> String {
        ([Store.shared.binder(binderID)?.name ?? "the binder"] + Store.shared.folderNames(folder)).joined(separator: " › ")
    }

    /// "Its 3 notes, 1 meeting and 2 folders move to Work › Ops. Nothing in it is deleted."
    static func deleteMessage(_ folder: FolderRecord) -> String {
        let held = Store.shared.contents(of: folder)
        func count(_ n: Int, _ one: String, _ many: String) -> String? { n == 0 ? nil : n == 1 ? "1 \(one)" : "\(n) \(many)" }
        let parts = [count(held.notes, "note", "notes"), count(held.meetings, "meeting", "meetings"), count(held.captures, "capture", "captures"),
                     count(held.folders, "folder", "folders")].compactMap { $0 }
        let listed = parts.count > 1 ? parts.dropLast().joined(separator: ", ") + " and " + parts.last! : parts.first ?? "nothing"
        let to = place(binderID: folder.binderID, folder: Store.shared.shownFolder(folder.parentID, in: folder.binderID))
        return "Its \(listed) move to \(to). Nothing in it is deleted."
    }
}

extension View {
    /// The folder dialogs (FolderPrompts), once for the window.
    func folderPrompts() -> some View { modifier(FolderPromptsModifier()) }
}

private struct FolderPromptsModifier: ViewModifier {
    @Environment(\.undoManager) private var undoManager
    @State private var prompts = FolderPrompts.shared

    func body(content: Content) -> some View {
        @Bindable var prompts = prompts
        content
            .alert("New Folder", isPresented: Binding(get: { prompts.creating != nil }, set: { if !$0 { prompts.creating = nil } })) {
                TextField("Name", text: $prompts.draft)
                Button("Create") { prompts.finishCreating() }
                    .disabled(FolderTree.cleanName(prompts.draft) == nil)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(prompts.creating.map { "In \(FolderPrompts.place(binderID: $0.binderID, folder: $0.parent)). New notes made inside it go there." } ?? "")
            }
            .alert("Rename “\(prompts.renaming.flatMap { Store.shared.folder($0)?.name } ?? "")”",
                   isPresented: Binding(get: { prompts.renaming != nil }, set: { if !$0 { prompts.renaming = nil } })) {
                TextField("Name", text: $prompts.draft)
                Button("Rename") { prompts.finishRenaming() }
                    .disabled(FolderTree.cleanName(prompts.draft) == nil)
                Button("Cancel", role: .cancel) {}
            } message: {
                let shared = prompts.renaming.flatMap { Store.shared.folder($0) }.flatMap { Store.shared.binder($0.binderID) }
                    .map { $0.sharedWithTeam || $0.isTeamCopy } ?? false
                Text(shared ? "Teammates see the new name on their next sync." : "Only the name changes; everything in it stays put.")
            }
            .confirmationDialog("Delete “\(prompts.deleting.flatMap { Store.shared.folder($0)?.name } ?? "")”?",
                                isPresented: Binding(get: { prompts.deleting != nil }, set: { if !$0 { prompts.deleting = nil } })) {
                Button("Delete Folder", role: .destructive) {
                    if let id = prompts.deleting, let folder = Store.shared.folder(id) { prompts.remove(folder, undoManager: undoManager) }
                    prompts.deleting = nil
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(prompts.deleting.flatMap { Store.shared.folder($0) }.map(FolderPrompts.deleteMessage) ?? "")
            }
    }
}

// MARK: - Menus

/// A folder in a menu or the sidebar, with how deep it is.
struct FolderEntry: Identifiable {
    let node: FolderNode
    let depth: Int
    var id: UUID { node.id }
}

/// "Move to" entries: the top of the binder, then each folder in it, inside one another as in the sidebar. `current` is
/// where the item is (nil: the top); `excluding`, a folder being moved, which can't go into itself or its own folders.
struct MoveToFolderItems: View {
    let binderID: UUID
    let current: UUID?
    var excluding: UUID? = nil
    /// False for several items from different folders: none is checked, and any will do.
    var marksCurrent = true
    let move: (UUID?) -> Void

    var body: some View {
        let current: UUID? = marksCurrent ? self.current : UUID()
        let flat = FolderTree.flattened(Store.shared.folderNodes(in: binderID), excluding: excluding.map { [$0] } ?? [])
            .map { FolderEntry(node: $0.node, depth: $0.depth) }
        Button {
            move(nil)
        } label: {
            let top = "Top of \(Store.shared.binder(binderID)?.name ?? "the Binder")"
            if current == nil { Label(top, systemImage: "checkmark") } else { Text(top) }
        }
        .disabled(current == nil)
        if !flat.isEmpty { Divider() }
        ForEach(flat) { entry in
            Button {
                move(entry.node.id)
            } label: {
                let name = String(repeating: "    ", count: entry.depth) + entry.node.name
                if entry.node.id == current { Label(name, systemImage: "checkmark") } else { Text(name) }
            }
            .disabled(entry.node.id == current)
        }
    }
}

/// What a folder's menu offers, in the sidebar and in a binder's lists.
struct FolderContextItems: View {
    let folder: FolderRecord
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        Button("New Folder Inside…") { FolderPrompts.shared.create(in: folder.binderID, parent: folder.id) }
        Button("Rename…") { FolderPrompts.shared.rename(folder) }
        Menu("Move to") {
            MoveToFolderItems(binderID: folder.binderID, current: Store.shared.shownFolder(folder.parentID, in: folder.binderID),
                              excluding: folder.id) { target in
                do {
                    try FolderMoves.move(.folder(folder.id), to: target, in: folder.binderID)
                    HubWindowController.shared.controller?.team.scheduleSync(after: 0.5)
                } catch {
                    NSSound.beep()
                }
            }
        }
        Divider()
        Button("Delete Folder…", role: .destructive) { FolderPrompts.shared.delete(folder, undoManager: undoManager) }
    }
}
