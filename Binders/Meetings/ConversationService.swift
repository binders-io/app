import Foundation
import Observation
import SwiftData
import BindersKit

/// Conversations the iPhone heard during the day, as they come in over the phone link. Each becomes a record of its own
/// kind: notes written the way a meeting's are, its promises as to-dos, filed in the binder it belongs to, and searchable
/// and askable like a meeting. Only text ever arrives; the audio stayed on the phone. Conversations never go to a team
/// folder, whatever binder they land in.
@MainActor
@Observable
final class ConversationService {
    /// Conversations being written up right now.
    private(set) var processing: Set<UUID> = []
    /// Conversations you wrapped up yourself, to be kept however short.
    @ObservationIgnored private var wrappedUp: Set<UUID> = []

    @ObservationIgnored private let meetings: MeetingService
    /// For the knowledge base and the boards, which suggestions draw on.
    @ObservationIgnored weak var controller: DictationController?
    private var settings: AppSettings { AppSettings.shared }
    /// The language model a capture's notes, its reading (lane Y2), its binder and its answers go to: the one set up in
    /// Settings → AI, in the "later" lane. The self-tests put a stand-in here.
    @ObservationIgnored var model: @MainActor () -> LLMClient? = { AppSettings.shared.makeLLMClient(lane: .later) }

    init(meetings: MeetingService) {
        self.meetings = meetings
    }

    enum Received: Equatable {
        case kept(UUID)
        /// Sent before (its answer was lost on the way): nothing changes.
        case known(UUID)
        /// The library didn't open, so nothing was kept: whoever sent it keeps it.
        case refused
    }

    /// Keeps a conversation: the record and its transcript at once, then its notes and its binder. One sent again is kept once.
    /// Lane Y2: over the link (`overLink`), from a paired phone whose hello listed soloAuto (`soloAuto`), the capture's vouch
    /// is kept with it (MeetingRecord.soloJSON); from a file, or any other phone, it's dropped and the capture is read as today.
    @discardableResult
    func receive(_ payload: ConversationPayload, from phone: UUID? = nil, overLink: Bool = false, soloAuto: Bool = false) -> Received {
        // Kept now, it would be gone at quit, after the phone or this Mac's capture had let it go.
        guard Store.shared.canSave else { return .refused }
        let id = payload.id
        if record(id) != nil { return .known(id) }
        let device = payload.device.trimmed
        let record = MeetingRecord(title: MeetingService.conversationPlaceholderPrefix + payload.started.formatted(date: .omitted, time: .shortened),
                                   appName: device.isEmpty ? "iPhone" : device, templateID: MeetingTemplate.conversation.id)
        record.id = id
        record.kind = MeetingRecord.conversationKind
        record.createdAt = payload.started
        record.endedAt = payload.ended
        record.duration = payload.duration
        record.status = "processing"
        record.speakerNames = payload.speakers
        // Filed where new things go until it's been read; never shared, so never in a teammate's binder.
        let current = Store.shared.binder(settings.currentBinderID)
        record.binderID = (current.flatMap { $0.isTeamCopy ? nil : $0 } ?? Store.shared.defaultBinder()).id
        record.sharedWithTeam = false
        if overLink, soloAuto, let vouch = SoloVouch(payload, device: phone?.uuidString) { record.soloJSON = vouch.json }
        Store.shared.insert(record)
        // Fresh ids: a segment's id is unique across every transcript here, and one a client reused would move another
        // conversation's line into this one.
        Store.shared.replaceSegments(for: id, with: payload.segments.sorted { $0.start < $1.start }.map {
            TranscriptSegment(channel: $0.channel, start: $0.start, end: $0.end, text: $0.text, speaker: $0.speaker)
        })
        Log.meeting.info("Conversation \(id) from \(record.appName ?? "iPhone"): \(payload.segments.count) segments, \(Int(payload.duration)) s, \(payload.engine)")
        if payload.wrappedUp == true { wrappedUp.insert(id) }
        Task { await process(record) }
        return .kept(id)
    }

