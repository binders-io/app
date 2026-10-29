import Foundation
import BindersKit

/// Your chats with your agents (lane AC1), kept in agent-chats.json: each a conversation of its own, never a card.
/// Claude Code answers in a session Binders starts for the chat (`AgentDispatcher.wakeChat`) and carries on with each
/// message; while it works, what it has written so far shows (`live`). An agent that checks the board itself reads your
/// messages and answers with Binders' tools (`list_messages`, `reply_message`). What changes reaches the iPhone as "chats".
@MainActor
@Observable
final class AgentChatService {
    static let fileName = "agent-chats.json"
    /// How many chats are kept, the latest, and how many messages each keeps.
    static let keptChats = 200
    static let keptMessages = 400

    struct File: Codable, Equatable {
        var chats: [AgentChat] = []
    }

    private(set) var file = File()
    /// What each chat's run has written so far, while it works.
    private(set) var live: [UUID: String] = [:]
    @ObservationIgnored weak var controller: DictationController?
    @ObservationIgnored let registry: AgentRegistry
    @ObservationIgnored private var processes: [UUID: Process] = [:]
    @ObservationIgnored private var runs: [UUID: (strict: Bool, resumed: Bool, log: URL)] = [:]
    /// Each run that takes your words while it works, by chat, and how many replies it has given so far.
    @ObservationIgnored private var inputs: [UUID: AgentLiveInput] = [:]
    @ObservationIgnored private var repliedLive: [UUID: Int] = [:]
    @ObservationIgnored private var stopping: Set<UUID> = []
    @ObservationIgnored private var restartedOnce: Set<UUID> = []
    @ObservationIgnored private var timer: Timer?

    init(controller: DictationController? = nil, registry: AgentRegistry = .shared) {
        self.controller = controller
        self.registry = registry
        file = Self.read()
        // A run that was going when Binders quit is over; your words wait to go again.
        var changed = false
        for index in file.chats.indices where file.chats[index].status == .running {
            file.chats[index].status = .idle
            file.chats[index].why = "Binders quit before it answered. Send again to carry on."
            for message in file.chats[index].messages.indices where file.chats[index].messages[message].from == .you {
                file.chats[index].messages[message].delivered = true
            }
            changed = true
        }
        if changed { save() }
    }

    static var url: URL { AppPaths.support.appendingPathComponent(fileName) }

