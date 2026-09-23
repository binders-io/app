import Foundation
import SwiftData
import BindersKit

@Model
final class TranscriptRecord {
    @Attribute(.unique) var id: UUID
    var createdAt: Date
    /// "dictation" or "command"
    var mode: String
    var rawText: String
    var finalText: String
    var appName: String?
    var bundleID: String?
    var category: String?
    var duration: Double
    var wordCount: Int
    var asrMillis: Int
    var llmMillis: Int
    var engine: String
    var llmModel: String?
    var usedLLM: Bool
    var fallbackReason: String?
    var audioFileName: String?
    /// inserted, empty, failed
    var status: String
    var errorMessage: String?

    init(id: UUID = UUID(), createdAt: Date = Date(), mode: String, rawText: String, finalText: String, appName: String?,
         bundleID: String?, category: String?, duration: Double, asrMillis: Int, llmMillis: Int, engine: String,
         llmModel: String?, usedLLM: Bool, fallbackReason: String?, audioFileName: String?, status: String,
         errorMessage: String? = nil) {
        self.id = id
        self.createdAt = createdAt
        self.mode = mode
        self.rawText = rawText
        self.finalText = finalText
        self.appName = appName
        self.bundleID = bundleID
        self.category = category
        self.duration = duration
        self.wordCount = finalText.wordCount
        self.asrMillis = asrMillis
        self.llmMillis = llmMillis
        self.engine = engine
        self.llmModel = llmModel
        self.usedLLM = usedLLM
        self.fallbackReason = fallbackReason
        self.audioFileName = audioFileName
        self.status = status
        self.errorMessage = errorMessage
    }

    var audioURL: URL? {
        audioFileName.map { AppPaths.audio.appendingPathComponent($0) }
    }
}

@Model
final class DictionaryWord {
    @Attribute(.unique) var id: UUID
    var term: String
    var aliases: [String]
    var createdAt: Date
    /// manual, auto, wispr
    var source: String

    init(term: String, aliases: [String] = [], source: String = "manual") {
        self.id = UUID()
        self.term = term
        self.aliases = aliases
        self.createdAt = Date()
        self.source = source
    }
}

@Model
final class SnippetItem {
    @Attribute(.unique) var id: UUID
    var trigger: String
    var expansion: String
    var createdAt: Date

    init(trigger: String, expansion: String) {
        self.id = UUID()
        self.trigger = trigger
        self.expansion = expansion
        self.createdAt = Date()
    }
}

/// A binder: one thing you're working on. Every meeting and note lives in exactly one, and sharing with the team is
/// decided per binder, not per item.
@Model
final class BinderRecord {
    @Attribute(.unique) var id: UUID
    var name: String
    /// Index into the binder palette, so binders stay visually distinct.
    var colorIndex: Int
    var createdAt: Date
    var updatedAt: Date
    /// Where things go when no binder was chosen; there is always one.
    var isDefault: Bool = false
    var archived: Bool = false
    /// Team space: everything in a shared binder syncs; a teammate's binder is a read-only copy here.
    var sharedWithTeam: Bool = false
    var isTeamCopy: Bool = false
    var teamAuthorName: String?
    var teamAuthorID: String?

    static let paletteSize = 8

    init(name: String, colorIndex: Int = 0) {
        self.id = UUID()
        self.name = name
        self.colorIndex = colorIndex
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}

@Model
final class NoteItem {
    @Attribute(.unique) var id: UUID
    var text: String
    /// The binder this note is filed in (nil only until `Store.ensureBinders` has run).
    var binderID: UUID?
    var createdAt: Date
    var updatedAt: Date
    /// Team space: shared with teammates by this Mac, or a teammate's note synced here.
    var sharedWithTeam: Bool = false
    var isTeamCopy: Bool = false
    var teamAuthorName: String?
    var teamAuthorID: String?
    /// The local model's digest of the note (title, summary, key points, to-dos) and the hash of the text it was written for.
    var digest: String = ""
    var digestHash: String = ""

    init(text: String = "") {
        self.id = UUID()
        self.text = text
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    var title: String {
        let firstLine = text.split(separator: "\n", maxSplits: 1).first.map(String.init)?.trimmed ?? ""
        return firstLine.isEmpty ? "Untitled note" : String(firstLine.prefix(80))
    }
}

/// Something you wrote in an allowed app and sent or saved while writing capture was on: the text (after redaction),
/// where it was written, who it was for, and the binder it was filed in.
@Model
final class WritingRecord {
    @Attribute(.unique) var id: UUID
    var createdAt: Date
    var text: String
    var wordCount: Int
    var appName: String?
    var bundleID: String?
    var windowTitle: String?
    var url: String?
    /// Comma-separated names or addresses the writing was addressed to, when known.
    var recipients: String = ""
    var subject: String?
    /// teams, outlook, mail, slack, browser or other.
    var source: String = "other"
    var redactions: Int = 0
    var binderID: UUID?
    /// When the text was checked for promises; nil until it has been.
    var analyzedAt: Date?

