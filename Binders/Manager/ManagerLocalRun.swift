import Foundation
import BindersKit

/// A run of the Manager that `ManagerService` can stop: Claude Code's process, or a local model's run.
@MainActor
protocol ManagerRunning: AnyObject {
    var isRunning: Bool { get }
    func terminate()
}

extension Process: ManagerRunning {}

/// The Manager on a local model, for one request (lane MG2): Binders starts its own `Binders --mcp` with the same
/// confinement a Claude Code Manager's has (the Manager's tools for this request, as this agent), shows the model the
/// request, the tools and its steps so far, and calls the one tool it picks each turn (`ManagerLocal`). The writes go
/// through the inbox to the app, as Claude Code's do, so the same refusals and Undo hold. Its log is JSON lines, the last
/// a `result` holding the reply, as Claude Code's stream-json ends, so `ManagerService` reads both the same way.
@MainActor
final class ManagerLocalRun: ManagerRunning {
    private let process = Process()
    private let input = Pipe(), output = Pipe()
    private let heard = ManagerLocalOutput()
    private var task: Task<Void, Never>?
    private var next = 1
    private var stopped = false
    private let log: URL
    private let request: UUID
    private let client: LLMClient
    /// Self-tests only: does what the child hands the app through the inbox while a call waits, as the app does when it's
    /// running. Nil in the app.
    private let pump: (@MainActor () async -> Void)?
    private(set) var isRunning = false

