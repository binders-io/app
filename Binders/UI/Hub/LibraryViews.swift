import AppKit
import SwiftData
import SwiftUI
import BindersKit

struct DictionaryView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(DictationController.self) private var controller
    @Query(sort: \DictionaryWord.createdAt, order: .reverse) private var words: [DictionaryWord]
    @State private var term = ""
    @State private var aliases = ""
    @State private var message: String?

    var body: some View {
        @Bindable var settings = settings
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(title: "Dictionary",
                       subtitle: "Names, jargon and spellings Binders should always get right. Used to steer recognition and formatting.")
            HStack {
                TextField("Word or phrase, e.g. Binders", text: $term)
                TextField("Often heard as (optional, comma-separated)", text: $aliases)
                Button("Add", action: add).disabled(term.trimmed.isEmpty)
            }
            .textFieldStyle(.roundedBorder)
            .onSubmit(add)

            HStack {
                Toggle("Learn from my corrections", isOn: $settings.autoLearnDictionary)
                    .help("When you fix a word right after dictating, Binders adds it here.")
                Spacer()
                if WisprImporter.isAvailable {
                    Button("Import from Wispr Flow") { runImport() }
                }
            }
            if let message { Text(message).font(.callout).foregroundStyle(.secondary) }

            List {
                ForEach(words) { word in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(word.term).font(.body.weight(.medium))
                            if !word.aliases.isEmpty {
                                Text("Heard as: " + word.aliases.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        switch word.source {
                        case "auto": Badge(text: "Learned", tinted: true)
                        case "wispr": Badge(text: "Imported")
                        default: EmptyView()
                        }
                        Button { Store.shared.delete(word) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                    .padding(.vertical, 3)
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .overlay {
                if words.isEmpty {
                    ContentUnavailableView("No words yet", systemImage: "book.closed",
                                           description: Text("Add names and terms, or fix a word right after dictating and Binders will learn it."))
                }
            }
        }
        .padding(28)
    }

    private func add() {
        let value = term.trimmed
        guard !value.isEmpty, Store.shared.allowsSave() else { return }
        let heardAs = aliases.split(separator: ",").map { String($0).trimmed }.filter { !$0.isEmpty }
        if !Store.shared.addDictionaryWord(value, aliases: heardAs, source: "manual") {
            message = "“\(value)” is already in your dictionary."
        } else {
            message = nil
        }
        term = ""
        aliases = ""
    }

    private func runImport() {
        guard Store.shared.allowsSave() else { return }
        do {
            let summary = try WisprImporter.importAll()
            AppDefaults.store.set(true, forKey: "importedFromWispr")
            message = "Imported \(summary.words) words and \(summary.snippets) snippets from Wispr Flow."
        } catch {
            message = "Import failed: \(error.localizedDescription)"
        }
    }
}

struct SnippetsView: View {
    @Query(sort: \SnippetItem.createdAt, order: .reverse) private var snippets: [SnippetItem]
    @State private var trigger = ""
    @State private var expansion = ""
    @State private var editing: SnippetItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(title: "Snippets",
                       subtitle: "Say a trigger phrase and Binders types the full text — links, addresses, intros, sign-offs.")
            VStack(alignment: .leading, spacing: 8) {
                TextField("Trigger phrase, e.g. my calendar link", text: $trigger)
                    .textFieldStyle(.roundedBorder)
                TextEditor(text: $expansion)
                    .font(.body)
                    .frame(height: 70)
                    .padding(4)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(BindersTheme.lineStrong))
                HStack {
                    Text("\(expansion.count)/4000").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    Spacer()
                    Button("Add Snippet") {
                        guard Store.shared.allowsSave() else { return }
                        Store.shared.insert(SnippetItem(trigger: trigger.trimmed, expansion: String(expansion.prefix(4000))))
                        trigger = ""
                        expansion = ""
                    }
                    .disabled(trigger.trimmed.isEmpty || expansion.trimmed.isEmpty)
                }
            }

            List {
                ForEach(snippets) { snippet in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 3) {
                            // The phrase you say, quoted.
                            Text("“\(snippet.trigger)”").font(BindersTheme.quote())
                            Text(snippet.expansion).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                        }
                        Spacer()
                        Button { editing = snippet } label: { Image(systemName: "pencil") }.buttonStyle(.borderless)
                        Button { Store.shared.delete(snippet) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                    }
                    .padding(.vertical, 3)
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .overlay {
                if snippets.isEmpty {
                    ContentUnavailableView("No snippets yet", systemImage: "text.badge.plus",
                                           description: Text("Try “my calendar link” → your booking URL."))
                }
            }
        }
        .padding(28)
        .sheet(item: $editing) { snippet in
            SnippetEditor(snippet: snippet)
        }
    }
}

private struct SnippetEditor: View {
    @Bindable var snippet: SnippetItem
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Edit Snippet").font(BindersTheme.cardTitle)
            TextField("Trigger", text: $snippet.trigger).textFieldStyle(.roundedBorder)
            TextEditor(text: $snippet.expansion)
                .frame(minHeight: 140)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(BindersTheme.lineStrong))
            HStack {
                Spacer()
                Button("Done") {
                    Store.shared.save()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
        .pageGround()
    }
}

struct StyleView: View {
    @Environment(AppSettings.self) private var settings
    @State private var category: StyleCategory = .personal
    @State private var newIdentifier = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(title: "Style", subtitle: "Binders formats your words differently depending on where you're typing.")

                Picker("Category", selection: $category) {
                    ForEach(StyleCategory.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(category.summary).foregroundStyle(.secondary)

                if category.usesTone {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 12)], spacing: 12) {
                        ForEach(Tone.allCases) { tone in
                            ToneCard(tone: tone, selected: settings.styles.tone(for: category) == tone) {
                                settings.styles.tones[category.rawValue] = tone
                            }
                        }
                    }
                } else {
                    Text("In terminals and editors Binders keeps commands, flags, file paths and identifiers exact, understands “camel case” and spoken symbols, and skips the trailing period on short commands.")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .paperCard(padding: 14)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Custom instructions").font(BindersTheme.cardTitle)
                    TextEditor(text: Binding(
                        get: { settings.styles.customInstructions[category.rawValue] ?? "" },
                        set: { settings.styles.customInstructions[category.rawValue] = $0 }))
                        .font(.body)
                        .frame(minHeight: 70)
                        .padding(4)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(BindersTheme.lineStrong))
                    Text("For example: “Use British spelling”, “Never use em dashes”, “Sign emails with – Maya”.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("App & website categories").font(BindersTheme.cardTitle)
                    Text("Binders recognizes common apps automatically. Override any app or site here.")
                        .font(.callout).foregroundStyle(.secondary)
                    ForEach(settings.styles.appOverrides.keys.sorted(), id: \.self) { key in
                        HStack {
                            Text(displayName(for: key))
                            Spacer()
                            Picker("", selection: Binding(
                                get: { settings.styles.appOverrides[key] ?? .other },
                                set: { settings.styles.appOverrides[key] = $0 })) {
                                ForEach(StyleCategory.allCases) { Text($0.displayName).tag($0) }
                            }
                            .labelsHidden()
                            .frame(width: 180)
                            Button { settings.styles.appOverrides.removeValue(forKey: key) } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless)
                        }
                    }
                    HStack {
                        Menu("Add running app") {
                            ForEach(runningApps, id: \.bundleIdentifier) { app in
                                Button(app.localizedName ?? app.bundleIdentifier ?? "App") {
                                    if let id = app.bundleIdentifier { settings.styles.appOverrides[id] = category }
                                }
                            }
                        }
                        .frame(width: 170)
                        TextField("or a website, e.g. notion.so", text: $newIdentifier)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(addDomain)
                        Button("Add as \(category.displayName)", action: addDomain).disabled(newIdentifier.trimmed.isEmpty)
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 900, alignment: .leading)
        }
    }

    private var runningApps: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }

    private func displayName(for identifier: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return identifier
    }

    private func addDomain() {
        var domain = newIdentifier.trimmed.lowercased()
        if let host = URL(string: domain.contains("://") ? domain : "https://\(domain)")?.host { domain = host }
        if domain.hasPrefix("www.") { domain.removeFirst(4) }
        guard !domain.isEmpty else { return }
        settings.styles.appOverrides[domain] = category
        newIdentifier = ""
    }
}