    init(text: String) {
        self.id = UUID()
        self.createdAt = Date()
        self.text = text
        self.wordCount = text.wordCount
    }

    var title: String {
        if !recipients.isEmpty { return "To \(recipients)" }
        if let subject, !subject.isEmpty { return subject }
        return windowTitle ?? appName ?? "Writing"
    }
}

/// A promise you made in a captured message, or something you asked of someone there, kept as a to-do.
@Model
final class CommitmentRecord {
    @Attribute(.unique) var id: UUID
    var createdAt: Date
    var task: String
    /// promise (you will do it) or ask (you asked the recipient to).
    var kind: String = "promise"
    /// "You" for promises, the other person's first name for asks.
    var owner: String = "You"
    var to: String?
    var dueAt: Date?
    var dueText: String?
    var quote: String?
    /// open, done or dismissed.
    var status: String = "open"
    var doneAt: Date?
    var sourceWritingID: UUID?
    var sourceApp: String?
    var binderID: UUID?
    var reminderScheduled: Bool = false

    init(task: String, kind: String, owner: String) {
        self.id = UUID()
        self.createdAt = Date()
        self.task = task
        self.kind = kind
        self.owner = owner
    }

    var isPromise: Bool { kind != "ask" }
    /// Added by voice ("add to-do…"), so it came from nobody's message.
    var isTodo: Bool { kind == "todo" }

    var sourceTitle: String {
        if isTodo { return "Added by voice" }
        let who = to.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 } ?? "someone"
        let place = sourceApp.map { " in \($0)" } ?? ""
        return isPromise ? "Promised to \(who)\(place)" : "Asked of \(who)\(place)"
    }
}

@Model
final class MeetingRecord {
    @Attribute(.unique) var id: UUID
    var title: String
    /// The binder this meeting is filed in (nil only until `Store.ensureBinders` has run).
    var binderID: UUID?
    var createdAt: Date
    var endedAt: Date?
    var duration: Double
    /// recording, processing, ready, failed
    var status: String
    var appName: String?
    var attendees: [String]
    var userNotes: String
    var summary: String
    var templateID: String
    /// JSON object: generic speaker label -> name
    var speakerNamesJSON: String
    /// JSON array of {role, text}
    var chatJSON: String
    var micAudioFile: String?
    var systemAudioFile: String?
    var errorMessage: String?
    /// Team space: shared with teammates by this Mac, or a teammate's meeting synced here (read-only).
    var sharedWithTeam: Bool = false
    var isTeamCopy: Bool = false
    var teamAuthorName: String?
    var teamAuthorID: String?

    init(title: String, appName: String?, templateID: String) {
        self.id = UUID()
        self.title = title
        self.createdAt = Date()
        self.duration = 0
        self.status = "recording"
        self.appName = appName
        self.attendees = []
        self.userNotes = ""
        self.summary = ""
        self.templateID = templateID
        self.speakerNamesJSON = "{}"
        self.chatJSON = "[]"
    }

    var speakerNames: [String: String] {
        get { (try? JSONDecoder().decode([String: String].self, from: Data(speakerNamesJSON.utf8))) ?? [:] }
        set { speakerNamesJSON = (try? String(data: JSONEncoder().encode(newValue), encoding: .utf8)) ?? "{}" }
    }

    struct ChatMessage: Codable, Hashable {
        var role: String
        var text: String
    }

    var chat: [ChatMessage] {
        get { (try? JSONDecoder().decode([ChatMessage].self, from: Data(chatJSON.utf8))) ?? [] }
        set { chatJSON = (try? String(data: JSONEncoder().encode(newValue), encoding: .utf8)) ?? "[]" }
    }

    /// The recordings, plus the backup a mic-track rescue leaves next to the mic file.
    var audioURLs: [URL] {
        [micAudioFile, systemAudioFile].compactMap { $0 }.flatMap { name -> [URL] in
            let url = AppPaths.meetings.appendingPathComponent(name)
            return [url, url.deletingPathExtension().appendingPathExtension("original.wav")]
        }
    }
}

@Model
final class MeetingSegmentRecord {
    @Attribute(.unique) var id: UUID
    var meetingID: UUID
    /// microphone or system
    var channel: String
    var start: Double
    var end: Double
    var speaker: String
    var text: String

