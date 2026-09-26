import CryptoKit
import Foundation
import Observation
import SwiftData
import BindersKit

extension KnowledgeKind {
    var symbol: String {
        switch self {
        case .meeting: "person.2.wave.2"
        case .note: "note.text"
        case .writing: "pencil.line"
        case .dictation: "waveform"
        case .command: "command"
        }
    }

    var singularName: String {
        switch self {
        case .meeting: "Meeting"
        case .note: "Note"
        case .writing: "Message"
        case .dictation: "Dictation"
        case .command: "Voice command"
        }
    }
}

extension KnowledgeHit {
    var metaLine: String {
        var parts = [createdAt.formatted(date: .abbreviated, time: .omitted)]
        if let author { parts.append("shared by \(author)") }
        if let startTime { parts.append(TranscriptFormatter.timestamp(startTime)) }
        if let speaker, !speaker.isEmpty { parts.append(speaker) }
        return parts.joined(separator: " · ")
    }
}

enum EmbeddingError: LocalizedError {
    case modelMissing(String)
    case unsupported(String)
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .modelMissing(let model): "Embedding model “\(model)” isn't installed — download it in Settings → Knowledge (or run `ollama pull \(model)`)."
        case .unsupported(let model): "“\(model)” can't create embeddings. Use an embedding model such as embeddinggemma."
        case .http(let status, let message): "Embedding request failed (\(status)): \(message.prefix(160))"
        }
    }
}

struct EmbeddingClient: Sendable {
    enum Provider: Sendable {
        case ollama
        case openAICompatible(apiKey: String?)
    }

    let baseURL: URL
    let model: String
    let provider: Provider
    /// Seconds Ollama keeps the embedding model after a request; -1 keeps it loaded.
    var keepAliveSeconds: Int = 900

    func embed(_ texts: [String]) async throws -> [[Float]] {
        var request: URLRequest
        let body: [String: Any]
        switch provider {
        case .ollama:
            request = URLRequest(url: baseURL.appendingPathComponent("api/embed"), timeoutInterval: 120)
            body = ["model": model, "input": texts, "keep_alive": keepAliveSeconds < 0 ? -1 : keepAliveSeconds, "truncate": true]
        case .openAICompatible(let apiKey):
            request = URLRequest(url: baseURL.appendingPathComponent("embeddings"), timeoutInterval: 120)
            if let apiKey { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
            body = ["model": model, "input": texts]
        }
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(status) else {
            let message = (json["error"] as? String) ?? ((json["error"] as? [String: Any])?["message"] as? String) ?? String(data: data, encoding: .utf8) ?? ""
            if status == 404 || message.localizedCaseInsensitiveContains("not found") { throw EmbeddingError.modelMissing(model) }
            if message.localizedCaseInsensitiveContains("does not support") { throw EmbeddingError.unsupported(model) }
            throw EmbeddingError.http(status, message)
        }
        let vectors: [[Double]]
        switch provider {
        case .ollama: vectors = json["embeddings"] as? [[Double]] ?? []
        case .openAICompatible: vectors = (json["data"] as? [[String: Any]] ?? []).compactMap { $0["embedding"] as? [Double] }
        }
        guard vectors.count == texts.count else { throw EmbeddingError.http(status, "unexpected response") }
        return vectors.map { $0.map(Float.init) }
    }
}

/// Keeps the knowledge index in sync with meetings, notes and dictations, and answers questions from it.
@MainActor
@Observable
final class KnowledgeService {
    struct Status: Equatable, CustomStringConvertible {
        var documents = 0
        var chunks = 0
        var embedded = 0
        var entities = 0
        var isIndexing = false
        var embeddingIssue: String?
        var extractionIssue: String?

        var searchReadiness: Int { chunks == 0 ? 100 : Int(Double(embedded) / Double(chunks) * 100) }

        var summary: String {
            documents == 0 ? "Nothing indexed yet" : "\(documents) items · \(entities) people & topics · meaning search \(searchReadiness)% ready"
        }

