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
                        case "auto": Badge(text: "Learned", color: .blue)
                        case "wispr": Badge(text: "Imported", color: .purple)
                        default: EmptyView()
                        }
                        Button { Store.shared.delete(word) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                    .padding(.vertical, 3)
                }
            }
            .listStyle(.inset)
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
        guard !value.isEmpty else { return }
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
        do {
            let summary = try WisprImporter.importAll()
            UserDefaults.standard.set(true, forKey: "importedFromWispr")
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
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.15)))
                HStack {
                    Text("\(expansion.count)/4000").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Add Snippet") {
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
                            Text("“\(snippet.trigger)”").font(.body.weight(.medium))
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
            Text("Edit Snippet").font(.headline)
            TextField("Trigger", text: $snippet.trigger).textFieldStyle(.roundedBorder)
            TextEditor(text: $snippet.expansion)
                .frame(minHeight: 140)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.15)))
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
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.045)))
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Custom instructions").font(.headline)
                    TextEditor(text: Binding(
                        get: { settings.styles.customInstructions[category.rawValue] ?? "" },
                        set: { settings.styles.customInstructions[category.rawValue] = $0 }))
                        .font(.body)
                        .frame(minHeight: 70)
                        .padding(4)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.15)))
                    Text("For example: “Use British spelling”, “Never use em dashes”, “Sign emails with – Maya”.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("App & website categories").font(.headline)
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
                    Text(tone.displayName).font(.headline)
                    Spacer()
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? Color.accentColor : .secondary)
                }
                Text(tone.example).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 110, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(selected ? 0.08 : 0.035)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(selected ? Color.accentColor : .clear, lineWidth: 1.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct NotesView: View {
    @Environment(HubNavigation.self) private var navigation
    @Environment(TeamSyncService.self) private var team
    @Query private var notes: [NoteItem]
    @State private var selection: UUID?
    @State private var noteToDelete: NoteItem?
    let binderID: UUID?

    /// The notes in one binder, or every note when `binderID` is nil.
    init(binderID: UUID? = nil) {
        self.binderID = binderID
        if let binderID {
            _notes = Query(filter: #Predicate<NoteItem> { $0.binderID == binderID }, sort: [SortDescriptor(\NoteItem.updatedAt, order: .reverse)])
        } else {
            _notes = Query(sort: [SortDescriptor(\NoteItem.updatedAt, order: .reverse)])
        }
    }

    var body: some View {
        content
            .onAppear(perform: consumePendingNote)
            .onChange(of: navigation.pendingNoteID) { consumePendingNote() }
            .onReceive(NotificationCenter.default.publisher(for: TeamSyncService.itemsWillBeRemoved)) { notification in
                // A teammate removed the open note: close it before sync deletes it.
                if let ids = notification.userInfo?["ids"] as? Set<UUID>, let selection, ids.contains(selection) { self.selection = nil }
            }
    }

    private func consumePendingNote() {
        guard let pending = navigation.pendingNoteID else { return }
        selection = pending
        navigation.pendingNoteID = nil
    }

    private var content: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Notes").font(BindersTheme.columnTitle)
                    Spacer()
                    Button {
                        let note = NoteItem()
                        let binder = Store.shared.binder(binderID ?? AppSettings.shared.currentBinderID) ?? Store.shared.defaultBinder()
                        note.binderID = binder.id
                        note.sharedWithTeam = binder.sharedWithTeam
                        Store.shared.insert(note)
                        selection = note.id
                    } label: { Image(systemName: "square.and.pencil") }
                        .buttonStyle(.borderless)
                        .help("New note")
                }
                .padding(.horizontal, 16)
                .padding(.top, 24)
                .padding(.bottom, 8)
                List(notes, selection: $selection) { note in
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
                            Text(note.updatedAt, format: .relative(presentation: .named))
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    }
                    .tag(note.id)
                }
                // ⌫ or ⌦ on the selected note, or right-click: asks once, and Return confirms.
                .onDeleteCommand { noteToDelete = notes.first { $0.id == selection } }
                .onKeyPress(.deleteForward) {
                    guard let note = notes.first(where: { $0.id == selection }) else { return .ignored }
                    noteToDelete = note
                    return .handled
                }
                .contextMenu(forSelectionType: UUID.self) { ids in
                    if let id = ids.first, let note = notes.first(where: { $0.id == id }) {
                        Button("Delete…", role: .destructive) { noteToDelete = note }
                    }
                }
                .confirmationDialog(deleteTitle, isPresented: Binding(get: { noteToDelete != nil }, set: { if !$0 { noteToDelete = nil } }),
                                    presenting: noteToDelete) { note in
                    Button(sharedWithTeam(note) ? "Delete for Everyone" : "Delete", role: .destructive) { delete(note) }
                        .keyboardShortcut(.defaultAction)
                    Button("Cancel", role: .cancel) {}
                } message: { note in
                    Text(sharedWithTeam(note) ? "It's removed for everyone on the team. This can't be undone." : "This can't be undone.")
                }
                Button("Open Scratchpad (\(AppSettings.shared.hotkeys.scratchpad?.displayString() ?? "menu bar"))") {
                    ScratchpadController.shared.show()
                }
                .buttonStyle(.link)
                .padding(12)
            }
            .frame(width: 260)
            Divider()
            if let note = notes.first(where: { $0.id == selection }) {
                NoteEditor(note: note) { selection = neighbour(of: note)?.id }
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
        team.isConfigured && (note.sharedWithTeam || note.isTeamCopy)
    }

    /// The note below this one in the list, or above it at the end, so deleting several in a row is ⌫ ⏎ ⌫ ⏎.
    private func neighbour(of note: NoteItem) -> NoteItem? {
        guard let index = notes.firstIndex(where: { $0.id == note.id }) else { return nil }
        if notes.indices.contains(index + 1) { return notes[index + 1] }
        return index > 0 ? notes[index - 1] : nil
    }

    private func delete(_ note: NoteItem) {
        if selection == note.id { selection = neighbour(of: note)?.id }
        NoteEditor.remove(note)
    }
}