    /// Writes its notes and files it. A conversation too slight to keep is marked trivial: out of sight, deleted after a week.
    func process(_ record: MeetingRecord) async {
        let id = record.id
        guard !processing.contains(id) else { return }
        processing.insert(id)
        defer { processing.remove(id) }
        let segments = Store.shared.segments(for: id)
        let words = segments.reduce(0) { $0 + $1.text.wordCount }
        // Lane Y2: a capture that came with a vouch is checked, and read for what you said when it's only you.
        var vouch = SoloVouch.decode(record.soloJSON)
        if var kept = vouch, kept.keptForMoment == true {
            // Kept, though short, for a moment said in it: its vouch goes to its moments, and nothing else is read.
            kept = checked(kept, record: record, segments: segments)
            setVouch(kept, on: record)
            await decideCapture(record, vouch: kept)
            record.status = "trivial"
            Store.shared.save()
            return
        }
        if let given = vouch {
            let kept = checked(given, record: record, segments: segments)
            setVouch(kept, on: record)
            vouch = kept
        }
        let reads = vouch.map { $0.vouched && [.add, .auto].contains($0.heardMode) } ?? false
        // Too few words to be worth a model call, unless you wrapped it up yourself to have it kept, or it's what you
        // thought out loud.
        if words < ConversationPrompts.minimumWords, !wrappedUp.contains(id), !reads {
            if let vouch { await decideCapture(record, vouch: vouch) }
            record.status = "trivial"
            Store.shared.save()
            return
        }
        // The reading comes before the notes, so a capture's to-dos are made once.
        if reads, var read = vouch, read.reply == nil {
            read = await self.read(record, segments: segments, vouch: read)
            // A lower mode that came while it was being read (Turn Off Auto, binders/outcome "mode") stands.
            if let now = self.vouch(of: id), MomentMode(stored: now.mode).rank < read.heardMode.rank { read.mode = now.mode }
            setVouch(read, on: record)
            vouch = read
        }
        let spoke = vouch.map { reads && [SoloPrompts.State.items.rawValue, SoloPrompts.State.none.rawValue].contains($0.reply ?? "") } ?? false
        await meetings.summarize(record, segments: segments, templateID: MeetingTemplate.conversation.id, solo: spoke, client: model())
        guard exists(record) else { return }
        if record.status == "trivial" {
            // What you thought out loud is often fragments: a capture with items is kept whatever the notes say.
            guard spoke, !(vouch?.items ?? []).isEmpty else {
                if let vouch { await decideCapture(record, vouch: vouch) }
                return
            }
            record.status = "processing"
        }
        // No notes (no model, or it failed): nothing to file it by or offer from. The phone hears why.
        if record.summary.trimmed.isEmpty, !(record.errorMessage ?? "").isEmpty {
            record.status = "ready"
            Store.shared.save()
            return
        }
        await route(record)
        guard exists(record) else { return }
        // Its items and the moments said in it, in the order heard, before it's filed: its outcome then says what each became.
        if let vouch = SoloVouch.decode(record.soloJSON) { await decideCapture(record, vouch: vouch) }
        guard exists(record) else { return }
        record.status = "ready"
        Store.shared.save()
        await suggest(record)
    }

    // MARK: Auto for thinking out loud (lane Y2)

    /// The vouch kept with a capture, as it stands; nil for one that came without.
    func vouch(of capture: UUID) -> SoloVouch? {
        record(capture).flatMap { SoloVouch.decode($0.soloJSON) }
    }

    /// The vouch of a capture whose items and moments have been decided: a moment said in it that arrives later goes the
    /// same way (MomentService.rejoin).
    func readVouch(_ capture: UUID) -> SoloVouch? {
        vouch(of: capture).flatMap { $0.read == true ? $0 : nil }
    }

    private func setVouch(_ vouch: SoloVouch, on record: MeetingRecord) {
        record.soloJSON = vouch.json
        Store.shared.save()
    }

