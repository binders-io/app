import AppKit
import Foundation
import SwiftData
import BindersKit

/// The Manager (lane MG1): what you ask the agent with the Manager role, from the Mac or your iPhone, and the tidies on the
/// schedule you set, one at a time. Kept in manager.json in the data folder with what each one changed, so Undo puts a whole
/// request's changes back, and with the note edits the Manager suggested, which change nothing until you accept them.
@MainActor
@Observable
final class ManagerService {
    static let fileName = "manager.json"

    private(set) var file = ManagerFile()
    /// The request whose run is going now.
    private(set) var runningID: UUID?
    @ObservationIgnored weak var controller: DictationController?
    @ObservationIgnored private var process: (any ManagerRunning)?
    /// The run going now is a local model's (lane MG2): when it fails, its log's result says why in its own words.
    @ObservationIgnored private var runningLocal = false
    /// The run going now asked for Binders' tools alone (`ManagerLaunch.make`'s `strictMCP`).
    @ObservationIgnored private var runStrict = false
    @ObservationIgnored private var stopping = false
    /// Requests started again without the limit to Binders' tools after a run with it didn't get going: once each.
    @ObservationIgnored private var triedLoose: Set<UUID> = []
    /// Why Binders stopped the run going now before it ended on its own, for the request.
    @ObservationIgnored private var cutShort: String?
    /// Watches a Claude Code run's start, to stop it at once when Binders' tools didn't come up in it.
    @ObservationIgnored private var startWatch: Task<Void, Never>?
    /// The model a local Manager runs on (lane MG2): Distill's in Settings → AI, or the one it names; in the lane you're
    /// waiting on for what you ask, behind it for a scheduled tidy. Self-tests put a stand-in here.
    @ObservationIgnored var localModel: @MainActor (LocalModelWake, ManagerRequest.From) -> LLMClient? = { wake, from in
        AppSettings.shared.makeManagerClient(wake, lane: from == .schedule ? .later : .now)
    }
    /// Self-tests only: what a local run's server hands the app through the inbox, done while it waits.
    @ObservationIgnored var localPump: (@MainActor () async -> Void)?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored let registry: AgentRegistry

    init(controller: DictationController? = nil, registry: AgentRegistry = .shared) {
        self.controller = controller
        self.registry = registry
        file = Self.readFile()
        // A run that was going when Binders quit is over.
        var changed = false
        for index in file.requests.indices where !file.requests[index].isOver {
            file.requests[index].status = .failed
            file.requests[index].why = "Binders quit before it finished."
            changed = true
        }
        if changed { save() }
    }

    static var url: URL { AppPaths.support.appendingPathComponent(fileName) }

