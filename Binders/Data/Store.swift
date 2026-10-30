import Foundation
import SwiftData
import BindersKit

@Model
final class TranscriptRecord {
    @Attribute(.unique) var id: UUID
    var createdAt: Date
    /// "dictation", "command", or "moment" (something you said to yourself near your iPhone)
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
    /// inserted, empty, failed; for a moment, answered
    var status: String
    var errorMessage: String?
    /// A moment's state (MomentService): what it was read as, what became of it, what it made.
    var outcomeJSON: String = ""

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
    /// On this binder's board, agents may move cards to Done themselves instead of handing them over for review.
    var agentsMayFinish: Bool = false
    /// "What goes here", in your words: one line the card router reads, with the latest titles in it, to file a card or a
    /// to-do that doesn't say where it goes. Empty: the titles alone. Not synced to your team.
    var whatGoesHere: String = ""
    /// "Agents may place work items" (lane DS1): an agent's proposal from Distill goes on this board without a person
    /// reviewing it first, its cards meant for whom it suggests as a suggestion. Off unless you turn it on.
    var agentsMayPlace: Bool = false
    /// Shared through a team database (lane DB2): the database's key on this Mac (`TeamDatabaseServer.key`), so its board
    /// goes through it. Empty for a binder that isn't.
    var teamDatabaseKey: String = ""
    /// Who made it in the team, by name, when it wasn't you: "From Dana". Empty otherwise.
    var teamMadeBy: String = ""
    /// Linked to a project on a hub (HubLinks): where (`HubLink.Place`, as JSON). Empty for a binder that isn't.
    var hubLink: String = ""

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
    /// Its properties: where it's at, whose it is, when it's due.
    var status: String?
    var owner: String?
    var dueAt: Date?
    /// The agent that wrote it over MCP, if one did: shown on the note, and its #corrections don't steer answers.
    var madeBy: String?
    /// The agent that last changed it over MCP when it isn't that agent's own note (append_to_note, update_note), and
    /// when. Like `madeBy`, it holds until you make the note yours.
    var editedBy: String?
    var editedAt: Date?
    /// Made from what you said to yourself (a moment), or quoting a capture: it stays unshared wherever it's filed or
    /// moved, a binder shared with your team included (Store.move, TeamSyncService.setShared), and team sync never sends
    /// it. Marked on the note itself, so deleting History, where the moment is kept, doesn't unmark it.
    var staysUnshared: Bool = false
    /// The folder it's filed in, in its binder (FolderRecord); nil at the top. One that isn't in its binder (a
    /// teammate's that hasn't synced yet) reads as the top.
    var folderID: UUID?
    /// Distill is on (lane DS1): its Work bar, its whole history kept, and a row in its binder's Work list. Off until you
    /// turn it on; `binders_distill: true` in the Markdown copy.
    var distill: Bool = false

    /// An agent's words in it, until you make it yours: labelled wherever it shows, left out of answers, and a correction
    /// in it steers nothing.
    var agentMark: AgentMark { AgentMark(madeBy: madeBy, editedBy: editedBy, editedAt: editedAt) }

    /// An agent changed it: marked as that agent's edit, unless it's the agent's own note. True when it was marked.
    @discardableResult
    func markEdited(by agent: String, at date: Date = Date()) -> Bool {
        guard AgentMark.marksEdit(by: agent, madeBy: madeBy) else { return false }
        editedBy = agent
        editedAt = date
        return true
    }

    /// Make It Mine: an agent's words in it count as yours from now on.
    func makeMine() {
        madeBy = nil
        editedBy = nil
        editedAt = nil
    }

    var properties: NoteProperties {
        get { NoteProperties(status: status, owner: owner, due: dueAt, distill: distill) }
        set {
            status = newValue.status
            owner = newValue.owner
            dueAt = newValue.due
            distill = newValue.distill
        }
    }