    /// What the Mac checks of a vouch (it can't hear the audio): the iPhone it came from may hand over; the transcript
    /// agrees (at most 2 segments of another voice, 12 words in all, and under 3 s of other speech let through); it doesn't
    /// read as talking to someone; this Mac wasn't on a call then; a speech engine, a mode it reads. The first that fails
    /// is kept as the Mac's word (SoloVouch.MacHold), and the capture is read as today.
    private func checked(_ given: SoloVouch, record: MeetingRecord, segments: [TranscriptSegment]) -> SoloVouch {
        var vouch = given
        guard vouch.solo == true, vouch.soloHold == nil, vouch.macHold == nil else { return vouch }
        let paired = controller?.moments.pairedDevices() ?? []
        if !AutoPhones.allows(vouch.device.flatMap(UUID.init(uuidString:)), paired: paired) {
            vouch.macHold = SoloVouch.MacHold.phone
            return vouch
        }
        let names = record.speakerNames
        let others = segments.filter { ![SoloRule.youLabel, SoloRule.unsureLabel].contains(names[$0.speaker] ?? $0.speaker) }
        // A vouch without its other speech can't be checked: refused.
        guard let otherSpeech = vouch.otherSpeech else {
            vouch.macHold = SoloVouch.MacHold.transcript
            return vouch
        }
        if others.count > 2 || others.reduce(0, { $0 + $1.text.wordCount }) > 12 || otherSpeech >= SoloRule.otherAllowed {
            vouch.macHold = SoloVouch.MacHold.transcript
            return vouch
        }
        let yours = SoloPrompts.numbered(segments, speakers: names).map(\.text)
        if SoloRules.talkingTo(yours) {
            vouch.macHold = SoloVouch.MacHold.talking
            return vouch
        }
        let ended = max(record.endedAt ?? record.createdAt, record.createdAt.addingTimeInterval(record.duration))
        if MeetingService.wasOnACall(from: record.createdAt, to: ended) {
            vouch.macHold = SoloVouch.MacHold.macCall
            return vouch
        }
        if ["siri", "test"].contains((vouch.engine ?? "").lowercased()) || ![MomentMode.add, .auto].contains(vouch.heardMode) {
            vouch.macHold = "unvouched"
        }
        return vouch
    }

    /// The reading (SoloPrompts): one call over your sentences, numbered, without the moments said in it; its reply and
    /// items kept in the vouch at once, so a quit never reads it twice. Refused lines are counted in the log, never their
    /// words. Without a model the reply stays unread, and the capture is written up as today.
    private func read(_ record: MeetingRecord, segments: [TranscriptSegment], vouch given: SoloVouch) async -> SoloVouch {
        var vouch = given
        let sentences = SoloPrompts.numbered(segments, speakers: record.speakerNames, leavingOut: saidAsMoments(record))
        guard let client = model() else { return vouch }
        guard !sentences.isEmpty else {
            vouch.reply = SoloPrompts.State.none.rawValue
            return vouch
        }
        let date = record.createdAt.formatted(date: .complete, time: .shortened)
        let agents = AgentRegistry.shared.agents.filter(\.isEnabled).map(\.name)
        let output = try? await client.complete(system: SoloPrompts.systemPrompt(),
                                                user: SoloPrompts.userPrompt(date: date, duration: record.duration, sentences: sentences),
                                                maxTokens: SoloPrompts.maxTokens, temperature: 0.1, timeout: SoloPrompts.timeout)
        let reply = SoloPrompts.parse(output ?? "", sentences: sentences, agents: agents)
        vouch.reply = reply.state.rawValue
        vouch.items = Array(reply.items.prefix(SoloPrompts.through))
        vouch.offers = Array(reply.items.dropFirst(SoloPrompts.through))
        if !reply.refused.isEmpty {
            Log.meeting.info("Capture \(record.id): the reading refused \(reply.refused.count) lines: \(reply.refused.joined(separator: "; "))")
        }
        return vouch
    }

    /// Step 6: the items read from it and the moments said in it that wait for it, together, in the order heard, each
    /// decided after the one before so each takes its place in Auto's limit in turn, and each reading the capture's mode
    /// again right before it's handed over. The moments of this capture still being decided are waited for first.
    private func decideCapture(_ record: MeetingRecord, vouch: SoloVouch) async {
        guard let moments = controller?.moments else { return }
        await moments.waitForMoments(in: record.id)
        let reads = vouch.vouched && [.add, .auto].contains(vouch.heardMode) && vouch.reply == SoloPrompts.State.items.rawValue
        let joining = moments.joining(record.id)
        let saidAsMoments = saidAsMoments(record)
        var queue: [(heard: Date, item: (SoloReading.Item, Int)?, moment: UUID?)] = joining.map { ($0.heard, nil, $0.id) }
        if reads {
            for (index, item) in (vouch.items ?? []).enumerated() where !saidAsMoments.contains(where: { MomentRules.sameWords(item.said, $0) }) {
                queue.append((record.createdAt.addingTimeInterval(item.offset), (item, index), nil))
            }
        }
        let id = record.id
        let device = vouch.device.flatMap(UUID.init(uuidString:))
        for entry in queue.sorted(by: { $0.heard < $1.heard }) {
            let now = self.vouch(of: id) ?? vouch
            if let (item, index) = entry.item {
                // Not Only Me pressed while its items were being decided: the rest aren't added either.
                if now.notOnlyMe == true { continue }
                _ = await moments.decideFound(item, index: index, capture: record, vouch: now, device: device) { [weak self] in
                    // Stop All and Not Only Me count as a lower mode for what's still to come.
                    self?.vouch(of: id)?.modeNow ?? .suggest
                }
            } else if let moment = entry.moment {
                await moments.rejoin(moment, vouch: now)
            }
        }
        guard exists(record), var done = self.vouch(of: id) else { return }
        done.read = true
        setVouch(done, on: record)
    }