    /// The file as it is, for `Binders --mcp`, which reads the request a run asks for.
    static func readFile() -> ManagerFile {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder.iso.decode(ManagerFile.self, from: $0) } ?? ManagerFile()
    }

    private func save() {
        file.trim()
        guard let data = try? JSONEncoder.iso.encode(file) else { return }
        try? data.write(to: Self.url, options: .atomic)
        controller?.link.changed(["manager"])
    }

    // MARK: Reading

    var requests: [ManagerRequest] { file.requests }

    func request(_ id: UUID) -> ManagerRequest? { file.requests.first { $0.id == id } }

    /// A conversation's requests, oldest first.
    func thread(_ id: UUID) -> [ManagerRequest] { file.requests.filter { $0.thread == id } }

    var waitingSuggestions: [NoteEditSuggestion] { file.suggestions.filter { $0.status == .waiting } }

    func suggestion(_ id: UUID) -> NoteEditSuggestion? { file.suggestions.first { $0.id == id } }

    /// The agent with the role.
    var agent: AgentProfile? { registry.manager }

    /// Why nothing you ask it would start now, or nil.
    var problem: String? {
        guard let agent else { return "No agent is the Manager yet. Give one the role in Settings → Agents." }
        if registry.paused { return "Agents are paused in Settings → Agents." }
        if !registry.wakeable(agent) { return "\(agent.name) can't be woken as it is. Look at it in Settings → Agents." }
        return nil
    }

    // MARK: Asking

    /// Something you asked it, in your words. `thread`: a request whose conversation this goes on.
    /// `id`: the phone's own for it, so one sent twice is one request.
    @discardableResult
    func ask(_ text: String, thread: UUID? = nil, from: ManagerRequest.From, id: UUID? = nil, askedOf: String? = nil) -> ManagerRequest {
        let follows = thread.flatMap(request)
        var request = ManagerRequest(id: id ?? UUID(), thread: follows?.thread, kind: .ask,
                                     text: String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(4_000)), from: from)
        request.askedOf = askedOf
        return add(request)
    }

    /// A tidy of one binder, or of every binder.
    @discardableResult
    func tidy(binder: UUID?, from: ManagerRequest.From, id: UUID? = nil, askedOf: String? = nil) -> ManagerRequest {
        let name = binder.flatMap { Store.shared.binder($0)?.name }
        var request = ManagerRequest(id: id ?? UUID(), kind: .tidy, text: ManagerRequest.tidyText(binder: name), binder: binder, from: from)
        request.askedOf = askedOf
        return add(request)
    }

    private func add(_ request: ManagerRequest) -> ManagerRequest {
        file.requests.append(request)
        save()
        startNext()
        return self.request(request.id) ?? request
    }

    /// Starts the oldest request waiting, when none is running.
    func startNext() {
        guard runningID == nil, let index = file.requests.firstIndex(where: { $0.status == .waiting }) else { return }
        let id = file.requests[index].id
        if let problem {
            finish(id, status: .failed, why: problem)
            return startNext()
        }
        guard let agent, let dispatcher = controller?.agents else { return }
        // Asked from your iPhone of another Manager, whose yes it had: not this one's.
        if let askedOf = file.requests[index].askedOf, askedOf != agent.name {
            finish(id, status: .failed, why: "The Manager is \(agent.name) now, not \(askedOf), which you asked. Ask again, so your iPhone can ask you about \(agent.name) first.")
            return startNext()
        }
        let exited: @MainActor (Int32, URL) -> Void = { [weak self] status, log in self?.ended(id, status: status, log: log) }
        let woken: Result<any ManagerRunning, ManagerWakeFailure>
        cutShort = nil
        if case .localModel(let wake) = agent.wake {
            runStrict = false
            woken = dispatcher.wakeLocalManager(agent, request: id, client: localModel(wake, file.requests[index].from), pump: localPump, exited: exited)
        } else {
            // Whether this run asks for Binders' tools alone, as it starts: a refusal of that starts it again once, without.
            let claude = dispatcher.wakeManager(agent, request: id, strict: triedLoose.contains(id) ? false : nil, exited: exited)
            runStrict = (try? claude.get())?.strict ?? false
            if case .success(let run) = claude { watchStart(id, run: run) }
            woken = claude.map { $0.process }
        }
        runningLocal = agent.wake.kind == "localModel"
        switch woken {
        case .success(let started):
            process = started
            runningID = id
            file.requests[index].status = .running
            file.requests[index].agent = agent.name
            file.requests[index].startedAt = Date()
            save()
        case .failure(let failure):
            finish(id, status: .failed, why: failure.why)
            startNext()
        }
    }

    /// Keeps an eye on a Claude Code run's start: when Binders' tools were kept out of it or didn't come up, it can't
    /// even read what you asked, so Binders stops it at once and says why, rather than leave it to answer without them.
    /// When it hasn't started after a few minutes, Binders stops it and says what Claude Code printed.
    private func watchStart(_ id: UUID, run: ManagerClaudeRun) {
        startWatch?.cancel()
        let log = run.log
        startWatch = Task { [weak self] in
            let began = Date()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, self.runningID == id, let process = self.process, process.isRunning else { return }
                let output = await Task.detached { AgentDispatcher.startAndEnd(of: log) }.value
                if ClaudeCodeManaged.started(in: output) {
                    let server = ManagerLaunch.server
                    if ClaudeCodeManaged.finding(in: output, server: server) == .keptOut {
                        self.cutShort = ClaudeCodeManaged.managerKeptOutLine
                    } else if let trouble = ClaudeCodeManaged.serverTrouble(in: output, server: server) {
                        self.cutShort = ClaudeCodeManaged.managerToolsLine(trouble)
                    } else {
                        return
                    }
                    process.terminate()
                    return
                }
                if Date().timeIntervalSince(began) > Self.startLimit {
                    let printed = AgentDispatcher.lastError(in: log).map { " It printed: “\(AgentRunReport.trimmed($0, limit: 240))”" } ?? ""
                    self.cutShort = ClaudeCodeManaged.startupProblem(in: output)
                        ?? "Claude Code didn't start within \(Int(Self.startLimit / 60)) minutes, so Binders stopped it.\(printed)"
                    process.terminate()
                    return
                }
            }
        }
    }

    /// The longest a Claude Code run of the Manager may take to start.
    static let startLimit: TimeInterval = 3 * 60

    /// The newest log of a request's runs, if it has one: what Claude Code printed, to see why one failed.
    func log(of id: UUID) -> URL? {
        let prefix = "manager-\(id.uuidString.prefix(8).lowercased())-"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: AgentDispatcher.logs.path)) ?? []
        return names.filter { $0.hasPrefix(prefix) }.max().map { AgentDispatcher.logs.appendingPathComponent($0) }
    }

    /// Asks a failed request again, as a new one.
    func again(_ id: UUID) {
        guard let request = request(id), request.status == .failed else { return }
        if request.kind == .tidy {
            tidy(binder: request.binder, from: .mac)
        } else {
            ask(request.text, thread: request.thread == request.id ? nil : request.thread, from: .mac)
        }
    }

    /// Stops a request: its run, if it's going, or before it starts.
    func stop(_ id: UUID) {
        if runningID == id, let process, process.isRunning {
            stopping = true
            process.terminate()
            return
        }
        guard request(id)?.status == .waiting else { return }
        finish(id, status: .stopped, why: "You stopped it.")
    }

    private func ended(_ id: UUID, status: Int32, log: URL) {
        guard runningID == id else { return }
        runningID = nil
        process = nil
        startWatch?.cancel()
        startWatch = nil
        let stoppedByYou = stopping
        stopping = false
        let cut = cutShort
        cutShort = nil
        let output = runningLocal ? "" : AgentDispatcher.startAndEnd(of: log)
        // This Mac's Claude Code, managed by an organization, refused a run limited to Binders' tools: once, it starts again
        // without that limit (`AgentDispatcher.asksOnlyBinders` is false from now, so it can't be refused so again), with a
        // hook keeping it to the Manager's tools.
        let managed = runningLocal || stoppedByYou ? nil : ClaudeCodeManaged.finding(in: output, server: ManagerLaunch.server)
        let wasStrict = runStrict
        runStrict = false
        let startup = runningLocal || stoppedByYou ? nil : ClaudeCodeManaged.startupProblem(in: output)
        if wasStrict, !stoppedByYou, cut == nil, let index = file.requests.firstIndex(where: { $0.id == id }),
           !file.requests[index].isOver, file.requests[index].changes.isEmpty, file.requests[index].reply == nil {
            if managed == .refusedOnlyBinders {
                AppDefaults.store.set(Date(), forKey: AgentDispatcher.refusedOnlyBindersKey)
                file.requests[index].status = .waiting
                save()
                return startNext()
            }
            // It stopped before it started, for a reason Binders doesn't know: an organization's settings from its server
            // leave no file to see, and may refuse the limit in other words. Once, it starts again without the limit.
            if status != 0, startup == nil, !ClaudeCodeManaged.started(in: output), !triedLoose.contains(id), !AgentDispatcher.managedHooksOnly {
                triedLoose.insert(id)
                // As after a refusal Binders knows: later runs start without the limit for a while too.
                AppDefaults.store.set(Date(), forKey: AgentDispatcher.refusedOnlyBindersKey)
                file.requests[index].status = .waiting
                save()
                return startNext()
            }
        }
        triedLoose.remove(id)
        if let request = request(id), !request.isOver {
            let result = AgentDispatcher.lastResult(in: log).text?.trimmingCharacters(in: .whitespacesAndNewlines)
            let resultFailed = !runningLocal && AgentDispatcher.resultIsError(in: log)
            if stoppedByYou {
                finish(id, status: .stopped, why: "You stopped it.")
            } else if let cut, request.reply == nil {
                finish(id, status: .failed, why: cut)
            } else if managed == .keptOut, request.reply == nil {
                finish(id, status: .failed, why: ClaudeCodeManaged.managerKeptOutLine)
            } else if let startup, request.reply == nil {
                finish(id, status: .failed, why: startup)
            } else if runningLocal, status != 0 {
                // A local run says why it failed in its own words.
                finish(id, status: .failed, why: result ?? "Its run stopped (exit \(status)).")
            } else if request.reply == nil, status == 0, !resultFailed, let said = result, !said.isEmpty {
                // It finished without calling reply: what it said last is its answer.
                answer(id, said)
            } else if request.reply == nil {
                // An error it gave as its result (not signed in, say) is Claude Code's, not the Manager's words.
                let known = resultFailed ? result.flatMap(ClaudeCodeManaged.startupProblem) : nil
                finish(id, status: .failed, why: known ?? Self.failure(status: status, result: result, printed: runningLocal ? nil : AgentDispatcher.lastError(in: log)))
            } else {
                // It replied, then stopped: the reply stands.
                finish(id, status: .answered, why: nil)
            }
        }
        startNext()
    }

    /// Why a run that ended without a reply failed, in words for the request: how it ended, and what it said or printed.
    static func failure(status: Int32, result: String?, printed: String?) -> String {
        let how = switch status {
        case 0: "Its run ended without a reply."
        case 15: "It ran past \(Int(AgentDispatcher.managerLimit / 60)) minutes, so Binders stopped it."
        default: "Its run stopped (exit \(status))."
        }
        if let result, !result.isEmpty { return how + " It said: " + AgentRunReport.trimmed(result, limit: 300) }
        if let printed, !printed.isEmpty { return how + " Claude Code printed: “" + AgentRunReport.trimmed(printed, limit: 300) + "”" }
        return how
    }

    private func finish(_ id: UUID, status: ManagerRequest.Status, why: String?) {
        guard let index = file.requests.firstIndex(where: { $0.id == id }) else { return }
        file.requests[index].status = status
        file.requests[index].why = why
        save()
    }

    private func answer(_ id: UUID, _ text: String) {
        guard let index = file.requests.firstIndex(where: { $0.id == id }) else { return }
        file.requests[index].reply = String(text.prefix(8_000))
        file.requests[index].repliedAt = Date()
        file.requests[index].status = .answered
        save()
    }

    // MARK: What its run does (through the inbox)

    /// Why a write that says it's for a request may not go ahead, or nil: only the Manager's run for the request running
    /// now, by its name, may write for it.
    func refusal(request id: String, actor: String, kind: String) -> String? {
        guard kind == BoardActor.Kind.agent.rawValue, let id = UUID(uuidString: id), runningID == id,
              let agent, registry.isManager(agent), AgentRegistry.isAgent(agent, named: actor) else {
            return "Only the Manager's run for the request it's on can do that."
        }
        return nil
    }

    /// What its run changed, kept with the request for Undo.
    func record(_ change: ManagerChange, for id: UUID) {
        guard let index = file.requests.firstIndex(where: { $0.id == id }) else { return }
        file.requests[index].changes.append(change)
        save()
    }

    /// Its answer, which ends the request: what the run does after it is still kept.
    func reply(_ id: UUID, _ text: String) {
        answer(id, text)
    }

    func suggest(_ suggestion: NoteEditSuggestion) {
        file.suggestions.append(suggestion)
        save()
    }

    // MARK: Undo

    /// Puts back what the request changed, newest first, as you. Says what it put back, and what it couldn't.
    @discardableResult
    func undo(_ id: UUID) -> String {
        guard let index = file.requests.firstIndex(where: { $0.id == id }), let board = controller?.board else { return "Nothing to undo." }
        // A run still going would go on changing what Undo can't put back.
        guard file.requests[index].isOver else { return "It's still working on this. Stop it or let it finish, then undo." }
        let changes = file.requests[index].undoable
        guard !changes.isEmpty else { return "Nothing to undo." }
        var done = 0, left: [String] = []
        for change in changes.reversed() {
            if let why = undo(change, board: board) { left.append(why) } else { done += 1 }
        }
        file.requests[index].undoneAt = Date()
        save()
        let put = "Put back \(done) of \(changes.count) change\(changes.count == 1 ? "" : "s")."
        return left.isEmpty ? put : put + " " + left.joined(separator: " ")
    }

    /// One change put back, or why it couldn't be.
    private func undo(_ change: ManagerChange, board: BoardService) -> String? {
        let store = Store.shared
        switch change.kind {
        case .editedCard:
            guard let card = board.card(change.id) else { return "“\(change.line)”: the card is gone." }
            board.tidy(card, title: change.before, details: change.beforeDetails, by: .you, line: "Undid the Manager's edit.")
        case .closedCard:
            guard let card = board.card(change.id) else { return "“\(change.line)”: the card is gone." }
            guard card.column == .done else { return "“\(card.title)” moved on since, so it stays where it is." }
            do {
                try board.tidyMove(card, to: BoardColumn(rawValue: change.before ?? "") ?? .backlog, note: "Undid the Manager's closing it.")
            } catch {
                return "“\(card.title)”: \(error.localizedDescription)"
            }
        case .mergedCards:
            guard let card = board.card(change.id) else { return "“\(change.line)”: the card is gone." }
            board.tidy(card, details: change.beforeDetails, links: change.beforeLinks, by: .you, line: "Undid the Manager's merge.")
            for merged in change.merged ?? [] {
                if let why = undo(merged, board: board) { return why }
            }
        case .madeCard:
            guard let card = board.card(change.id) else { return nil }
            guard card.column == .backlog || card.column == .ready, card.assignee == nil else {
                return "“\(card.title)” was picked up since, so it stays."
            }
            ManagerProposals.unplace(card)
            if let why = board.delete(card) { return "“\(card.title)”: \(why)" }
        case .movedCard:
            guard let card = board.card(change.id) else { return "“\(change.line)”: the card is gone." }
            guard let column = BoardColumn(rawValue: change.before ?? ""), card.column != column else { return nil }
            do {
                try board.tidyMove(card, to: column, note: "Undid the Manager's move.")
            } catch {
                return "“\(card.title)”: \(error.localizedDescription)"
            }
        case .assignedCard:
            guard let card = board.card(change.id) else { return "“\(change.line)”: the card is gone." }
            let before = change.before ?? ""
            board.assign(card, to: before.isEmpty ? nil : before, by: .you)
        case .deletedCard:
            guard board.card(change.id) == nil else { return nil }
            guard let was = ManagerCardSnapshot.read(change.snapshot) else { return "“\(change.line)”: Binders didn't keep enough of it to make it again." }
            // On a board shared with the team, or a hub's, it comes back as a new card: the team's deletion stands, and the
            // hub keeps a card's first put once, so the same id there wouldn't bring it back.
            let shared = controller?.teamBoard.isShared(binder: was.binder) == true || was.binder.map { board.hub?.covers(binder: $0) == true } == true
            let column = BoardColumn(rawValue: was.column) ?? .backlog
            let card = board.create(title: was.title, details: was.details, binderID: was.binder, column: column == .done ? .backlog : column, due: was.due,
                                    source: was.sourceKind.flatMap { kind in was.sourceID.map { (kind, $0, was.sourceTitle ?? "") } },
                                    id: shared ? nil : was.id, by: .you)
            if !was.links.isEmpty { board.tidy(card, links: was.links, by: .you, line: "Brought back: Undid the Manager's deleting it.") }
            if let who = was.meantFor { board.assign(card, to: who, by: .you) }
            if column == .done { try? board.tidyMove(card, to: .done, note: "Brought back as it was.") }
        case .editedNote:
            guard let note = store.note(change.id), let was = change.beforeDetails else { return "“\(change.line)”: the note is gone." }
            guard note.text == change.snapshot else { return "“\(note.title)” changed since, so it stays as it is. Its history has the earlier version." }
            NoteHistory.willChange(note, to: was, always: true)
            note.text = was
            note.updatedAt = Date()
            // Whose edit it was before, as it was: yours again if it was yours.
            note.editedBy = (change.before ?? "").isEmpty ? nil : change.before
            note.editedAt = note.editedBy == nil ? nil : change.beforeLinks?.first.flatMap { ISO8601DateFormatter().date(from: $0) }
            store.save()
        case .madeNote:
            guard let note = store.note(change.id) else { return nil }
            guard note.text == change.snapshot else { return "“\(note.title)” changed since, so it stays." }
            store.delete(note)
        case .deletedNote:
            guard store.note(change.id) == nil else { return nil }
            guard let was = ManagerNoteSnapshot.read(change.snapshot) else { return "“\(change.line)”: Binders didn't keep enough of it to put it back." }
            let note = NoteItem(text: was.text)
            note.id = was.id
            note.binderID = store.binder(was.binder)?.id ?? store.defaultBinder().id
            note.folderID = store.shownFolder(was.folder, in: note.binderID)
            note.createdAt = was.createdAt
            note.madeBy = was.madeBy
            note.staysUnshared = was.staysUnshared
            store.insert(note)
        case .dismissedProposal:
            return ManagerProposals.undoDismiss(change)
        case .madeBinder:
            guard let binder = store.binder(change.id) else { return nil }
            let counts = store.counts(in: binder.id)
            guard counts.meetings + counts.notes == 0, board.cards(in: binder.id).isEmpty else { return "The binder “\(binder.name)” has things in it now, so it stays." }
            store.deleteBinder(binder, movingItemsTo: store.defaultBinder())
        case .editedBinder:
            guard let binder = store.binder(change.id), let was = ManagerBinderSnapshot.read(change.snapshot) else { return "“\(change.line)”: the binder is gone." }
            binder.name = was.name
            binder.colorIndex = was.color
            binder.archived = was.archived
            store.save()
        case .movedItem:
            guard let (item, binder) = Self.movable(change.id) else { return "“\(change.line)”: it's gone." }
            let folder = change.before.flatMap(UUID.init(uuidString:)).flatMap { store.folder($0) != nil ? $0 : nil }
            do {
                try FolderMoves.move(item, to: folder, in: binder)
                store.save()
            } catch {
                return "“\(change.line)”: \(error.localizedDescription)"
            }
        case .madeFolder:
            guard let folder = store.folder(change.id) else { return nil }
            let contents = store.contents(of: folder)
            guard contents.notes + contents.meetings + contents.captures + contents.folders == 0 else {
                return "The folder “\(folder.name)” has things in it now, so it stays."
            }
            _ = store.deleteFolder(folder)
        case .renamedFolder:
            guard let folder = store.folder(change.id), let name = change.before else { return "“\(change.line)”: the folder is gone." }
            guard store.rename(folder, to: name) else { return "“\(folder.name)”: \(Store.refusedMessage)" }
        case .suggestedEdit, .distilled:
            break
        }
        return nil
    }

    /// What a moved item is, and its binder, for Undo.
    private static func movable(_ id: UUID) -> (DraggedItem, UUID)? {
        let store = Store.shared
        if let note = store.note(id), let binder = note.binderID { return (.note(id), binder) }
        if let meeting = store.meeting(id), let binder = meeting.binderID { return (.meeting(id), binder) }
        if let folder = store.folder(id) { return (.folder(id), folder.binderID) }
        return nil
    }

    // MARK: Suggested note edits

    /// Your yes to a suggested edit: the note changes as your edit, its earlier version kept in its history.
    func accept(_ id: UUID) -> Result<String, ManagerFailure> {
        guard let index = file.suggestions.firstIndex(where: { $0.id == id }), file.suggestions[index].status == .waiting else {
            return .failure(.init("That suggestion isn't waiting any more."))
        }
        let suggestion = file.suggestions[index]
        guard let note = Store.shared.note(suggestion.note) else { return .failure(.init("That note is gone.")) }
        MarkdownEditor.flushAll()
        switch suggestion.applied(to: note.text) {
        case .failure(.changed):
            return .failure(.init("“\(note.title)” changed since, so the suggestion doesn't fit it any more. Dismiss it, or ask the Manager again."))
        case .failure(.nothing):
            file.suggestions[index].status = .accepted
            save()
            return .success("“\(note.title)” already says that.")
        case .success(let updated):
            NoteHistory.willChange(note, to: updated, always: true, by: .you)
            let oldTitle = MarkdownSyntax.noteTitle(note.text)
            note.text = updated
            note.updatedAt = Date()
            Store.shared.save()
            TeamNotes.current?.capture(note, by: .person)
            if !oldTitle.isEmpty { _ = LinkTargets.renameNote(note.id, from: oldTitle, to: note.title, itself: true) }
            file.suggestions[index].status = .accepted
            save()
            return .success("Changed “\(note.title)”. The earlier version is in its history.")
        }
    }

    func dismiss(_ id: UUID) {
        guard let index = file.suggestions.firstIndex(where: { $0.id == id }), file.suggestions[index].status == .waiting else { return }
        file.suggestions[index].status = .dismissed
        save()
    }

    // MARK: The schedule

    static let scheduleKey = "managerSchedule", lastTidyKey = "managerLastTidy"

    /// The tidy on a schedule, in Settings → Agents: off unless you turn it on.
    var schedule: ManagerSchedule {
        get { ManagerSchedule(rawValue: AppDefaults.store.string(forKey: Self.scheduleKey) ?? "") ?? .off }
        set { AppDefaults.store.set(newValue.rawValue, forKey: Self.scheduleKey) }
    }

    func startSchedule() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkSchedule() }
        }
    }

    /// A tidy of every binder when one is due, and only while the Mac is plugged in, cool, idle for 10 minutes and doing
    /// nothing else of Binders': not dictating, recording or capturing.
    func checkSchedule(now: Date = Date()) {
        let last = AppDefaults.store.object(forKey: Self.lastTidyKey) as? Date
        guard schedule.isDue(last: last, now: now), problem == nil, runningID == nil, let controller else { return }
        let power = DistillBackgroundReader.power()
        let thermal = ProcessInfo.processInfo.thermalState
        var dictating = true
        if case .idle = controller.phase { dictating = false }
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        guard !power.onBattery, !ProcessInfo.processInfo.isLowPowerModeEnabled, thermal != .serious, thermal != .critical,
              !dictating, !controller.meetings.isRecording, idle >= 600 else { return }
        AppDefaults.store.set(now, forKey: Self.lastTidyKey)
        tidy(binder: nil, from: .schedule)
    }
}

/// Why the Manager couldn't do something you asked, in words for you.
struct ManagerFailure: Error {
    var why: String
    init(_ why: String) { self.why = why }
}

extension JSONEncoder {
    /// Dates as ISO 8601, as the Manager's file keeps them.
    static var iso: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        return encoder
    }
}

extension JSONDecoder {
    static var iso: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
