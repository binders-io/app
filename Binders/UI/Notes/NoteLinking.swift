import SwiftData
import SwiftUI
import BindersKit

/// What [[links]] point to, and going there: notes, meetings and binders by title, and the knowledge graph's people,
/// projects and topics by name. A link to nothing yet makes a note of that name.
@MainActor
enum LinkTargets {
    enum Target {
        case note(NoteItem), meeting(MeetingRecord), binder(BinderRecord), entity(Int64)
    }

    /// The graph's names, read now and then so linking never waits on the index.
    private static var entities: [(id: Int64, name: String)] = []
    private static var entitiesRead = Date.distantPast
    /// Every title's key, for fading links to nothing; built at most every couple of seconds, as it's asked per link.
    private static var keys: Set<String> = []
    private static var keysBuilt = Date.distantPast

    static func refreshEntities(_ knowledge: KnowledgeService) async {
        guard Date().timeIntervalSince(entitiesRead) > 30 else { return }
        entitiesRead = Date()
        entities = await knowledge.store.entities(limit: 2000).map { ($0.id, $0.name) }
        keysBuilt = .distantPast
    }

    private static var notes: [NoteItem] {
        (try? Store.shared.context.fetch(FetchDescriptor<NoteItem>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]))) ?? []
    }

    private static var meetings: [MeetingRecord] {
        (try? Store.shared.context.fetch(FetchDescriptor<MeetingRecord>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)]))) ?? []
    }

    static func resolve(_ title: String) -> Target? {
        let key = WikiLinks.key(title)
        guard !key.isEmpty else { return nil }
        if let note = notes.first(where: { WikiLinks.key($0.title) == key }) { return .note(note) }
        if let meeting = meetings.first(where: { WikiLinks.key($0.title) == key }) { return .meeting(meeting) }
        if let binder = Store.shared.binders(includeArchived: true).first(where: { WikiLinks.key($0.name) == key }) { return .binder(binder) }
        return entities.first { WikiLinks.key($0.name) == key }.map { .entity($0.id) }
    }

    static func exists(_ title: String) -> Bool {
        if Date().timeIntervalSince(keysBuilt) > 2 {
            keysBuilt = Date()
            keys = Set(notes.map { WikiLinks.key($0.title) } + meetings.map { WikiLinks.key($0.title) }
                       + Store.shared.binders(includeArchived: true).map { WikiLinks.key($0.name) } + entities.map { WikiLinks.key($0.name) })
        }
        return keys.contains(WikiLinks.key(title))
    }

    /// Titles to offer after "[[", best first: the most recent notes and meetings when nothing's typed yet.
    static func suggestions(for typed: String) -> [String] {
        var seen = Set<String>()
        let titles = (notes.map(\.title) + meetings.map(\.title) + Store.shared.binders().map(\.name) + entities.map(\.name))
            .filter { $0 != "Untitled note" && seen.insert(WikiLinks.key($0)).inserted }
        let typed = typed.trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty else { return Array(titles.prefix(12)) }
        return titles.compactMap { title in FuzzyMatch.score(typed, in: title).map { (title, $0) } }
            .sorted { $0.1 > $1.1 }
            .prefix(12)
            .map(\.0)
    }

    /// Opens what a link points to, in the Binders window. A link to nothing yet makes a note of that name in `binderID`.
    /// `navigation` is the window's unless given.
    static func open(_ title: String, from binderID: UUID?, in given: HubNavigation? = nil) {
        let navigation: HubNavigation
        if let given {
            navigation = given
        } else {
            HubWindowController.shared.show()
            navigation = HubWindowController.shared.navigation
        }
        func show(binder id: UUID?, tab: BinderTab, then: (HubNavigation) -> Void = { _ in }) {
            navigation.binderID = id ?? Store.shared.defaultBinder().id
            navigation.pendingBinderTab = tab
            then(navigation)
            navigation.selection = .binder
        }
        switch resolve(title) {
        case .note(let note): show(binder: note.binderID, tab: .notes) { $0.pendingNoteID = note.id }
        case .meeting(let meeting): show(binder: meeting.binderID, tab: .meetings) { $0.pendingMeetingID = meeting.id }
        case .binder(let binder): show(binder: binder.id, tab: .overview)
        case .entity(let id):
            navigation.pendingEntityID = id
            navigation.selection = .knowledge
        case nil:
            let binder = Store.shared.binder(binderID) ?? Store.shared.defaultBinder()
            let note = NoteItem(text: "# \(title.trimmingCharacters(in: .whitespaces))\n\n")
            note.binderID = binder.id
            note.sharedWithTeam = binder.sharedWithTeam
            Store.shared.insert(note)
            keysBuilt = .distantPast
            show(binder: binder.id, tab: .notes) { $0.pendingNoteID = note.id }
        }
    }

    /// Everything a note editor in `binderID` needs for its links.
    static func forEditor(in binderID: UUID?) -> NoteLinks {
        NoteLinks(suggestions: { suggestions(for: $0) }, exists: { exists($0) }, open: { open($0, from: binderID) })
    }
}

