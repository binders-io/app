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
        case .conversation: "bubble.left.and.bubble.right"
        }
    }

    var singularName: String {
        switch self {
        case .meeting: "Meeting"
        case .note: "Note"
        case .writing: "Message"
        case .dictation: "Dictation"
        case .command: "Voice command"
        case .conversation: "Capture"
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
        /// In Binders, with MLX.
        case mlx
    }

    let baseURL: URL
    let model: String
    let provider: Provider
    /// Seconds Ollama keeps the embedding model after a request; -1 keeps it loaded.
    var keepAliveSeconds: Int = 900

    func embed(_ texts: [String]) async throws -> [[Float]] {
        if case .mlx = provider { return try await MLXEmbedder.shared.embed(texts, model: model) }
        var request: URLRequest
        let body: [String: Any]
        switch provider {
        case .mlx:
            return []
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
        case .mlx: vectors = []
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
        /// Found, and left out of the answer: passages from notes with an agent's words in them, until you make them yours.
        var leftOut: [KnowledgeHit] = []
    }

    /// Ask as it goes, for what shows it: the passages found by their words (at once, before the slower search by
    /// meaning), then the passages the answer draws on, then the answer as it's written.
    struct AskProgress: Equatable, Sendable {
        var stage: AskStage
        var sources: [KnowledgeHit]
        /// The answer so far, cleaned up as the finished one will be, with the writing stage.
        var text = ""
    }

    /// What the last pass did, for the log and the speed self-test.
    struct PassReport: Equatable, Sendable, CustomStringConvertible {
        var read = 0
        var written = 0
        var removed = 0
        /// Items saved where their id wasn't known, found by reading their kind whole.
        var lookedUp = 0
        var digestCandidates = 0
        var milliseconds = 0
        var mainMilliseconds = 0

        var description: String {
            "\(read) items read, \(written) written, \(removed) removed, \(digestCandidates) waiting for a digest; \(milliseconds) ms, \(mainMilliseconds) ms of it on the main thread"
                + (lookedUp > 0 ? " (\(lookedUp) looked up)" : "")
        }
    }

    private(set) var status = Status()
    @ObservationIgnored private(set) var lastPass = PassReport()
    /// Off for self-tests that time or check the index alone: no digests, embeddings or people and topics.
    @ObservationIgnored var modelWork = true
    /// A stand-in for the model that writes digests, for self-tests: digests are written with it even with `modelWork` off.
    @ObservationIgnored var digestModel: LLMClient?
    /// Stand-ins for self-tests: the model that writes Ask's answers, and what a search's words become for the search by
    /// meaning, instead of the ones in Settings.
    @ObservationIgnored var answerModel: LLMClient?
    @ObservationIgnored var queryEmbedder: (@Sendable (String) async throws -> [Float])?
    /// Stand-ins for self-tests: the embedding model passages are embedded with (its name, and what each becomes), and
    /// the model that finds people and topics.
    @ObservationIgnored var documentEmbedder: (model: String, embed: @Sendable ([String]) async throws -> [[Float]])?
    @ObservationIgnored var entityModel: LLMClient?
    /// The longest an answer shown as it's written takes, from the question to its last word, the search included: the
    /// iPhone waits a little longer (LinkTimeouts.ask), so it always gets what was written. Shorter for self-tests.
    @ObservationIgnored var answerSeconds: TimeInterval = 180
    /// Bumped whenever indexed data changes, so views can reload.
    private(set) var revision = 0
    private(set) var pullProgress: Double?
    /// Notes whose digest is being written right now.
    private(set) var digestingNoteIDs: Set<UUID> = []
    /// Why a note's last digest failed, shown next to the note until the next one is written.
    private(set) var digestIssues: [UUID: String] = [:]

    @ObservationIgnored let store = KnowledgeStore(url: AppPaths.support.appendingPathComponent("Knowledge.sqlite"))
    /// Reads the library for the index, off the main thread.
    @ObservationIgnored private lazy var indexer = KnowledgeIndexer(container: Store.shared.container, store: store)
    /// What was saved since the last pass, so a pass reads only that; kept from the first pass on.
    @ObservationIgnored private var changes: IndexChangeLog?
    /// The first notes due a digest as of the last pass, the one edited longest ago first, and how many are due in all.
    @ObservationIgnored private var digestsDue: [UUID] = []
    @ObservationIgnored private var digestsDueCount = 0
    /// Entity extraction shares the local model with dictation; it waits while this returns true.
    @ObservationIgnored var isAppBusy: () -> Bool = { false }
    @ObservationIgnored private var indexing = false
    @ObservationIgnored private var needsAnotherPass = false
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var saveObserver: NSObjectProtocol?

    private var settings: AppSettings { AppSettings.shared }

    func start() {
        trackChanges()
        saveObserver = NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: nil, queue: .main) { [weak self] notification in
            // The boards aren't indexed: an agent's progress report doesn't send the index over the whole library again.
            guard !TaskCard.onlyBoards(notification.userInfo) else { return }
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
            guard !Task.isCancelled, let self else { return }
            // Once a pass starts it runs to the end: a save meanwhile asks for another pass rather than cancelling this
            // one, which cut its model calls off and turned its waits for the app into a spin on the main thread.
            self.pending = nil
            await self.indexNow()
        }
    }

    func indexNow() async {
        // The library didn't open: an index of the empty stand-in would take everything out of the index on disk.
        guard Store.shared.canSave else { return }
        trackChanges()
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
            let started = Date()
            lastPass = PassReport()
            await syncDocuments()
            // Digests for notes that have settled, and their passages in the same pass.
            if await digestNotes() { await syncDocuments() }
            lastPass.milliseconds = Int(Date().timeIntervalSince(started) * 1000)
            Log.app.notice("Knowledge pass: \(self.lastPass.description, privacy: .public)")
            guard modelWork else { continue }
            await embedPending()
            await extractEntities()
        } while needsAnotherPass
    }

    /// Starts noting what's saved, so each pass reads only that. Until then a pass reads everything.
    private func trackChanges() {
        if changes == nil { changes = IndexChangeLog(container: Store.shared.container) }
    }

    /// Demo screenshots: index the throwaway store, then file hand-written people and topics per document title
    /// instead of asking the model.
    func seedDemoGraph(_ byTitle: [String: ExtractionResult]) async {
        guard AppPaths.isDemo else { return }
        await store.reset()
        await indexer.forget()
        await syncDocuments()
        while let job = await store.nextEntityJob(kinds: [.meeting, .conversation, .note, .writing]) {
            let result = byTitle[job.title] ?? byTitle.first { job.title.hasPrefix($0.key) }?.value ?? ExtractionResult()
            await store.saveEntities(job: job, result: EntityExtraction.clean(result))
        }
        revision += 1
        await refreshStatus()
    }

    func rebuild() async {
        guard Store.shared.allowsSave() else { return }
        await store.reset()
        await indexer.forget()
        revision += 1
        await indexNow()
    }

    // MARK: Search and answers

    /// Passages by their words and by meaning together. `onKeywordHits` is told the ones with the words first, as they're
    /// found, before the search by meaning waits on the embedding model.
    /// `sources`: only passages from these items, by id (a folder's notes, meetings and captures, `Store.itemIDs`).
    func search(_ query: String, kinds: Set<KnowledgeKind>? = nil, owner: KnowledgeOwner = .everyone, binder: UUID? = nil,
                sources: Set<String>? = nil, limit: Int = 30, onKeywordHits: (([KnowledgeHit]) -> Void)? = nil) async -> [KnowledgeHit] {
        let text = query.trimmed
        guard !text.isEmpty else { return [] }
        let binderKey = binder?.uuidString
        let keywordHits = await store.keywordSearch(text, limit: 40, kinds: kinds, owner: owner, binder: binderKey, sources: sources)
        // Labelled with the agent where a note has an agent's words, so what's shown first is told apart too.
        onKeywordHits?(labelled(Self.fused(keywordHits, [], limit: limit)))
        var semanticHits: [KnowledgeHit] = []
        if let vector = await queryVector(text) {
            semanticHits = await store.semanticSearch(vector, limit: 40, minScore: 0.35, kinds: kinds, owner: owner, binder: binderKey, sources: sources)
        }
        return labelled(Self.fused(keywordHits, semanticHits, limit: limit))
    }

    /// The two searches' passages in one ranking (reciprocal rank fusion). One found by its words keeps its highlights.
    private static func fused(_ keywordHits: [KnowledgeHit], _ semanticHits: [KnowledgeHit], limit: Int) -> [KnowledgeHit] {
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

    // MARK: Agent text

    /// Passages from notes with an agent's words in them, labelled with the agent: search finds them like any other, and
    /// answers leave them out (`ask`) until you make the note yours. While the library didn't open, whose words a note
    /// holds is in the library, so notes are left out rather than shown as yours.
    func labelled(_ hits: [KnowledgeHit]) -> [KnowledgeHit] {
        guard hits.contains(where: { $0.kind == .note }) else { return hits }
        guard Store.shared.canSave else { return hits.filter { $0.kind != .note } }
        let marks = Store.shared.agentMarks()
        guard !marks.isEmpty else { return hits }
        return hits.map { hit in
            guard hit.kind == .note, let mark = marks[hit.sourceID] else { return hit }
            var labelled = hit
            labelled.agent = mark
            return labelled
        }
    }

    /// A search's words for the search by meaning, from the embedding model; nil without one.
    private func queryVector(_ text: String) async -> [Float]? {
        if let queryEmbedder { return try? await queryEmbedder(text) }
        guard let client = embeddingClient() else { return nil }
        return try? await client.embed(["task: search result | query: \(text)"]).first
    }

    // MARK: Corrections

    /// A correction kept in a note: what was wrong, what's right, and when it was made.
    struct CorrectionNote: Sendable {
        let id: UUID
        let date: Date
        let binderID: UUID?
        let correction: KnowledgeCorrection
    }

    @ObservationIgnored private var correctionCache: (revision: Int, list: [CorrectionNote])?

    /// A note's correction now counts, or no longer does, without its words changing (Make It Mine): looked up again.
    func correctionsChanged() {
        correctionCache = nil
    }

    /// The corrections, looked up again only when what's indexed has changed.
    func currentCorrections() -> [CorrectionNote] {
        if let cache = correctionCache, cache.revision == revision { return cache.list }
        let list = corrections()
        correctionCache = (revision, list)
        return list
    }

    /// Every correction in the notes, newest first. An agent's correction is its note, not yours, so it doesn't steer
    /// answers unless `includingAgents` (to find one made twice); nor does one in a note an agent changed since, until you
    /// make it yours. `includingTeam: false` leaves out teammates' corrections, for what may not read their items.
    func corrections(includingAgents: Bool = false, includingTeam: Bool = true) -> [CorrectionNote] {
        let tag = KnowledgeCorrection.tag
        let notes = ((try? Store.shared.context.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.text.contains(tag) }))) ?? [])
            .filter { (includingAgents || $0.agentMark.isEmpty) && (includingTeam || !$0.isTeamCopy) }
        let mine = notes.compactMap { note in
            KnowledgeCorrection.parse(note.text).map { CorrectionNote(id: note.id, date: note.updatedAt, binderID: note.binderID, correction: $0) }
        }
        return mine.sorted { $0.date > $1.date }
    }

    /// The correction to a passage that says what a correction calls wrong, if there is one.
    func correction(for hit: KnowledgeHit, in corrections: [CorrectionNote]) -> CorrectionNote? {
        corrections.first { $0.id.uuidString != hit.sourceID && $0.correction.corrects(hit.text) }
    }

    /// `kinds`, `owner` and `keep` narrow what the answer may draw on, as for a tool that may not read everything.
    /// `brief`: one or two sentences, or no text at all when the binders don't answer it or there's no model, for something
    /// asked out loud and heard back in a notification. Notes with an agent's words in them are never drawn on: they come
    /// back as `leftOut` until you make them yours.
    /// `progress` is told how it's going, for something that shows it: the passages with the words at once, then the
    /// passages the answer draws on, then the answer as it's written (at most every 50 ms). With it, the answer streams;
    /// without it, it's one reply, as before.
    func ask(_ question: String, searchQuery: String? = nil, binder: UUID? = nil, sources: Set<String>? = nil, kinds: Set<KnowledgeKind>? = nil,
             owner: KnowledgeOwner = .everyone, brief: Bool = false, keep: @escaping (KnowledgeHit) -> Bool = { _ in true },
             progress: (@MainActor (AskProgress) -> Void)? = nil) async -> Answer {
        // While the library didn't open, which notes hold an agent's words, and your corrections, are in it: say so, as
        // MCP's reads do, rather than answer without them.
        guard Store.shared.canSave else { return Answer(question: question, text: brief ? "" : Store.unanswerableMessage, sources: []) }
        // "How's the onboarding spec going?": a Distill note's report, from the board alone, the same every time (lane DS1).
        if !brief, let report = DistillService.answer(question) { return Answer(question: question, text: report, sources: []) }
        // An answer shown as it's written has its time from now, so the search counts too.
        let budget = TimeBudget(seconds: answerSeconds)
        /// What the answer may draw on of what a search found, the same for the passages with the words shown first. An
        /// agent's passages don't take the place of yours: your best 16, as if they weren't there; theirs are left out, one
        /// per note.
        func usable(_ found: [KnowledgeHit]) -> (hits: [KnowledgeHit], leftOut: [KnowledgeHit]) {
            let yours = found.filter { $0.agent == nil }.prefix(16).filter(keep).prefix(8)
            var notes = Set<String>()
            let agents = found.filter { $0.agent != nil && keep($0) && notes.insert($0.sourceID).inserted }.prefix(3)
            return (Array(yours), Array(agents))
        }
        func find(_ text: String) async -> (hits: [KnowledgeHit], leftOut: [KnowledgeHit]) {
            let found = await search(text, kinds: kinds, owner: owner, binder: binder, sources: sources, limit: 32,
                                     onKeywordHits: progress.map { tell in { tell(AskProgress(stage: .keywordHits, sources: usable($0).hits)) } })
            return usable(found)
        }
        var found = await find(searchQuery ?? question)
        if found.hits.isEmpty, searchQuery != nil {
            let again = await find(question)
            found = (again.hits, again.leftOut.isEmpty ? found.leftOut : again.leftOut)
        }
        var hits = found.hits
        let leftOut = found.leftOut
        guard !hits.isEmpty else {
            let none = leftOut.isEmpty ? "I couldn't find anything about that in your meetings, notes or dictations."
                : "Only notes an agent wrote or changed mention that, and answers leave those out until you make them yours."
            return Answer(question: question, text: brief ? "" : none, sources: [], leftOut: leftOut)
        }
        // Corrections to what was found come first, as sources the answer has to follow: only yours when it may draw only
        // on yours.
        let all = corrections(includingTeam: owner != .mine)
        var seen = Set<String>()
        let relevant = all.filter { correction in
            hits.contains { $0.sourceID == correction.id.uuidString || correction.correction.corrects($0.text) }
        }
        // The same correction kept twice counts once: the newest.
        .filter { seen.insert(KnowledgeCorrections.normalize($0.correction.wrong) + "→" + KnowledgeCorrections.normalize($0.correction.right)).inserted }
        let allIDs = Set(all.map(\.id.uuidString)), keptIDs = Set(relevant.map(\.id.uuidString))
        hits.removeAll { allIDs.contains($0.sourceID) && !keptIDs.contains($0.sourceID) }
        if !relevant.isEmpty {
            let corrections = relevant.enumerated().map { index, item in
                hits.first { $0.sourceID == item.id.uuidString } ?? KnowledgeHit(
                    chunkID: -Int64(index + 1), documentID: "note:\(item.id.uuidString)", kind: .note, sourceID: item.id.uuidString,
                    title: "Correction: \(item.correction.right)", createdAt: item.date, text: item.correction.markdown, snippet: "",
                    startTime: nil, speaker: nil, author: nil, binderID: item.binderID?.uuidString, score: 1)
            }
            hits = corrections + hits.filter { hit in !relevant.contains { $0.id.uuidString == hit.sourceID } }
        }
        progress?(AskProgress(stage: .sources, sources: hits))
        guard let client = answerModel ?? settings.makeLLMClient() else {
            return Answer(question: question, text: brief ? "" : "Choose a language model in Settings to get written answers. The closest matches are below.", sources: hits, leftOut: leftOut)
        }
        let contexts = hits.map { hit -> KnowledgeContext in
            if let item = relevant.first(where: { $0.id.uuidString == hit.sourceID }) {
                let why = item.correction.reason.map { "\nWhy: \($0)" } ?? ""
                return KnowledgeContext(label: "CORRECTION · \(item.date.formatted(date: .abbreviated, time: .omitted))",
                                        text: "Wrong: \(item.correction.wrong)\nRight: \(item.correction.right)\(why)")
            }
            return KnowledgeContext(label: "\(hit.kind.singularName) “\(hit.title)” · \(hit.metaLine)", text: hit.text)
        }
        let today = Date().formatted(date: .complete, time: .omitted)
        if brief {
            let output = try? await client.complete(system: KnowledgePrompts.briefAnswerSystemPrompt(today: today),
                                                    user: KnowledgePrompts.answerUserPrompt(question: question, contexts: contexts),
                                                    maxTokens: 250, temperature: 0.2, timeout: 25)
            return Answer(question: question, text: output.flatMap(SuggestionPrompts.parseAnswer) ?? "", sources: hits, leftOut: leftOut)
        }
        let system = KnowledgePrompts.answerSystemPrompt(today: today)
        let user = KnowledgePrompts.answerUserPrompt(question: question, contexts: contexts)
        guard let progress else {
            do {
                let output = try await client.complete(system: system, user: user, maxTokens: 900, temperature: 0.2, timeout: 180)
                return Answer(question: question, text: OutputGuard.sanitize(output), sources: hits, leftOut: leftOut)
            } catch {
                return Answer(question: question, text: "Couldn't write an answer (\(error.localizedDescription)). The closest matches are below.", sources: hits, leftOut: leftOut)
            }
        }
        let written = await streamAnswer(client, system: system, user: user, sources: hits, within: budget, progress: progress)
        guard let error = written.error else {
            return Answer(question: question, text: OutputGuard.sanitize(written.text), sources: hits, leftOut: leftOut)
        }
        // Stopped part-way: what was written stays, with why it stopped.
        let partial = written.text
        let why = (partial.isEmpty ? "Couldn't write an answer" : "Couldn't finish the answer")
            + (error is TimeLimit.Exceeded ? " in time." : " (\(error.localizedDescription)).")
        return Answer(question: question, text: (partial.isEmpty ? "" : partial + "\n\n") + why + " The closest matches are below.", sources: hits, leftOut: leftOut)
    }

    /// The answer from the model as it's written, within `budget`: `progress` is told the text so far at most every 50 ms,
    /// and has been told the last of it before this returns. On an error, or out of time, what was shown of it by then,
    /// and the error.
    private func streamAnswer(_ client: LLMClient, system: String, user: String, sources: [KnowledgeHit], within budget: TimeBudget,
                              progress: @escaping @MainActor (AskProgress) -> Void) async -> (text: String, error: Error?) {
        // A model whose replies start inside its reasoning, as an earlier reply showed, shows nothing until it closes.
        let model = "\(settings.llmProvider.rawValue):\(client.model)"
        let opens = Self.opensInReasoning(model)
        // Only the newest text waits to be shown: a model faster than the screen skips the pieces in between.
        let (pieces, received) = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let shown = Task { @MainActor () -> String in
            var last = "", told = ""
            for await piece in pieces {
                last = piece
                let text = OutputGuard.streaming(piece, opensInReasoning: opens)
                guard !text.isEmpty, text != told else { continue }
                told = text
                progress(AskProgress(stage: .writing, sources: sources, text: text))
                try? await Task.sleep(for: .milliseconds(50))
            }
            return last
        }
        do {
            // Out of time, the model is stopped: closing its stream stops the server writing too.
            let output = try await TimeLimit.run(within: budget.left) {
                try await client.stream(system: system, user: user, maxTokens: 900, temperature: 0.2, timeout: 180,
                                        stopWhen: { _ in false }, onText: { received.yield($0) })
            }
            received.yield(output)
            received.finish()
            _ = await shown.value
            Self.note(model, opensInReasoning: OutputGuard.opensInReasoning(output))
            return (output, nil)
        } catch {
            received.finish()
            let last = await shown.value
            if OutputGuard.opensInReasoning(last) { Self.note(model, opensInReasoning: true) }
            return (OutputGuard.streaming(last, opensInReasoning: opens), error)
        }
    }

    // MARK: Models that open in reasoning

    /// Models whose replies start inside their reasoning, as "provider:model", because their chat template opened it (a
    /// server that passes reasoning on as the reply): an answer from one shows nothing while it's written until the
    /// reasoning closes. Noted from a reply that closes reasoning it never opened, and let go after one that doesn't.
    /// Apart in a throwaway folder, as self-tests' Keychain items are.
    static var reasoningOpenersKey: String { (AppPaths.isDemo ? "selftest-" : "") + "modelsOpeningInReasoning" }

    static func opensInReasoning(_ model: String) -> Bool {
        AppDefaults.store.stringArray(forKey: reasoningOpenersKey)?.contains(model) == true
    }

    private static func note(_ model: String, opensInReasoning opens: Bool) {
        var models = Set(AppDefaults.store.stringArray(forKey: reasoningOpenersKey) ?? [])
        guard models.contains(model) != opens else { return }
        if opens { models.insert(model) } else { models.remove(model) }
        AppDefaults.store.set(models.sorted(), forKey: reasoningOpenersKey)
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

    /// Writes digests for notes that changed and have settled, a few per pass so a big import doesn't hog the model. The
    /// pass found them; each is checked again as it is now. True when one was written.
    private func digestNotes() async -> Bool {
        guard settings.noteDigests, let client = digestModel ?? (modelWork ? settings.makeLLMClient(lane: .later) : nil) else { return false }
        var wrote = false
        var tried = 0
        for id in digestsDue where tried < 4 {
            guard let note = Store.shared.note(id), note.digestHash != Self.noteContentHash(note.text),
                  NoteDigest.isEligible(wordCount: note.text.wordCount, secondsSinceEdit: Date().timeIntervalSince(note.updatedAt)) else { continue }
            tried += 1
            while isAppBusy(), !Task.isCancelled { try? await Task.sleep(for: .seconds(3)) }
            if await digest(note, using: client) { wrote = true }
        }
        if digestsDueCount > 4 { scheduleIndex(after: 20) }
        return wrote
    }

    /// Writes (or rewrites) a note's digest now, whatever its length.
    func digest(_ note: NoteItem) async {
        guard let client = settings.makeLLMClient() else {
            status.extractionIssue = "Choose a language model in Settings to write note digests"
            digestIssues[note.id] = "Choose a language model in Settings → AI to write digests."
            return
        }
        await digest(note, using: client)
    }

    /// True when it wrote the digest.
    @discardableResult
    private func digest(_ note: NoteItem, using client: LLMClient) async -> Bool {
        let text = note.text.trimmed
        guard text.wordCount >= 3 else { return false }
        digestingNoteIDs.insert(note.id)
        digestIssues[note.id] = nil
        defer { digestingNoteIDs.remove(note.id) }
        let hash = Self.noteContentHash(note.text)
        do {
            let prompt = NotePrompts.digestUserPrompt(date: note.createdAt.formatted(date: .abbreviated, time: .shortened),
                                                      text: String(text.prefix(30_000)))
            let output = try await client.stream(system: NotePrompts.digestSystemPrompt(), user: prompt,
                                                 maxTokens: 900, temperature: 0.2, timeout: 300, stopWhen: { LoopGuard.isLooping($0) })
            guard note.modelContext != nil, !note.isDeleted else { return false }
            let parsed = SummaryParser.parse(output)
            guard !parsed.body.isEmpty else {
                digestIssues[note.id] = "The model's reply had no digest in it. Try again, or choose another model in Settings."
                return false
            }
            // A rewritten digest keeps the to-dos already ticked off.
            note.digest = NotesEditing.carryOverTicks(from: note.digest, into: (parsed.title.map { "# \($0)\n\n" } ?? "") + parsed.body)
            note.digestHash = hash
            Store.shared.save()
            status.extractionIssue = nil
            revision += 1
            return true
        } catch {
            Log.app.error("Couldn't digest note: \(error.localizedDescription)")
            status.extractionIssue = "Couldn't write a note digest: \(error.localizedDescription)"
            digestIssues[note.id] = "Couldn't write the digest. \(error.localizedDescription)"
            return false
        }
    }

    /// Hash of a note's text, so a digest can tell whether the note changed since it was written.
    nonisolated static func noteContentHash(_ text: String) -> String {
        KnowledgeContentHash.of([text])
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

    /// One pass of the indexer over what changed, off the main thread; the main thread only hands it the changes and
    /// takes its report.
    private func syncDocuments() async {
        trackChanges()
        var began = Date()
        let saved = changes?.take() ?? IndexChangeLog.Changes()
        let revisions = Store.shared.segmentRevisions
        lastPass.mainMilliseconds += Int(Date().timeIntervalSince(began) * 1000)
        let report = await indexer.pass(saved, transcriptRevisions: revisions)
        began = Date()
        lastPass.read += report.read
        lastPass.written += report.written
        lastPass.removed += report.removed
        lastPass.lookedUp += report.lookedUp
        digestsDue = report.digestsDue
        digestsDueCount = report.digestsDueCount
        lastPass.digestCandidates = settings.noteDigests ? report.digestsDueCount : 0
        if report.written > 0 || report.removed > 0 { revision += 1 }
        lastPass.mainMilliseconds += Int(Date().timeIntervalSince(began) * 1000)
        await refreshStatus()
    }

    private func embeddingClient() -> EmbeddingClient? {
        if settings.llmProvider == .mlx {
            let model = settings.mlxEmbeddingModel.trimmed
            guard !model.isEmpty else { return nil }
            return EmbeddingClient(baseURL: MLXModels.folder, model: model, provider: .mlx)
        }
        let model = settings.embeddingModel.trimmed
        guard !model.isEmpty else { return nil }
        switch settings.llmProvider {
        case .mlx:
            return nil
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

    /// The embedding model passages are embedded with now, by name; nil without one.
    var passageModel: String? { documentEmbedder?.model ?? embeddingClient()?.model }

    /// Passages embedded now, as `embedPending` embeds them (each "title: … | text: …").
    func embedPassages(_ inputs: [String]) async throws -> [[Float]] {
        if let documentEmbedder { return try await documentEmbedder.embed(inputs) }
        guard let client = embeddingClient() else { throw EmbeddingError.modelMissing(settings.embeddingModel) }
        return try await client.embed(inputs)
    }

    private func embedPending() async {
        guard let model = passageModel else {
            status.embeddingIssue = "Choose an embedding model in Settings → Knowledge for meaning-based search"
            return
        }
        await store.useEmbeddingModel(model)
        while true {
            let batch = await store.chunksNeedingEmbedding(limit: 48)
            guard !batch.isEmpty else { break }
            do {
                // What the embedding model reads for a passage.
                let vectors = try await embedPassages(batch.map { "title: \($0.title) | text: \($0.text)" })
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
        let kinds: [KnowledgeKind] = [.meeting, .conversation, .note, .writing]
        if settings.knowledgeGraph, let client = entityModel ?? settings.makeLLMClient(lane: .later) {
            while let job = await store.nextEntityJob(kinds: kinds) {
                while isAppBusy(), !Task.isCancelled { try? await Task.sleep(for: .seconds(3)) }
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
        var next = status
        next.documents = stats.documents
        next.chunks = stats.chunks
        next.embedded = stats.embedded
        next.entities = stats.entities
        // Set only when it changed: every set redraws what shows it.
        if next != status { status = next }
    }

    // MARK: Documents
    //
    // What each item puts in the index, made by the indexer off the main thread. The content hashes have to stay exactly
    // as they are: a different hash for the same words writes, embeds and extracts that item again after an update
    // (KnowledgeContentHashTests and --selftest-index pin them).

    /// A meeting's or capture's notes, your notes and its transcript (`segments`, in order); nil when it has none of them.
    nonisolated static func document(for meeting: MeetingRecord, segments: [TranscriptSegment]) -> (KnowledgeDocument, [KnowledgeChunk])? {
        guard meeting.status == "ready" || meeting.status == "failed" else { return nil }
        var chunks: [KnowledgeChunk] = []
        if !meeting.summary.trimmed.isEmpty { chunks += KnowledgeChunker.chunks(meeting.summary, label: "Summary") }
        if !meeting.userNotes.trimmed.isEmpty { chunks += KnowledgeChunker.chunks(meeting.userNotes, label: "My notes") }
        chunks += KnowledgeChunker.transcriptChunks(TranscriptFormatter.blocks(segments, names: meeting.speakerNames))
        guard !chunks.isEmpty else { return nil }
        let author = meeting.isTeamCopy ? (meeting.teamAuthorName ?? "a teammate") : nil
        let kind: KnowledgeKind = meeting.isConversation ? .conversation : .meeting
        return (KnowledgeDocument(id: "\(kind.rawValue):\(meeting.id.uuidString)", kind: kind, sourceID: meeting.id.uuidString,
                                  title: meeting.title, createdAt: meeting.createdAt,
                                  contentHash: hash([meeting.title] + chunks.map(\.text) + authorPart(author)
                                                    + [meeting.binderID?.uuidString ?? ""]),
                                  author: author, binderID: meeting.binderID?.uuidString), chunks)
    }

    /// A note, its digest first; nil for an empty note.
    nonisolated static func document(for note: NoteItem) -> (KnowledgeDocument, [KnowledgeChunk])? {
        guard !note.text.trimmed.isEmpty else { return nil }
        var chunks: [KnowledgeChunk] = []
        if !note.digest.trimmed.isEmpty { chunks += KnowledgeChunker.chunks(note.digest, label: "Digest") }
        chunks += KnowledgeChunker.chunks(note.text)
        let author = note.isTeamCopy ? (note.teamAuthorName ?? "a teammate") : nil
        return (KnowledgeDocument(id: "note:\(note.id.uuidString)", kind: .note, sourceID: note.id.uuidString,
                                  title: note.title, createdAt: note.createdAt,
                                  contentHash: hash(chunks.map(\.text) + authorPart(author) + [note.binderID?.uuidString ?? ""]),
                                  author: author, binderID: note.binderID?.uuidString), chunks)
    }

    /// Something you wrote, with where and to whom; nil under three words.
    nonisolated static func document(for writing: WritingRecord) -> (KnowledgeDocument, [KnowledgeChunk])? {
        guard writing.wordCount >= 3 else { return nil }
        var header = "Written in \(writing.appName ?? writing.source)"
        if !writing.recipients.isEmpty { header += " to \(writing.recipients)" }
        if let subject = writing.subject, !subject.isEmpty { header += ", subject: \(subject)" }
        let chunks = KnowledgeChunker.chunks(header + "\n" + writing.text, label: writing.appName)
        return (KnowledgeDocument(id: "writing:\(writing.id.uuidString)", kind: .writing, sourceID: writing.id.uuidString,
                                  title: writing.title, createdAt: writing.createdAt,
                                  contentHash: hash([writing.title] + chunks.map(\.text) + [writing.binderID?.uuidString ?? ""]),
                                  binderID: writing.binderID?.uuidString), chunks)
    }

    /// A dictation or command typed into an app; nil for one that wasn't, or under three words.
    nonisolated static func document(for record: TranscriptRecord) -> (KnowledgeDocument, [KnowledgeChunk])? {
        guard record.status == "inserted", record.finalText.wordCount >= 3 else { return nil }
        let isCommand = record.mode == "command"
        let text = isCommand ? "Command: \(record.rawText)\nResult: \(record.finalText)" : record.finalText
        let chunks = KnowledgeChunker.chunks(text, label: record.appName)
        let app = record.appName ?? "an app"
        let kind: KnowledgeKind = isCommand ? .command : .dictation
        return (KnowledgeDocument(id: "\(kind.rawValue):\(record.id.uuidString)", kind: kind, sourceID: record.id.uuidString,
                                  title: isCommand ? "Command in \(app)" : "Dictation in \(app)", createdAt: record.createdAt,
                                  contentHash: hash(chunks.map(\.text))), chunks)
    }

    /// Only shared items hash their author, so your existing index isn't rebuilt.
    nonisolated private static func authorPart(_ author: String?) -> [String] {
        author.map { ["author: \($0)"] } ?? []
    }

    nonisolated private static func hash(_ parts: [String]) -> String {
        KnowledgeContentHash.of(parts)
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
        case .meeting, .conversation:
            let id = UUID(uuidString: sourceID)
            hub.navigation.pendingMeetingID = id
            hub.navigation.binderID = Store.shared.binderID(ofMeeting: id) ?? hub.navigation.binderID ?? Store.shared.defaultBinder().id
            hub.navigation.pendingBinderTab = kind == .conversation ? .conversations : .meetings
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
