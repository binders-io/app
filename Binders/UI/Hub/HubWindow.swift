import AppKit
import SwiftData
import SwiftUI
import BindersKit

enum HubSection: String, CaseIterable, Identifiable {
    case home, today, work, agents, binder, writing, knowledge, dictionary, snippets, style, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Home"
        case .today: "Today"
        case .work: "Work"
        case .agents: "Agents"
        case .binder: "Binder"
        case .writing: "Writing"
        case .knowledge: "Knowledge"
        case .dictionary: "Dictionary"
        case .snippets: "Snippets"
        case .style: "Style"
        case .settings: "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .home: "house"
        case .today: "sun.max"
        case .work: "rectangle.split.3x1"
        case .agents: "wand.and.stars"
        case .binder: "books.vertical"
        case .writing: "pencil.line"
        case .knowledge: "point.3.connected.trianglepath.dotted"
        case .dictionary: "book.closed"
        case .snippets: "text.badge.plus"
        case .style: "paintbrush"
        case .settings: "gearshape"
        }
    }
}

@MainActor
@Observable
final class HubNavigation {
    var selection: HubSection? = .home
    /// The binder the binder page shows. Another binder starts at its top.
    var binderID: UUID? {
        didSet { if binderID != oldValue { folderID = nil } }
    }
    /// The folder in it the binder page is in; nil at its top. Set after the binder.
    var folderID: UUID?
    /// Tidy into Folders, asked for from the sidebar: the binder page opens its sheet.
    var pendingTidy = false
    /// Deep links from search results and spoken answers, consumed by the destination page.
    var pendingBinderTab: BinderTab?
    var pendingMeetingID: UUID?
    var pendingNoteID: UUID?
    /// The pending note was just made: its editor takes the cursor.
    var pendingNoteIsNew = false
    /// A heading, or "^" and a block's id, to show in the pending note: where a link to it points.
    var pendingNotePlace: String?
    /// A card's words to show and flash in the pending note, in `pendingNotePlace`'s section (lane DS4).
    var pendingNoteQuote: String?
    /// Cards to select on the board as it opens (lane DS5): a note's work, from its Work panel's Select on Board.
    var pendingBoardSelection: Set<UUID>?
    /// The note open on the Notes page, for the Note menu.
    var currentNoteID: UUID?
    var pendingHistorySearch: String?
    var pendingWritingSearch: String?
    var pendingKnowledgeQuery: String?
    /// A person, project or topic to show in Knowledge.
    var pendingEntityID: Int64?
    /// The Settings page to open next, consumed by Settings when it appears.
    var pendingSettingsPage: SettingsPage?
    /// The quick switcher, when it's open: ⌘O to find, ⌘P for commands.
    var switcher: SwitcherMode?
    /// What to type into the switcher as it opens, such as a #tag.
    var switcherQuery: String?

    /// The folder the binder page shows for `binderID`: where a new note, meeting or capture made for that binder goes.
    /// Nil, the top, when the page isn't on that binder or shows none of its folders.
    func folderShown(for binderID: UUID?) -> UUID? {
        guard selection == .binder, let binderID, self.binderID == binderID else { return nil }
        return Store.shared.shownFolder(folderID, in: binderID)
    }
}

@MainActor
final class HubWindowController: NSObject, NSWindowDelegate, NSMenuItemValidation {
    static let shared = HubWindowController()

    var controller: DictationController?
    let navigation = HubNavigation()
    private var window: NSWindow?

    /// Whether the Binders window is open.
    var isOpen: Bool { window != nil }

    /// The Binders window's Undo, for changes made by dropping things onto its folders and binders.
    var undoManager: UndoManager? { window?.undoManager }

    /// The Binders window while it's visible, not minimised and on the Space you're in: what a card opens over.
    var visibleWindow: NSWindow? {
        guard let window, window.isVisible, !window.isMiniaturized, window.isOnActiveSpace else { return nil }
        return window
    }