    init(text: String = "") {
        self.id = UUID()
        self.text = text
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    var title: String {
        let title = MarkdownSyntax.noteTitle(text)
        return title.isEmpty ? "Untitled note" : title
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
    /// Where a to-do came from (TodoOrigin): automations run for the ones you made, and for the others only when a rule
    /// takes them. Nil for promises and for to-dos from before it was kept.
    var origin: String?
    /// Who added it when that wasn't you, as the board says who made a card: the agent or tool ("Claude Code"), or
    /// "a link" for binders://todo.
    var madeBy: String?
    /// A teammate's, shared through a team database (lane DB4): their member id and name, and where it came from in their
    /// words. Nil for yours. You can tick, reopen or dismiss it; the rest is theirs.
    var teamAuthorID: String?
    var teamAuthorName: String?
    var teamSource: String?

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
    var todoOrigin: TodoOrigin? { origin.flatMap(TodoOrigin.init(rawValue:)) }

    /// Where it came from, where to-dos show it: "Added by Claude Code", "Added by a link", "Promised to Sam in Mail"; a
    /// teammate's says whose: "From Dana: Added by voice".
    var sourceTitle: String {
        if let teamAuthorName { return TeamTodoValues.source(teamSource ?? "", maker: teamAuthorName) }
        if isTodo {
            switch todoOrigin {
            case .agent?:
                let name = (madeBy ?? "").trimmingCharacters(in: .whitespaces)
                return "Added by \(name.isEmpty || BoardRules.isReserved(name) || ["AI agent", "An AI agent"].contains(name) ? "an AI agent" : name)"
            case .link?: return "Added by a link"
            case .phone?: return "Added on your iPhone"
            case .moment?, .suggestion?: return "Said to yourself"
            case .voice?, nil: return "Added by voice"
            }
        }
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
    /// recording, processing, ready, failed; a conversation with nothing worth keeping is trivial (hidden, then deleted).
    var status: String
    /// meeting, or conversation: heard by the iPhone during the day. Conversations are never shared with the team.
    var kind: String = "meeting"
    /// Why a conversation was filed in its binder, in the words of the model that picked it.
    var routingReason: String?
    /// A conversation's suggestions: cards for what you said you'd do, answers to what you asked (JSON).
    var suggestionsJSON: String = "[]"
    /// Lane Y2: what the iPhone vouched for a capture in which it heard only you, and what the reading found (SoloVouch, as
    /// JSON). Empty for every capture that came any other way.
    var soloJSON: String = ""
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
    /// The folder it's filed in, in its binder (FolderRecord); nil at the top. A capture's too.
    var folderID: UUID?
    /// Sent to a linked binder as a note (MeetingNotes): that note, and its words as they were last sent, so sending again
    /// updates the same note and can tell when someone changed it since. Nil for a meeting that wasn't sent.
    var sentNoteID: UUID?
    var sentNoteText: String = ""

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

    static let conversationKind = "conversation"

    var suggestions: [ConversationSuggestion] {
        get { ConversationSuggestion.decodeList(suggestionsJSON) }
        set { suggestionsJSON = ConversationSuggestion.encodeList(newValue) }
    }
    var isConversation: Bool { kind == Self.conversationKind }
    /// A meeting or conversation in words: "Meeting", "Capture".
    var kindName: String { isConversation ? "Capture" : "Meeting" }

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

    /// What Binders says while its library didn't open: on the hub's banner, at the top of the menu bar menu, and in place
    /// of a save you asked for.
    static let unavailableMessage = "Binders couldn't open its library, so nothing new can be saved. Quit and reopen Binders."
    /// What a tool, an agent or the phone hears when it asks Binders to save something then.
    static let refusedMessage = "Binders can't save right now: its library didn't open."
    /// And when it asks to read: the stand-in is empty, which isn't what the library holds.
    static let unreadableMessage = "Binders can't read your binders right now: its library didn't open. The user can quit and reopen Binders."
    /// And what Ask on this Mac says then (the Knowledge page, Command Mode): which notes hold an agent's words, and your
    /// corrections, are in the library.
    static let unanswerableMessage = "Binders can't answer from your binders right now: its library didn't open. Quit and reopen Binders."
    /// And after a dictation or a Command Mode result was pasted then: it went where you asked, and History doesn't have it.
    static let notKeptMessage = "Pasted, but not kept in History: Binders couldn't open its library. Quit and reopen Binders."
    /// The same for a dictation pasted as you said it, as AI formatting didn't answer.
    static let notKeptUnformattedMessage = "Pasted without AI formatting, and not kept in History: Binders couldn't open its library. Quit and reopen Binders."
    /// The same for one copied to the clipboard instead, as you'd switched apps.
    static let notKeptCopiedMessage = "You switched apps, so it was copied to the clipboard. It isn't kept in History: Binders couldn't open its library. Quit and reopen Binders."
    /// And for Paste Last Transcript then: no dictation is kept to paste.
    static let nothingToPasteMessage = "Nothing to paste: dictations aren't kept while Binders can't open its library. Quit and reopen Binders."
    /// What to do about it, on the help page.
    static let unavailableHelp = URL(string: "https://binders.io/help.html#library")!

    let container: ModelContainer
    var context: ModelContext { container.mainContext }
    /// True when the database couldn't be opened and an empty in-memory store stands in. Nothing new is kept then: saves
    /// are refused (`canSave`, `allowsSave()`), phones are turned away so they keep what they have, team sync and indexing
    /// pause, and the hub and the menu bar menu say so.
    let isFallback: Bool
    /// Told when a save you asked for is refused because the library didn't open; the app shows `unavailableMessage`.
    var onRefused: (() -> Void)?
    /// Bumped whenever a meeting's transcript changes, so readers can cache per revision.
    private(set) var segmentRevisions: [UUID: Int] = [:]

    private convenience init() {
        self.init(url: AppPaths.store, failing: Self.failsForSelfTest)
    }

    /// `--selftest-fallback`, in a throwaway folder only: the library counts as one that didn't open, so the test sees
    /// Binders as you would then.
    private static var failsForSelfTest: Bool { AppPaths.isDemo && CommandLine.arguments.contains("--selftest-fallback") }

    /// A separate store; the app uses `shared`, self-tests use throwaway files. `failing` opens the stand-in, as when the
    /// file can't be opened.
    init(url: URL, failing: Bool = false) {
        let schema = Schema([TranscriptRecord.self, DictionaryWord.self, SnippetItem.self, NoteItem.self,
                             MeetingRecord.self, MeetingSegmentRecord.self, BinderRecord.self, WritingRecord.self,
                             CommitmentRecord.self, TaskCard.self, TaskEvent.self, FolderRecord.self])
        let configuration = ModelConfiguration(schema: schema, url: url)
        do {
            if failing { throw CocoaError(.fileReadCorruptFile) }
            container = try ModelContainer(for: schema, configurations: [configuration])
            isFallback = false
        } catch {
            Log.app.error("Store failed to open\(failing ? " (self-test)" : ""), falling back to in-memory: \(error.localizedDescription)")
            container = try! ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
            isFallback = true
        }
    }

    /// Whether anything can be kept: not while the library didn't open, when whatever went into the stand-in would be gone
    /// at quit.
    var canSave: Bool { !isFallback }

    /// For a save you asked for (a window, a shortcut, a link, your voice): true when it can go ahead. While the library
    /// didn't open it says so instead (`onRefused`), and nothing is saved.
    func allowsSave() -> Bool {
        guard isFallback else { return true }
        onRefused?()
        return false
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

    /// Never while the library didn't open: whatever got this far then would show until quit and be gone after. A save you
    /// ask for is refused before it gets here, with why (`allowsSave()`); anything else is dropped, and logged.
    func insert(_ model: some PersistentModel) {
        guard canSave else {
            Log.app.error("Not kept, as the library didn't open: \(String(describing: type(of: model)), privacy: .public)")
            return
        }
        context.insert(model)
        save()
    }

    /// `keepingHistory` leaves a note's earlier versions for Undo; whatever's left is cleared at the next launch.
    func delete(_ model: some PersistentModel, keepingHistory: Bool = false) {
        // A deleted note's earlier versions go with it.
        if let note = model as? NoteItem, self === Store.shared, !keepingHistory {
            NoteHistory.forget(note.id)
            DistillStore.shared.forget(note.id)
        }
        if let record = model as? TranscriptRecord, let url = record.audioURL {
            try? FileManager.default.removeItem(at: url)
        }
        context.delete(model)
        save()
    }

    func save() {
        do { try context.save() } catch { Log.app.error("Save failed: \(error.localizedDescription)") }
    }

    /// Adds a term unless an entry with the same spelling exists; returns true when added. Never while the library didn't
    /// open, so a word learned then isn't announced as kept.
    @discardableResult
    func addDictionaryWord(_ term: String, aliases: [String] = [], source: String) -> Bool {
        guard canSave else { return false }
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

    /// Lines added to a transcript in one save (a teammate's meeting as its lines arrive, lane DB4).
    func appendSegments(_ segments: [TranscriptSegment], to meetingID: UUID) {
        guard !segments.isEmpty else { return }
        segments.forEach { context.insert(MeetingSegmentRecord(meetingID: meetingID, segment: $0)) }
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

    func note(_ id: UUID) -> NoteItem? {
        var descriptor = FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    /// The notes with an agent's words in them that you haven't made yours, by id string (as search results name their
    /// source): what answers leave out and search labels. Read each time, so Make It Mine counts at once.
    func agentMarks() -> [String: AgentMark] {
        let notes = (try? context.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.madeBy != nil || $0.editedBy != nil }))) ?? []
        return Dictionary(notes.compactMap { note in note.agentMark.isEmpty ? nil : (note.id.uuidString, note.agentMark) },
                          uniquingKeysWith: { first, _ in first })
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
        markMomentNotes()
    }

    /// Notes made from what you said to yourself before that was marked on the note itself (`staysUnshared`), found by
    /// their moment's id while History still has it: marked, and unshared if a move had shared one, which takes it off the
    /// team folder at the next sync. Each launch, before team sync starts; it finds nothing once they're marked.
    func markMomentNotes() {
        guard canSave else { return }
        let moments = Array(momentIDs())
        guard !moments.isEmpty else { return }
        let unmarked = (try? context.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { moments.contains($0.id) && !$0.staysUnshared }))) ?? []
        guard !unmarked.isEmpty else { return }
        for note in unmarked where !note.isTeamCopy {
            note.staysUnshared = true
            note.sharedWithTeam = false
        }
        save()
        Log.app.info("Marked \(unmarked.count) notes made from what you said, so they stay unshared")
    }

    func binderID(ofMeeting id: UUID?) -> UUID? {
        guard let id else { return nil }
        return ((try? context.fetch(FetchDescriptor<MeetingRecord>(predicate: #Predicate { $0.id == id }))) ?? []).first?.binderID
    }

    /// True when the id is one of the iPhone's conversations rather than a meeting.
    /// Something you said to yourself near the iPhone, or a note or to-do made from it: it has the moment's id.
    func isMoment(_ id: UUID) -> Bool {
        ((try? context.fetchCount(FetchDescriptor<TranscriptRecord>(predicate: #Predicate { $0.id == id && $0.mode == "moment" }))) ?? 0) > 0
    }

    /// Every moment's id, for checking many notes at once.
    func momentIDs() -> Set<UUID> {
        var descriptor = FetchDescriptor<TranscriptRecord>(predicate: #Predicate { $0.mode == "moment" })
        descriptor.propertiesToFetch = [\.id]
        return Set(((try? context.fetch(descriptor)) ?? []).map(\.id))
    }

    func isConversation(_ id: UUID?) -> Bool {
        guard let id else { return false }
        return ((try? context.fetch(FetchDescriptor<MeetingRecord>(predicate: #Predicate { $0.id == id }))) ?? []).first?.isConversation ?? false
    }

    func binderID(ofNote id: UUID?) -> UUID? {
        guard let id else { return nil }
        return ((try? context.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == id }))) ?? []).first?.binderID
    }

    /// Meetings (not conversations) and notes in a binder.
    func counts(in binderID: UUID) -> (meetings: Int, notes: Int) {
        let meetings = (try? context.fetchCount(FetchDescriptor<MeetingRecord>(predicate: #Predicate { $0.binderID == binderID && $0.kind == "meeting" }))) ?? 0
        let notes = (try? context.fetchCount(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.binderID == binderID }))) ?? 0
        return (meetings, notes)
    }

    /// The iPhone's conversations in a binder, less the ones kept out of sight as small talk.
    func conversationCount(in binderID: UUID, includingTrivial: Bool = false) -> Int {
        let kind = MeetingRecord.conversationKind
        let descriptor = includingTrivial
            ? FetchDescriptor<MeetingRecord>(predicate: #Predicate { $0.binderID == binderID && $0.kind == kind })
            : FetchDescriptor<MeetingRecord>(predicate: #Predicate { $0.binderID == binderID && $0.kind == kind && $0.status != "trivial" })
        return (try? context.fetchCount(descriptor)) ?? 0
    }

    /// Moves an item into a binder, at its top; your items take on the binder's sharing, except conversations, which stay
    /// yours.
    func move(_ meeting: MeetingRecord, to binder: BinderRecord) {
        let moved = meeting.binderID != binder.id
        if moved { meeting.folderID = nil }
        meeting.binderID = binder.id
        if !meeting.isTeamCopy { meeting.sharedWithTeam = binder.sharedWithTeam && !meeting.isConversation }
        // A capture you put in a binder shared through a team database yourself is one you share (lane DB4).
        if moved, meeting.isConversation, !meeting.isTeamCopy { Self.capturesFiled?(meeting.id, binder.id) }
        save()
    }

    /// Told when one of your captures moves into another binder, with its id and the binder (lane DB4): a person moved it,
    /// as the router never files a capture into a binder shared through a team database.
    static var capturesFiled: ((UUID, UUID) -> Void)?

    /// Conversations kept as trivial are deleted a week after they were heard; until then they can be brought back.
    func purgeTrivialConversations(olderThan days: Int = 7, now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        let kind = MeetingRecord.conversationKind
        let old = (try? context.fetch(FetchDescriptor<MeetingRecord>(predicate: #Predicate {
            $0.kind == kind && $0.status == "trivial" && $0.createdAt < cutoff
        }))) ?? []
        for record in old { deleteMeeting(record) }
        if !old.isEmpty { Log.app.info("Deleted \(old.count) trivial conversations older than \(days) days") }
    }

    /// Your notes take on the binder's sharing, except one made from what you said, which stays unshared in a shared
    /// binder too. It goes to the binder's top.
    func move(_ note: NoteItem, to binder: BinderRecord) {
        if note.binderID != binder.id { note.folderID = nil }
        note.binderID = binder.id
        if !note.isTeamCopy { note.sharedWithTeam = binder.sharedWithTeam && !note.staysUnshared }
        save()
    }

    /// Deletes a binder after moving its contents somewhere else; the default binder can't be deleted. They take on that
    /// binder's sharing as any move does (`move`): captures and notes made from what you said stay unshared. They go to
    /// the top of that binder, and the binder's folders go with it.
    func deleteBinder(_ binder: BinderRecord, movingItemsTo target: BinderRecord) {
        guard !binder.isDefault, binder.id != target.id else { return }
        let binderID = binder.id
        for meeting in (try? context.fetch(FetchDescriptor<MeetingRecord>(predicate: #Predicate { $0.binderID == binderID }))) ?? [] { move(meeting, to: target) }
        for note in (try? context.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.binderID == binderID }))) ?? [] { move(note, to: target) }
        for folder in folders(in: binderID) { context.delete(folder) }
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

    /// Never while the library didn't open: the recordings belong to dictations the stand-in doesn't have. Notes made from
    /// moments are marked on the note first, so taking the moments away leaves them unshared.
    func deleteAllHistory() {
        guard allowsSave() else { return }
        markMomentNotes()
        try? context.delete(model: TranscriptRecord.self)
        save()
        if let files = try? FileManager.default.contentsOfDirectory(at: AppPaths.audio, includingPropertiesForKeys: nil) {
            files.forEach { try? FileManager.default.removeItem(at: $0) }
        }
        // The record of how each card was sorted goes with the moments it was about.
        RouterLogFile.shared.clear()
    }
}
