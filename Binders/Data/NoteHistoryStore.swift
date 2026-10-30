import Foundation
import SwiftData
import SwiftUI
import BindersKit

/// Earlier versions of notes, kept as Markdown files in History/<note id>/ next to the database. A version is one editing
/// session (`NoteVersions.beginsSession`): it ends when its author leaves the note or closes its window, after ten minutes
/// without a change, or when someone else edits, a teammate's or an agent's change landing; versions kept before sessions
/// stay as they are. A note with Distill on keeps every version for good, with who made each one (versions.json beside
/// them, `NoteVersionIndex`): a name can be given to one, and Distill marks the one it read.
@MainActor
enum NoteHistory {
    struct Version: Identifiable, Hashable {
        let url: URL
        let date: Date
        let text: String
        var id: URL { url }
        /// Its id in the index and over MCP: the moment it was kept, in milliseconds.
        var stem: String { url.deletingPathExtension().lastPathComponent }
    }

    static var folder: URL { AppPaths.support.appendingPathComponent("History", isDirectory: true) }
    private static func folder(for id: UUID) -> URL { folder.appendingPathComponent(id.uuidString, isDirectory: true) }
    private static func indexURL(for id: UUID) -> URL { folder(for: id).appendingPathComponent("versions.json") }
    /// The last version kept per note, so a keystroke costs a lookup, not a trip to the disk.
    private static var lastKept: [UUID: (date: Date, text: String)] = [:]
    /// Each Distill note's index, as last read or written, with its file's date: read again when the file changed (the
    /// app writes it; `Binders --mcp` reads it).
    private static var indexes: [UUID: (modified: Date?, index: NoteVersionIndex)] = [:]
    /// The editing session going on in each note: who's making it, and when they last changed it.
    private static var sessions: [UUID: NoteVersions.Session] = [:]

    /// Newest first. Files are named by the moment they were kept, in milliseconds.
    static func versions(of id: UUID) -> [Version] {
        ((try? FileManager.default.contentsOfDirectory(at: folder(for: id), includingPropertiesForKeys: nil)) ?? [])
            .compactMap { url -> Version? in
                guard url.pathExtension == "md", let milliseconds = Double(url.deletingPathExtension().lastPathComponent),
                      let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                return Version(url: url, date: Date(timeIntervalSince1970: milliseconds / 1000), text: text)
            }
            .sorted { $0.date > $1.date }
    }

    /// Call before changing a note's text from code: sync, an agent, a tick. `always` makes the change a session of its
    /// own, for changes that aren't typing in the note, such as a teammate's. `author`: who the change is by.
    static func willChange(_ note: NoteItem, to newText: String, always: Bool = false, by author: NoteAuthor = .you) {
        guard newText != note.text else { return }
        changed(note.id, previous: note.text, always: always, by: author)
    }

    /// A note changed from `previous`. When the change begins a new editing session (the one before ended: its author
    /// left, ten minutes went by, someone else makes this one), `previous` is kept as the version that session made, dated
    /// at its last change. For a Distill note, who wrote what is noted, and its sections are then looked at for the cards
    /// made from them (`DistillService`).
    static func changed(_ id: UUID, previous: String, always: Bool = false, by author: NoteAuthor = .you) {
        let last = lastKept[id] ?? versions(of: id).first.map { ($0.date, $0.text) }
        let now = Date()
        let note = Store.shared.note(id)
        var index = note?.distill == true ? self.index(of: id, note: note) : nil
        let authorChanges = index?.authorChanges(to: author) ?? false
        let blank = previous.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let session = sessions[id]
        let begins = authorChanges || NoteVersions.beginsSession(after: session, by: author, at: now, always: always)
        let due = begins && last?.text != previous && !blank
        if due {
            let stem = keep(previous, for: id, at: NoteVersions.versionDate(of: session, now: now, after: last?.date))
            index?.kept(stem, before: author, at: now)
        } else {
            if lastKept[id] == nil, let last { lastKept[id] = last }
            if authorChanges { index?.current = .init(by: author, since: now) }
        }
        sessions[id] = NoteVersions.Session(author: author, last: now)
        if let index {
            // Written only when it changed: a pause in your typing usually changes nothing in it.
            if due || authorChanges { save(index, for: id) }
            DistillService.shared?.noteChanged(id, by: author)
        } else if DistillBoard.followsSections(id) {
            // Lane DS6: cards made with Put on Board from its sections follow them, Distill on or not.
            DistillService.shared?.noteChanged(id, by: author)
        }
    }