    func show(section: HubSection? = nil) {
        guard let controller else { return }
        if let section { navigation.selection = section }
        if window == nil {
            let root = HubView()
                .environment(controller)
                .environment(controller.meetings)
                .environment(controller.knowledge)
                .environment(controller.team)
                .environment(controller.capture)
                .environment(controller.commitments)
                .environment(navigation)
                .environment(AppSettings.shared)
                .modelContainer(Store.shared.container)
            let window = Self.makeWindow(root)
            window.center()
            window.setFrameAutosaveName(AppDefaults.frameName("BindersHub"))
            // A window an earlier build stretched past the screen to fit a page comes back on it.
            Self.keepOnScreen(window)
            window.delegate = self
            self.window = window
        }
        NSApp.setActivationPolicy(.regular)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// The window's default size, and the smallest you can make it: every page fits from there up.
    static let defaultSize = NSSize(width: 1020, height: 720)
    static let smallestSize = NSSize(width: 840, height: 560)

    /// The Binders window, with `root` (its pages) as its content. The page fits the window, not the window the page: the
    /// hosting view doesn't size the window to what a page holds, so a long note, a long folder path or a page's row of
    /// controls never stretches the window past the screen. The window-fit self-test makes its windows here too.
    static func makeWindow<Content: View>(_ root: Content, size: NSSize = defaultSize) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "Binders"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.contentMinSize = smallestSize
        // The ground shows through the title bar, which floats over the page.
        window.backgroundColor = BindersTheme.NS.ground
        let hosting = NSHostingView(rootView: root)
        // Its size is the window's, which only you change: not its pages' smallest (which grew the window to fit a note's
        // controls), ideal or largest.
        hosting.sizingOptions = []
        window.contentView = hosting
        return window
    }