struct NoteEditor: View {
    @Environment(TeamSyncService.self) private var team
    @Environment(KnowledgeService.self) private var knowledge
    @Environment(AppSettings.self) private var settings
    @Bindable var note: NoteItem
    var onDelete: () -> Void
    @State private var confirmDelete = false
    @State private var digestVisible = true
    @State private var digestCopied = false

    private var digesting: Bool { knowledge.digestingNoteIDs.contains(note.id) }
    private var digestStale: Bool { !note.digest.isEmpty && note.digestHash != KnowledgeService.noteContentHash(note.text) }

    var body: some View {
        VStack(spacing: 0) {
            if note.isTeamCopy {
                Label("\(note.teamAuthorName ?? "A teammate") shared this note. Your edits sync to everyone on the team.", systemImage: "person.2")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.top, 16)
            }
            HStack(spacing: 0) {
                MarkdownNoteEditor(text: $note.text, fontSize: 15, placeholder: "Write, or hold fn to dictate.")
                    .onChange(of: note.text) { note.updatedAt = Date() }
                if digestVisible {
                    Divider()
                    digestColumn.frame(width: 300)
                }
            }
            HStack {
                Text("\(note.text.wordCount) words").font(.caption).foregroundStyle(.secondary)
                Button {
                    digestVisible.toggle()
                } label: {
                    Label("Digest", systemImage: "sparkles")
                }
                .controlSize(.small)
                .padding(.leading, 8)
                .help(digestVisible ? "Hide the digest" : "Show the digest: title, summary, key points and to-dos from your local model")
                if !note.isTeamCopy, let binder = Store.shared.binder(note.binderID) {
                    Menu {
                        MoveToBinderItems(current: note.binderID) { target in
                            Store.shared.move(note, to: target)
                            team.scheduleSync(after: 0.5)
                        }
                    } label: {
                        Label(binder.sharedWithTeam ? "\(binder.name) · shared" : binder.name, systemImage: binder.sharedWithTeam ? "person.2" : "books.vertical")
                    }
                    .controlSize(.small)
                    .fixedSize()
                    .padding(.leading, 8)
                    .help("Which binder this note is in. Sharing follows the binder.")
                }
                Spacer()
                Button("Copy") { TextInserter.copyToClipboard(note.text) }
                Button("Delete", role: .destructive) {
                    if team.isConfigured, note.sharedWithTeam || note.isTeamCopy { confirmDelete = true } else { delete() }
                }
            }
            .padding(12)
        }
        .confirmationDialog("Delete this note for everyone on the team?", isPresented: $confirmDelete) {
            Button("Delete for Everyone", role: .destructive, action: delete)
        }
    }

    /// The model's short take on the note, kept next to it and searchable in Knowledge.
    private var digestColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Digest").font(.headline)
                Spacer()
                if !note.digest.isEmpty {
                    Button(action: copyDigest) {
                        Image(systemName: digestCopied ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .help("Copy the digest as Markdown")
                }
                if digesting {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        Task { await knowledge.digest(note) }
                    } label: {
                        Image(systemName: note.digest.isEmpty ? "sparkles" : "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .disabled(note.text.wordCount < 3)
                    .help(note.digest.isEmpty ? "Write a digest with your local model" : "Write the digest again")
                }
            }
            if note.digest.isEmpty {
                Text(digestPlaceholder)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                if digestStale {
                    Label(digesting ? "Updating…" : "The note changed since this was written.", systemImage: "clock")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ScrollView {
                    MarkdownBlocks(markdown: note.digest, onToggleTask: { line in
                        note.digest = NotesEditing.toggleCheckbox(in: note.digest, line: line)
                    })
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contextMenu {
                    Button("Copy Digest", action: copyDigest)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
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

    private var digestPlaceholder: String {
        if digesting { return "Reading the note…" }
        if note.text.wordCount < NoteDigest.minimumWords {
            return "Short notes speak for themselves. Click the sparkles to digest this one anyway."
        }
        if !settings.noteDigests {
            return "Digests are off in Settings → Knowledge. Click the sparkles to write one now."
        }
        return "A digest is written about a minute and a half after you stop editing: a title, a summary, key points and to-dos, all searchable in Knowledge."
    }

    private func delete() {
        onDelete()
        Self.remove(note)
    }

    static func remove(_ note: NoteItem) {
        ScratchpadController.shared.noteWillBeDeleted(note)
        // Let the editor leave the hierarchy before the model is deleted.
        DispatchQueue.main.async { Store.shared.delete(note) }
    }
}