    init(meetingID: UUID, segment: TranscriptSegment) {
        self.id = segment.id
        self.meetingID = meetingID
        self.channel = segment.channel.rawValue
        self.start = segment.start
        self.end = segment.end
        self.speaker = segment.speaker
        self.text = segment.text
    }

    var segment: TranscriptSegment {
        TranscriptSegment(id: id, channel: AudioChannel(rawValue: channel) ?? .system, start: start, end: end, text: text, speaker: speaker)
    }
}

@MainActor
final class Store {
    static let shared = Store()

    let container: ModelContainer
    var context: ModelContext { container.mainContext }
    /// True when the database couldn't be opened and an empty in-memory store stands in; team sync pauses then.
    let isFallback: Bool
    /// Bumped whenever a meeting's transcript changes, so readers can cache per revision.
    private(set) var segmentRevisions: [UUID: Int] = [:]

    private convenience init() {
        self.init(url: AppPaths.store)
    }

    /// A separate store; the app uses `shared`, self-tests use throwaway files.
    init(url: URL) {
        let schema = Schema([TranscriptRecord.self, DictionaryWord.self, SnippetItem.self, NoteItem.self,
                             MeetingRecord.self, MeetingSegmentRecord.self, BinderRecord.self, WritingRecord.self,
                             CommitmentRecord.self])
        let configuration = ModelConfiguration(schema: schema, url: url)
        do {
            container = try ModelContainer(for: schema, configurations: [configuration])
            isFallback = false
        } catch {
            Log.app.error("Store failed to open, falling back to in-memory: \(error.localizedDescription)")
            container = try! ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
            isFallback = true
        }
    }

    func vocabulary() -> [VocabularyTerm] {
        let words = (try? context.fetch(FetchDescriptor<DictionaryWord>(sortBy: [SortDescriptor(\.createdAt)]))) ?? []
        return words.map { VocabularyTerm(term: $0.term, aliases: $0.aliases) }
    }

    func snippets() -> [SnippetDefinition] {
        let items = (try? context.fetch(FetchDescriptor<SnippetItem>())) ?? []
        return items.map { SnippetDefinition(trigger: $0.trigger, expansion: $0.expansion) }
    }