    /// You left the note or closed its window: your editing session in it ends, and what it made is kept as a version now,
    /// dated at its last change, unless that's kept already. A session someone else is making (an agent's edit, a
    /// teammate's copy) isn't yours to end: it ends when someone else edits, or after ten minutes.
    static func endSession(_ id: UUID) {
        guard let session = sessions[id], session.author.isYou else { return }
        sessions[id] = nil
        guard let note = Store.shared.note(id) else { return }
        let last = lastKept[id] ?? versions(of: id).first.map { ($0.date, $0.text) }
        guard last?.text != note.text, !note.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let stem = keep(note.text, for: id, at: NoteVersions.versionDate(of: session, now: Date(), after: last?.date))
        guard note.distill else { return }
        var index = self.index(of: id, note: note)
        var version = index.versions[stem] ?? .init(by: index.current?.by ?? session.author)
        version.by = index.current?.by ?? session.author
        if let from = index.current?.restoredFrom { version.restoredFrom = from }
        index.versions[stem] = version
        save(index, for: id)
    }

    @discardableResult
    static func keep(_ text: String, for id: UUID, at date: Date) -> String {
        let directory = folder(for: id)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = String(Int64(date.timeIntervalSince1970 * 1000))
        try? text.write(to: directory.appendingPathComponent(name).appendingPathExtension("md"), atomically: true, encoding: .utf8)
        lastKept[id] = (date, text)
        // A note with Distill on keeps every version for good.
        guard Store.shared.note(id)?.distill != true else { return name }
        // By their names, which are their dates: what's expired is known without reading every version's words (lane
        // DB10: a teammate typing keeps a version every few seconds).
        let all = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []).compactMap { url -> (URL, Date)? in
            guard url.pathExtension == "md", let milliseconds = Double(url.deletingPathExtension().lastPathComponent) else { return nil }
            return (url, Date(timeIntervalSince1970: milliseconds / 1000))
        }
        let expired = Set(NoteVersions.expired(all.map(\.1), now: date))
        for (url, kept) in all where expired.contains(kept) { try? FileManager.default.removeItem(at: url) }
        return name
    }

    /// A deleted note's versions.
    static func forget(_ id: UUID) {
        lastKept[id] = nil
        indexes[id] = nil
        sessions[id] = nil
        try? FileManager.default.removeItem(at: folder(for: id))
    }

    /// Clears the versions of notes that are gone: deleted and not put back before the app quit, or removed by sync.
    static func forgetDeletedNotes() {
        // A store that can't be read, or the empty one used when the database won't open, says nothing about which notes
        // are gone.
        guard !Store.shared.isFallback, let notes = try? Store.shared.context.fetch(FetchDescriptor<NoteItem>()) else { return }
        let kept = Set(notes.map(\.id))
        for folder in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
            guard let id = UUID(uuidString: folder.lastPathComponent), !kept.contains(id) else { continue }
            forget(id)
        }
    }

    /// Puts a version back, keeping what's there now as a version first, so a restore can be undone the same way. For a
    /// Distill note the text put back is kept too, as a version of its own by you, so its history is only ever added to.
    static func restore(_ version: Version, to note: NoteItem) {
        let now = Date()
        if note.distill {
            var index = self.index(of: note.id, note: note)
            let before = keep(note.text, for: note.id, at: now)
            index.kept(before, before: .you, at: now, restoring: version.stem)
            note.text = version.text
            let after = keep(version.text, for: note.id, at: now.addingTimeInterval(0.01))
            index.kept(after, before: .you, at: now)
            save(index, for: note.id)
        } else {
            keep(note.text, for: note.id, at: now)
            note.text = version.text
        }
        // Putting a version back is a session of its own: the typing after it begins another.
        sessions[note.id] = nil
        note.updatedAt = Date()
        Store.shared.save()
        if note.distill || DistillBoard.followsSections(note.id) { DistillService.shared?.noteChanged(note.id, by: .you) }
    }

    // MARK: Who made each version (Distill notes)

    /// The note's index; for a note whose index doesn't exist yet, who wrote its text now is worked out from the note.
    static func index(of id: UUID, note: NoteItem? = nil) -> NoteVersionIndex {
        let url = indexURL(for: id)
        let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        if let cached = indexes[id], cached.modified == modified { return cached.index }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var index = (try? Data(contentsOf: url)).flatMap { try? decoder.decode(NoteVersionIndex.self, from: $0) } ?? NoteVersionIndex()
        if index.current == nil, let note = note ?? Store.shared.note(id) {
            index.current = .init(by: author(of: note), since: note.updatedAt)
            index.stamp(note.text, by: author(of: note), at: note.updatedAt)
        }
        indexes[id] = (modified, index)
        return index
    }

    static func save(_ index: NoteVersionIndex, for id: UUID) {
        guard Store.shared.canSave else { return }
        try? FileManager.default.createDirectory(at: folder(for: id), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let url = indexURL(for: id)
        if let data = try? encoder.encode(index) { try? data.write(to: url, options: .atomic) }
        indexes[id] = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date, index)
    }

    /// Who wrote a note's text, as the note itself says: the agent whose edit it carries, the agent that made it, the
    /// teammate who shared it, or you.
    static func author(of note: NoteItem) -> NoteAuthor {
        if let agent = note.editedBy ?? note.madeBy { return .agent(agent, owner: note.isTeamCopy ? note.teamAuthorName : nil) }
        if note.isTeamCopy { return .teammate(note.teamAuthorName ?? "A teammate") }
        return .you
    }

    /// Gives a version a name ("Approved", "v2"), or takes it away with an empty one.
    static func name(_ version: String, of note: NoteItem, _ name: String) {
        var index = self.index(of: note.id, note: note)
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        var entry = index.versions[version] ?? .init(by: index.current?.by ?? .you)
        entry.name = trimmed.isEmpty ? nil : trimmed
        index.versions[version] = entry
        save(index, for: note.id)
    }

    /// The version Distill read: the latest kept, when it's what the note says now, else the note as it is now, kept now.
    /// Marked with the distill. Returns its id.
    @discardableResult
    static func markRead(_ note: NoteItem, by distill: UUID, at date: Date = Date()) -> String {
        var index = self.index(of: note.id, note: note)
        let id: String
        if let latest = versions(of: note.id).first, latest.text == note.text {
            id = latest.stem
        } else {
            id = keep(note.text, for: note.id, at: date)
        }
        var entry = index.versions[id] ?? .init(by: index.current?.by ?? .you)
        if !entry.distills.contains(distill) { entry.distills.append(distill) }
        index.versions[id] = entry
        save(index, for: note.id)
        return id
    }

    /// Marks a version kept earlier (the one an agent was given to read) with the distill that read it.
    static func markVersion(_ version: String, of note: NoteItem, by distill: UUID) {
        var index = self.index(of: note.id, note: note)
        var entry = index.versions[version] ?? .init(by: index.current?.by ?? .you)
        if !entry.distills.contains(distill) { entry.distills.append(distill) }
        index.versions[version] = entry
        save(index, for: note.id)
    }

    /// A version's text by its id, or the note's as it is now for "now".
    static func text(of version: String, note: NoteItem) -> String? {
        if version == NoteVersions.nowID { return note.text }
        let url = folder(for: note.id).appendingPathComponent(version).appendingPathExtension("md")
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// History's list for a note: every version newest first, the note as it is now on top, each with who made it.
    static func entries(of note: NoteItem) -> [NoteVersions.Entry] {
        let texts = versions(of: note.id).map { (id: $0.stem, at: $0.date, text: $0.text) }
        return NoteVersions.entries(texts: texts, now: note.text, index: index(of: note.id, note: note))
    }
}

