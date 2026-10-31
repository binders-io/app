import Foundation
import SwiftData
import BindersKit

/// Send to Hub…, from a linked binder's menu, when you choose: what this Mac holds that the hub doesn't, written as notes
/// in the binder, each kind in a folder of its own (Meetings, Captures, Knowledge, Dictations), so HubNotesSync takes
/// them up like any other note. Meetings are written as Send to Binder writes them (MeetingNotes); a capture the same
/// way, with what was heard; the knowledge graph's people, projects and the rest as a note per kind, with each one's
/// links; dictations a note per day. Sending again updates those notes rather than adding more: a meeting or capture
/// keeps its note's id, and the others are found by their folder and title.
@MainActor
enum HubSend {
    enum Part: String, CaseIterable, Identifiable {
        case meetings, captures, knowledge, dictations
        var id: String { rawValue }
        var folder: String {
            switch self {
            case .meetings: "Meetings"
            case .captures: "Captures"
            case .knowledge: "Knowledge"
            case .dictations: "Dictations"
            }
        }
    }

    /// The meetings filed in this binder, finished and yours.
    static func meetings(in binder: BinderRecord) -> [MeetingRecord] {
        let id = binder.id
        let all = (try? Store.shared.context.fetch(FetchDescriptor<MeetingRecord>(predicate: #Predicate { $0.binderID == id && $0.kind == "meeting" && $0.status == "ready" },
                                                                                  sortBy: [SortDescriptor(\.createdAt)]))) ?? []
        return all.filter { !$0.isTeamCopy }
    }

    /// The captures filed in this binder: what was said and heard during the day.
    static func captures(in binder: BinderRecord) -> [MeetingRecord] {
        let id = binder.id
        return (try? Store.shared.context.fetch(FetchDescriptor<MeetingRecord>(predicate: #Predicate { $0.binderID == id && $0.kind == "conversation" && $0.status == "ready" },
                                                                               sortBy: [SortDescriptor(\.createdAt)]))) ?? []
    }

    /// This Mac's dictations and what you said to yourself, with words in them: they belong to no binder.
    static func dictations() -> [TranscriptRecord] {
        let all = (try? Store.shared.context.fetch(FetchDescriptor<TranscriptRecord>(predicate: #Predicate { $0.mode == "dictation" || $0.mode == "moment" },
                                                                                     sortBy: [SortDescriptor(\.createdAt)]))) ?? []
        return all.filter { $0.status != "failed" && !words(of: $0).isEmpty }
    }

    private static func words(of record: TranscriptRecord) -> String {
        let final = record.finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        return final.isEmpty ? record.rawText.trimmingCharacters(in: .whitespacesAndNewlines) : final
    }

    private static let dayFormat: DateFormatter = {
        let format = DateFormatter()
        format.dateFormat = "yyyy-MM-dd"
        return format
    }()

    /// The dictation days, each with its dictations.
    static func dictationDays() -> [(day: String, records: [TranscriptRecord])] {
        Dictionary(grouping: dictations()) { dayFormat.string(from: $0.createdAt) }
            .map { (day: $0.key, records: $0.value) }
            .sorted { $0.day < $1.day }
    }

    /// The binder's folder of that name at its top, made when it isn't there.
    private static func folder(_ part: Part, in binder: BinderRecord) -> FolderRecord {
        let store = Store.shared
        if let found = store.folders(in: binder.id).first(where: { $0.parentID == nil && $0.name == part.folder }) { return found }
        let made = FolderRecord(name: part.folder, binderID: binder.id)
        store.insert(made)
        return made
    }