        var description: String { summary + (isIndexing ? " (indexing)" : "") }
    }

    struct Answer: Equatable, Sendable {
        var question: String
        var text: String
        var sources: [KnowledgeHit]
    }

    private(set) var status = Status()
    /// Bumped whenever indexed data changes, so views can reload.
    private(set) var revision = 0
    private(set) var pullProgress: Double?
    /// Notes whose digest is being written right now.
    private(set) var digestingNoteIDs: Set<UUID> = []

    @ObservationIgnored let store = KnowledgeStore(url: AppPaths.support.appendingPathComponent("Knowledge.sqlite"))
    /// Entity extraction shares the local model with dictation; it waits while this returns true.
    @ObservationIgnored var isAppBusy: () -> Bool = { false }
    @ObservationIgnored private var indexing = false
    @ObservationIgnored private var needsAnotherPass = false
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var saveObserver: NSObjectProtocol?

    private var settings: AppSettings { AppSettings.shared }

    func start() {
        saveObserver = NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleIndex(after: 4) }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleIndex(after: 0) }
        }
        scheduleIndex(after: 5)
    }

    func scheduleIndex(after delay: TimeInterval) {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.indexNow()
        }
    }

    func indexNow() async {
        guard !indexing else {
            needsAnotherPass = true
            return
        }
        indexing = true
        status.isIndexing = true
        defer {
            indexing = false
            status.isIndexing = false
        }
        repeat {
            needsAnotherPass = false
            await digestNotes()
            await syncDocuments()
            await embedPending()
            await extractEntities()
        } while needsAnotherPass
    }

    /// Demo screenshots: index the throwaway store, then file hand-written people and topics per document title
    /// instead of asking the model.
    func seedDemoGraph(_ byTitle: [String: ExtractionResult]) async {
        guard AppPaths.isDemo else { return }
        await store.reset()
        await syncDocuments()
        while let job = await store.nextEntityJob(kinds: [.meeting, .note, .writing]) {
            let result = byTitle[job.title] ?? byTitle.first { job.title.hasPrefix($0.key) }?.value ?? ExtractionResult()
            await store.saveEntities(job: job, result: EntityExtraction.clean(result))
        }
        revision += 1
        await refreshStatus()
    }

    func rebuild() async {
        await store.reset()
        revision += 1
        await indexNow()
    }

    // MARK: Search and answers

    func search(_ query: String, kinds: Set<KnowledgeKind>? = nil, owner: KnowledgeOwner = .everyone, binder: UUID? = nil,
                limit: Int = 30) async -> [KnowledgeHit] {
        let text = query.trimmed
        guard !text.isEmpty else { return [] }
        let binderKey = binder?.uuidString
        let keywordHits = await store.keywordSearch(text, limit: 40, kinds: kinds, owner: owner, binder: binderKey)
        var semanticHits: [KnowledgeHit] = []
        if let client = embeddingClient(), let vector = try? await client.embed(["task: search result | query: \(text)"]).first {
            semanticHits = await store.semanticSearch(vector, limit: 40, minScore: 0.35, kinds: kinds, owner: owner, binder: binderKey)
        }
        var byID: [Int64: KnowledgeHit] = [:]
        for hit in semanticHits { byID[hit.chunkID] = hit }
        for hit in keywordHits { byID[hit.chunkID] = hit }
        return RankFusion.reciprocalRank([keywordHits.map(\.chunkID), semanticHits.map(\.chunkID)])
            .prefix(limit)
            .compactMap { ranked in
                guard var hit = byID[ranked.id] else { return nil }
                hit.score = ranked.score
                return hit
            }
    }

    func ask(_ question: String, searchQuery: String? = nil, binder: UUID? = nil) async -> Answer {
        var hits = await search(searchQuery ?? question, binder: binder, limit: 8)
        if hits.isEmpty, searchQuery != nil { hits = await search(question, binder: binder, limit: 8) }
        guard !hits.isEmpty else {
            return Answer(question: question, text: "I couldn't find anything about that in your meetings, notes or dictations.", sources: [])
        }
        guard let client = settings.makeLLMClient() else {
            return Answer(question: question, text: "Choose a language model in Settings to get written answers. The closest matches are below.", sources: hits)
        }
        let contexts = hits.map { KnowledgeContext(label: "\($0.kind.singularName) “\($0.title)” · \($0.metaLine)", text: $0.text) }
        do {
            let output = try await client.complete(system: KnowledgePrompts.answerSystemPrompt(today: Date().formatted(date: .complete, time: .omitted)),
                                                   user: KnowledgePrompts.answerUserPrompt(question: question, contexts: contexts),
                                                   maxTokens: 900, temperature: 0.2, timeout: 180)
            return Answer(question: question, text: OutputGuard.sanitize(output), sources: hits)
        } catch {
            return Answer(question: question, text: "Couldn't write an answer (\(error.localizedDescription)). The closest matches are below.", sources: hits)
        }
    }

    func pullEmbeddingModel() async {
        guard settings.llmProvider == .ollama, let base = URL(string: settings.ollamaURL) else {
            status.embeddingIssue = "Downloading models is only available with Ollama"
            return
        }
        pullProgress = 0
        defer { pullProgress = nil }
        var request = URLRequest(url: base.appendingPathComponent("api/pull"), timeoutInterval: 3600)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["model": settings.embeddingModel.trimmed, "stream": true])
        do {
            let (bytes, _) = try await URLSession.shared.bytes(for: request)
            for try await line in bytes.lines {
                guard let json = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
                if let error = json["error"] as? String {
                    status.embeddingIssue = error
                    return
                }
                if let total = json["total"] as? Double, total > 0, let completed = json["completed"] as? Double {
                    pullProgress = completed / total
                }
            }
            status.embeddingIssue = nil
            scheduleIndex(after: 0)
        } catch {
            status.embeddingIssue = "Download failed: \(error.localizedDescription)"
        }
    }

    // MARK: Indexing

    // MARK: Note digests

    /// Writes digests for notes that changed and have settled, a few per pass so a big import doesn't hog the model.
    private func digestNotes() async {
        guard settings.noteDigests, let client = settings.makeLLMClient() else { return }
        let all = (try? Store.shared.context.fetch(FetchDescriptor<NoteItem>(sortBy: [SortDescriptor(\.updatedAt)]))) ?? []
        let stale = all.filter { note in
            note.digestHash != Self.noteContentHash(note.text)
                && NoteDigest.isEligible(wordCount: note.text.wordCount, secondsSinceEdit: Date().timeIntervalSince(note.updatedAt))
        }
        for note in stale.prefix(4) {
            while isAppBusy() { try? await Task.sleep(for: .seconds(3)) }
            await digest(note, using: client)
        }
        if stale.count > 4 { scheduleIndex(after: 20) }
    }

    /// Writes (or rewrites) a note's digest now, whatever its length.
    func digest(_ note: NoteItem) async {
        guard let client = settings.makeLLMClient() else {
            status.extractionIssue = "Choose a language model in Settings to write note digests"
            return
        }
        await digest(note, using: client)
    }

    private func digest(_ note: NoteItem, using client: LLMClient) async {
        let text = note.text.trimmed
        guard text.wordCount >= 3 else { return }
        digestingNoteIDs.insert(note.id)
        defer { digestingNoteIDs.remove(note.id) }
        let hash = Self.noteContentHash(note.text)
        do {
            let prompt = NotePrompts.digestUserPrompt(date: note.createdAt.formatted(date: .abbreviated, time: .shortened),
                                                      text: String(text.prefix(30_000)))
            let output = try await client.stream(system: NotePrompts.digestSystemPrompt(), user: prompt,
                                                 maxTokens: 900, temperature: 0.2, timeout: 300, stopWhen: { LoopGuard.isLooping($0) })
            guard note.modelContext != nil, !note.isDeleted else { return }
            let parsed = SummaryParser.parse(output)
            guard !parsed.body.isEmpty else { return }
            // A rewritten digest keeps the to-dos already ticked off.
            note.digest = NotesEditing.carryOverTicks(from: note.digest, into: (parsed.title.map { "# \($0)\n\n" } ?? "") + parsed.body)
            note.digestHash = hash
            Store.shared.save()
            status.extractionIssue = nil
            revision += 1
        } catch {
            Log.app.error("Couldn't digest note: \(error.localizedDescription)")
            status.extractionIssue = "Couldn't write a note digest: \(error.localizedDescription)"
        }
    }

    /// Hash of a note's text, so a digest can tell whether the note changed since it was written.
    nonisolated static func noteContentHash(_ text: String) -> String {
        hash([text])
    }

    /// Removes a wrongly extracted person, project or topic and keeps it from coming back.
    func forget(entityID: Int64) async {
        guard await store.forget(entityID: entityID) else { return }
        revision += 1
        await refreshStatus()
    }

    /// Renames a person, project or topic; renaming onto an existing name merges the two. Returns the surviving id.
    func rename(entityID: Int64, to name: String) async -> Int64? {
        guard let survivor = await store.rename(entityID: entityID, to: name) else { return nil }
        revision += 1
        await refreshStatus()
        return survivor
    }

    /// Folds one entity into another; the merged-away name keeps pointing here in future extractions.
    func merge(_ source: Int64, into target: Int64) async -> Bool {
        guard await store.merge(source, into: target) else { return false }
        revision += 1
        await refreshStatus()
        return true
    }

    func ignoredEntities() async -> [KnowledgeStore.IgnoredEntity] {
        await store.ignoredEntities()
    }

    func restore(ignoredKey key: String) async {
        await store.restore(ignoredKey: key)
        revision += 1
        scheduleIndex(after: 0)
    }

    private func syncDocuments() async {
        let documents = collectDocuments()
        let known = await store.documentHashes()
        var changed = false
        for (document, chunks) in documents where known[document.id] != document.contentHash {
            await store.upsert(document, chunks: chunks)
            changed = true
        }
        let live = Set(documents.map(\.0.id))
        let stale = known.keys.filter { !live.contains($0) }
        if !stale.isEmpty {
            await store.remove(documentIDs: stale)
            changed = true
        }
        if changed { revision += 1 }
        await refreshStatus()
    }

    private func embeddingClient() -> EmbeddingClient? {
        let model = settings.embeddingModel.trimmed
        guard !model.isEmpty else { return nil }
        switch settings.llmProvider {
        case .ollama:
            let keepAlive = settings.modelIdleMinutes <= 0 ? -1 : settings.modelIdleMinutes * 60
            return URL(string: settings.ollamaURL).map { EmbeddingClient(baseURL: $0, model: model, provider: .ollama, keepAliveSeconds: keepAlive) }
        case .openAICompatible:
            let key = settings.openAIKey
            return URL(string: settings.openAIBaseURL).map {
                EmbeddingClient(baseURL: $0, model: model, provider: .openAICompatible(apiKey: key.isEmpty ? nil : key))
            }
        }
    }

    private func embedPending() async {
        guard let client = embeddingClient() else {
            status.embeddingIssue = "Choose an embedding model in Settings → Knowledge for meaning-based search"
            return
        }
        await store.useEmbeddingModel(client.model)
        while true {
            let batch = await store.chunksNeedingEmbedding(limit: 48)
            guard !batch.isEmpty else { break }
            do {
                let vectors = try await client.embed(batch.map { "title: \($0.title) | text: \($0.text)" })
                await store.setEmbeddings(zip(batch, vectors).map { (id: $0.0.id, vector: $0.1) })
                status.embeddingIssue = nil
            } catch {
                status.embeddingIssue = error.localizedDescription
                break
            }
            await refreshStatus()
        }
        await refreshStatus()
    }

    private func extractEntities() async {
        var learnedNames = false
        if settings.knowledgeGraph, let client = settings.makeLLMClient() {
            while let job = await store.nextEntityJob(kinds: [.meeting, .note, .writing]) {
                while isAppBusy() { try? await Task.sleep(for: .seconds(3)) }
                let text = String(job.chunks.map(\.text).joined(separator: "\n").prefix(20_000))
                do {
                    let output = try await client.complete(system: EntityExtraction.systemPrompt(), user: "Title: \(job.title)\n\n\(text)",
                                                           maxTokens: 1500, temperature: 0, timeout: 300)
                    let parsed = EntityExtraction.parse(output)
                    let links = WikiLinks.targets(in: text).map { ExtractedEntity(name: $0, type: "topic") }
                    let result = EntityExtraction.clean(ExtractionResult(entities: parsed.entities + links, relations: parsed.relations))
                    await store.saveEntities(job: job, result: result)
                    status.extractionIssue = nil
                    learnedNames = true
                    revision += 1
                } catch {
                    status.extractionIssue = "Couldn't extract people and topics: \(error.localizedDescription)"
                    break
                }
                await refreshStatus()
            }
        }
        // Dictations and commands link to names learned from meetings and notes, without the model.
        if learnedNames { await store.resetLinks(kinds: [.dictation, .command]) }
        if await store.linkKnownEntities(kinds: [.dictation, .command], limit: 2_000) > 0 { revision += 1 }
        await refreshStatus()
    }

    private func refreshStatus() async {
        let stats = await store.stats()
        status.documents = stats.documents
        status.chunks = stats.chunks
        status.embedded = stats.embedded
        status.entities = stats.entities
    }

    private func collectDocuments() -> [(KnowledgeDocument, [KnowledgeChunk])] {
        let context = Store.shared.context
        var documents: [(KnowledgeDocument, [KnowledgeChunk])] = []

        for meeting in (try? context.fetch(FetchDescriptor<MeetingRecord>())) ?? [] where meeting.status == "ready" || meeting.status == "failed" {
            var chunks: [KnowledgeChunk] = []
            if !meeting.summary.trimmed.isEmpty { chunks += KnowledgeChunker.chunks(meeting.summary, label: "Summary") }
            if !meeting.userNotes.trimmed.isEmpty { chunks += KnowledgeChunker.chunks(meeting.userNotes, label: "My notes") }
            chunks += KnowledgeChunker.transcriptChunks(TranscriptFormatter.blocks(Store.shared.segments(for: meeting.id), names: meeting.speakerNames))
            guard !chunks.isEmpty else { continue }
            let author = meeting.isTeamCopy ? (meeting.teamAuthorName ?? "a teammate") : nil
            documents.append((KnowledgeDocument(id: "meeting:\(meeting.id.uuidString)", kind: .meeting, sourceID: meeting.id.uuidString,
                                                title: meeting.title, createdAt: meeting.createdAt,
                                                contentHash: Self.hash([meeting.title] + chunks.map(\.text) + Self.authorPart(author)
                                                                       + [meeting.binderID?.uuidString ?? ""]),
                                                author: author, binderID: meeting.binderID?.uuidString), chunks))
        }

        for note in (try? context.fetch(FetchDescriptor<NoteItem>())) ?? [] where !note.text.trimmed.isEmpty {
            var chunks: [KnowledgeChunk] = []
            if !note.digest.trimmed.isEmpty { chunks += KnowledgeChunker.chunks(note.digest, label: "Digest") }
            chunks += KnowledgeChunker.chunks(note.text)
            let author = note.isTeamCopy ? (note.teamAuthorName ?? "a teammate") : nil
            documents.append((KnowledgeDocument(id: "note:\(note.id.uuidString)", kind: .note, sourceID: note.id.uuidString,
                                                title: note.title, createdAt: note.createdAt,
                                                contentHash: Self.hash(chunks.map(\.text) + Self.authorPart(author) + [note.binderID?.uuidString ?? ""]),
                                                author: author, binderID: note.binderID?.uuidString), chunks))
        }

        for writing in (try? context.fetch(FetchDescriptor<WritingRecord>())) ?? [] where writing.wordCount >= 3 {
            var header = "Written in \(writing.appName ?? writing.source)"
            if !writing.recipients.isEmpty { header += " to \(writing.recipients)" }
            if let subject = writing.subject, !subject.isEmpty { header += ", subject: \(subject)" }
            let chunks = KnowledgeChunker.chunks(header + "\n" + writing.text, label: writing.appName)
            documents.append((KnowledgeDocument(id: "writing:\(writing.id.uuidString)", kind: .writing, sourceID: writing.id.uuidString,
                                                title: writing.title, createdAt: writing.createdAt,
                                                contentHash: Self.hash([writing.title] + chunks.map(\.text) + [writing.binderID?.uuidString ?? ""]),
                                                binderID: writing.binderID?.uuidString), chunks))
        }

        let transcripts = (try? context.fetch(FetchDescriptor<TranscriptRecord>(predicate: #Predicate { $0.status == "inserted" }))) ?? []
        for record in transcripts where record.finalText.wordCount >= 3 {
            let isCommand = record.mode == "command"
            let text = isCommand ? "Command: \(record.rawText)\nResult: \(record.finalText)" : record.finalText
            let chunks = KnowledgeChunker.chunks(text, label: record.appName)
            let app = record.appName ?? "an app"
            let kind: KnowledgeKind = isCommand ? .command : .dictation
            documents.append((KnowledgeDocument(id: "\(kind.rawValue):\(record.id.uuidString)", kind: kind, sourceID: record.id.uuidString,
                                                title: isCommand ? "Command in \(app)" : "Dictation in \(app)", createdAt: record.createdAt,
                                                contentHash: Self.hash(chunks.map(\.text))), chunks))
        }
        return documents
    }

    /// Only shared items hash their author, so your existing index isn't rebuilt.
    private static func authorPart(_ author: String?) -> [String] {
        author.map { ["author: \($0)"] } ?? []
    }

    nonisolated private static func hash(_ parts: [String]) -> String {
        var hasher = SHA256()
        for part in parts {
            hasher.update(data: Data(part.utf8))
            hasher.update(data: Data([0]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Opens the meeting, note or history entry a search result came from.
@MainActor
enum KnowledgeNavigator {
    static func open(_ hit: KnowledgeHit) {
        openSource(kind: hit.kind, sourceID: hit.sourceID, text: hit.text)
    }

    static func openSource(kind: KnowledgeKind, sourceID: String, text: String = "") {
        let hub = HubWindowController.shared
        switch kind {
        case .meeting:
            let id = UUID(uuidString: sourceID)
            hub.navigation.pendingMeetingID = id
            hub.navigation.binderID = Store.shared.binderID(ofMeeting: id) ?? hub.navigation.binderID ?? Store.shared.defaultBinder().id
            hub.navigation.pendingBinderTab = .meetings
            hub.show(section: .binder)
        case .note:
            let id = UUID(uuidString: sourceID)
            hub.navigation.pendingNoteID = id
            hub.navigation.binderID = Store.shared.binderID(ofNote: id) ?? hub.navigation.binderID ?? Store.shared.defaultBinder().id
            hub.navigation.pendingBinderTab = .notes
            hub.show(section: .binder)
        case .writing:
            let firstLine = text.components(separatedBy: "\n").dropFirst().first ?? text
            hub.navigation.pendingWritingSearch = String(firstLine.prefix(40))
            hub.show(section: .writing)
        case .dictation, .command:
            let firstLine = text.components(separatedBy: "\n").first ?? text
            hub.navigation.pendingHistorySearch = String(firstLine.replacingOccurrences(of: "Command: ", with: "").prefix(40))
            hub.show(section: .home)
        }
    }
}
