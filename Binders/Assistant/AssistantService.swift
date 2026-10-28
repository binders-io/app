import Foundation
import Observation
import SwiftData
import BindersKit

/// The Assistant (`BinderAssistant`): each binder's conversation with the language model in Settings → AI, which answers
/// from that binder's meetings, captures, notes and board. Binders reads first (a search for the question, the board, the
/// newest meetings and notes); then the model takes steps, as a local model as the Manager does, but in the app and on the
/// reading tools alone: Binders calls `MCPServer.call` itself, with the binder filled in, opens an item by id only when
/// it's in this binder, and turns down any write. Once it's read enough, it writes the answer freely, in Markdown, shown as
/// it comes. The conversations last until Binders quits.
@MainActor
@Observable
final class AssistantService {
    static let shared = AssistantService()

    struct Message: Identifiable, Equatable {
        enum Role: Equatable { case user, assistant }
        let id = UUID()
        var role: Role
        var text: String
        var sources: [BinderAssistant.Source] = []
        /// It couldn't answer: the text says why.
        var failed = false
    }

    struct Conversation: Equatable {
        var messages: [Message] = []
        /// What it's doing now, while it works: "Searching “pricing”".
        var activity: String?
        /// What it has done for the question it's on, oldest first.
        var steps: [String] = []
        var isRunning = false
    }

    private(set) var conversations: [UUID: Conversation] = [:]
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    /// Self-tests only: the model to ask in place of Settings → AI's (none when it gives none). Nil in the app.
    @ObservationIgnored var localModel: (() -> LLMClient?)?

    func conversation(_ binder: UUID) -> Conversation { conversations[binder] ?? Conversation() }

    func ask(_ question: String, binder: BinderRecord, knowledge: KnowledgeService, settings: AppSettings) {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = binder.id
        guard !question.isEmpty, !conversation(id).isRunning else { return }
        var history: [BinderAssistant.Exchange] = []
        var asked: String?
        for message in conversation(id).messages {
            switch message.role {
            case .user: asked = message.text
            case .assistant:
                if let question = asked, !message.failed { history.append(.init(question: question, answer: message.text)) }
                asked = nil
            }
        }
        update(id) {
            $0.messages.append(Message(role: .user, text: question))
            $0.messages.append(Message(role: .assistant, text: ""))
            $0.isRunning = true
            $0.activity = "Thinking"
            $0.steps = []
        }
        let name = binder.name, purpose = binder.whatGoesHere
        tasks[id] = Task { [weak self] in
            guard let self else { return }
            let result = await self.run(question: question, history: history, binder: id, name: name, purpose: purpose,
                                        knowledge: knowledge, settings: settings)
            self.update(id) {
                guard let last = $0.messages.indices.last else { return }
                if Task.isCancelled {
                    // What it had written of its answer stays, marked as stopped.
                    let partial = $0.messages[last].text
                    $0.messages[last].text = partial.isEmpty ? "Stopped." : partial + " … (stopped)"
                    $0.messages[last].failed = true
                } else {
                    $0.messages[last].text = result.text
                    $0.messages[last].sources = result.sources
                    $0.messages[last].failed = result.failed
                }
                $0.isRunning = false
                $0.activity = nil
            }
            self.tasks[id] = nil
        }
    }

    func stop(_ binder: UUID) {
        tasks[binder]?.cancel()
    }

    /// A new conversation: the one before is forgotten.
    func clear(_ binder: UUID) {
        stop(binder)
        conversations[binder] = nil
    }

    private func update(_ binder: UUID, _ change: (inout Conversation) -> Void) {
        var conversation = conversations[binder] ?? Conversation()
        change(&conversation)
        conversations[binder] = conversation
    }

    private func showing(_ binder: UUID, partial: String) {
        update(binder) {
            guard $0.isRunning, let last = $0.messages.indices.last, $0.messages[last].role == .assistant else { return }
            $0.messages[last].text = partial
            $0.activity = nil
        }
    }

    // MARK: The turns