    /// Stop All, Not Only Me, or a lower mode, on a capture read for what you said, from a phone that lists soloAuto. Nil
    /// when the id isn't such a capture here.
    func act(on id: UUID, action: String, mode: String? = nil) async -> (ok: Bool, message: String)? {
        guard let record = record(id), var vouch = SoloVouch.decode(record.soloJSON), let moments = controller?.moments else { return nil }
        let at = AutoText.saidAt(record.createdAt, now: Date())
        switch action {
        case "stop-all":
            // Kept first, so nothing still being decided from it, or arriving later, is handed over after this.
            vouch.stoppedAll = true
            setVouch(vouch, on: record)
            var stopped = 0
            for found in moments.found(in: id) where found.state.started == true && found.state.stopped != true {
                if moments.act(on: found.id, action: "stop")?.ok == true { stopped += 1 }
            }
            return (true, AutoText.stopAllLine(stopped, at: at))
        case "not-only-me":
            vouch.notOnlyMe = true
            setVouch(vouch, on: record)
            for found in moments.found(in: id) where ["acted", "offered"].contains(found.state.outcome.state) {
                _ = moments.act(on: found.id, action: "not-me")
            }
            return (true, AutoText.notOnlyMeLine(at: at))
        case "mode":
            let lowered = MomentMode(stored: mode)
            guard mode == lowered.rawValue, lowered.rank < vouch.heardMode.rank else { return (true, "") }
            vouch.mode = lowered.rawValue
            setVouch(vouch, on: record)
            return (true, "")
        default:
            return (false, "That isn't something you can do with it now.")
        }
    }

    // MARK: Suggestions

    /// A conversation as its write-up reads it: without the "Binders, …" you said in it that became a moment, as that moment
    /// made the to-do or gave the answer already (MomentRules.withoutMoments). The transcript itself stays whole.
    func writeUp(_ record: MeetingRecord, _ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        MomentRules.withoutMoments(segments, said: saidAsMoments(record))
    }

    /// The words of the moments said in a conversation, decided or on their way (MomentService.said).
    private func saidAsMoments(_ record: MeetingRecord) -> [String] {
        guard record.isConversation, let moments = controller?.moments else { return [] }
        let ended = max(record.endedAt ?? record.createdAt, record.createdAt.addingTimeInterval(record.duration))
        return moments.said(in: record.id, from: record.createdAt.addingTimeInterval(-600), to: ended.addingTimeInterval(600))
    }