    func lastTranscript() -> TranscriptRecord? {
        var descriptor = FetchDescriptor<TranscriptRecord>(
            predicate: #Predicate { $0.status == "inserted" },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    func recentTranscripts(limit: Int) -> [TranscriptRecord] {
        var descriptor = FetchDescriptor<TranscriptRecord>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        descriptor.fetchLimit = limit
        return (try? context.fetch(descriptor)) ?? []
    }

    func insert(_ model: some PersistentModel) {
        context.insert(model)
        save()
    }

    func delete(_ model: some PersistentModel) {
        if let record = model as? TranscriptRecord, let url = record.audioURL {
            try? FileManager.default.removeItem(at: url)
        }
        context.delete(model)
        save()
    }

    func save() {
        do { try context.save() } catch { Log.app.error("Save failed: \(error.localizedDescription)") }
    }

    /// Adds a term unless an entry with the same spelling exists; returns true when added.
    @discardableResult
    func addDictionaryWord(_ term: String, aliases: [String] = [], source: String) -> Bool {
        let existing = (try? context.fetch(FetchDescriptor<DictionaryWord>())) ?? []
        if let match = existing.first(where: { $0.term.caseInsensitiveCompare(term) == .orderedSame }) {
            let newAliases = aliases.filter { alias in !match.aliases.contains { $0.caseInsensitiveCompare(alias) == .orderedSame } }
            if !newAliases.isEmpty {
                match.aliases += newAliases
                save()
            }
            return false
        }
        insert(DictionaryWord(term: term, aliases: aliases, source: source))
        return true
    }

    func pruneOldAudio(olderThanDays days: Int) {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        let descriptor = FetchDescriptor<TranscriptRecord>(predicate: #Predicate { $0.createdAt < cutoff && $0.audioFileName != nil })
        for record in (try? context.fetch(descriptor)) ?? [] {
            if let url = record.audioURL { try? FileManager.default.removeItem(at: url) }
            record.audioFileName = nil
        }
        save()
    }

    // MARK: Meetings

    func segments(for meetingID: UUID) -> [TranscriptSegment] {
        let descriptor = FetchDescriptor<MeetingSegmentRecord>(predicate: #Predicate { $0.meetingID == meetingID },
                                                               sortBy: [SortDescriptor(\.start)])
        do {
            return try context.fetch(descriptor).map(\.segment)
        } catch {
            Log.app.error("Couldn't read meeting transcript: \(error.localizedDescription)")
            return []
        }
    }

    func appendSegment(_ segment: TranscriptSegment, to meetingID: UUID) {
        context.insert(MeetingSegmentRecord(meetingID: meetingID, segment: segment))
        segmentRevisions[meetingID, default: 0] += 1
        save()
    }

    func replaceSegments(for meetingID: UUID, with segments: [TranscriptSegment]) {
        try? context.delete(model: MeetingSegmentRecord.self, where: #Predicate { $0.meetingID == meetingID })
        segments.forEach { context.insert(MeetingSegmentRecord(meetingID: meetingID, segment: $0)) }
        segmentRevisions[meetingID, default: 0] += 1
        save()
    }

    // MARK: Writing capture

    func pruneWriting(olderThanDays days: Int) {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        try? context.delete(model: WritingRecord.self, where: #Predicate { $0.createdAt < cutoff })
        save()
    }

    func deleteAllWriting() {
        try? context.delete(model: WritingRecord.self)
        save()
    }

    /// Captures not yet checked for promises, newest first.
    func unanalyzedWriting(limit: Int) -> [WritingRecord] {
        var descriptor = FetchDescriptor<WritingRecord>(predicate: #Predicate { $0.analyzedAt == nil },
                                                        sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        descriptor.fetchLimit = limit
        return (try? context.fetch(descriptor)) ?? []
    }

    func commitments() -> [CommitmentRecord] {
        (try? context.fetch(FetchDescriptor<CommitmentRecord>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)]))) ?? []
    }

    /// Repairs what early builds kept by mistake: captures that are only a field's placeholder ("Type a message"),
    /// recipients that are an object-replacement character, "(You)" tags on names.
    func cleanupWriting() {
        let placeholders: Set<String> = ["type a message", "type a new message", "type your message", "write a message", "reply", "type here"]
        let records = (try? context.fetch(FetchDescriptor<WritingRecord>())) ?? []
        var removed = 0
        var repaired = 0
        for record in records {
            let text = ContextReader.comparable(record.text)
            if placeholders.contains(text) || !text.contains(where: \.isLetter) {
                context.delete(record)
                removed += 1
                continue
            }
            let names = record.recipients.components(separatedBy: ",").compactMap(WritingCleanup.cleanName).joined(separator: ", ")
            if names != record.recipients { record.recipients = names; repaired += 1 }
        }
        for commitment in commitments() {
            let cleaned = commitment.to.flatMap(WritingCleanup.cleanName)
            if cleaned != commitment.to { commitment.to = cleaned; repaired += 1 }
        }
        if removed > 0 || repaired > 0 {
            save()
            Log.app.notice("Writing cleanup: removed \(removed), repaired \(repaired)")
        }
    }

    // MARK: Binders

    /// Binders in sidebar order: the default first, then yours by name, then teammates'.
    func binders(includeArchived: Bool = false) -> [BinderRecord] {
        let all = (try? context.fetch(FetchDescriptor<BinderRecord>())) ?? []
        return all.filter { includeArchived || !$0.archived }.sorted { a, b in
            if a.isDefault != b.isDefault { return a.isDefault }
            if a.isTeamCopy != b.isTeamCopy { return !a.isTeamCopy }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    func binder(_ id: UUID?) -> BinderRecord? {
        guard let id else { return nil }
        return ((try? context.fetch(FetchDescriptor<BinderRecord>(predicate: #Predicate { $0.id == id }))) ?? []).first
    }

    /// The binder new things go into when none was chosen. Created on first use.
    func defaultBinder() -> BinderRecord {
        if let existing = ((try? context.fetch(FetchDescriptor<BinderRecord>(predicate: #Predicate { $0.isDefault }))) ?? []).first {
            return existing
        }
        let binder = BinderRecord(name: "General", colorIndex: 0)
        binder.isDefault = true
        context.insert(binder)
        save()
        return binder
    }

    /// Files everything that isn't in a binder yet: your private items into General, what you had shared into a
    /// shared "Shared" binder so nothing changes hands, and teammates' items into a binder per author until their
    /// files say which binder they belong to.
    func ensureBinders() {
        let general = defaultBinder()
        var shared: BinderRecord?
        var byAuthor: [String: BinderRecord] = [:]
        func sharedBinder() -> BinderRecord {
            if let shared { return shared }
            let existing = binders(includeArchived: true).first { !$0.isTeamCopy && $0.sharedWithTeam && $0.name == "Shared" }
            let binder = existing ?? BinderRecord(name: "Shared", colorIndex: 2)
            if existing == nil {
                binder.sharedWithTeam = true
                context.insert(binder)
            }
            shared = binder
            return binder
        }
        func authorBinder(id: String?, name: String?) -> BinderRecord {
            let key = id ?? name ?? "team"
            if let binder = byAuthor[key] { return binder }
            let existing = binders(includeArchived: true).first { $0.isTeamCopy && ($0.teamAuthorID ?? "") == (id ?? "") && $0.teamAuthorName == name }
            let binder = existing ?? BinderRecord(name: "From \(name ?? "the team")", colorIndex: 5)
            if existing == nil {
                binder.isTeamCopy = true
                binder.sharedWithTeam = true
                binder.teamAuthorID = id
                binder.teamAuthorName = name
                context.insert(binder)
            }
            byAuthor[key] = binder
            return binder
        }
        var changed = false
        for meeting in (try? context.fetch(FetchDescriptor<MeetingRecord>(predicate: #Predicate { $0.binderID == nil }))) ?? [] {
            meeting.binderID = meeting.isTeamCopy ? authorBinder(id: meeting.teamAuthorID, name: meeting.teamAuthorName).id
                : (meeting.sharedWithTeam ? sharedBinder().id : general.id)
            changed = true
        }
        for note in (try? context.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.binderID == nil }))) ?? [] {
            note.binderID = note.isTeamCopy ? authorBinder(id: note.teamAuthorID, name: note.teamAuthorName).id
                : (note.sharedWithTeam ? sharedBinder().id : general.id)
            changed = true
        }
        if changed {
            save()
            Log.app.info("Filed existing meetings and notes into binders")
        }
    }

    func binderID(ofMeeting id: UUID?) -> UUID? {
        guard let id else { return nil }
        return ((try? context.fetch(FetchDescriptor<MeetingRecord>(predicate: #Predicate { $0.id == id }))) ?? []).first?.binderID
    }

    func binderID(ofNote id: UUID?) -> UUID? {
        guard let id else { return nil }
        return ((try? context.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == id }))) ?? []).first?.binderID
    }

    func counts(in binderID: UUID) -> (meetings: Int, notes: Int) {
        let meetings = (try? context.fetchCount(FetchDescriptor<MeetingRecord>(predicate: #Predicate { $0.binderID == binderID }))) ?? 0
        let notes = (try? context.fetchCount(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.binderID == binderID }))) ?? 0
        return (meetings, notes)
    }

    /// Moves an item into a binder; your items take on the binder's sharing.
    func move(_ meeting: MeetingRecord, to binder: BinderRecord) {
        meeting.binderID = binder.id
        if !meeting.isTeamCopy { meeting.sharedWithTeam = binder.sharedWithTeam }
        save()
    }

    func move(_ note: NoteItem, to binder: BinderRecord) {
        note.binderID = binder.id
        if !note.isTeamCopy { note.sharedWithTeam = binder.sharedWithTeam }
        save()
    }

    /// Deletes a binder after moving its contents somewhere else; the default binder can't be deleted.
    func deleteBinder(_ binder: BinderRecord, movingItemsTo target: BinderRecord) {
        guard !binder.isDefault, binder.id != target.id else { return }
        let binderID = binder.id
        for meeting in (try? context.fetch(FetchDescriptor<MeetingRecord>(predicate: #Predicate { $0.binderID == binderID }))) ?? [] { move(meeting, to: target) }
        for note in (try? context.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.binderID == binderID }))) ?? [] { move(note, to: target) }
        context.delete(binder)
        save()
    }

    func deleteMeeting(_ meeting: MeetingRecord) {
        let meetingID = meeting.id
        segmentRevisions[meetingID, default: 0] += 1
        meeting.audioURLs.forEach { try? FileManager.default.removeItem(at: $0) }
        try? context.delete(model: MeetingSegmentRecord.self, where: #Predicate { $0.meetingID == meetingID })
        context.delete(meeting)
        save()
    }

    func deleteAllHistory() {
        try? context.delete(model: TranscriptRecord.self)
        save()
        if let files = try? FileManager.default.contentsOfDirectory(at: AppPaths.audio, includingPropertiesForKeys: nil) {
            files.forEach { try? FileManager.default.removeItem(at: $0) }
        }
    }
}