    private struct Result {
        var text: String
        var sources: [BinderAssistant.Source] = []
        var failed = false
    }

    private func run(question: String, history: [BinderAssistant.Exchange], binder: UUID, name: String, purpose: String,
                     knowledge: KnowledgeService, settings: AppSettings) async -> Result {
        let client: LLMClient? = if let localModel { localModel() } else { settings.makeLLMClient() }
        guard let client else {
            return Result(text: "Choose a language model in Settings → AI, and the Assistant answers from this binder with it.", failed: true)
        }
        let all = MCPServer.tools.filter { BinderAssistant.tools.contains($0.name) && $0.readOnly }
        let full = all.map { tool in
            ManagerLocal.Tool(name: tool.name, description: tool.description, arguments: tool.parameters.map {
                .init(name: $0.name, type: $0.type, description: $0.description, required: $0.required, options: $0.options)
            })
        }
        let shown = full.map(BinderAssistant.shown)
        let names = shown.map(\.name)
        let schema = ReplySchema(name: BinderAssistant.schemaName, bounded: ManagerLocal.schema(tools: names, bounded: true),
                                 portable: ManagerLocal.schema(tools: names, bounded: false), answerTokens: BinderAssistant.stepTokens)
        // What it reads each turn fits the model's context with room for the step, about three characters a token: the
        // instructions with the binder's contents (up to a third of it), then the conversation and the steps.
        let context = await client.contextTokens() ?? 8_192
        let room = (context - BinderAssistant.stepTokens) * 3
        let (items, titles) = overview(binder)
        let bare = BinderAssistant.system(binder: name, purpose: purpose, today: Date().formatted(date: .complete, time: .omitted),
                                          overview: "", tools: shown)
        let system = BinderAssistant.system(binder: name, purpose: purpose, today: Date().formatted(date: .complete, time: .omitted),
                                            overview: BinderAssistant.overview(items, limit: max(600, room / 3 - bare.count)), tools: shown)
        let budget = room - system.count
        guard budget >= BinderAssistant.leastTurn else {
            let needs = (system.count + BinderAssistant.leastTurn) / 3 + BinderAssistant.stepTokens
            return Result(text: "The model reads \(context) tokens at once, and the Assistant needs about \(needs). Give it a larger context (num_ctx in Ollama) or choose a bigger model in Settings → AI.", failed: true)
        }
        let request = BinderAssistant.request(history: history, question: question, limit: budget / 3)
        let log = Self.startLog(question: question, binder: binder)
        var turns: [ManagerLocal.Turn] = []
        // Binders reads first, so the model starts from the binder rather than deciding whether to look. These aren't
        // counted against its own steps.
        for read in BinderAssistant.firstReads(question: question, items: items) {
            if Task.isCancelled { break }
            let doing = BinderAssistant.activity(tool: read.tool, arguments: read.arguments, titles: titles)
            update(binder) {
                $0.activity = doing
                $0.steps.append(doing)
            }
            let answer = await call(read.tool, read.arguments, tools: full, binder: binder, knowledge: knowledge)
            turns.append(.init(tool: read.tool, arguments: read.arguments, answer: answer.text, failed: answer.failed))
            Self.write(log, ["type": "read", "tool": read.tool, "arguments": read.arguments, "failed": answer.failed, "answer": String(answer.text.prefix(2_000))])
        }
        update(binder) { $0.activity = "Thinking" }
        var unreadable = 0
        var calls = 0
        while !Task.isCancelled {
            let last = calls >= BinderAssistant.maxSteps
            let user = BinderAssistant.user(request: request, turns: turns, budget: budget, last: last)
            let said: String
            do {
                said = try await client.stream(system: system, user: user, maxTokens: BinderAssistant.stepTokens, temperature: 0.2,
                                               timeout: 300, schema: schema, stopWhen: { _ in false }, onText: { _ in }).text
            } catch {
                if Task.isCancelled { break }
                return Result(text: "The model didn't answer: \(error.localizedDescription)", sources: BinderAssistant.sources(from: turns), failed: true)
            }
            if Task.isCancelled { break }
            Self.write(log, ["type": "said", "text": String(said.prefix(8_000))])
            switch ManagerLocal.parse(said) {
            case .reply:
                if BinderAssistant.mustReadFirst(turns: turns, binderHasItems: !items.isEmpty) {
                    turns.append(.init(tool: BinderAssistant.readFirstTool, arguments: [:], answer: BinderAssistant.readFirst, failed: true))
                    update(binder) { $0.activity = "Reading the binder first" }
                    continue
                }
                return await answer(request: request, turns: turns, binder: binder, name: name, purpose: purpose, context: context, client: client, log: log)
            case .call(let tool, let arguments):
                // Out of steps: the answer from what it has read.
                if last {
                    return await answer(request: request, turns: turns, binder: binder, name: name, purpose: purpose, context: context, client: client, log: log)
                }
                calls += 1
                let doing = BinderAssistant.activity(tool: tool, arguments: arguments, titles: titles)
                update(binder) {
                    $0.activity = doing
                    $0.steps.append(doing)
                }
                let answer = await call(tool, arguments, tools: full, binder: binder, knowledge: knowledge)
                turns.append(.init(tool: tool, arguments: arguments, answer: answer.text, failed: answer.failed))
                Self.write(log, ["type": "step", "tool": tool, "arguments": arguments, "failed": answer.failed, "answer": String(answer.text.prefix(2_000))])
            case nil:
                unreadable += 1
                if unreadable > 2 {
                    return Result(text: "The model's answers weren't steps Binders could read. A larger model, or one that follows instructions closely, does better here.",
                                  sources: BinderAssistant.sources(from: turns), failed: true)
                }
                turns.append(.init(tool: "(your last answer)", arguments: [:],
                                   answer: "Binders couldn't read it as one step. Answer with one JSON object, as the instructions show.", failed: true))
            }
        }
        return Result(text: "Stopped.", failed: true)
    }