    /// The note in that folder whose title is `title`, updated to `text`, or a new one there.
    private static func keep(_ text: String, title: String, in folder: FolderRecord, binder: BinderRecord) {
        let store = Store.shared
        let folderID: UUID? = folder.id
        let binderID: UUID? = binder.id
        let there = (try? store.context.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.binderID == binderID && $0.folderID == folderID }))) ?? []
        if let note = there.first(where: { $0.title == title }) {
            if note.text != text {
                note.text = text
                note.updatedAt = Date()
            }
            return
        }
        let note = NoteItem(text: text)
        note.binderID = binder.id
        note.folderID = folder.id
        store.insert(note)
    }

    /// A meeting or capture as its note: updated where it is, or made in its folder.
    private static func keep(_ meeting: MeetingRecord, in folder: FolderRecord, binder: BinderRecord, transcript: Bool) {
        let store = Store.shared
        var words = MeetingNotes.text(of: meeting, transcript: transcript)
        if meeting.isConversation { words = words.replacingOccurrences(of: "# \(meeting.title)", with: "# Capture · \(meeting.title)", options: .anchored) }
        if let note = MeetingNotes.note(of: meeting) {
            if note.text != words {
                note.text = words
                note.updatedAt = Date()
            }
        } else {
            let note = NoteItem(text: words)
            note.binderID = binder.id
            note.folderID = folder.id
            store.insert(note)
            meeting.sentNoteID = note.id
        }
        meeting.sentNoteText = words
    }

    /// The knowledge graph's people, projects and the rest found in this binder, a note per kind, each with its links.
    static func knowledgeNotes(binder: BinderRecord, knowledge: KnowledgeService) async -> [(title: String, text: String)] {
        let entities = await knowledge.store.entities(limit: 2000, binder: binder.id.uuidString)
        var byKind: [String: [String]] = [:]
        for entity in entities {
            let relations = await knowledge.store.relations(of: entity.id)
            var lines = ["## \(entity.name)", "", "Mentioned \(entity.mentions) time\(entity.mentions == 1 ? "" : "s") in \(entity.documents) note\(entity.documents == 1 ? "" : "s"), meeting\(entity.documents == 1 ? "" : "s") or capture\(entity.documents == 1 ? "" : "s")."]
            for relation in relations.prefix(40) {
                lines.append(relation.outgoing ? "- \(relation.label) **\(relation.other)**" : "- **\(relation.other)** \(relation.label) this")
            }
            byKind[entity.type.isEmpty ? "Other" : entity.type.capitalized, default: []].append(lines.joined(separator: "\n"))
        }
        return byKind.keys.sorted().map { kind in
            let title = "Knowledge · \(kind)"
            return (title: title, text: "# \(title)\n\nFrom this binder's knowledge graph on \(Host.current().localizedName ?? "a Mac"), as it was when sent.\n\n" + byKind[kind]!.joined(separator: "\n\n"))
        }
    }

    /// Sends what's chosen, into `binder`. What was written, in words.
    static func send(_ parts: Set<Part>, to binder: BinderRecord, transcripts: Bool, knowledge: KnowledgeService) async -> String {
        let store = Store.shared
        guard HubLinks.place(of: binder) != nil else { return "This binder isn't linked to a hub." }
        guard store.allowsSave() else { return "The library can't save now, so nothing was sent." }
        var done: [String] = []
        if parts.contains(.meetings) {
            let list = meetings(in: binder)
            let folder = folder(.meetings, in: binder)
            for meeting in list { keep(meeting, in: folder, binder: binder, transcript: transcripts) }
            if !list.isEmpty { done.append("\(list.count) meeting\(list.count == 1 ? "" : "s")") }
        }
        if parts.contains(.captures) {
            let list = captures(in: binder)
            let folder = folder(.captures, in: binder)
            for capture in list { keep(capture, in: folder, binder: binder, transcript: true) }
            if !list.isEmpty { done.append("\(list.count) capture\(list.count == 1 ? "" : "s")") }
        }
        if parts.contains(.knowledge) {
            let notes = await knowledgeNotes(binder: binder, knowledge: knowledge)
            let folder = folder(.knowledge, in: binder)
            for note in notes { keep(note.text, title: note.title, in: folder, binder: binder) }
            if !notes.isEmpty { done.append("knowledge in \(notes.count) note\(notes.count == 1 ? "" : "s")") }
        }
        if parts.contains(.dictations) {
            let days = dictationDays()
            let folder = folder(.dictations, in: binder)
            for (day, records) in days {
                let title = "Dictations · \(day)"
                let time = DateFormatter()
                time.dateFormat = "HH:mm"
                let lines = records.map { "- \(time.string(from: $0.createdAt))\($0.appName.map { " · \($0)" } ?? "")\($0.mode == "moment" ? " · to yourself" : ""): \(words(of: $0).replacingOccurrences(of: "\n", with: " "))" }
                keep("# \(title)\n\n" + lines.joined(separator: "\n"), title: title, in: folder, binder: binder)
            }
            if !days.isEmpty { done.append("\(days.count) day\(days.count == 1 ? "" : "s") of dictations") }
        }
        store.save()
        return done.isEmpty ? "Nothing to send." : "Sent \(done.joined(separator: ", ")). They go up to the hub with the binder's notes."
    }
}
