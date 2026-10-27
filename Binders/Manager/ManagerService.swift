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
    @ObservationIgnored private var stopping = false
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
    func ask(_ text: String, thread: UUID? = nil, from: ManagerRequest.From, id: UUID? = nil) -> ManagerRequest {
        let follows = thread.flatMap(request)
        return add(ManagerRequest(id: id ?? UUID(), thread: follows?.thread, kind: .ask,
                                  text: String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(4_000)), from: from))
    }

    /// A tidy of one binder, or of every binder.
    @discardableResult
    func tidy(binder: UUID?, from: ManagerRequest.From, id: UUID? = nil) -> ManagerRequest {
        let name = binder.flatMap { Store.shared.binder($0)?.name }
        return add(ManagerRequest(id: id ?? UUID(), kind: .tidy, text: ManagerRequest.tidyText(binder: name), binder: binder, from: from))
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
        let exited: @MainActor (Int32, URL) -> Void = { [weak self] status, log in self?.ended(id, status: status, log: log) }
        let woken: Result<any ManagerRunning, ManagerWakeFailure>
        if case .localModel(let wake) = agent.wake {
            woken = dispatcher.wakeLocalManager(agent, request: id, client: localModel(wake, file.requests[index].from), pump: localPump, exited: exited)
        } else {
            woken = dispatcher.wakeManager(agent, request: id, exited: exited).map { $0 }
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
        let stoppedByYou = stopping
        stopping = false
        if let request = request(id), !request.isOver {
            if stoppedByYou {
                finish(id, status: .stopped, why: "You stopped it.")
            } else if runningLocal, status != 0 {
                // A local run says why it failed in its own words.
                finish(id, status: .failed, why: AgentDispatcher.lastResult(in: log).text ?? "Its run stopped (exit \(status)).")
            } else if request.reply == nil, status == 0, let said = AgentDispatcher.lastResult(in: log).text?.trimmingCharacters(in: .whitespacesAndNewlines), !said.isEmpty {
                // It finished without calling reply: what it said last is its answer.
                answer(id, said)
            } else {
                let error = AgentDispatcher.lastResult(in: log).text.map { " It said: " + AgentRunReport.trimmed($0, limit: 300) } ?? ""
                finish(id, status: .failed, why: (status == 0 ? "Its run ended without a reply." : "Its run stopped (exit \(status)).") + error)
            }
        }
        startNext()
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
            if let why = board.delete(card) { return "“\(card.title)”: \(why)" }
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