    /// The answer, written freely from what was read (`BinderAssistant.answerSystem`), shown as it comes.
    private func answer(request: String, turns: [ManagerLocal.Turn], binder: UUID, name: String, purpose: String, context: Int,
                        client: LLMClient, log: URL?) async -> Result {
        let sources = BinderAssistant.sources(from: turns)
        update(binder) { $0.activity = "Writing the answer" }
        let system = BinderAssistant.answerSystem(binder: name, purpose: purpose, today: Date().formatted(date: .complete, time: .omitted))
        // It reads what fits the model's context beside these instructions and the answer: about three characters a token.
        let user = BinderAssistant.answerUser(request: request, turns: turns,
                                              budget: max(BinderAssistant.leastTurn, (context - BinderAssistant.answerTokens) * 3 - system.count))
        do {
            let text = try await client.stream(system: system, user: user, maxTokens: BinderAssistant.answerTokens, temperature: 0.2,
                                               timeout: 300, stopWhen: { _ in false }, onText: { [weak self] text in
                guard !Task.isCancelled else { return }
                let shown = OutputGuard.sanitize(text)
                Task { @MainActor in self?.showing(binder, partial: shown) }
            })
            Self.write(log, ["type": "answer", "text": String(text.prefix(8_000))])
            let answer = OutputGuard.sanitize(text)
            guard !answer.isEmpty else { return Result(text: "The model wrote no answer. Try asking again.", sources: sources, failed: true) }
            return Result(text: answer, sources: sources)
        } catch {
            if Task.isCancelled { return Result(text: "Stopped.", sources: sources, failed: true) }
            return Result(text: "The model didn't answer: \(error.localizedDescription)", sources: sources, failed: true)
        }
    }

    // MARK: The log