/// A note's earlier versions: pick one to read it, or what changed since, then copy it or put it back. For a note with
/// Distill on, each says who made it, its name and the distills that read it, any two can be compared, and a version can
/// be given a name.
struct NoteHistorySheet: View {
    @Environment(\.dismiss) private var dismiss
    let note: NoteItem
    /// See What Changed on an agent's edit: opens at the version kept just before that moment, showing what changed since.
    var changesFrom: Date? = nil
    @State private var versions: [NoteHistory.Version] = []
    @State private var selected: NoteHistory.Version?
    @State private var showingChanges = false
    /// What the selected version is compared with, for a Distill note: "now", another version's id, or "" to read it.
    @State private var compareTo = ""
    /// Who made each version, its name and its distills, by id (Distill notes).
    @State private var entries: [String: NoteVersions.Entry] = [:]
    @State private var naming = false
    @State private var name = ""

    var body: some View {
        // A note with "## " headings says which sections each version touched; one without has only its opening.
        let showsSections = DistillSections.sections(of: note.text).contains { $0.heading != nil }
        VStack(spacing: 0) {
            HStack {
                Text("Earlier versions of “\(note.title)”").font(BindersTheme.cardTitle).lineLimit(1)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(16)
            Divider()
            if versions.isEmpty {
                ContentUnavailableView("No earlier versions yet", systemImage: "clock.arrow.circlepath",
                                       description: Text(note.distill ? "Binders keeps every version of a note with Distill on, with who made it." : "Binders keeps a note as it was before each time you edit it, every few minutes while you write, and before a teammate's or an agent's change lands. Versions stay for 30 days."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 0) {
                    // Who wrote the note as it is now, above the versions kept before it.
                    if note.distill, let now = entries[NoteVersions.nowID] {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Now").font(.callout.weight(.semibold))
                            Label(now.by.label, systemImage: now.by.isAgent ? BindersTheme.agentSymbol : "person")
                                .font(.caption)
                                .foregroundStyle(now.by.isAgent ? AnyShapeStyle(BindersTheme.agent) : AnyShapeStyle(.secondary))
                            Text(NoteVersions.counts(added: now.added, removed: now.removed) + " since the version below").font(.caption).foregroundStyle(.secondary)
                            if showsSections, let sections = Self.sectionsLabel(now.sections) {
                                Text(sections).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        Divider()
                    }
                    List(versions, selection: $selected) { version in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(version.date.formatted(date: .abbreviated, time: .shortened)).monospacedDigit()
                                if let name = entries[version.stem]?.name {
                                    Text(name).font(.caption.weight(.semibold)).padding(.horizontal, 5).padding(.vertical, 1)
                                        .background(Capsule().fill(TintFill().opacity(0.14)))
                                }
                            }
                            if let entry = entries[version.stem] {
                                if note.distill {
                                    Label(entry.by.label, systemImage: entry.by.isAgent ? BindersTheme.agentSymbol : "person")
                                        .font(.caption)
                                        .foregroundStyle(entry.by.isAgent ? AnyShapeStyle(BindersTheme.agent) : AnyShapeStyle(.secondary))
                                    ForEach(entry.distills, id: \.self) { distill in
                                        if let line = DistillService.versionMark(distill, note: note.id) {
                                            Label(line, systemImage: "square.stack.3d.down.right").font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                // Its own change, from the version before it, and the sections it touched.
                                Text(changeLabel(version, entry: entry)).font(.caption).foregroundStyle(.secondary)
                                if showsSections, let sections = Self.sectionsLabel(entry.sections) {
                                    Text(sections).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                            }
                        }
                        .tag(version)
                    }
                    .scrollContentBackground(.hidden)
                    }
                    .background(BindersTheme.ground2)
                    .frame(width: 250)
                    Divider()
                    if let selected {
                        VStack(alignment: .leading, spacing: 0) {
                            ScrollView {
                                if showingChanges {
                                    NoteChangesView(lines: NoteVersions.lines(from: selected.text, to: comparedText))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(20)
                                } else {
                                    MarkdownBlocks(markdown: selected.text, onToggleTask: nil)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(20)
                                }
                            }
                            Divider()
                            HStack {
                                Button("Copy") { TextInserter.copyToClipboard(selected.text) }
                                if note.distill {
                                    // Compare it with any other version, or with the note now; or just read it.
                                    Picker("Compare", selection: $compareTo) {
                                        Text("Read It").tag("")
                                        Text("Compare with Now").tag(NoteVersions.nowID)
                                        ForEach(versions.filter { $0.stem != selected.stem }) { other in
                                            Text("Compare with " + other.date.formatted(date: .abbreviated, time: .shortened) + (entries[other.stem]?.name.map { " · \($0)" } ?? ""))
                                                .tag(other.stem)
                                        }
                                    }
                                    .labelsHidden()
                                    .fixedSize()
                                    .help("What changed from this version to another, or to the note as it is now")
                                    .onChange(of: compareTo) { showingChanges = !compareTo.isEmpty }
                                    Button("Name…") {
                                        name = entries[selected.stem]?.name ?? ""
                                        naming = true
                                    }
                                    .help("Give this version a name, such as Approved or v2")
                                    .popover(isPresented: $naming) {
                                        HStack {
                                            TextField("Approved, v2…", text: $name).frame(width: 180).onSubmit(saveName)
                                            Button("Save", action: saveName).keyboardShortcut(.defaultAction)
                                        }
                                        .padding(12)
                                    }
                                } else {
                                    Toggle("Show Changes Since", isOn: $showingChanges)
                                        .toggleStyle(.button)
                                        .help("What changed from this version to the note as it is now")
                                }
                                Spacer()
                                Button("Restore This Version") {
                                    NoteHistory.restore(selected, to: note)
                                    dismiss()
                                }
                                .help(note.distill ? "Puts this version back as a new version. Nothing in the history is taken away."
                                      : "Puts this version back. What's there now is kept as a version, so you can go back to it.")
                            }
                            .padding(12)
                        }
                    }
                }
            }
        }
        .frame(width: 820, height: 560)
        .pageGround()
        .task {
            versions = NoteHistory.versions(of: note.id)
            reloadEntries()
            // The version kept as the change landed is from the same moment, give or take the rounding of its name.
            let before = changesFrom.flatMap { moment in versions.first { $0.date <= moment.addingTimeInterval(1) } }
            selected = before ?? versions.first
            showingChanges = before != nil
            if before != nil { compareTo = NoteVersions.nowID }
        }
        .onChange(of: selected) {
            guard note.distill else { return }
            compareTo = ""
            showingChanges = false
        }
    }

    private var comparedText: String {
        compareTo.isEmpty || compareTo == NoteVersions.nowID ? note.text : versions.first { $0.stem == compareTo }?.text ?? note.text
    }

    /// Every version's own change and sections, for any note; who made each, its name and its distills, for a Distill note.
    private func reloadEntries() {
        entries = Dictionary(NoteHistory.entries(of: note).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    private func saveName() {
        guard let selected else { return }
        NoteHistory.name(selected.stem, of: note, name)
        naming = false
        reloadEntries()
    }

    /// The version's own change, from the version before it: "3 lines added, 1 removed"; for the earliest kept, which has
    /// none before it, that it's the earliest.
    private func changeLabel(_ version: NoteHistory.Version, entry: NoteVersions.Entry) -> String {
        if version.stem == versions.last?.stem { return "The earliest version kept" }
        return NoteVersions.counts(added: entry.added, removed: entry.removed)
    }

    /// "In Auth flow, Billing and 2 more", "In the opening": the sections a version touched. Nil for none.
    static func sectionsLabel(_ sections: [String]) -> String? {
        guard !sections.isEmpty else { return nil }
        let named = sections.map { $0 == DistillSections.openingTitle ? "the opening" : $0 }
        let shown = named.count > 3 ? Array(named.prefix(2)) + ["\(named.count - 2) more"] : named
        return "In " + DistillProgress.list(shown)
    }
}

/// What changed from a version to the note as it is now, line by line: what was taken out struck through, what was
/// added marked with a plus, the rest as it was.
struct NoteChangesView: View {
    let lines: [NoteVersions.Line]

    private var unchanged: Bool {
        lines.allSatisfy { line in
            if case .same = line { return true }
            return false
        }
    }

    var body: some View {
        if unchanged {
            Text("Nothing has changed since this version.").foregroundStyle(.secondary)
        } else {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    row(line)
                }
            }
            .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func row(_ line: NoteVersions.Line) -> some View {
        switch line {
        case .same(let text):
            mark(" ", text).foregroundStyle(.secondary)
        case .added(let text):
            mark("+", text)
                .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(.infoFill(0.12)))
                .accessibilityLabel("Added: \(text)")
        case .removed(let text):
            mark("−", text, struck: true).foregroundStyle(.secondary)
                .accessibilityLabel("Taken out: \(text)")
        }
    }

    private func mark(_ sign: String, _ text: String, struck: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(sign).monospaced().frame(width: 12)
            Text(text.isEmpty ? " " : text).strikethrough(struck).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 1)
        .accessibilityElement(children: .combine)
    }
}