    /// A window wider or taller than the screen it's mostly on, as an earlier build could leave its saved frame, made to fit
    /// that screen and put on it. Any other window stays exactly where you left it, on whichever screen.
    static func keepOnScreen(_ window: NSWindow) {
        let frame = window.frame
        func overlap(_ screen: NSScreen) -> CGFloat {
            let shared = screen.visibleFrame.intersection(frame)
            return shared.isNull ? 0 : shared.width * shared.height
        }
        let screen = NSScreen.screens.filter { overlap($0) > 0 }.max { overlap($0) < overlap($1) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame, frame.width > visible.width || frame.height > visible.height else { return }
        var fitted = frame
        fitted.size.width = min(frame.width, visible.width)
        fitted.size.height = min(frame.height, visible.height)
        fitted.origin.x = min(max(frame.minX, visible.minX), visible.maxX - fitted.width)
        fitted.origin.y = min(max(frame.minY, visible.minY), visible.maxY - fitted.height)
        window.setFrame(fitted, display: false)
    }

    /// ⌘N: a new note in the binder that's open (or the current one), in the folder you're in, on the Notes page, ready
    /// to type in.
    @objc func newNote(_ sender: Any?) {
        guard Store.shared.allowsSave() else { return }
        let binderID = navigation.selection == .binder ? navigation.binderID : nil
        let binder = Store.shared.binder(binderID ?? AppSettings.shared.currentBinderID) ?? Store.shared.defaultBinder()
        let note = TemplateStore.newNote(from: nil, in: binder, folder: navigation.folderShown(for: binder.id))
        navigation.binderID = binder.id
        navigation.pendingBinderTab = .notes
        navigation.pendingNoteIsNew = true
        navigation.pendingNoteID = note.id
        show(section: .binder)
    }

    /// The note the Note menu acts on: the pop-out in front, or the one open on the Notes page.
    private var noteInFront: (id: UUID, inPopout: Bool)? {
        if let key = NSApp.keyWindow, let id = key.identifier.flatMap({ UUID(uuidString: $0.rawValue) }), NotePopouts.shared.isOpen(id) {
            return (id, true)
        }
        if let id = navigation.currentNoteID, window?.isVisible == true, navigation.selection == .binder { return (id, false) }
        return nil
    }

    @objc func popOutNote(_ sender: Any?) {
        guard let (id, inPopout) = noteInFront, !inPopout, let note = Store.shared.note(id) else { return }
        NotePopouts.shared.open(note)
    }

    @objc func foldIntoBubble(_ sender: Any?) {
        guard let (id, inPopout) = noteInFront else { return }
        if inPopout {
            NotePopouts.shared.collapse(id)
        } else if let note = Store.shared.note(id) {
            NotePopouts.shared.open(note, collapsed: true)
        }
    }

    /// Put on Board (lane DS6): the words selected in the note being edited, or the note in front as a whole.
    @objc func putOnBoard(_ sender: Any?) {
        if let editor = NSApp.keyWindow?.firstResponder as? MarkdownTextView, editor.putOnBoardFromMenu() { return }
        guard let (id, inPopout) = noteInFront else { return }
        NotificationCenter.default.post(name: NotePutOnBoard.wholeNote, object: nil, userInfo: ["note": id, "popout": inPopout])
    }

    @objc func toggleDigest(_ sender: Any?) {
        let defaults = AppDefaults.store
        defaults.set(!(defaults.object(forKey: "notesShowDigest") as? Bool ?? true), forKey: "notesShowDigest")
    }

    @objc func zoomIn(_ sender: Any?) { TextZoom.step(0.1) }
    @objc func zoomOut(_ sender: Any?) { TextZoom.step(-0.1) }
    @objc func actualSize(_ sender: Any?) { TextZoom.reset() }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(popOutNote(_:)):
            return noteInFront.map { !$0.inPopout } ?? false
        case #selector(foldIntoBubble(_:)):
            return noteInFront != nil
        case #selector(putOnBoard(_:)):
            if let editor = NSApp.keyWindow?.firstResponder as? MarkdownTextView, editor.putOnBoard != nil {
                item.title = editor.selectedRange().length > 0 ? "Put Selection on Board" : "Put on Board"
                return true
            }
            item.title = "Put on Board"
            return noteInFront != nil
        case #selector(toggleDigest(_:)):
            item.title = (AppDefaults.store.object(forKey: "notesShowDigest") as? Bool ?? true) ? "Hide Digest" : "Show Digest"
            return true
        case #selector(zoomIn(_:)):
            return TextZoom.level < TextZoom.range.upperBound
        case #selector(zoomOut(_:)):
            return TextZoom.level > TextZoom.range.lowerBound
        default:
            return true
        }
    }

    /// ⌥⌘N: a new note in a small window of its own, in the current binder, in the folder the Binders window shows for it.
    @objc func newNoteWindow(_ sender: Any?) {
        guard Store.shared.allowsSave() else { return }
        let binder = Store.shared.binder(AppSettings.shared.currentBinderID) ?? Store.shared.defaultBinder()
        NotePopouts.shared.open(TemplateStore.newNote(from: nil, in: binder, folder: navigation.folderShown(for: binder.id)))
    }

    /// ⌘O and ⌘P, from the Go menu: opens the window if needed, and the switcher; the same keys again close it.
    @objc func openQuickly(_ sender: Any?) { toggleSwitcher(.open) }
    @objc func openCommandPalette(_ sender: Any?) { toggleSwitcher(.commands) }

    private func toggleSwitcher(_ mode: SwitcherMode) {
        show()
        navigation.switcher = navigation.switcher == mode ? nil : mode
    }

    func windowWillClose(_ notification: Notification) {
        // A card still open keeps Binders in the Dock and in ⌘Tab until it closes too.
        if !CardWindows.shared.hasOpenWindows { NSApp.setActivationPolicy(.accessory) }
        // The views go with the window. Kept alive, they would carry on observing, polling and rendering unseen.
        window?.contentView = nil
        window = nil
    }
}

struct HubView: View {
    @Environment(HubNavigation.self) private var navigation