    /// What the last question's run did, step by step, as JSON lines, in the data folder: the model's own words each turn
    /// and what each tool answered (cut short). Only the last run is kept.
    private static func startLog(question: String, binder: UUID) -> URL? {
        let folder = AppPaths.support.appendingPathComponent("Assistant", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let log = folder.appendingPathComponent("last-run.jsonl")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        write(log, ["type": "question", "binder": binder.uuidString, "text": question, "at": ISO8601DateFormatter().string(from: Date())])
        return log
    }

    private static func write(_ log: URL?, _ line: [String: Any]) {
        guard let log, let data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]),
              let handle = try? FileHandle(forWritingTo: log) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data + Data("\n".utf8))
    }

    /// Calls one of the reading tools for this binder: the binder filled in, an item opened only when it's in this binder,
    /// and anything else turned down.
    private func call(_ name: String, _ arguments: [String: String], tools: [ManagerLocal.Tool], binder: UUID,
                      knowledge: KnowledgeService) async -> (text: String, failed: Bool) {
        guard let tool = tools.first(where: { $0.name == name }) else {
            return ("There's no tool named \(name). Use one of the tools listed.", true)
        }
        if let kind = BinderAssistant.opensItem[name] {
            guard let id = UUID(uuidString: arguments["id"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") else {
                return ("id must be an id from the binder's contents or a tool's answer.", true)
            }
            guard owner(of: id, kind) == binder else { return ("There's nothing with that id in this binder.", true) }
        }
        let typed = tool.typed(BinderAssistant.pinned(name, arguments, binder: binder))
        do {
            let text = try await MCPServer.call(name, typed, knowledge: knowledge, write: { _, _ in
                throw MCPCore.ToolFailure("The Assistant only reads.")
            }, actor: BoardActor(name: "Assistant", kind: .agent), host: "Assistant", doing: false)
            return (text, false)
        } catch let failure as MCPCore.ToolFailure {
            return (failure.message, true)
        } catch {
            return (error.localizedDescription, true)
        }
    }

    private func owner(of id: UUID, _ kind: BinderAssistant.ItemKind) -> UUID? {
        let context = Store.shared.context
        switch kind {
        case .meeting: return Store.shared.binderID(ofMeeting: id)
        case .note: return Store.shared.binderID(ofNote: id)
        case .card: return (try? context.fetch(FetchDescriptor<TaskCard>(predicate: #Predicate { $0.id == id })))?.first?.binderID
        }
    }

    /// The binder's meetings, captures and notes, for the instructions, and their titles by id for what it's doing.
    private func overview(_ binder: UUID) -> ([BinderAssistant.OverviewItem], [String: String]) {
        let context = Store.shared.context
        let meetings = (try? context.fetch(FetchDescriptor<MeetingRecord>(predicate: #Predicate { $0.binderID == binder }))) ?? []
        let notes = (try? context.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.binderID == binder }))) ?? []
        var items = meetings.map { meeting in
            BinderAssistant.OverviewItem(id: meeting.id, kind: meeting.isConversation ? "capture" : "meeting", title: meeting.title,
                                         date: meeting.createdAt, preview: Self.preview(meeting.summary))
        }
        items += notes.map { note in
            BinderAssistant.OverviewItem(id: note.id, kind: "note", title: note.title, date: note.updatedAt,
                                         preview: Self.preview(note.digest.isEmpty ? note.text : note.digest, skippingTitle: note.digest.isEmpty))
        }
        let titles = Dictionary(items.map { ($0.id.uuidString.uppercased(), $0.title) }, uniquingKeysWith: { first, _ in first })
        return (items, titles)
    }

    /// The first lines of Markdown that say something: no headings' marks, bullets or check boxes.
    private static func preview(_ markdown: String, skippingTitle: Bool = false) -> String {
        var lines = markdown.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if skippingTitle, lines.first?.hasPrefix("# ") == true { lines.removeFirst() }
        return lines.prefix(3).map { line in
            var line = line
            for mark in ["#### ", "### ", "## ", "# ", "- [ ] ", "- [x] ", "- ", "* "] where line.hasPrefix(mark) {
                line.removeFirst(mark.count)
                break
            }
            return line
        }.joined(separator: " ")
    }
}