    /// What to offer once a conversation is written up: a card for each thing you said you'd do that isn't on a board,
    /// a card for an idea in its notes, and an answer, from your binders, to each question you asked that the conversation
    /// didn't answer. Heard by this Mac, they're notifications here; heard by the iPhone, the iPhone asks for them and
    /// shows them there. A card or an idea can be given to an agent too (`give`). Nothing a moment said in it did already
    /// is offered again: its words are left out of what's read for questions, and a to-do, idea or question with mostly
    /// its words isn't offered.
    func suggest(_ record: MeetingRecord) async {
        guard record.isConversation, record.status == "ready", settings.suggestCards || settings.suggestAnswers else { return }
        let binder = Store.shared.binder(record.binderID)?.name ?? "General"
        var offered: [ConversationSuggestion] = []
        let names = record.speakerNames
        let segments = Store.shared.segments(for: record.id)
        let youKnown = segments.contains { $0.speaker == TranscriptSegment.you || names[$0.speaker] == TranscriptSegment.you }
        // Asked again now: a moment found in its transcript may have been decided after the notes were written.
        let moments = saidAsMoments(record)
        func wasAMoment(_ text: String) -> Bool { moments.contains { MomentRules.sameWords(text, $0) } }
        // Lane Y2: a capture read for what you said gets no cards or ideas from its notes (its items took their place, and
        // went on as to-dos and cards); the reading's 9th to 16th are offered instead.
        let vouch = SoloVouch.decode(record.soloJSON)
        let wasRead = vouch.map { $0.vouched && [.add, .auto].contains($0.heardMode)
            && [SoloPrompts.State.items.rawValue, SoloPrompts.State.none.rawValue].contains($0.reply ?? "") } ?? false
        if wasRead {
            for item in vouch?.offers ?? [] {
                offered.append(ConversationSuggestion(conversation: record.id, kind: item.kind == "idea" ? .idea : .card, text: item.title, binder: binder))
            }
        } else if settings.suggestCards {
            for candidate in SuggestionPrompts.cardCandidates(summary: record.summary, conversation: record.id, youKnown: youKnown)
                where controller?.board.card(forTodo: candidate.todo) == nil && !wasAMoment(candidate.text) {
                offered.append(ConversationSuggestion(conversation: record.id, kind: .card, text: candidate.text, binder: binder, todo: candidate.todo))
            }
            for idea in SuggestionPrompts.ideaCandidates(summary: record.summary) where !wasAMoment(idea) {
                let suggestion = ConversationSuggestion(conversation: record.id, kind: .idea, text: idea, binder: binder)
                if controller?.board.card(suggestion.cardID) == nil { offered.append(suggestion) }
            }
        }
        if settings.suggestAnswers, let client = model(), let knowledge = controller?.knowledge {
            let transcript = TranscriptFormatter.plainText(MomentRules.withoutMoments(segments, said: moments), names: names)
            let questions = (try? await client.complete(system: SuggestionPrompts.questionsSystemPrompt(youKnown: youKnown),
                                                        user: SuggestionPrompts.questionsUserPrompt(transcript: transcript),
                                                        maxTokens: 200, temperature: 0.1, timeout: 180))
                .map { SuggestionPrompts.parseQuestions($0) } ?? []
            for question in questions where !wasAMoment(question) {
                // The conversation itself didn't answer it, so it isn't a source; nor is a note with an agent's words in it,
                // as in Ask (your best 8, as if those weren't there).
                let hits = Array(await knowledge.search(question, limit: 16).filter { $0.agent == nil }.prefix(8))
                    .filter { $0.sourceID != record.id.uuidString }
                guard !hits.isEmpty else { continue }
                let contexts = hits.map { KnowledgeContext(label: "\($0.kind.singularName) “\($0.title)” · \($0.metaLine)", text: $0.text) }
                guard let output = try? await client.complete(system: SuggestionPrompts.answerSystemPrompt(today: Date().formatted(date: .complete, time: .omitted)),
                                                              user: KnowledgePrompts.answerUserPrompt(question: question, contexts: contexts),
                                                              maxTokens: 250, temperature: 0.1, timeout: 180),
                      let answer = SuggestionPrompts.parseAnswer(output) else { continue }
                var titles: [String] = []
                for hit in hits where !titles.contains(hit.title) { titles.append(hit.title) }
                offered.append(ConversationSuggestion(conversation: record.id, kind: .answer, text: question, binder: binder, answer: answer,
                                                      sources: Array(titles.prefix(3))))
            }
        }
        guard exists(record), !offered.isEmpty else { return }
        // Offered before (written up again): keep what you already said yes or no to.
        let earlier = Dictionary(record.suggestions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        record.suggestions = offered.map { earlier[$0.id] ?? $0 }
        Store.shared.save()
        if record.appName == "Mac" {
            for suggestion in record.suggestions where suggestion.status == .offered && earlier[suggestion.id] == nil {
                MacNotifications.shared.post(suggestion)
            }
        }
    }

    /// Yes to a suggestion: the card goes on its binder's board, linked to the to-do; an idea goes on its Backlog; an
    /// answer is just marked seen.
    @discardableResult
    func accept(_ suggestionID: String) -> (ok: Bool, message: String) {
        guard let (record, index) = suggestion(suggestionID) else { return (false, "That suggestion is gone.") }
        let suggestion = record.suggestions[index]
        var message = "Done."
        if suggestion.kind != .answer {
            guard let board = controller?.board, let made = card(for: suggestion, in: record, board: board) else {
                return (false, "That to-do has changed or is gone.")
            }
            // The agent whose work it is, suggested a moment later: never started, as a capture heard it.
            if !made.existed { controller?.router.suggestLater(for: made.card, origin: .capture) }
            message = made.existed ? "Already on the \(suggestion.binder) board."
                : suggestion.kind == .idea ? "On the \(suggestion.binder) board, in Backlog." : "On the \(suggestion.binder) board."
        }
        settle(suggestionID, .accepted)
        return (true, message)
    }

    /// Give to, your tap on a capture's card or idea, here or on the iPhone: the card goes on its binder's board, meant
    /// for the agent and in Ready, and Binders hands it over at once, with a receipt on the card. Only to an agent that's
    /// set up, on and takes that binder's cards.
    @discardableResult
    func give(_ suggestionID: String, to name: String) -> (ok: Bool, message: String) {
        guard let (record, index) = suggestion(suggestionID) else { return (false, "That suggestion is gone.") }
        let suggestion = record.suggestions[index]
        guard suggestion.kind != .answer else { return (false, "An answer is yours to read; there's nothing to give to an agent.") }
        let registry = AgentRegistry.shared
        guard let agent = registry.agent(named: name.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return (false, "No agent goes by “\(name)”. Set one up in Settings → Agents on \(LinkServer.macName).")
        }
        guard agent.takesCards(from: record.binderID) else {
            return (false, "\(agent.name) doesn't take cards from the \(suggestion.binder) board. Change that in Settings → Agents.")
        }
        guard let board = controller?.board, let made = card(for: suggestion, in: record, board: board) else {
            return (false, "That to-do has changed or is gone.")
        }
        board.give(made.card, to: agent.name, by: .you)
        settle(suggestionID, .accepted)
        let waits = registry.paused && made.card.column == .ready ? " Agents are paused, so it waits there until you resume them." : ""
        return (true, "Gave “\(made.card.title)” to \(agent.name), in \(made.card.column.title) on the \(suggestion.binder) board.\(waits)")
    }

    /// The card a suggestion becomes: a to-do's, linked to it, in Ready; an idea's, in Backlog, the same one however often
    /// it's said yes to. `existed` when it was made before. Nil when its to-do has changed or gone.
    private func card(for suggestion: ConversationSuggestion, in record: MeetingRecord, board: BoardService) -> (card: TaskCard, existed: Bool)? {
        switch suggestion.kind {
        case .card:
            guard let todo = suggestion.todo.flatMap(Todos.find) else {
                // Lane Y2: one of the reading's items past the eighth, which made no to-do: its own card, in Ready.
                guard suggestion.todo == nil, !record.soloJSON.isEmpty else { return nil }
                if let card = board.card(suggestion.cardID) { return (card, true) }
                let heard = record.createdAt.formatted(date: .abbreviated, time: .shortened)
                let card = board.create(title: suggestion.text, details: "From what you thought out loud, heard \(heard).", binderID: record.binderID,
                                        column: .ready, source: (MeetingRecord.conversationKind, record.id.uuidString, record.title),
                                        id: suggestion.cardID, by: .you)
                return (card, false)
            }
            return board.create(from: todo, column: .ready, binderID: record.binderID, by: .you)
        case .idea:
            if let card = board.card(suggestion.cardID) { return (card, true) }
            let heard = record.createdAt.formatted(date: .abbreviated, time: .shortened)
            let card = board.create(title: suggestion.text, details: "An idea from “\(record.title)”, heard \(heard).", binderID: record.binderID,
                                    column: .backlog, source: (MeetingRecord.conversationKind, record.id.uuidString, record.title),
                                    id: suggestion.cardID, by: .you)
            return (card, false)
        case .answer:
            return nil
        }
    }

    private func settle(_ suggestionID: String, _ status: ConversationSuggestion.Status) {
        guard let (record, index) = suggestion(suggestionID) else { return }
        var list = record.suggestions
        list[index].status = status
        record.suggestions = list
        Store.shared.save()
    }

    func dismiss(_ suggestionID: String) {
        settle(suggestionID, .dismissed)
    }

    /// Suggestions on recent conversations the iPhone heard, for the iPhone to show.
    func suggestionsForPhone(since: Date = Date().addingTimeInterval(-3 * 86_400)) -> [ConversationSuggestion] {
        let kind = MeetingRecord.conversationKind
        let records = (try? Store.shared.context.fetch(FetchDescriptor<MeetingRecord>(predicate: #Predicate {
            $0.kind == kind && $0.createdAt > since
        }))) ?? []
        return records.filter { $0.appName != "Mac" }.flatMap(\.suggestions)
    }