private struct ToneCard: View {
    let tone: Tone
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(tone.displayName).font(BindersTheme.cardTitle)
                    Spacer()
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? AnyShapeStyle(.tintText) : AnyShapeStyle(.secondary))
                }
                Text(tone.example).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 110, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(selected ? AnyShapeStyle(TintFill().opacity(0.08)) : AnyShapeStyle(Color.clear)))
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(BindersTheme.surface))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(selected ? AnyShapeStyle(.tintFill) : AnyShapeStyle(BindersTheme.line), lineWidth: selected ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct NotesView: View {
    @Environment(DictationController.self) private var controller
    @Environment(HubNavigation.self) private var navigation
    @Environment(TeamSyncService.self) private var team
    @Environment(\.undoManager) private var undoManager
    @ReducedMotion private var reduceMotion
    @Query private var notes: [NoteItem]
    /// The binder's folders, for the ones in the folder you're in and for which notes are where.
    @Query private var folders: [FolderRecord]
    /// The notes chosen in the list: one, which opens beside it, or several (⌘-click, ⇧-click, ⌘A), to move or delete
    /// together.
    @State private var selection: Set<UUID> = []
    /// A note just made, whose editor takes the cursor.
    @State private var focusID: UUID?
    /// A heading or block to show in a note, from a link to it.
    @State private var reveal: (note: UUID, place: EditorReveal)?
    @State private var noteToDelete: NoteItem?
    /// Several notes to delete, waiting for the one yes they all need.
    @State private var notesToDelete: [NoteItem] = []
    /// Stop Distilling… on a note whose cards are still open asks first, about that note.
    @State private var noteToStop: NoteItem?
    /// Show only notes with this status, or this #tag.
    @State private var statusFilter: String?
    @State private var tagFilter: String?
    let binderID: UUID?
    /// The folder you're in, in that binder; nil at its top.
    let folderID: UUID?
    /// For self-tests: the notes to select as the list opens, as ⌘-click would.
    @MainActor static var selectOnOpen: Set<UUID>?

    /// The one note selected, open beside the list; nil for none or several.
    private var single: UUID? { selection.count == 1 ? selection.first : nil }

    /// The notes selected, in the list's order.
    private var chosen: [NoteItem] { shown.filter { selection.contains($0.id) } }

    /// The notes in the folder you're in (at the top, those in no folder of the binder's), or every note when this isn't
    /// one binder's list.
    private var here: [NoteItem] {
        guard let binderID else { return notes }
        let known = Set(folders.map(\.id))
        // Its binder checked too: a note just moved to another binder leaves at once, before the list is read again.
        return notes.filter { note in note.binderID == binderID && note.folderID.flatMap { known.contains($0) ? $0 : nil } == folderID }
    }

    private var shown: [NoteItem] { filtered(here) }

    /// The notes here that the status and tag filters let through.
    private func filtered(_ here: [NoteItem]) -> [NoteItem] {
        here.filter { note in
            (statusFilter == nil || note.status == statusFilter) && (tagFilter.map { NoteTagCache.tags(of: note).contains($0) } ?? true)
        }
    }

    /// The folders in the folder you're in, by name, with how many notes each holds.
    private var subfolders: [(folder: FolderRecord, notes: Int)] {
        guard binderID != nil else { return [] }
        let nodes = FolderTree.untangled(folders.map(\.node))
        let parents = Dictionary(nodes.map { ($0.id, $0.parentID) }, uniquingKeysWith: { first, _ in first })
        let counts = notes.reduce(into: [UUID: Int]()) { counts, note in if let id = note.folderID { counts[id, default: 0] += 1 } }
        return folders.filter { (parents[$0.id] ?? nil) == folderID }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map { ($0, counts[$0.id] ?? 0) }
    }

    /// The tags in these notes, most used first.
    private var tags: [String] {
        let counts = notes.flatMap { NoteTagCache.tags(of: $0) }.reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
        return counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.prefix(30).map(\.key)
    }

    /// The notes in one binder, in the folder you're in, or every note when `binderID` is nil.
    init(binderID: UUID? = nil, folderID: UUID? = nil) {
        self.binderID = binderID
        self.folderID = folderID
        if let binderID {
            _notes = Query(filter: #Predicate<NoteItem> { $0.binderID == binderID }, sort: [SortDescriptor(\NoteItem.updatedAt, order: .reverse)])
            _folders = Query(filter: #Predicate<FolderRecord> { $0.binderID == binderID })
        } else {
            _notes = Query(sort: [SortDescriptor(\NoteItem.updatedAt, order: .reverse)])
            _folders = Query(filter: #Predicate<FolderRecord> { _ in false })
        }
    }

    var body: some View {
        content
            .onAppear {
                navigation.currentNoteID = single
                consumePendingNote()
                if let ids = Self.selectOnOpen { selection = ids }
            }
            .onChange(of: navigation.pendingNoteID) { consumePendingNote() }
            // Gone to the folder of a note asked for: it opens there. Into another folder: the note open from the last one
            // closes, as it isn't in this list.
            .onChange(of: folderID) {
                if navigation.pendingNoteID != nil {
                    consumePendingNote()
                } else {
                    selection = selection.filter { id in here.contains { $0.id == id } }
                }
            }
            .onChange(of: NoteTrash.shared.restoredNotes) { _, ids in if !ids.isEmpty { selection = ids } }
            // Not on appearing: then it would see the selection from before a new note's, and the new note would open
            // without the cursor in it.
            .onChange(of: selection) { _, _ in
                if single != focusID { focusID = nil }
                navigation.currentNoteID = single
            }
            .onDisappear { navigation.currentNoteID = nil }
            .onReceive(NotificationCenter.default.publisher(for: TeamSyncService.itemsWillBeRemoved)) { notification in
                // A teammate removed a selected note: let it go before sync deletes it.
                if let ids = notification.userInfo?["ids"] as? Set<UUID> { selection.subtract(ids) }
            }
    }

    /// In the folder you're in, or the one its template names.
    private func newNote(from template: NoteTemplate?) {
        guard Store.shared.allowsSave() else { return }
        let binder = Store.shared.binder(binderID ?? AppSettings.shared.currentBinderID) ?? Store.shared.defaultBinder()
        let note = TemplateStore.newNote(from: template, in: binder, folder: binder.id == binderID ? folderID : nil)
        // One its template filed elsewhere opens there, so it shows in the list.
        if binderID != nil, Store.shared.shownFolder(note.folderID, in: binder.id) != folderID {
            navigation.folderID = Store.shared.shownFolder(note.folderID, in: binder.id)
        }
        focusID = note.id
        selection = [note.id]
    }

    private func consumePendingNote() {
        guard let pending = navigation.pendingNoteID else { return }
        // A note opened from a link or a search shows in its own folder.
        if binderID != nil, let note = notes.first(where: { $0.id == pending }) {
            let known = Set(folders.map(\.id))
            let its = note.folderID.flatMap { known.contains($0) ? $0 : nil }
            if its != folderID {
                navigation.folderID = its
                return
            }
        }
        if navigation.pendingNoteIsNew { focusID = pending }
        navigation.pendingNoteIsNew = false
        // A card's words in it, from the card (lane DS4), or a heading or block.
        if navigation.pendingNotePlace != nil || navigation.pendingNoteQuote != nil {
            reveal = (pending, EditorReveal(place: navigation.pendingNotePlace ?? "", quote: navigation.pendingNoteQuote))
        } else {
            reveal = nil
        }
        navigation.pendingNotePlace = nil
        navigation.pendingNoteQuote = nil
        selection = [pending]
        navigation.pendingNoteID = nil
    }

    /// The notes list's width: narrower on a narrow page, so the note beside it keeps its room.
    static func listWidth(onPage width: CGFloat) -> CGFloat { width < 700 ? 220 : 260 }

    private var content: some View {
        GeometryReader { proxy in
            list(width: Self.listWidth(onPage: proxy.size.width))
        }
    }

    private func list(width: CGFloat) -> some View {
        // Worked out once each time the list draws (lane DB10), rather than once for each place that shows them.
        let here = self.here
        let shown = filtered(here)
        let subfolders = self.subfolders
        let chosen = shown.filter { selection.contains($0.id) }
        return HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Notes").font(BindersTheme.columnTitle).foregroundStyle(.sectionInk)
                    Spacer()
                    Menu {
                        Section("Status") {
                            Button("Any") { statusFilter = nil }
                            ForEach(NoteProperties.statuses + Array(Set(notes.compactMap(\.status)).subtracting(NoteProperties.statuses)).sorted(), id: \.self) { status in
                                Button(status) { statusFilter = status }
                            }
                        }
                        if !tags.isEmpty {
                            Section("Tag") {
                                Button("Any") { tagFilter = nil }
                                ForEach(tags, id: \.self) { tag in Button("#\(tag)") { tagFilter = tag } }
                            }
                        }
                    } label: {
                        Image(systemName: statusFilter != nil || tagFilter != nil ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .quietControl()
                    .help("Show only notes with a status or a tag")
                    // A click makes a blank note; the menu starts one from a template.
                    Menu {
                        Section("From a template") {
                            ForEach(TemplateStore.all) { template in
                                // One that files its notes in a folder says which.
                                Button(template.folder.map { "\(template.name) · in \($0)" } ?? template.name) { newNote(from: template) }
                            }
                        }
                        Divider()
                        if let binderID {
                            Button(folderID == nil ? "New Folder…" : "New Folder Here…") { FolderPrompts.shared.create(in: binderID, parent: folderID) }
                            Divider()
                        }
                        if let note = notes.first(where: { $0.id == single }) {
                            Button("Save “\(note.title)” as a Template") {
                                MarkdownEditor.flushAll()
                                TemplateStore.save(note)
                            }
                            // From inside a folder, a template can file its notes there too.
                            let folder = Store.shared.folderPath(Store.shared.shownFolder(note.folderID, in: note.binderID))
                            if !folder.isEmpty {
                                Button("Save “\(note.title)” as a Template for “\(folder)”") {
                                    MarkdownEditor.flushAll()
                                    TemplateStore.save(note, folder: folder)
                                }
                            }
                        }
                        Button("Show Templates Folder") { TemplateStore.showFolder() }
                    } label: {
                        Image(systemName: "square.and.pencil")
                    } primaryAction: {
                        newNote(from: nil)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .quietControl()
                    .help("New note. The arrow starts one from a template.")
                }
                .padding(.horizontal, 16)
                .padding(.top, 24)
                .padding(.bottom, 8)
                if statusFilter != nil || tagFilter != nil {
                    HStack(spacing: 6) {
                        if let statusFilter { filterChip(statusFilter) { self.statusFilter = nil } }
                        if let tagFilter { filterChip("#\(tagFilter)") { self.tagFilter = nil } }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 6)
                }
                List(selection: $selection) {
                    // The folders in the folder you're in: click to go in, drop a note on one to move it in.
                    if !subfolders.isEmpty {
                        Section {
                            ForEach(subfolders, id: \.folder.id) { entry in
                                FolderListRow(folder: entry.folder, count: entry.notes) { navigation.folderID = entry.folder.id }
                            }
                        }
                    }
                    ForEach(shown) { note in
                        NoteRow(note: note)
                            .tag(note.id)
                            // Onto a folder, here or in the sidebar, or onto a binder: with every note selected beside it.
                            .draggable(dragged(note))
                            // Two fingers to the left on the trackpad.
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) { requestDelete([note]) } label: { Label("Delete", systemImage: "trash") }
                            }
                    }
                }
                .scrollContentBackground(.hidden)
                .overlay {
                    if binderID != nil, folderID != nil, here.isEmpty, subfolders.isEmpty {
                        ContentUnavailableView("Nothing in this folder yet", systemImage: "folder",
                                               description: Text("New notes you make here go in it. Drag notes onto it, or use Move to on a note."))
                    }
                }
                // ⌫ or ⌦ on the selected notes, or right-click. Undo puts a note back; a team note, or several, ask first.
                .onDeleteCommand { requestDelete(chosen) }
                .onKeyPress(.deleteForward) {
                    guard !chosen.isEmpty else { return .ignored }
                    requestDelete(chosen)
                    return .handled
                }
                .contextMenu(forSelectionType: UUID.self) { ids in
                    if ids.count > 1 {
                        severalItems(shown.filter { ids.contains($0.id) })
                    } else if let id = ids.first, let note = notes.first(where: { $0.id == id }) {
                        Button("Open in Its Own Window") { NotePopouts.shared.open(note) }
                        Button("Fold into a Bubble") { NotePopouts.shared.open(note, collapsed: true) }
                        Button("Put on Board") {
                            // Lane DS6: the note's card, which its Work bar and marks follow.
                            guard let put = NotePutOnBoard.put(note, controller: controller) else { return }
                            controller.flowBar.toast(put.line, symbol: "checkmark.circle")
                        }
                        if let noteBinder = note.binderID {
                            Menu("Move to") {
                                MoveToFolderItems(binderID: noteBinder, current: Store.shared.shownFolder(note.folderID, in: noteBinder)) { target in
                                    move([note], toFolder: target, in: noteBinder)
                                }
                            }
                        }
                        // Lane DS1: off for every note until you turn it on.
                        DistillToggleItems(note: note) { noteToStop = $0 }
                        Divider()
                        Button(sharedWithTeam(note) ? "Delete for Everyone…" : "Delete", role: .destructive) { requestDelete([note]) }
                    }
                } primaryAction: { ids in
                    // A double-click opens the note in a window of its own.
                    if ids.count == 1, let id = ids.first, let note = notes.first(where: { $0.id == id }) { NotePopouts.shared.open(note) }
                }
                .confirmationDialog(deleteTitle, isPresented: Binding(get: { noteToDelete != nil }, set: { if !$0 { noteToDelete = nil } }),
                                    presenting: noteToDelete) { note in
                    Button(sharedWithTeam(note) ? "Delete for Everyone" : "Delete", role: .destructive) { delete([note]) }
                        .keyboardShortcut(.defaultAction)
                    Button("Cancel", role: .cancel) {}
                } message: { note in
                    Text(sharedWithTeam(note) ? "It's removed for everyone on the team. This can't be undone." : "This can't be undone.")
                }
                // Several at once ask once, for all of them, saying which can come back.
                .confirmationDialog("Delete \(notesToDelete.count) notes?", isPresented: Binding(get: { !notesToDelete.isEmpty }, set: { if !$0 { notesToDelete = [] } })) {
                    Button(deleteSeveralTitle(notesToDelete), role: .destructive) { delete(notesToDelete) }
                        .keyboardShortcut(.defaultAction)
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text(deleteSeveralMessage(notesToDelete))
                }
                .confirmsStopDistilling($noteToStop, controller: controller)
                if let deleted = NoteTrash.shared.last {
                    let count = NoteTrash.shared.lastDeleted.count
                    HStack(spacing: 8) {
                        Image(systemName: "trash").foregroundStyle(.secondary)
                        Text(count > 1 ? "Deleted \(count) notes" : "Deleted “\(deleted.title)”").lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 4)
                        Button("Undo") { NoteTrash.shared.restore(NoteTrash.shared.lastDeleted, undoManager: undoManager) }
                            .help(count > 1 ? "Put the notes back (⌘Z)" : "Put the note back (⌘Z)")
                    }
                    .font(.callout)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(BindersTheme.surface))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(BindersTheme.line))
                    .padding(.horizontal, 10)
                    .padding(.top, 6)
                    // It rises into place; under Reduce Motion it fades in.
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                }
                Button("Open Scratchpad (\(AppSettings.shared.hotkeys.scratchpad?.displayString() ?? "menu bar"))") {
                    ScratchpadController.shared.show()
                }
                .themedLink()
                .padding(12)
            }
            .frame(width: width)
            .animation(.easeOut(duration: 0.2), value: NoteTrash.shared.last?.id)
            Divider()
            if selection.count > 1 {
                several(chosen)
            } else if let note = notes.first(where: { $0.id == single }) {
                // A fresh editor per note: reusing one would take the switch for an edit and move the note to the top.
                NoteEditor(note: note, focused: note.id == focusID, reveal: reveal?.note == note.id ? reveal?.place : nil) {
                    selection = neighbour(of: [note]).map { [$0.id] } ?? []
                }
                    .id(note.id)
            } else {
                ContentUnavailableView("Select a note", systemImage: "note.text",
                                       description: Text("Dictate into the Scratchpad and your notes land here."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var deleteTitle: String {
        guard let noteToDelete else { return "Delete this note?" }
        return sharedWithTeam(noteToDelete) ? "Delete “\(noteToDelete.title)” for everyone on the team?" : "Delete “\(noteToDelete.title)”?"
    }

    private func sharedWithTeam(_ note: NoteItem) -> Bool {
        (team.isConfigured && (note.sharedWithTeam || note.isTeamCopy)) || TeamNotes.current?.covers(note) == true
    }

    /// The note below these in the list, or above them at the end, so deleting several in a row is ⌫ ⏎ ⌫ ⏎.
    private func neighbour(of going: [NoteItem]) -> NoteItem? {
        let list = shown
        let ids = Set(going.map(\.id))
        guard let last = list.lastIndex(where: { ids.contains($0.id) }) else { return nil }
        if let below = list[(last + 1)...].first(where: { !ids.contains($0.id) }) { return below }
        return list[..<last].last { !ids.contains($0.id) }
    }

    private func filterChip(_ label: String, clear: @escaping () -> Void) -> some View {
        Button(action: clear) {
            HStack(spacing: 4) {
                Text(label)
                Image(systemName: "xmark").font(.caption2.weight(.bold))
            }
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(TintFill().opacity(0.14)))
            .foregroundStyle(.tintText)
        }
        .buttonStyle(.plain)
        .help("Show all notes again")
    }

    /// A note of your own goes at once, and Undo brings it back; one shared with the team is deleted for everyone, so
    /// that asks first. Several ask once, for all of them.
    private func requestDelete(_ going: [NoteItem]) {
        guard !going.isEmpty else { return }
        if going.count > 1 {
            notesToDelete = going
        } else if let note = going.first {
            if sharedWithTeam(note) { noteToDelete = note } else { delete([note]) }
        }
    }

    /// Each by its own rule: one shared with the team goes for everyone; the rest together, which one Undo puts back.
    private func delete(_ going: [NoteItem]) {
        let ids = Set(going.map(\.id))
        if !selection.isDisjoint(with: ids) { selection = neighbour(of: going).map { [$0.id] } ?? [] }
        let forEveryone = going.filter(sharedWithTeam)
        forEveryone.forEach(NoteEditor.remove)
        NoteTrash.shared.delete(going.filter { !sharedWithTeam($0) }, undoManager: undoManager)
    }

    /// "Delete 5 Notes", "Delete 5 Notes, 2 for Everyone", "Delete 5 Notes for Everyone".
    private func deleteSeveralTitle(_ going: [NoteItem]) -> String {
        let shared = going.filter(sharedWithTeam).count
        if shared == 0 { return "Delete \(going.count) Notes" }
        return shared == going.count ? "Delete \(going.count) Notes for Everyone" : "Delete \(going.count) Notes, \(shared) for Everyone"
    }

    /// "2 of them are shared with your team: they're removed for everyone, which can't be undone. Undo puts the other 3
    /// back."
    private func deleteSeveralMessage(_ going: [NoteItem]) -> String {
        let shared = going.filter(sharedWithTeam).count
        let mine = going.count - shared
        if shared == 0 { return "Undo puts them back." }
        let them = shared == going.count ? "They're shared with your team" : shared == 1 ? "1 of them is shared with your team" : "\(shared) of them are shared with your team"
        return them + ": " + (shared == 1 && shared != going.count ? "it's" : "they're") + " removed for everyone, which can't be undone."
            + (mine == 0 ? "" : mine == 1 ? " Undo puts the other one back." : " Undo puts the other \(mine) back.")
    }

    // MARK: Several notes

    /// What dragging a note carries: the note, or, when it's one of several selected, all of them.
    private func dragged(_ note: NoteItem) -> String {
        guard selection.count > 1, selection.contains(note.id) else { return DraggedItem.note(note.id).string }
        return DraggedItem.payload(chosen.map { .note($0.id) })
    }

    /// Moves notes into a folder in `binderID` (nil: its top), each by its own rules, as one change one Undo puts back,
    /// and says what happened.
    private func move(_ moving: [NoteItem], toFolder target: UUID?, in binderID: UUID) {
        guard Store.shared.allowsSave() else { return }
        MarkdownEditor.flushAll()
        let outcome = NoteMoves.move(moving, toFolder: target, in: binderID, undoManager: undoManager)
        said(outcome, of: moving, place: FolderPrompts.place(binderID: Store.shared.folder(target)?.binderID ?? binderID, folder: target))
    }

    private func move(_ moving: [NoteItem], to binder: BinderRecord) {
        guard Store.shared.allowsSave() else { return }
        MarkdownEditor.flushAll()
        let outcome = NoteMoves.move(moving, to: binder, undoManager: undoManager)
        said(outcome, of: moving, place: binder.name)
    }

    /// "Moved 4 notes to Work › DevOps." and why any stayed. Notes that left this list leave the selection.
    private func said(_ outcome: NoteMoves.Outcome, of moving: [NoteItem], place: String) {
        selection = selection.filter { id in here.contains { $0.id == id } }
        let why = outcome.stayed.count > 1 ? "\(outcome.stayed.count) are teammates' notes, which stay in their binders." : outcome.stayed.first?.why
        guard let line = outcome.line(asked: moving.count, noun: ("note", "notes"), place: place, whyStayed: why) else { return }
        controller.flowBar.toast(line, symbol: outcome.stayed.isEmpty ? "folder" : BindersTheme.problemSymbol, duration: 4)
    }

    /// The menu items for several notes at once, in the list's menu.
    private func severalItems(_ moving: [NoteItem]) -> some View {
        SeveralMenuItems(count: moving.count, noun: "Notes", binderID: binderID, folderID: folderID,
                         toFolder: { target in if let binderID { move(moving, toFolder: target, in: binderID) } },
                         toBinder: { move(moving, to: $0) }, delete: { requestDelete(moving) })
    }

    /// Beside the list with several notes selected: how many, what to do with them all, and what stays as it is.
    private func several(_ moving: [NoteItem]) -> some View {
        let teammates = moving.filter(\.isTeamCopy).count
        let fromSpeech = moving.filter(\.staysUnshared).count
        var rules: [String] = []
        if teammates > 0 {
            rules.append(teammates == 1 ? "1 is a teammate's note: it stays in their binder, in any folder you choose."
                         : "\(teammates) are teammates' notes: they stay in their binders, in any folder you choose.")
        }
        if fromSpeech > 0 {
            rules.append(fromSpeech == 1 ? "1 was made from what you said: it stays on this Mac, even in a shared binder."
                         : "\(fromSpeech) were made from what you said: they stay on this Mac, even in a shared binder.")
        }
        return SeveralSelectedPanel(heading: "\(moving.count) notes selected", titles: moving.map(\.title), rules: rules, probe: "notes.several") {
            SeveralButtons(count: moving.count, noun: "notes", binderID: binderID, folderID: folderID,
                           toFolder: { target in if let binderID { move(moving, toFolder: target, in: binderID) } },
                           toBinder: { move(moving, to: $0) }, delete: { requestDelete(moving) })
        }
    }
}

/// The edge between a page and a side panel: drag it to resize the panel, or all the way across to hide it.
struct PanelEdge: View {
    /// How wide the edge is, which the page leaves it.
    static let thickness: CGFloat = 7
    @Binding var width: Double
    @Binding var visible: Bool
    var minimum: Double = 220
    var maximum: Double = 620
    /// Narrower than this when let go, and the panel hides.
    var hideBelow: Double = 140
    @State private var start: Double?
    @State private var hovering = false

    var body: some View {
        ZStack {
            Rectangle().fill(BindersTheme.line).frame(width: 1).opacity(visible ? 1 : 0)
            Color.clear.frame(width: Self.thickness).contentShape(Rectangle())
        }
        .frame(width: Self.thickness)
        .onHover { inside in
            if inside, !hovering { NSCursor.resizeLeftRight.push() } else if !inside, hovering { NSCursor.pop() }
            hovering = inside
        }
        .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { drag in
                let from = start ?? (visible ? width : 0)
                if start == nil { start = from }
                let wanted = from - drag.translation.width
                if from == 0 {
                    // Hidden: a short pull brings it out, at its narrowest, and it follows from there.
                    guard wanted > 24 else { return }
                    visible = true
                    width = min(max(wanted, minimum), maximum)
                } else if wanted < hideBelow {
                    visible = false
                } else {
                    visible = true
                    width = min(max(wanted, minimum), maximum)
                }
            }
            .onEnded { _ in start = nil })
        .help(visible ? "Drag to resize the digest, or all the way to hide it" : "Drag to show the digest")
        .accessibilityLabel("Digest width")
    }
}

/// A note in the notes list. A view of its own, so typing in one note redraws its row and leaves the others.
private struct NoteRow: View {
    let note: NoteItem

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(note.title).lineLimit(1)
            HStack(spacing: 4) {
                if note.isTeamCopy {
                    Image(systemName: "person.2.fill")
                    Text("\(note.teamAuthorName ?? "Team") ·")
                } else if note.sharedWithTeam, AppSettings.shared.teamFolderPath != nil {
                    Image(systemName: "person.2")
                    Text("Shared ·")
                }
                // An agent's words in it: whose, until you make it yours.
                if !note.agentMark.isEmpty {
                    AgentLabel(note.agentMark)
                    Text("·")
                }
                Text(note.updatedAt, format: .relative(presentation: .named)).monospacedDigit()
                if let status = note.status { Text("· \(status)") }
                if let due = note.dueAt {
                    // Late needs you: amber, with its clock.
                    let late = due < Calendar.current.startOfDay(for: Date()) && note.status != "Done"
                    Text("·")
                    if late { Image(systemName: "clock").foregroundStyle(BindersTheme.needsYou).accessibilityHidden(true) }
                    Text("due \(due.formatted(.dateTime.month(.abbreviated).day()))").foregroundStyle(late ? AnyShapeStyle(BindersTheme.needsYou) : AnyShapeStyle(.secondary))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
    }
}

struct NoteEditor: View {
    @Environment(DictationController.self) private var controller
    @Environment(TeamSyncService.self) private var team
    @Environment(KnowledgeService.self) private var knowledge
    @Environment(AppSettings.self) private var settings
    @Environment(\.undoManager) private var undoManager
    @Bindable var note: NoteItem
    /// Just made: the editor takes the cursor.
    var focused = false
    /// A heading or block to show, from a link to it.
    var reveal: EditorReveal? = nil
    var onDelete: () -> Void
    @State private var confirmDelete = false
    @State private var showingHistory = false
    /// See What Changed: the history opens at the version from before an agent's change, showing what changed since.
    @State private var historyFrom: Date?
    /// Every note follows the same choice.
    @AppStorage("notesShowDigest", store: AppDefaults.store) private var digestVisible = true
    @AppStorage("notesDigestWidth", store: AppDefaults.store) private var digestWidth: Double = 300
    @State private var digestCopied = false
    /// "Updated 3 links in 2 notes", for a moment after a new title.
    @State private var renameNotice: String?
    /// Put on Board: the cards it made, and where, for a few seconds.
    @State private var boardNotice: (cards: [TaskCard], line: String)?
    /// For a Distill note, what the column beside it shows: its Work, or the digest and properties.
    @AppStorage("notesSidePanel", store: AppDefaults.store) private var sidePanel = "work"
    /// For a Distill note: its cards marked at the words they came from (lane DS4), as the Work bar's switch says.
    @AppStorage(DistillNoteMarks.shownKey, store: AppDefaults.store) private var showWork = true
    @State private var noteToStop: NoteItem?
    /// Lane DS9: where Distill's motion is drawn on this page, and its list over the note when there's no room beside it.
    @State private var stage = DistillStage()
    @State private var distillOver = false
    @Environment(\.binderTint) private var binderTint
    @ReducedMotion private var reduceMotion

    private var digesting: Bool { knowledge.digestingNoteIDs.contains(note.id) }
    private var digestStale: Bool { !note.digest.isEmpty && note.digestHash != KnowledgeService.noteContentHash(note.text) }

    /// For the window-fit self-test: Put on Board's notice on this note as it opens, as if the button had been pressed.
    @MainActor static var noticeOnOpen: (note: UUID, card: TaskCard, line: String)?

    /// What the note keeps for itself before the digest goes beside it, and the narrowest the digest goes before it hides.
    static let noteRoom: CGFloat = 340
    static let columnSmallest: CGFloat = 220

    /// The digest column's width beside a note `width` points wide: the width you gave it, narrower when that would
    /// squeeze the note, and nil when there's no room for it at all.
    static func columnWidth(beside width: CGFloat, wanted: Double) -> CGFloat? {
        let room = width - noteRoom - PanelEdge.thickness
        guard room >= columnSmallest else { return nil }
        return min(max(CGFloat(wanted), columnSmallest), room)
    }

    var body: some View {
        // The digest beside the note narrows as the window does, then hides, and comes back when there's room. Your
        // choice to show it or not stays as it is.
        GeometryReader { proxy in
            let column = Self.columnWidth(beside: proxy.size.width, wanted: digestWidth)
            VStack(spacing: 0) {
                if !note.agentMark.isEmpty {
                    AgentNoteBanner(note: note, seeChanges: {
                        MarkdownEditor.flushAll()
                        historyFrom = note.editedAt
                        showingHistory = true
                    }, madeMine: { knowledge.correctionsChanged() })
                    .padding(.horizontal, 24)
                    .padding(.top, 16)
                }
                if note.isTeamCopy {
                    Label("\(note.teamAuthorName ?? "A teammate") shared this note. Your edits sync to everyone on the team.", systemImage: "person.2")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 24)
                        .padding(.top, 16)
                }
                // Lane DB3: who else has this shared note open now ("Dana is in this note").
                if let here = controller.teamBoard.notes.presenceLine(note.id) {
                    Label(here, systemImage: "person.wave.2")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 24)
                        .padding(.top, note.isTeamCopy ? 4 : 16)
                        .accessibilityLabel(here)
                }
                if note.distill || DistillBoard.hasCards(note.id) {
                    // Lane DS1: how the work distilled from it is going, under its title. Lane DS6: any note with cards.
                    WorkBar(note: note, panelShown: Binding(get: { digestVisible && sidePanel == "work" && column != nil }, set: { shown in
                        sidePanel = shown ? "work" : "digest"
                        if shown { digestVisible = true }
                    }), panelRoom: column != nil)
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
                }
                HStack(spacing: 0) {
                    // The note page: a sheet, light paper in the light appearance and a dark page in the dark.
                    MarkdownNoteEditor(text: $note.text, fontSize: 15, placeholder: "Write, or hold fn to dictate.",
                                       links: LinkTargets.forNote(note) { renamed($0) }, focused: focused, reveal: reveal,
                                       accessories: AnyView(NoteToolbarButtons(note: note, digestVisible: $digestVisible, room: column != nil)),
                                       paper: true, headingTip: note.distill ? { [controller, note] heading in controller.distill.headingTip(heading, in: note) } : nil,
                                       work: DistillNoteMarks.work(for: note, controller: controller, shown: showWork),
                                       putOnBoard: { selection, eachLine in putOnBoard(selection: selection, eachLine: eachLine) },
                                       distill: editorDistill(listShown: distillShown(column: column)))
                        .paperSheet()
                        .onChange(of: note.text) { previous, _ in
                            note.updatedAt = Date()
                            NoteHistory.changed(note.id, previous: previous)
                            // A note shared through a team database: the typing goes to the team once it pauses.
                            controller.teamBoard.notes.typed(note.id)
                        }
                    if let column {
                        // Drag the edge to make the digest wider or narrower; most of the way closed, it hides. Dragged out
                        // again, it comes back.
                        PanelEdge(width: Binding(get: { Double(column) }, set: { digestWidth = $0 }), visible: $digestVisible)
                        if digestVisible {
                            digestColumn.frame(width: column).fitProbe("note.column")
                        }
                    }
                }
                bottomBar
            }
            // Lane DS9: no room beside the note, the Distill list goes over its right side, until it's closed.
            .overlay(alignment: .topTrailing) {
                if distillOver, column == nil, note.distill {
                    DistillListPanel(note: note, onClose: { distillOver = false })
                        .padding(14)
                        .frame(width: min(330, max(250, proxy.size.width - 60)))
                        .frame(maxHeight: .infinity)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(BindersTheme.surface))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(BindersTheme.line))
                        .shadow(color: .black.opacity(0.18), radius: 16, y: 6)
                        .padding(.top, 12)
                        .padding(.bottom, 52)
                        .padding(.trailing, 14)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .distillStage(stage, note: note, listShown: distillShown(column: column))
            // Lane DS9: Distill (its button, the Note menu, the Work bar) opens the list beside the note, or over it.
            .onReceive(NotificationCenter.default.publisher(for: DistillActions.show)) { notification in
                guard notification.userInfo?["note"] as? UUID == note.id else { return }
                if column == nil {
                    withAnimation(BindersTheme.motion(BoardDesign.settle, reduced: reduceMotion)) { distillOver = true }
                } else {
                    sidePanel = "distill"
                    digestVisible = true
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: DistillActions.fromMenu)) { notification in
                guard notification.userInfo?["note"] as? UUID == note.id, notification.userInfo?["popout"] as? Bool != true else { return }
                DistillActions.press(note, controller: controller)
            }
        }
        .sheet(isPresented: $showingHistory) { NoteHistorySheet(note: note, changesFrom: historyFrom) }
        // Leaving a Distill note: the sections your typing changed are looked at now, for the cards made from them.
        .onDisappear {
            // Lane DS6: cards made with Put on Board follow sections of notes without Distill too; nothing waits otherwise.
            controller.distill.settleNow(note.id)
            // Leaving the note ends your editing session in it: what it made is kept as a version.
            NoteHistory.endSession(note.id)
            controller.teamBoard.notes.closed(note.id)
        }
        // The team sees who's in a shared note (lane DB3).
        .onAppear {
            controller.teamBoard.notes.opened(note.id)
            if let notice = Self.noticeOnOpen, notice.note == note.id { boardNotice = ([notice.card], notice.line) }
        }
        // Note → Put on Board with no editor of this note at the keyboard: the whole note (lane DS6).
        .onReceive(NotificationCenter.default.publisher(for: NotePutOnBoard.wholeNote)) { notification in
            guard notification.userInfo?["note"] as? UUID == note.id, notification.userInfo?["popout"] as? Bool != true else { return }
            putOnBoard()
        }
        .confirmationDialog("Delete this note for everyone on the team?", isPresented: $confirmDelete) {
            Button("Delete for Everyone", role: .destructive, action: delete)
        }
    }

    /// How wide the binder and folder's name goes in the bottom row: whole, as it always was; at most a few words wide; or
    /// as narrow as the row needs.
    private enum PlaceWidth { case whole, capped, shrinks }

    /// Under the note: how long it is, where it is, and what to do with it. As room runs out, where it is truncates in the
    /// middle, then the buttons show their icons, their words kept for the help and VoiceOver.
    private var bottomBar: some View {
        ViewThatFits(in: .horizontal) {
            bottomRow(words: true, place: .whole)
            bottomRow(words: true, place: .capped)
            bottomRow(words: false, place: .shrinks)
        }
        .padding(12)
    }

    private func bottomRow(words: Bool, place: PlaceWidth) -> some View {
        HStack {
            Text("\(note.text.wordCount) words").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                .fixedSize()
                .fitProbe("note.bottom.first")
            if let renameNotice {
                Label(renameNotice, systemImage: "link")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.leading, 8)
                    .transition(.opacity)
                    .help("They follow the note's new title. Undo, with the cursor in the note, puts them back.")
            }
            if let binder = Store.shared.binder(note.binderID) {
                placeMenu(binder, width: place)
                    .padding(.leading, 8)
                    .help(note.staysUnshared ? "Which binder and folder this note is in. Made from what you said, it stays on this Mac, even in a shared binder."
                          : "Which binder and folder this note is in. Sharing follows the binder.")
            }
            Spacer(minLength: 0)
            if let boardNotice {
                // What was done, with the way to it. Short of room, its tick says it, and its words are its help.
                Group {
                    if words {
                        Label(boardNotice.line, systemImage: "checkmark.circle")
                            .lineLimit(1)
                            .modifier(IdealWidthCap(cap: 120))
                    } else {
                        Image(systemName: "checkmark.circle")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .help(boardNotice.line)
                .accessibilityLabel(boardNotice.line)
                .transition(.opacity)
                .fitProbe("note.notice")
                Button("Open") { NotePutOnBoard.open(boardNotice.cards) }
                    .controlSize(.small)
                    .fixedSize()
                    .help(boardNotice.cards.count == 1 ? "Open the card on its board" : "Open the board with these cards chosen")
            }
            // The buttons keep their size: where the note is and a passing notice share what's left, truncating.
            Group {
                Button { putOnBoard() } label: { face("Put on Board", symbol: "rectangle.split.3x1", words: words) }
                    .help("A card on this binder's board with the note's title, its first lines and a link back to the note. To put only some of it, select those words and Control-click them.")
                    .accessibilityLabel("Put on Board")
                Menu {
                    DistillToggleItems(note: note) { noteToStop = $0 }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More for this note: Distill This Note")
                .accessibilityLabel("More")
                Button {
                    MarkdownEditor.flushAll()
                    historyFrom = nil
                    showingHistory = true
                } label: { face("History", symbol: "clock.arrow.circlepath", words: words) }
                    .help("Earlier versions of this note, to read or put back")
                    .accessibilityLabel("History")
                Button {
                    MarkdownEditor.flushAll()
                    TextInserter.copyToClipboard(note.text)
                } label: { face("Copy", symbol: "doc.on.doc", words: words, icon: false) }
                    .help("Copy the note as Markdown")
                    .accessibilityLabel("Copy")
                Button(role: .destructive) {
                    if (team.isConfigured && (note.sharedWithTeam || note.isTeamCopy)) || TeamNotes.current?.covers(note) == true { confirmDelete = true } else { delete() }
                } label: { face("Delete", symbol: "trash", words: words, icon: false) }
                    .help("Delete this note")
                    .accessibilityLabel("Delete")
                    .fitProbe("note.bottom.last")
            }
            .modifier(BottomRowButtons(words: words))
        }
        .confirmsStopDistilling($noteToStop, controller: controller)
        .fitProbe(words ? "note.bottom.labels" : "note.bottom.icons")
    }

    /// A bottom-row button's face: its words (with its icon, for those that have one there), or its icon alone.
    @ViewBuilder
    private func face(_ title: String, symbol: String, words: Bool, icon: Bool = true) -> some View {
        if !words {
            Image(systemName: symbol)
        } else if icon {
            Label(title, systemImage: symbol)
        } else {
            Text(title)
        }
    }

    /// Which binder and folder the note is in, and sharing, as a menu that moves it. Whole, it's the pop-up it always was;
    /// short of room, its words truncate in the middle, so the binder's name and the folder it's in still show.
    @ViewBuilder
    private func placeMenu(_ binder: BinderRecord, width: PlaceWidth) -> some View {
        // Made from what you said, it's on this Mac only, though its binder is shared.
        let shared = binder.sharedWithTeam && !note.staysUnshared
        let place = ([binder.name] + Store.shared.folderNames(Store.shared.shownFolder(note.folderID, in: binder.id))).joined(separator: " › ")
        let title = shared ? "\(place) · shared" : binder.sharedWithTeam ? "\(place) · on this Mac only" : place
        let symbol = shared ? "person.2" : "books.vertical"
        if width == .whole {
            Menu { placeItems(binder) } label: { Label(title, systemImage: symbol) }
                .controlSize(.small)
                .fixedSize()
        } else {
            Menu { placeItems(binder) } label: {
                HStack(spacing: 4) {
                    Image(systemName: symbol).imageScale(.small)
                    Text(title).lineLimit(1).truncationMode(.middle)
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
                }
                .font(.system(size: NSFont.smallSystemFontSize))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(BindersTheme.ink.opacity(0.06)))
                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(BindersTheme.line))
                .contentShape(Rectangle())
                .modifier(IdealWidthCap(cap: width == .capped ? 180 : nil))
            }
            // A borderless menu draws no label of its own making: the plain button style draws this one, words and all.
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .accessibilityLabel("In \(title)")
        }
    }

    @ViewBuilder
    private func placeItems(_ binder: BinderRecord) -> some View {
        // A teammate's note stays in their binder; within it, any folder.
        if !note.isTeamCopy {
            Section("Binder") {
                MoveToBinderItems(current: note.binderID) { target in
                    MarkdownEditor.flushAll()
                    NoteMoves.move([note], to: target, undoManager: undoManager)
                }
            }
        }
        Section("Folder in \(binder.name)") {
            MoveToFolderItems(binderID: binder.id, current: Store.shared.shownFolder(note.folderID, in: binder.id)) { target in
                MarkdownEditor.flushAll()
                NoteMoves.move([note], toFolder: target, in: binder.id, undoManager: undoManager)
            }
        }
    }

    /// Put on Board: a card in the note's binder (lane DS6: for the words selected in it, one, or one per line), and a word
    /// that says where, with Open, for a few seconds.
    private func putOnBoard(selection: NSRange = NSRange(location: 0, length: 0), eachLine: Bool = false) {
        guard let put = NotePutOnBoard.put(note, selection: selection, eachLine: eachLine, controller: controller) else { return }
        let first = put.cards[0].id
        withAnimation { boardNotice = (put.cards, put.line) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            if boardNotice?.cards.first?.id == first { withAnimation { boardNotice = nil } }
        }
    }

    /// Says how many links a new title changed, for a few seconds.
    private func renamed(_ rename: LinkRename) {
        let notice = rename.summary
        DispatchQueue.main.async {
            withAnimation { renameNotice = notice }
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                if renameNotice == notice { withAnimation { renameNotice = nil } }
            }
        }
    }

    /// Whether the Distill list shows: beside the note, or over it where there's no room.
    private func distillShown(column: CGFloat?) -> Bool {
        guard note.distill else { return false }
        return column == nil ? distillOver : digestVisible && sidePanel == "distill"
    }

    /// What the editor lights of the Distill list (lane DS9).
    private func editorDistill(listShown: Bool) -> EditorDistill? {
        guard note.distill else { return nil }
        let service = controller.distill
        let list = service.list(for: note.id)
        let accent = binderTint.map { BinderPalette.nsColor($0.index) } ?? BindersTheme.NS.accent
        return list.editorDistill(service: service, rows: list.rows(service, text: note.text), stage: stage, accent: accent,
                                  reduceMotion: reduceMotion, listShown: listShown) { [note] id in
            list.selected = id
            DistillActions.open(note.id)
        }
    }

    /// Beside the note: for a Distill note, its Distill list (lane DS9), Work or digest and properties; for one with cards
    /// (lane DS6), its Work or its digest and properties; for any other, the digest and properties.
    @ViewBuilder
    private var digestColumn: some View {
        if note.distill || DistillBoard.hasCards(note.id) {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Beside the note", selection: $sidePanel) {
                    if note.distill { Text("Distill").tag("distill") }
                    Text("Work").tag("work")
                    Text("Digest").tag("digest")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding([.horizontal, .top], 16)
                if sidePanel == "distill", note.distill {
                    DistillListPanel(note: note).padding(.horizontal, 16).padding(.bottom, 16)
                } else if sidePanel == "work" || sidePanel == "distill" {
                    ScrollView { WorkPanel(note: note).padding(.horizontal, 16).padding(.bottom, 16) }
                } else {
                    digestAndProperties
                }
            }
        } else {
            digestAndProperties
        }
    }

    /// The model's short take on the note, kept next to it and searchable in Knowledge.
    private var digestAndProperties: some View {
        VStack(alignment: .leading, spacing: 10) {
            NotePropertiesPanel(note: note)
            Divider().padding(.vertical, 4)
            HStack {
                Text("Digest").font(BindersTheme.cardTitle).foregroundStyle(.sectionInk)
                Spacer()
                if !note.digest.isEmpty {
                    Button(action: copyDigest) {
                        Image(systemName: digestCopied ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .quietControl()
                    .help("Copy the digest as Markdown")
                }
                if digesting {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        MarkdownEditor.flushAll()
                        Task { await knowledge.digest(note) }
                    } label: {
                        // The model writes it; no agent does, so not the sparkle.
                        Image(systemName: note.digest.isEmpty ? BindersTheme.modelSymbol : "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .quietControl()
                    .disabled(note.text.wordCount < 3)
                    .help(note.digest.isEmpty ? "Write a digest with your local model" : "Write the digest again")
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if let digestIssue {
                        StatusLabel(digestIssue, .problem)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    if note.digest.isEmpty {
                        if digestIssue == nil {
                            Text(digestPlaceholder)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } else {
                        if digestStale {
                            Label(digesting ? "Updating…" : "The note changed since this was written.", systemImage: "clock")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        MarkdownBlocks(markdown: note.digest, foldable: true, onToggleTask: { line in
                            note.digest = NotesEditing.toggleCheckbox(in: note.digest, line: line)
                        })
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contextMenu {
                            Button("Copy Digest", action: copyDigest)
                        }
                    }
                    // Notes and meetings that link to this one, or mention it.
                    Divider().padding(.vertical, 6)
                    MentionsPanel(title: note.title, excluding: note.id)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
        .task { await LinkTargets.refreshEntities(knowledge) }
    }

    /// The whole digest, as Markdown, so it pastes cleanly into another note, Obsidian or a message.
    private func copyDigest() {
        TextInserter.copyToClipboard(note.digest.trimmingCharacters(in: .whitespacesAndNewlines))
        digestCopied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            digestCopied = false
        }
    }

    private var digestIssue: String? {
        digesting ? nil : knowledge.digestIssues[note.id]
    }

    private var digestPlaceholder: String {
        if digesting { return "Reading the note…" }
        if note.text.wordCount < NoteDigest.minimumWords {
            return "Short notes speak for themselves. Click the wand to digest this one anyway."
        }
        if !settings.noteDigests {
            return "Digests are off in Settings → Knowledge. Click the wand to write one now."
        }
        return "A digest is written about a minute and a half after you stop editing: a title, a summary, key points and to-dos, all searchable in Knowledge."
    }

    private func delete() {
        onDelete()
        if (team.isConfigured && (note.sharedWithTeam || note.isTeamCopy)) || TeamNotes.current?.covers(note) == true {
            Self.remove(note)
        } else {
            NoteTrash.shared.delete(note, undoManager: undoManager)
        }
    }

    /// For good, history and all: for notes shared with the team, once deleting for everyone was confirmed.
    static func remove(_ note: NoteItem) {
        ScratchpadController.shared.noteWillBeDeleted(note)
        NotePopouts.shared.close(note.id)
        // Let the editor leave the hierarchy before the model is deleted.
        DispatchQueue.main.async { Store.shared.delete(note) }
    }
}

/// At the top right of a note on its page: the digest beside it, shown or not, and popping the note out. Short of room,
/// Pop Out shows its icon only; with no room for the digest at all, its button says so and waits.
private struct NoteToolbarButtons: View {
    @Environment(\.toolbarIconsOnly) private var iconsOnly
    let note: NoteItem
    @Binding var digestVisible: Bool
    /// Room for the digest beside the note, at this width.
    let room: Bool

    var body: some View {
        HStack(spacing: 4) {
            // Lane DS9: Distill, prominent, in the same place in every note; hidden where the library can't be saved.
            if Store.shared.canSave {
                DistillButton(note: note, compact: iconsOnly)
                    .padding(.trailing, 6)
            }
            Toggle(isOn: Binding(get: { digestVisible && room }, set: { digestVisible = $0 })) {
                Image(systemName: "sidebar.right").frame(width: 24, height: 20)
                    .foregroundStyle(digestVisible && room ? AnyShapeStyle(.tintText) : AnyShapeStyle(.secondary))
            }
            .toggleStyle(.button)
            .disabled(!room)
            .help(!room ? "No room for the digest beside the note at this width. Make the window wider and it comes back."
                  : digestVisible ? "Hide the digest and properties" : "Show the digest and properties beside the note")
            .accessibilityLabel("Digest")
            Button { NotePopouts.shared.open(note) } label: {
                if iconsOnly {
                    Image(systemName: "macwindow.on.rectangle")
                } else {
                    Label("Pop Out", systemImage: "macwindow.on.rectangle").labelStyle(.titleAndIcon).font(.callout)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Open this note in a small window that stays in front of everything and folds into a bubble. Or double-click it in the list.")
            .accessibilityLabel("Pop Out")
            .padding(.leading, 4)
        }
    }
}

/// The note's bottom-row buttons: bordered, as they always were, with their words; borderless icons when short of room.
private struct BottomRowButtons: ViewModifier {
    let words: Bool

    func body(content: Content) -> some View {
        if words {
            content.fixedSize()
        } else {
            content.buttonStyle(.borderless).quietControl().fixedSize()
        }
    }
}