    var body: some View {
        NavigationSplitView {
            HubSidebar()
                .fitProbe("sidebar")
                .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 290)
        } detail: {
            detail
                .safeAreaInset(edge: .top, spacing: 0) {
                    if Store.shared.isFallback { LibraryUnavailableBanner() }
                }
                .pageGround()
                .fitProbe("page")
        }
        .overlay(alignment: .top) {
            if let mode = navigation.switcher {
                ZStack(alignment: .top) {
                    Color.black.opacity(0.12)
                        .ignoresSafeArea()
                        .onTapGesture { navigation.switcher = nil }
                    QuickSwitcher(mode: mode, query: navigation.switcherQuery ?? "")
                        .id(mode)
                        .onAppear { navigation.switcherQuery = nil }
                        .padding(.top, 64)
                }
            }
        }
        .folderPrompts()
    }

    @ViewBuilder
    private var detail: some View {
        switch navigation.selection ?? .home {
        case .home: HomeView()
        case .today: TodayView()
        case .work: WorkView()
        case .agents: AgentsView()
        case .binder: BinderPage(binderID: navigation.binderID).id(navigation.binderID)
        case .writing: WritingView()
        case .knowledge: KnowledgeView()
        case .dictionary: DictionaryView()
        case .snippets: SnippetsView()
        case .style: StyleView()
        case .settings: SettingsView()
        }
    }
}

/// While the library didn't open: an amber strip above every page, as it needs you, with the problem style's glyph and
/// what to do. Nothing new is kept until Binders is reopened, and a save you ask for says so instead.
struct LibraryUnavailableBanner: View {
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: BindersTheme.problemSymbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
            Text(Store.unavailableMessage)
                .font(.callout.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Link("Learn More", destination: Store.unavailableHelp)
                .font(.callout)
                .foregroundStyle(.tintText)
            Button("Quit Binders") { NSApp.terminate(nil) }
                .controlSize(.small)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Its own strip under the title bar, not tinting the bar too.
        .background(BindersTheme.needsYou.opacity(0.14), ignoresSafeAreaEdges: [])
        .overlay(alignment: .bottom) { BindersTheme.needsYou.opacity(0.4).frame(height: 1) }
    }
}

/// The binder's spine: the brand at the top, the sections grouped by what they hold, and what the app is doing at
/// the bottom. Quiet by design: the second ground, a shade off the page's, with the indigo kept for the icon and the
/// selection.
struct HubSidebar: View {
    @Environment(HubNavigation.self) private var navigation
    @Environment(DictationController.self) private var controller
    @Environment(AppSettings.self) private var settings
    @Environment(\.colorScheme) private var colorScheme
    @Query private var allBinders: [BinderRecord]
    @Query private var allFolders: [FolderRecord]
    @State private var hovered: HubSection?
    @State private var hoveredBinder: UUID?
    /// Binders and folders shown open, with their folders under them; all closed at first.
    @State private var openBinders: Set<UUID> = []
    @State private var openFolders: Set<UUID> = []
    /// What a drag is over: a binder's row, or a folder's.
    @State private var dropTarget: UUID?
    @State private var creating = false
    @State private var newName = ""
    @State private var showArchived = false
    @State private var renamingBinder: BinderRecord?
    @State private var renameDraft = ""
    @Environment(\.undoManager) private var undoManager