    /// Starts the child and the turns. `exited` hears 0 when the model replied, 1 when it failed (the log's result says
    /// why), 143 when it was stopped.
    init(request: UUID, agentName: String, client: LLMClient, executable: String, log: URL, limit: TimeInterval,
         pump: (@MainActor () async -> Void)? = nil, exited: @escaping @MainActor (Int32, URL) -> Void) throws {
        self.request = request
        self.client = client
        self.log = log
        self.pump = pump
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["--mcp"]
        var environment = ProcessInfo.processInfo.environment
        for key in ["BINDERS_AGENT", "BINDERS_TOOLS", "BINDERS_CARD", "BINDERS_RUN", "BINDERS_MANAGER"] { environment[key] = nil }
        // As `ManagerLaunch` gives Claude Code's server: BINDERS_CARD is the request's id, which no card has.
        environment.merge(["BINDERS_AGENT": agentName, "BINDERS_TOOLS": "board", "BINDERS_RUN": "1",
                           "BINDERS_CARD": request.uuidString, "BINDERS_MANAGER": request.uuidString]) { _, new in new }
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let heard = heard
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            // At its end the handle reads empty again and again: stop listening.
            if data.isEmpty { handle.readabilityHandler = nil } else { heard.append(data) }
        }
        signal(SIGPIPE, SIG_IGN)
        FileManager.default.createFile(atPath: log.path, contents: nil)
        try process.run()
        isRunning = true
        let deadline = Date().addingTimeInterval(limit)
        task = Task { [weak self] in
            guard let self else { return }
            let status = await self.turns(until: deadline)
            self.end()
            exited(self.stopped ? 143 : status, log)
        }
    }

    func terminate() {
        guard isRunning else { return }
        stopped = true
        task?.cancel()
        end()
    }

    private func end() {
        guard isRunning else { return }
        isRunning = false
        output.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }

    // MARK: The turns

    private func turns(until deadline: Date) async -> Int32 {
        guard await call("initialize", ["protocolVersion": "2025-06-18", "capabilities": [String: Any](),
                                        "clientInfo": ["name": "binders-manager", "title": "Binders Manager", "version": "1"]]) != nil else {
            return finish(failing: "Binders' tools didn't start.")
        }
        send(notification: "notifications/initialized")
        guard let listed = await call("tools/list", [:])?["tools"] as? [[String: Any]] else {
            return finish(failing: "Binders' tools didn't say what they are.")
        }
        // get_request is asked here, once, and a reply is the step's own: neither is offered as a tool.
        let tools = listed.compactMap(ManagerLocal.Tool.init(listed:)).filter { !["get_request", "reply"].contains($0.name) }
        guard let asked = await tool("get_request", [:]), !asked.failed else {
            return finish(failing: "Binders couldn't read the request.")
        }
        let system = ManagerLocal.system(tools: tools)
        let names = tools.map(\.name)
        let schema = ReplySchema(name: ManagerLocal.schemaName, bounded: ManagerLocal.schema(tools: names, bounded: true),
                                 portable: ManagerLocal.schema(tools: names, bounded: false), answerTokens: ManagerLocal.stepTokens)
        // What it reads each turn fits its context with room for the step: about three characters a token. A model that
        // can't hold the instructions and one step isn't asked: a server would cut the instructions off first.
        let context = await client.contextTokens() ?? 8_192
        let budget = (context - ManagerLocal.stepTokens) * 3 - system.count
        guard budget >= ManagerLocal.leastTurn else {
            let needs = (system.count + ManagerLocal.leastTurn) / 3 + ManagerLocal.stepTokens
            return finish(failing: "The model reads \(context) tokens at once, and the Manager needs about \(needs). Give it a larger context (num_ctx in Ollama) or choose a bigger model.")
        }
        var turns: [ManagerLocal.Turn] = []
        var unreadable = 0
        var calls = 0
        while !Task.isCancelled {
            if Date() > deadline { return finish(failing: "It ran past its time limit.") }
            if !process.isRunning { return finish(failing: "Binders' tools stopped.") }
            let last = calls >= ManagerLocal.maxSteps
            let user = ManagerLocal.user(request: asked.text, turns: turns, budget: budget, last: last)
            let said: String
            do {
                said = try await client.stream(system: system, user: user, maxTokens: ManagerLocal.stepTokens, temperature: 0.2,
                                               timeout: 600, schema: schema, stopWhen: { _ in false }, onText: { _ in }).text
            } catch {
                if Task.isCancelled { return 143 }
                return finish(failing: "The model didn't answer: \(error.localizedDescription)")
            }
            if Task.isCancelled { return 143 }
            switch ManagerLocal.parse(said) {
            case .reply(let text):
                return finish(replying: text)
            case .call(let name, let arguments):
                // reply called as a tool is a reply.
                if name == "reply", let text = arguments["text"]?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                    return finish(replying: text)
                }
                if last { return finish(failing: "It didn't reply within \(ManagerLocal.maxSteps) steps.") }
                calls += 1
                guard let tool = tools.first(where: { $0.name == name }) else {
                    turns.append(.init(tool: name, arguments: arguments, answer: "There's no tool named \(name). Use one of the tools listed.", failed: true))
                    continue
                }
                guard let answer = await self.tool(name, tool.typed(arguments)) else {
                    if Task.isCancelled { return 143 }
                    return finish(failing: process.isRunning ? "Binders' tools didn't answer \(name) in time." : "Binders' tools stopped.")
                }
                turns.append(.init(tool: name, arguments: arguments, answer: answer.text, failed: answer.failed))
                write(["type": "step", "tool": name, "arguments": arguments, "failed": answer.failed,
                       "answer": String(answer.text.prefix(2_000))])
            case nil:
                unreadable += 1
                write(["type": "unreadable", "text": String(said.prefix(2_000))])
                if unreadable > 2 { return finish(failing: "The model's answers weren't steps Binders could read.") }
                turns.append(.init(tool: "(your last answer)", arguments: [:],
                                   answer: "Binders couldn't read it as one step. Answer with one JSON object, as the instructions show.", failed: true))
            }
        }
        return 143
    }

    private func finish(replying text: String) -> Int32 {
        write(["type": "result", "subtype": "success", "result": text])
        return 0
    }

    private func finish(failing why: String) -> Int32 {
        write(["type": "result", "subtype": "error", "result": why])
        return 1
    }

    private func write(_ line: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]),
              let handle = try? FileHandle(forWritingTo: log) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data + Data("\n".utf8))
    }

    // MARK: Talking to the child

    /// A tool's text and whether it failed; nil when the child didn't answer.
    private func tool(_ name: String, _ arguments: [String: Any]) async -> (text: String, failed: Bool)? {
        guard let result = await call("tools/call", ["name": name, "arguments": arguments]) else { return nil }
        let text = ((result["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String } ?? []).joined(separator: "\n")
        return (text, result["isError"] as? Bool == true)
    }

    /// The result of a request, or nil when it failed or nothing came within two minutes.
    private func call(_ method: String, _ params: [String: Any]) async -> [String: Any]? {
        let id = next
        next += 1
        send(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        for _ in 0..<1_200 {
            if Task.isCancelled || !process.isRunning && heard.isEmpty { return nil }
            for line in heard.take() {
                guard let message = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      message["id"] as? Int == id else { continue }
                return message["result"] as? [String: Any]
            }
            if let pump { await pump() }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }

    private func send(notification method: String) {
        send(["jsonrpc": "2.0", "method": method])
    }

    private func send(_ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        try? input.fileHandleForWriting.write(contentsOf: data + Data("\n".utf8))
    }
}

/// What the child wrote, gathered on whatever queue it arrives on, and handed out a whole line at a time.
private final class ManagerLocalOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.withLock { data.append(chunk) }
    }

    var isEmpty: Bool { lock.withLock { data.isEmpty } }

    /// The whole lines so far, taken out.
    func take() -> [String] {
        lock.withLock {
            guard let last = data.lastIndex(of: UInt8(ascii: "\n")) else { return [] }
            let lines = String(decoding: data[data.startIndex...last], as: UTF8.self).split(separator: "\n").map(String.init)
            data.removeSubrange(data.startIndex...last)
            return lines
        }
    }
}