/// Where something is mentioned: notes that [[link]] to it, then notes and meetings that name it without a link. A note's
/// mention becomes a link with one click.
struct MentionsPanel: View {
    let title: String
    /// The item itself, which isn't listed.
    var excluding: UUID? = nil
    var heading = "Mentioned in"
    @Query(sort: \NoteItem.updatedAt, order: .reverse) private var notes: [NoteItem]
    @Query(sort: \MeetingRecord.createdAt, order: .reverse) private var meetings: [MeetingRecord]

    struct Mention: Identifiable {
        let id: UUID
        let title: String
        let snippet: String
        let isMeeting: Bool
        let linked: Bool
        var note: NoteItem?
        var binderID: UUID?
    }

    private var searchable: Bool { Self.searchable(title) }

    /// Titles too generic to look for.
    static func searchable(_ title: String) -> Bool {
        let key = WikiLinks.key(title)
        return key.count >= 3 && key != "untitled note"
    }

    private var mentions: [Mention] { Self.mentions(of: title, excluding: excluding, notes: notes, meetings: meetings) }

    static func mentions(of title: String, excluding: UUID?, notes: [NoteItem], meetings: [MeetingRecord]) -> [Mention] {
        guard searchable(title) else { return [] }
        var found: [Mention] = []
        for note in notes where note.id != excluding && !note.text.isEmpty {
            if let link = WikiLinks.links(in: note.text).first(where: { WikiLinks.key($0.target) == WikiLinks.key(title) }) {
                found.append(Mention(id: note.id, title: note.title, snippet: Self.snippet(note.text, around: link.range), isMeeting: false, linked: true,
                                     note: note, binderID: note.binderID))
            } else if let range = WikiLinks.plainMention(of: title, in: note.text) {
                found.append(Mention(id: note.id, title: note.title, snippet: Self.snippet(note.text, around: range), isMeeting: false, linked: false,
                                     note: note, binderID: note.binderID))
            }
        }
        for meeting in meetings where meeting.id != excluding {
            for text in [meeting.summary, meeting.userNotes] where !text.isEmpty {
                let linked = WikiLinks.links(in: text).first { WikiLinks.key($0.target) == WikiLinks.key(title) }?.range
                guard let range = linked ?? WikiLinks.plainMention(of: title, in: text) else { continue }
                found.append(Mention(id: meeting.id, title: meeting.title, snippet: Self.snippet(text, around: range), isMeeting: true, linked: linked != nil,
                                     binderID: meeting.binderID))
                break
            }
        }
        return found
    }

    var body: some View {
        let mentions = mentions
        let linked = mentions.filter(\.linked), unlinked = mentions.filter { !$0.linked }
        VStack(alignment: .leading, spacing: 8) {
            Text(heading).font(.headline)
            if mentions.isEmpty {
                Text(searchable ? "Nothing else mentions “\(title)” yet. Type [[ in a note to link to it." : "Give this a title to see where it's mentioned.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(linked.prefix(30)) { row($0) }
            if !unlinked.isEmpty {
                Text("Not linked yet")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, linked.isEmpty ? 0 : 4)
                ForEach(unlinked.prefix(30)) { row($0) }
            }
        }
    }

    private func row(_ mention: Mention) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: mention.isMeeting ? "person.2.wave.2" : "note.text")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                Button(mention.title) { LinkTargets.open(mention.title, from: mention.binderID) }
                    .buttonStyle(.link)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text(mention.snippet)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if !mention.linked, let note = mention.note {
                Button("Link") {
                    if let text = WikiLinks.linkingFirstMention(of: title, in: note.text) {
                        note.text = text
                        note.updatedAt = Date()
                        Store.shared.save()
                    }
                }
                .controlSize(.small)
                .help("Make this mention of “\(title)” a link")
            }
        }
    }

    /// The words around a mention, on one line, without markup brackets.
    static func snippet(_ text: String, around range: NSRange) -> String {
        let string = text as NSString
        let line = string.lineRange(for: range)
        var snippet = string.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines)
        snippet = snippet.replacingOccurrences(of: #"^([-*+]|\d+\.)\s+(\[[ xX]\]\s+)?|^#+\s+"#, with: "", options: .regularExpression)
        // A link reads as what it shows.
        snippet = snippet.replacingOccurrences(of: #"\[\[[^\]|]+\|([^\]]+)\]\]"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"\[\[([^\]]+)\]\]"#, with: "$1", options: .regularExpression)
        return snippet.count > 140 ? String(snippet.prefix(140)) + "…" : snippet
    }
}