    private var binders: [BinderRecord] {
        allBinders.filter { showArchived || !$0.archived }.sorted { a, b in
            if a.isDefault != b.isDefault { return a.isDefault }
            if a.isTeamCopy != b.isTeamCopy { return !a.isTeamCopy }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }
    private var archivedCount: Int { allBinders.filter(\.archived).count }

    private var dark: Bool { colorScheme == .dark }
    private var edge: Color { BindersTheme.line }
    private var ink: Color { BindersTheme.ink }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 48, height: 48)
                    .shadow(color: .black.opacity(dark ? 0.35 : 0.18), radius: 8, y: 4)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Binders")
                        .font(.system(size: 20, weight: .heavy, design: .rounded))
                        .foregroundStyle(ink)
                    Text("Private, on this Mac.")
                        .font(.caption)
                        .foregroundStyle(BindersTheme.muted)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 44)
            .padding(.bottom, 14)
            Button { navigation.switcher = .open } label: {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .medium))
                    Text("Jump to…").font(.system(size: 13))
                    Spacer(minLength: 0)
                    Text("⌘O").font(.system(size: 11, weight: .medium)).foregroundStyle(ink.opacity(0.4))
                }
                .foregroundStyle(ink.opacity(0.6))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(edge))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Jump to any binder, note, meeting, card or person (⌘O). ⌘P runs a command.")
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    row(.home)
                    row(.today)
                    row(.work)
                    row(.agents)
                    groupLabel("Binders")
                    ForEach(binders) { binder in
                        binderRow(binder)
                        if openBinders.contains(binder.id) { folderRows(binder) }
                    }
                    Button {
                        guard Store.shared.allowsSave() else { return }
                        newName = ""
                        creating = true
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "plus").font(.system(size: 12, weight: .semibold)).frame(width: 20)
                            Text("New binder…").font(.system(size: 13))
                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(ink.opacity(0.55))
                        .padding(.vertical, 5)
                        .padding(.horizontal, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if archivedCount > 0 {
                        Button {
                            showArchived.toggle()
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: showArchived ? "archivebox.fill" : "archivebox").font(.system(size: 12)).frame(width: 20)
                                Text(showArchived ? "Hide archived" : "Archived (\(archivedCount))").font(.system(size: 12.5))
                                Spacer(minLength: 0)
                            }
                            .foregroundStyle(ink.opacity(0.45))
                            .padding(.vertical, 4)
                            .padding(.horizontal, 10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer().frame(height: 12)
                    row(.writing)
                    row(.knowledge)
                    group("Dictation", [.dictionary, .snippets, .style])
                }
                .padding(.horizontal, 12)
            }
            .scrollIndicators(.hidden)
            .alert("New binder", isPresented: $creating) {
                TextField("Name", text: $newName)
                Button("Create") { createBinder() }
                    .disabled(newName.trimmed.isEmpty)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("A binder holds the meetings and notes for one thing you're working on. Share it with the team as a whole, or keep it to yourself.")
            }
            .alert("Rename “\(renamingBinder?.name ?? "")”", isPresented: Binding(get: { renamingBinder != nil }, set: { if !$0 { renamingBinder = nil } }),
                   presenting: renamingBinder) { binder in
                TextField("Name", text: $renameDraft)
                Button("Rename") {
                    let name = renameDraft.trimmed
                    guard !name.isEmpty else { return }
                    let old = binder.name
                    binder.name = name
                    binder.updatedAt = Date()
                    Store.shared.save()
                    LinkTargets.renameLinks(from: old, to: name)
                }
                .disabled(renameDraft.trimmed.isEmpty)
                Button("Cancel", role: .cancel) {}
            } message: { binder in
                Text(binder.sharedWithTeam ? "Teammates see the new name on their next sync." : "Only the name changes; everything in the binder stays put.")
            }
            Spacer(minLength: 8)
            row(.settings).padding(.horizontal, 12)
            status
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(BindersTheme.ground2)
        .overlay(alignment: .trailing) { edge.frame(width: 1) }
        .toolbar(removing: .sidebarToggle)
        // The folder you're in shows in the sidebar, its binder and the folders around it open.
        .onChange(of: navigation.folderID, initial: true) { _, folder in reveal(folder) }
        .onChange(of: FolderPrompts.shared.made) { _, made in reveal(Store.shared.folder(made)?.parentID, binder: Store.shared.folder(made)?.binderID) }
    }

    /// Opens a folder's binder and the folders it's in, so it shows.
    private func reveal(_ folder: UUID?, binder: UUID? = nil) {
        guard let binderID = binder ?? Store.shared.folder(folder)?.binderID else { return }
        openBinders.insert(binderID)
        let nodes = Store.shared.folderNodes(in: binderID)
        for ancestor in FolderTree.chain(to: folder, in: FolderTree.index(nodes)).dropLast() { openFolders.insert(ancestor.id) }
        if binder != nil, let folder { openFolders.insert(folder) }
    }

    @ViewBuilder
    private func group(_ name: String, _ sections: [HubSection]) -> some View {
        groupLabel(name)
        ForEach(sections) { row($0) }
    }

    private func groupLabel(_ name: String) -> some View {
        Text(name.uppercased())
            .font(.system(size: 10.5, weight: .semibold))
            .tracking(0.9)
            .foregroundStyle(ink.opacity(0.42))
            .padding(.leading, 10)
            .padding(.top, 18)
            .padding(.bottom, 5)
    }

    private func createBinder() {
        let name = newName.trimmed
        guard !name.isEmpty, Store.shared.allowsSave() else { return }
        let used = Set(allBinders.map(\.colorIndex))
        let binder = BinderRecord(name: name, colorIndex: (0..<BinderRecord.paletteSize).first { !used.contains($0) } ?? allBinders.count % BinderRecord.paletteSize)
        Store.shared.insert(binder)
        navigation.binderID = binder.id
        navigation.selection = .binder
        settings.currentBinderID = binder.id
    }

    private func binderRow(_ binder: BinderRecord) -> some View {
        let here = navigation.selection == .binder && navigation.binderID == binder.id
        // Inside one of its folders, the folder's row is the one selected; one that has gone counts as the top.
        let selected = here && Store.shared.shownFolder(navigation.folderID, in: binder.id) == nil
        let hasFolders = allFolders.contains { $0.binderID == binder.id }
        return HStack(spacing: 0) {
            Button {
                navigation.binderID = binder.id
                navigation.folderID = nil
                navigation.selection = .binder
                settings.currentBinderID = binder.id
            } label: {
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(BinderPalette.color(binder.colorIndex))
                        .frame(width: 10, height: 14)
                        .frame(width: 20)
                    Text(binder.name)
                        .font(.system(size: 13.5, weight: here ? .semibold : .regular))
                        .foregroundStyle(ink.opacity(here ? 1 : (binder.archived ? 0.5 : 0.82)))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if binder.isTeamCopy || binder.sharedWithTeam {
                        Image(systemName: binder.isTeamCopy ? "person.2.fill" : "person.2")
                            .font(.system(size: 10))
                            .foregroundStyle(ink.opacity(0.45))
                            .help(binder.isTeamCopy ? "Shared by \(binder.teamAuthorName ?? "a teammate")" : "Shared with the team")
                    }
                }
                .padding(.vertical, 6)
                .padding(.leading, 10)
                .padding(.trailing, hasFolders ? 2 : 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if hasFolders {
                disclosure(openBinders.contains(binder.id), name: binder.name) { toggle(binder.id, in: &openBinders) }
                    .padding(.trailing, 6)
            }
        }
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(rowFill(selected: selected, hovered: hoveredBinder == binder.id, dropping: dropTarget == binder.id)))
        .onHover { inside in
            if inside { hoveredBinder = binder.id } else if hoveredBinder == binder.id { hoveredBinder = nil }
        }
        // A note, meeting or folder dropped here goes to the top of the binder.
        .dropDestination(for: String.self) { items, _ in
            DraggedItem.drop(items, into: nil, binder: binder.id, undoManager: undoManager)
        } isTargeted: { inside in
            if inside { dropTarget = binder.id } else if dropTarget == binder.id { dropTarget = nil }
        }
        .contextMenu {
            Button("New Folder…") { FolderPrompts.shared.create(in: binder.id, parent: nil) }
            if !binder.isTeamCopy {
                Button("Tidy into Folders…") {
                    guard Store.shared.allowsSave() else { return }
                    navigation.binderID = binder.id
                    navigation.folderID = nil
                    navigation.selection = .binder
                    navigation.pendingTidy = true
                }
                Divider()
                Button("Rename…") {
                    guard Store.shared.allowsSave() else { return }
                    renameDraft = binder.name
                    renamingBinder = binder
                }
                if !binder.isDefault {
                    Button(binder.archived ? "Unarchive" : "Archive") {
                        binder.archived.toggle()
                        binder.updatedAt = Date()
                    }
                }
            }
        }
    }

    /// A binder's folders under it, each folder's under it once it's open: indented, collapsed at first.
    @ViewBuilder
    private func folderRows(_ binder: BinderRecord) -> some View {
        let records = allFolders.filter { $0.binderID == binder.id }
        let nodes = FolderTree.untangled(records.map(\.node))
        let parents = Set(nodes.compactMap(\.parentID))
        ForEach(visibleFolders(nodes)) { entry in
            if let folder = records.first(where: { $0.id == entry.id }) {
                folderRow(folder, binder: binder, depth: entry.depth, hasFolders: parents.contains(folder.id))
            }
        }
    }

    private func visibleFolders(_ nodes: [FolderNode]) -> [FolderEntry] {
        var rows: [FolderEntry] = []
        func walk(_ parent: UUID?, depth: Int) {
            for child in FolderTree.children(of: parent, in: nodes) {
                rows.append(FolderEntry(node: child, depth: depth))
                if openFolders.contains(child.id) { walk(child.id, depth: depth + 1) }
            }
        }
        walk(nil, depth: 0)
        return rows
    }

    private func folderRow(_ folder: FolderRecord, binder: BinderRecord, depth: Int, hasFolders: Bool) -> some View {
        let selected = navigation.selection == .binder && navigation.binderID == binder.id && navigation.folderID == folder.id
        return HStack(spacing: 0) {
            Button {
                navigation.binderID = binder.id
                navigation.folderID = folder.id
                navigation.selection = .binder
                settings.currentBinderID = binder.id
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: selected ? "folder.fill" : "folder")
                        .font(.system(size: 11.5))
                        .foregroundStyle(selected ? AnyShapeStyle(BindersTheme.accentText) : AnyShapeStyle(ink.opacity(0.55)))
                        .frame(width: 16)
                    Text(folder.name)
                        .font(.system(size: 13, weight: selected ? .semibold : .regular))
                        .foregroundStyle(ink.opacity(selected ? 1 : 0.78))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 4)
                .padding(.leading, 28 + CGFloat(depth) * 14)
                .padding(.trailing, hasFolders ? 2 : 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if hasFolders {
                disclosure(openFolders.contains(folder.id), name: folder.name) { toggle(folder.id, in: &openFolders) }
                    .padding(.trailing, 6)
            }
        }
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(rowFill(selected: selected, hovered: hoveredBinder == folder.id, dropping: dropTarget == folder.id)))
        .onHover { inside in
            if inside { hoveredBinder = folder.id } else if hoveredBinder == folder.id { hoveredBinder = nil }
        }
        .draggable(DraggedItem.folder(folder.id).string)
        .dropDestination(for: String.self) { items, _ in
            DraggedItem.drop(items, into: folder.id, binder: binder.id, undoManager: undoManager)
        } isTargeted: { inside in
            if inside { dropTarget = folder.id } else if dropTarget == folder.id { dropTarget = nil }
        }
        .contextMenu { FolderContextItems(folder: folder) }
        .accessibilityLabel("Folder \(folder.name), in \(binder.name)")
    }

    /// The small arrow that shows or hides the folders under a row.
    private func disclosure(_ open: Bool, name: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .rotationEffect(.degrees(open ? 90 : 0))
                .foregroundStyle(ink.opacity(0.45))
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(open ? "Hide the folders in \(name)" : "Show the folders in \(name)")
        .accessibilityLabel(open ? "Hide folders" : "Show folders")
    }

    private func toggle(_ id: UUID, in set: inout Set<UUID>) {
        if set.contains(id) { set.remove(id) } else { set.insert(id) }
    }

    private func rowFill(selected: Bool, hovered: Bool, dropping: Bool) -> AnyShapeStyle {
        if dropping { return AnyShapeStyle(BindersTheme.accent.opacity(dark ? 0.4 : 0.22)) }
        if selected { return AnyShapeStyle(BindersTheme.accent.opacity(dark ? 0.3 : 0.14)) }
        return AnyShapeStyle(hovered ? ink.opacity(0.06) : .clear)
    }

    private func row(_ section: HubSection) -> some View {
        let selected = navigation.selection == section
        return Button {
            if section == .binder, navigation.binderID == nil { navigation.binderID = Store.shared.defaultBinder().id }
            navigation.selection = section
        } label: {
            HStack(spacing: 10) {
                Image(systemName: section.symbol)
                    .font(.system(size: 13.5, weight: .medium))
                    .frame(width: 20)
                    .foregroundStyle(selected ? BindersTheme.accentText : ink.opacity(0.7))
                Text(section.title)
                    .font(.system(size: 13.5, weight: selected ? .semibold : .regular))
                    .foregroundStyle(ink.opacity(selected ? 1 : 0.82))
                Spacer(minLength: 0)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(selected ? BindersTheme.accent.opacity(dark ? 0.3 : 0.14) : (hovered == section ? ink.opacity(0.06) : .clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { hovered = section } else if hovered == section { hovered = nil }
        }
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: statusSymbol).foregroundStyle(statusStyle)
                Text(statusText).lineLimit(1)
            }
            Text("Hold \(settings.hotkeys.dictation.displayString()) to dictate · \(settings.hotkeys.meeting?.displayString() ?? "⌥M") for a meeting")
                .lineLimit(2)
        }
        .font(.caption)
        .foregroundStyle(BindersTheme.muted)
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var statusText: String {
        if AppPaths.isDemo { return "Parakeet v3 · local AI, on this Mac" }   // screenshots show the ready state
        switch controller.speech.state {
        case .idle: return "Speech model not loaded"
        case .downloading(let fraction): return "Downloading speech model \(Int(fraction * 100))%"
        case .loading: return "Loading speech model…"
        case .failed: return "Speech model failed"
        case .ready: return settings.aiFormatting ? "\(settings.speechModel.displayName) · \(settings.llmModelName)" : "\(settings.speechModel.displayName) · no AI"
        }
    }

    /// Ready wears a check, not green, which is for done; a failure, the problem style's glyph.
    private var statusSymbol: String {
        if AppPaths.isDemo { return BindersTheme.readySymbol }
        switch controller.speech.state {
        case .ready: return BindersTheme.readySymbol
        case .failed: return BindersTheme.problemSymbol
        case .idle: return "circle.dotted"
        case .downloading: return "arrow.down.circle"
        case .loading: return "hourglass"
        }
    }

    private var statusStyle: Color {
        if AppPaths.isDemo { return BindersTheme.accentText }
        switch controller.speech.state {
        case .ready: return BindersTheme.accentText
        case .failed: return ink
        default: return BindersTheme.faint
        }
    }
}

struct PageHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(BindersTheme.title())
            Text(subtitle).foregroundStyle(.secondary).frame(maxWidth: 680, alignment: .leading)
        }
    }
}

/// A small capsule label. A semantic colour comes with its glyph.
struct Badge: View {
    let text: String
    var symbol: String? = nil
    var color: Color = BindersTheme.muted
    /// Wears the accent, or the binder's colour on its pages, in place of `color`: for a badge you click, or on a
    /// binder's own card. One that only tells you something inside a binder takes `color`.
    var tinted = false

    var body: some View {
        HStack(spacing: 3) {
            // The words carry the meaning for VoiceOver; the glyph is for the eye.
            if let symbol { Image(systemName: symbol).imageScale(.small).accessibilityHidden(true) }
            Text(text)
        }
        .font(.caption2.weight(.semibold))
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(tinted ? AnyShapeStyle(TintFill().opacity(0.16)) : AnyShapeStyle(color.opacity(0.15))))
        .foregroundStyle(tinted ? AnyShapeStyle(.tintText) : AnyShapeStyle(color))
    }
}