    /// The file as it is, for `Binders --mcp`, which reads it to give an agent its messages.
    static func read() -> File {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder.iso.decode(File.self, from: $0) } ?? File()
    }

    private func save() {
        file.chats.sort { $0.updatedAt > $1.updatedAt }
        if file.chats.count > Self.keptChats { file.chats = Array(file.chats.prefix(Self.keptChats)) }
        for index in file.chats.indices where file.chats[index].messages.count > Self.keptMessages {
            file.chats[index].messages = Array(file.chats[index].messages.suffix(Self.keptMessages))
        }
        if let data = try? JSONEncoder.iso.encode(file) { try? data.write(to: Self.url, options: .atomic) }
        controller?.link.changed(["chats"])
    }

    // MARK: Reading

    func chat(_ id: UUID) -> AgentChat? { file.chats.first { $0.id == id } }

    /// An agent's chats, the latest first.
    func chats(with name: String) -> [AgentChat] {
        file.chats.filter { Self.same($0.agent, name) }
    }

    /// The same agent's name: exactly, but for case and spaces at the ends. Never a name that only starts the same.
    nonisolated static func same(_ one: String, _ other: String) -> Bool {
        let one = one.trimmingCharacters(in: .whitespaces).lowercased()
        return !one.isEmpty && one == other.trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// Whether the chat is with an agent that checks the board itself, by that name: the only chats its tools reach.
    private func boardChat(_ chat: AgentChat, by name: String) -> Bool {
        guard Self.same(chat.agent, name), let agent = agent(named: chat.agent) else { return false }
        return agent.wake == .board
    }

    /// The agent you set up by that name, if chat reaches it.
    func agent(named name: String) -> AgentProfile? {
        registry.agents.first { AgentRegistry.isAgent($0, named: name) && AgentChatReach.chats($0.wake.kind) }
    }

    /// Why a message to it wouldn't go now, or nil.
    func problem(with agent: AgentProfile) -> String? {
        if registry.paused { return "Agents are paused in Settings → Agents." }
        if !agent.isEnabled { return "\(agent.name) is off in Settings → Agents." }
        if let why = registry.held[agent.id] { return why }
        if agent.wake != .board, !registry.wakeable(agent) { return "\(agent.name) can't be started as it is. Look at it in Settings → Agents." }
        return nil
    }

    // MARK: Writing

    struct Failure: Error, Equatable {
        let why: String
        init(_ why: String) { self.why = why }
    }

    /// Your message, to the agent named `name`: in `chat` (a new chat when nil). `id`, the iPhone's own for it, makes one sent
    /// twice a single message. `via` is "mac" or "iphone".
    @discardableResult
    func send(_ raw: String, to name: String, chat chatID: UUID? = nil, via: String, id: UUID? = nil) -> Result<AgentChat, Failure> {
        let text = String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(8_000))
        guard !text.isEmpty else { return .failure(Failure("Write something to send.")) }
        if let id, let earlier = file.chats.first(where: { $0.messages.contains { $0.id == id } }) { return .success(earlier) }
        guard let agent = agent(named: name) else {
            return .failure(Failure("\(name) can't chat: only Claude Code and agents that check the board themselves can. Give it a card instead."))
        }
        if let problem = problem(with: agent) { return .failure(Failure(problem)) }
        let index: Int
        if let chatID {
            guard let found = file.chats.firstIndex(where: { $0.id == chatID }) else {
                return .failure(Failure("That chat isn't on this Mac any more. Start a new one."))
            }
            guard Self.same(agent.name, file.chats[found].agent) else { return .failure(Failure("That chat is with \(file.chats[found].agent).")) }
            index = found
        } else {
            file.chats.insert(AgentChat(agent: agent.name, title: AgentChat.title(from: text)), at: 0)
            index = 0
        }
        let message = AgentChatMessage(id: id ?? UUID(), from: .you, text: text, via: via)
        file.chats[index].messages.append(message)
        file.chats[index].updatedAt = Date()
        file.chats[index].why = nil
        // Its run takes your words while it works: straight into it.
        if let input = inputs[file.chats[index].id], input.send(text),
           let at = file.chats[index].messages.firstIndex(where: { $0.id == message.id }) {
            file.chats[index].messages[at].delivered = true
        }
        let chat = file.chats[index]
        save()
        start(chat.id)
        return .success(self.chat(chat.id) ?? chat)
    }

    /// Whether the chat's run takes your words now.
    func takesLive(_ id: UUID) -> Bool { inputs[id]?.isOpen == true }

    /// The logs of the chat's runs, oldest first, in Binders' logs folder.
    func logs(of id: UUID) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: AgentPlaces.logs.path)) ?? []
        return AgentChatLaunch.logs(names, chat: id).map { AgentPlaces.logs.appendingPathComponent($0) }
    }

    /// Stops the chat's run, if it's going.
    func stop(_ id: UUID) {
        guard let process = processes[id], process.isRunning else { return }
        stopping.insert(id)
        process.terminate()
    }

    /// Starts the agent on what waits in the chat, unless it's at work on it already; what you write meanwhile goes when it
    /// stops.
    private func start(_ id: UUID) {
        guard processes[id] == nil, let index = file.chats.firstIndex(where: { $0.id == id }), !file.chats[index].unsent.isEmpty else { return }
        guard let agent = agent(named: file.chats[index].agent) else {
            return fail(id, "\(file.chats[index].agent) isn't one Binders can chat with now. Look at it in Settings → Agents.")
        }
        if let problem = problem(with: agent) { return fail(id, problem) }
        switch agent.wake {
        case .board:
            // It reads them with its tools when it next checks.
            file.chats[index].status = .waiting
            save()
        case .claudeCode(let wake):
            guard let dispatcher = controller?.agents else { return fail(id, "Binders isn't ready to start agents yet. Send again in a moment.") }
            // Its folder gone (a worktree cleaned up): a new session, with the chat so far, where a new one is made.
            if let directory = file.chats[index].directory, !FileManager.default.fileExists(atPath: directory) {
                file.chats[index].directory = nil
                file.chats[index].session = nil
            }
            let chat = file.chats[index]
            let texts = chat.unsent.map(\.text)
            // On the chat's session where its first run left it; a new one when there's none (or it was lost).
            let resume = chat.session != nil && chat.directory != nil
            let session = resume ? chat.session ?? UUID() : UUID()
            let earlier = chat.messages.filter { !chat.unsent.contains($0) }
            let prompt = resume ? AgentChatPrompt.next(texts)
                : (earlier.isEmpty ? AgentChatPrompt.first(agent: agent.name, text: AgentChatPrompt.next(texts), draftsFirst: agent.draftsFirst)
                   : AgentChatPrompt.again(agent: agent.name, earlier: earlier, text: AgentChatPrompt.next(texts), draftsFirst: agent.draftsFirst))
            let strict = AgentDispatcher.asksOnlyBinders
            switch dispatcher.wakeChat(agent, wake: wake, chat: chat, session: session, resume: resume, prompt: prompt, strict: strict,
                                       exited: { [weak self] status, log in self?.ended(id, status: status, log: log) }) {
            case .success(let (process, log, input)):
                processes[id] = process
                runs[id] = (strict, resume, log)
                if let input {
                    inputs[id] = input
                    input.answer = { [weak self] answer in self?.answered(id, answer) }
                }
                file.chats[index].session = session
                file.chats[index].status = .running
                for message in file.chats[index].messages.indices where file.chats[index].messages[message].from == .you {
                    file.chats[index].messages[message].delivered = true
                }
                save()
                watch()
            case .failure(let failure):
                fail(id, failure.why)
            }
        default:
            fail(id, "\(agent.name) can't chat. Give it a card instead.")
        }
    }

    /// A turn of a run that takes your words ended: its reply goes in now, as it gives it, rather than when the run ends.
    private func answered(_ id: UUID, _ answer: ClaudeCodeLiveInput.Answer) {
        guard let text = answer.text, !answer.error, let index = file.chats.firstIndex(where: { $0.id == id }) else { return }
        file.chats[index].messages.append(AgentChatMessage(from: .agent, text: text))
        file.chats[index].why = nil
        file.chats[index].updatedAt = Date()
        repliedLive[id, default: 0] += 1
        live[id] = nil
        save()
    }

    private func fail(_ id: UUID, _ why: String) {
        guard let index = file.chats.firstIndex(where: { $0.id == id }) else { return }
        file.chats[index].status = .idle
        file.chats[index].why = why
        for message in file.chats[index].messages.indices where file.chats[index].messages[message].from == .you {
            file.chats[index].messages[message].delivered = true
        }
        save()
    }

    /// A run ended: its last word is the agent's reply, or the chat says why there's none. Your words written meanwhile go
    /// next. A session Claude Code no longer has starts again, once, as a new one with the chat so far.
    private func ended(_ id: UUID, status: Int32, log: URL) {
        processes[id] = nil
        let run = runs.removeValue(forKey: id)
        live[id] = nil
        let stoppedByYou = stopping.remove(id) != nil
        inputs.removeValue(forKey: id)?.ended()
        let replied = repliedLive.removeValue(forKey: id) ?? 0
        guard let index = file.chats.firstIndex(where: { $0.id == id }) else { return }
        let output = AgentDispatcher.startAndEnd(of: log)
        let (reply, error) = AgentChatStream.reply(in: output)
        file.chats[index].status = .idle
        if replied > 0 {
            // Its replies went in as it gave them.
            file.chats[index].why = stoppedByYou ? "You stopped it." : nil
            restartedOnce.remove(id)
        } else if let reply, !error {
            file.chats[index].messages.append(AgentChatMessage(from: .agent, text: reply))
            file.chats[index].why = nil
            restartedOnce.remove(id)
        } else if stoppedByYou {
            file.chats[index].why = "You stopped it."
        } else if !restartedOnce.contains(id), let run,
                  (run.resumed && AgentChatStream.sessionGone(in: output))
                    || (run.strict && ClaudeCodeManaged.finding(in: output) == .refusedOnlyBinders) {
            // Once: a lost session starts again as a new one, and a managed Claude Code without the limit it refused.
            if run.strict, ClaudeCodeManaged.finding(in: output) == .refusedOnlyBinders {
                AppDefaults.store.set(Date(), forKey: AgentDispatcher.refusedOnlyBindersKey)
            }
            restartedOnce.insert(id)
            // Your words since its last reply go again.
            let lastReply = file.chats[index].messages.lastIndex { $0.from == .agent } ?? -1
            for message in file.chats[index].messages.indices where message > lastReply {
                file.chats[index].messages[message].delivered = false
            }
            file.chats[index].session = nil
            save()
            return start(id)
        } else if let reply {
            file.chats[index].why = AgentRunReport.trimmed(reply, limit: 300)
            restartedOnce.remove(id)
        } else {
            file.chats[index].why = status == 0 ? "It ended without a reply." : "Its run stopped (exit \(status))."
            restartedOnce.remove(id)
        }
        // Where its session is, for the next message: the folder Claude Code says it started in (the chat's worktree,
        // wherever the repository's top is), else where Binders asked it to make it.
        if file.chats[index].directory == nil, let agent = agent(named: file.chats[index].agent), case .claudeCode(let wake) = agent.wake {
            let repository = (wake.repository as NSString).expandingTildeInPath
            let asked = wake.worksInFolder ? repository : AgentChatLaunch.worktree(repository: repository, chat: id)
            let place = AgentChatStream.folder(in: output) ?? asked
            var isFolder: ObjCBool = false
            if FileManager.default.fileExists(atPath: place, isDirectory: &isFolder), isFolder.boolValue { file.chats[index].directory = place }
        }
        file.chats[index].updatedAt = Date()
        save()
        start(id)
    }

    /// While a run goes on, what it has written so far, every second.
    private func watch() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.readLive() }
        }
    }

    private func readLive() {
        guard !runs.isEmpty else {
            timer?.invalidate()
            timer = nil
            return
        }
        var changed = false
        for (id, run) in runs {
            let said = AgentChatStream.said(in: CLIRuns.tail(run.log, bytes: 256 * 1024) ?? "")
            if !said.isEmpty, live[id] != said {
                live[id] = said
                changed = true
            }
        }
        if changed { controller?.link.changed(["chats"]) }
    }

    // MARK: An agent that checks the board itself

    /// It has read these (`list_messages`, through the inbox): they're delivered.
    func read(_ ids: Set<UUID>, by name: String) -> String? {
        var any = false
        for index in file.chats.indices where boardChat(file.chats[index], by: name) {
            for message in file.chats[index].messages.indices where ids.contains(file.chats[index].messages[message].id) {
                file.chats[index].messages[message].delivered = true
                any = true
            }
        }
        if any { save() }
        return nil
    }

    /// Its reply in a chat (`reply_message`): only in one of its own chats.
    func reply(_ raw: String, chat id: UUID, by name: String) -> String? {
        let text = String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(8_000))
        guard !text.isEmpty else { return "text is required" }
        guard let index = file.chats.firstIndex(where: { $0.id == id }) else { return "No chat with that id. list_messages shows yours." }
        guard boardChat(file.chats[index], by: name) else { return "That chat isn't one of yours." }
        file.chats[index].messages.append(AgentChatMessage(from: .agent, text: text))
        // What you wrote that it hasn't read yet still waits for it.
        file.chats[index].status = file.chats[index].unsent.isEmpty ? .idle : .waiting
        file.chats[index].why = nil
        file.chats[index].updatedAt = Date()
        save()
        return nil
    }

    /// The messages waiting for an agent, by chat, from the file as it is: for `list_messages` in `Binders --mcp`.
    nonisolated static func waiting(for name: String, in file: File) -> [[String: Any]] {
        // Only chats that wait for an agent that checks the board itself: never a Claude Code chat Binders runs.
        file.chats.filter { same(name, $0.agent) && $0.status == .waiting }.compactMap { chat in
            let unread = chat.unsent
            guard !unread.isEmpty else { return nil }
            // What came before, so it knows what it's answering: the last few messages.
            let before = chat.messages.filter { message in !unread.contains { $0.id == message.id } }.suffix(6)
            return ["chat": chat.id.uuidString, "title": chat.title,
                    "earlier": before.map { ["from": $0.from == .you ? "user" : "you", "text": String($0.text.prefix(2_000))] },
                    "messages": unread.map { ["id": $0.id.uuidString, "text": $0.text, "at": $0.at.formatted(.iso8601)] }]
        }
    }
}