    private func suggestion(_ id: String) -> (MeetingRecord, Int)? {
        let kind = MeetingRecord.conversationKind
        let records = (try? Store.shared.context.fetch(FetchDescriptor<MeetingRecord>(predicate: #Predicate { $0.kind == kind }))) ?? []
        for record in records where record.suggestionsJSON.contains(id) {
            if let index = record.suggestions.firstIndex(where: { $0.id == id }) { return (record, index) }
        }
        return nil
    }

    /// Picks the binder it belongs to with the language model, from your binders' names and what's in them. When the model
    /// can't tell, it stays where new things go. One in a folder was put there by you (opened inside it, or moved there),
    /// so it stays.
    func route(_ record: MeetingRecord) async {
        guard Store.shared.shownFolder(record.folderID, in: record.binderID) == nil else { return }
        let binders = Store.shared.binders().filter { !$0.isTeamCopy }
        guard binders.count > 1, let client = model() else { return }
        let hints = binders.map { ConversationPrompts.BinderHint(name: $0.name, titles: recentTitles(in: $0.id, excluding: record.id), about: MomentService.about($0)) }
        let prompt = ConversationPrompts.routingUserPrompt(binders: hints, title: record.title, summary: String(record.summary.prefix(2_000)))
        guard let output = try? await client.complete(system: ConversationPrompts.routingSystemPrompt(), user: prompt,
                                                      maxTokens: 80, temperature: 0.1, timeout: 180),
              exists(record), Store.shared.shownFolder(record.folderID, in: record.binderID) == nil else { return }
        let picked = ConversationPrompts.parseRouting(output, names: hints.map(\.name))
        if let name = picked.binder, let binder = binders.first(where: { $0.name == name }) {
            Store.shared.move(record, to: binder)
            record.routingReason = picked.reason
        } else {
            record.routingReason = picked.reason.map { "No binder clearly fit: \($0)" } ?? "No binder clearly fit"
        }
        Store.shared.save()
    }

    /// Picks up conversations a quit or crash left half-written, and lets go of trivial ones older than a week.
    func recover() {
        Store.shared.purgeTrivialConversations()
        let kind = MeetingRecord.conversationKind
        let stuck = (try? Store.shared.context.fetch(FetchDescriptor<MeetingRecord>(predicate: #Predicate {
            $0.kind == kind && $0.status == "processing"
        }))) ?? []
        guard !stuck.isEmpty else { return }
        Task {
            for record in stuck { await process(record) }
        }
    }

    /// A conversation that was trivial, kept after all.
    func keep(_ record: MeetingRecord) async {
        guard record.isConversation, record.status == "trivial" else { return }
        record.status = "processing"
        Store.shared.save()
        let segments = Store.shared.segments(for: record.id)
        await meetings.summarize(record, segments: segments, templateID: MeetingTemplate.conversation.id, client: model())
        guard exists(record) else { return }
        // Asked to keep it, so the model's "nothing here" doesn't throw it out again.
        if record.status == "trivial" { record.status = "processing" }
        await route(record)
        guard exists(record) else { return }
        record.status = "ready"
        Store.shared.save()
    }

    // MARK: Outcomes

    /// What became of a conversation the iPhone sent, for its row there; nil when there's no such conversation here.
    func outcome(_ id: UUID) -> CaptureOutcome? {
        guard let record = record(id), record.isConversation else { return nil }
        let mac = LinkServer.macName
        let binder = Store.shared.binder(record.binderID)?.name
        switch record.status {
        case "trivial":
            let words = Store.shared.segments(for: id).reduce(0) { $0 + $1.text.wordCount }
            let why = words < ConversationPrompts.minimumWords ? "too short" : "small talk"
            var outcome = CaptureOutcome(id: id, state: CaptureOutcome.States.notKept, line: "Not kept: \(why)", title: "Not kept", settled: true)
            // Lane Y2: from a phone in Auto or Add at Once, why it wasn't read for what you said.
            if let vouch = SoloVouch.decode(record.soloJSON), vouch.keptForMoment != true, [.add, .auto].contains(vouch.heardMode), vouch.why != nil {
                outcome.soloLine = AutoText.soloHeader(why: vouch.why, mode: vouch.heardMode)
            }
            return outcome
        case "ready" where record.summary.trimmed.isEmpty && !(record.errorMessage ?? "").isEmpty:
            let error = (record.errorMessage ?? "").replacingOccurrences(of: #"^Couldn't write (the )?notes: "#, with: "", options: .regularExpression)
            return CaptureOutcome(id: id, state: CaptureOutcome.States.failed, line: "Couldn't write up: \(error)",
                                  title: "Couldn't write up", binder: binder)
        case "ready":
            let todos = NotesEditing.openTasks(in: record.summary)
            let title = MeetingService.hasPlaceholderTitle(record) ? "" : ": \(record.title)"
            let count = todos == 0 ? "" : " · \(todos == 1 ? "1 to-do" : "\(todos) to-dos")"
            var outcome = CaptureOutcome(id: id, state: CaptureOutcome.States.filed, line: "Filed in \(binder ?? "General")\(title)\(count)",
                                         title: "Filed in \(binder ?? "General")", settled: true, binder: binder, todos: todos)
            if let vouch = SoloVouch.decode(record.soloJSON) { soloOutcome(&outcome, record: record, vouch: vouch, binder: binder ?? "General") }
            return outcome
        default:
            return CaptureOutcome(id: id, state: CaptureOutcome.States.writing, line: "Being written up on \(mac)", title: "Being written up")
        }
    }

    /// Lane Y2: what a capture that came with a vouch says on its outcome. Read for what you said: what each thing became
    /// (`found`, in the order heard, and its own outcome under its id) and the line's counts; not read: why (`soloLine`).
    private func soloOutcome(_ outcome: inout CaptureOutcome, record: MeetingRecord, vouch: SoloVouch, binder: String) {
        let mode = vouch.heardMode
        guard [.add, .auto].contains(mode) else { return }
        let found = controller?.moments.found(in: record.id) ?? []
        if !found.isEmpty {
            outcome.found = found.map { CaptureOutcome.Found(id: $0.id, heard: $0.heard, said: $0.state.said, kind: $0.state.kind,
                                                             joined: $0.state.joined == true ? true : nil) }
        }
        let read = vouch.vouched && vouch.reply != nil && vouch.reply != SoloPrompts.State.talking.rawValue
        if read, vouch.reply == SoloPrompts.State.items.rawValue {
            let handed = found.filter { $0.state.auto == true && $0.state.outcome.waiting == nil }.count
            let added = found.filter { $0.state.auto != true && $0.state.outcome.state == "acted" }.count
            let title = MeetingService.hasPlaceholderTitle(record) ? "" : record.title
            outcome.line = AutoText.captureLine(binder: binder, title: title, handed: handed, added: added, offered: vouch.offers?.count ?? 0)
        } else if read, vouch.reply == SoloPrompts.State.none.rawValue {
            outcome.soloLine = AutoText.nothingFound
        } else if read, vouch.reply == SoloPrompts.State.unread.rawValue {
            outcome.soloLine = AutoText.unreadFound
        } else if !read {
            outcome.soloLine = AutoText.soloHeader(why: vouch.why, mode: mode)
        }
    }

    private func record(_ id: UUID) -> MeetingRecord? {
        var descriptor = FetchDescriptor<MeetingRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return (try? Store.shared.context.fetch(descriptor))?.first
    }

    func recentTitles(in binderID: UUID, excluding id: UUID) -> [String] {
        let context = Store.shared.context
        var meetings = FetchDescriptor<MeetingRecord>(predicate: #Predicate { $0.binderID == binderID && $0.status == "ready" && $0.id != id },
                                                      sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        meetings.fetchLimit = 3
        var notes = FetchDescriptor<NoteItem>(predicate: #Predicate { $0.binderID == binderID }, sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        notes.fetchLimit = 3
        let titles = ((try? context.fetch(meetings)) ?? []).map(\.title) + ((try? context.fetch(notes)) ?? []).map(\.title)
        return titles.map { String($0.prefix(80)) }.filter { !$0.isEmpty }
    }

    private func exists(_ record: MeetingRecord) -> Bool {
        record.modelContext != nil && !record.isDeleted
    }
}
