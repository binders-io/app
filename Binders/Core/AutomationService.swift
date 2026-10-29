import AppKit
import CryptoKit
import Foundation
import BindersKit

/// The user's rules, and running them. Rules live in automations.json in the data folder: readable, versionable, shareable,
/// and with no secrets in them: a web hook's token is in the Keychain, and goes only to the address it was saved with.
@MainActor
@Observable
final class AutomationService {
    static let shared = AutomationService()

    struct Outcome: Equatable {
        var at: Date
        var ok: Bool
        var message: String
    }

    enum Failure: LocalizedError {
        case badURL(String)
        case shortcut(String)
        case script(Int32, String)
        case http(Int)
        /// A link that would put a value where it could change what opens: why, from AutomationTemplate.urlProblem.
        case unsafeLink(String)
        /// A web hook whose address isn't the one its token was saved with, as when automations.json was changed outside.
        case addressChanged

        var errorDescription: String? {
            switch self {
            case .badURL(let url): "Not a valid URL: \(url)"
            case .shortcut(let detail): "Shortcut failed: \(detail)"
            case .script(let status, let detail): "Script exited with \(status)\(detail.isEmpty ? "" : ": \(detail)")"
            case .http(let status): "The server answered \(status)"
            case .unsafeLink(let reason): "Not opened. \(reason) Change the rule in Settings → Automations."
            case .addressChanged: "Not sent: its address isn't the one you saved it with. Save the rule again in Settings → Automations."
            }
        }
    }

    private(set) var rules: [AutomationRule] = []
    private(set) var outcomes: [UUID: Outcome] = [:]
    /// The web hook rules that have a token in the Keychain, for the editor to say so without reading it.
    private(set) var withToken: Set<UUID> = []
    /// Shows a line in the Flow bar: text and symbol.
    @ObservationIgnored var notify: ((String, String) -> Void)?
    /// Opens a rule's link; the self-test watches instead.
    @ObservationIgnored var open: (URL) -> Void = { NSWorkspace.shared.open($0) }
    @ObservationIgnored private let url: URL

    /// A payload to try a rule with from the editor.
    static let sample = AutomationPayload(event: "test", text: "call Sam tomorrow at 3 pm", title: "call Sam", when: "tomorrow at 3 pm",
                                          date: AutomationPayload.iso(Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()),
                                          app: "Binders", binder: "Work", summary: "A sample summary of a meeting.", link: "binders://open?section=home")

    init(url: URL = AppPaths.support.appendingPathComponent("automations.json")) {
        self.url = url
        load()
    }

    func load() {
        rules = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([AutomationRule].self, from: $0) } ?? []
        withToken = Set(rules.filter { rule in
            guard case .webhook = rule.action else { return false }
            return token(for: rule.id) != nil
        }.map(\.id))
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try encoder.encode(rules).write(to: url, options: .atomic)
        } catch {
            Log.app.error("Couldn't save automations: \(error.localizedDescription)")
        }
    }

    /// Adds or replaces a rule as saved in Settings. A web hook's token, when given, goes to the Keychain ("" removes it),
    /// never to automations.json, and with it the address it's for, as the rule has it now; a rule that no longer calls a
    /// web hook keeps none.
    func upsert(_ rule: AutomationRule, token: String? = nil) {
        if let index = rules.firstIndex(where: { $0.id == rule.id }) { rules[index] = rule } else { rules.append(rule) }
        if case .webhook(let address, _) = rule.action {
            if let token {
                Keychain.write(token.trimmed, for: Self.key("automation-token", rule.id))
                if token.trimmed.isEmpty { withToken.remove(rule.id) } else { withToken.insert(rule.id) }
            }
            Keychain.write(withToken.contains(rule.id) ? Self.fingerprint(address) : "", for: Self.key("automation-token-address", rule.id))
        } else if withToken.contains(rule.id) || self.token(for: rule.id) != nil {
            Keychain.write("", for: Self.key("automation-token", rule.id))
            Keychain.write("", for: Self.key("automation-token-address", rule.id))
            withToken.remove(rule.id)
        }
        save()
    }

    func remove(_ id: UUID) {
        rules.removeAll { $0.id == id }
        outcomes[id] = nil
        Keychain.write("", for: Self.key("automation-token", id))
        Keychain.write("", for: Self.key("automation-token-address", id))
        withToken.remove(id)
        save()
    }

    func setEnabled(_ id: UUID, _ enabled: Bool) {
        guard let index = rules.firstIndex(where: { $0.id == id }) else { return }
        rules[index].isEnabled = enabled
        save()
    }

    // MARK: Web hook tokens

    /// A web hook rule's token, from the Keychain, or nil when it has none.
    func token(for id: UUID) -> String? {
        Keychain.read(Self.key("automation-token", id)).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The token a web hook rule sends: the one typed in the editor (`typed`, "" for none), or else the one in the Keychain,
    /// but only to the address it was saved with in Settings. Anything that can write automations.json could point the rule
    /// somewhere else; then nothing is sent until you save the rule again.
    private func bearer(for rule: AutomationRule, typed: String?) throws -> String? {
        guard case .webhook(let address, _) = rule.action else { return nil }
        if let typed { return typed.trimmed.isEmpty ? nil : typed.trimmed }
        guard let saved = token(for: rule.id) else { return nil }
        guard Keychain.read(Self.key("automation-token-address", rule.id)) == Self.fingerprint(address) else { throw Failure.addressChanged }
        return saved
    }

    /// A web hook's address, as its token is kept bound to it.
    private static func fingerprint(_ address: String) -> String {
        SHA256.hash(data: Data(address.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Keychain items, kept apart in a throwaway folder so the self-tests never touch yours (as AgentRegistry keeps them).
    private static func key(_ name: String, _ id: UUID) -> String {
        (AppPaths.isDemo ? "selftest-" : "") + name + "-\(id.uuidString)"
    }

    // MARK: Triggers

    /// The rule a Command Mode instruction is for, with what follows its phrase. The longest phrase wins.
    func match(_ instruction: String) -> (rule: AutomationRule, payload: AutomationPayload)? {
        var best: (rule: AutomationRule, rest: String, length: Int)?
        for rule in rules where rule.isEnabled {
            guard case .phrase(let phrase) = rule.trigger, let rest = AutomationTemplate.remainder(of: instruction, afterPhrase: phrase),
                  phrase.count > (best?.length ?? -1) else { continue }
            best = (rule, rest, phrase.count)
        }
        guard let best else { return nil }
        return (best.rule, AutomationPayload.spoken(best.rest))
    }

    /// Runs every enabled rule for the event, without waiting. A to-do from `origin` runs the rules that take to-dos from
    /// there: all of them for one you made, and for one said to yourself, an agent's or a link's only the rules that also
    /// take those (AutomationRule.runs(for:)). Only failures are shown.
    func fire(_ event: AutomationEvent, payload: AutomationPayload, origin: TodoOrigin? = nil) {
        var payload = payload
        payload.event = event.rawValue
        if let origin { payload.todoOrigin = origin.rawValue }
        for rule in rules where rule.isEnabled && rule.runs(for: origin) {
            guard case .event(let name) = rule.trigger, name == event else { continue }
            Task { await self.run(rule, payload: payload, quietly: true) }
        }
    }

    /// Runs one rule; what happened is kept for the editor and shown in the Flow bar. `token` is a web hook's token as
    /// typed in the editor ("" for none); nil uses the one in the Keychain, for the address it was saved with.
    @discardableResult
    func run(_ rule: AutomationRule, payload: AutomationPayload, quietly: Bool = false, token: String? = nil) async -> Outcome {
        let outcome: Outcome
        do {
            outcome = Outcome(at: Date(), ok: true, message: try await perform(rule.action, payload: payload, token: try bearer(for: rule, typed: token)))
        } catch {
            outcome = Outcome(at: Date(), ok: false, message: error.localizedDescription)
        }
        outcomes[rule.id] = outcome
        if !outcome.ok {
            Log.app.error("Automation “\(rule.name, privacy: .public)” failed: \(outcome.message, privacy: .public)")
            notify?("\(rule.name): \(outcome.message)", "bolt.trianglebadge.exclamationmark")
        } else if !quietly {
            notify?("\(rule.name): \(outcome.message)", "bolt")
        }
        return outcome
    }

    // MARK: Actions

    private func perform(_ action: AutomationRule.Action, payload: AutomationPayload, token: String?) async throws -> String {
        switch action {
        case .openURL(let template):
            // Values go only into the query, so what a to-do or binder says can't change what opens; a rule saved before
            // the editor checked that is refused here.
            if let problem = AutomationTemplate.urlProblem(template) { throw Failure.unsafeLink(problem) }
            let rendered = AutomationTemplate.render(template, payload: payload, encode: AutomationTemplate.percentEncoded)
            guard let url = URL(string: rendered), url.scheme != nil else { throw Failure.badURL(rendered) }
            open(url)
            return "opened \(url.scheme ?? "")://\(url.host ?? url.path)"

        case .shortcut(let name, let input):
            let text = AutomationTemplate.render(input.trimmed.isEmpty ? "{text}" : input, payload: payload)
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("binders-shortcut-\(UUID().uuidString).txt")
            try text.write(to: file, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: file) }
            let result = try await Self.runProcess("/usr/bin/shortcuts", ["run", name, "--input-path", file.path], stdin: nil, environment: nil, timeout: 120)
            guard result.status == 0 else { throw Failure.shortcut(result.stderr.trimmed.isEmpty ? "exit \(result.status)" : result.stderr.trimmed) }
            return "ran “\(name)”"

        case .script(let command):
            // Never an agent with its permission checks off, whoever wrote the rule into automations.json.
            guard AgentCommands.isAllowed(command) else {
                throw Failure.script(-1, "Binders never runs a command with an agent's permission checks off")
            }
            var environment = ProcessInfo.processInfo.environment
            for (key, value) in payload.fields { environment["BINDERS_" + key.uppercased()] = value }
            let result = try await Self.runProcess("/bin/zsh", ["-lc", command], stdin: payload.text, environment: environment, timeout: 120)
            guard result.status == 0 else { throw Failure.script(result.status, String(result.stderr.trimmed.prefix(200))) }
            let output = result.stdout.trimmed
            return output.isEmpty ? "script finished" : String(output.prefix(80))

        case .webhook(let address, let body):
            guard let url = URL(string: address), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
                throw Failure.badURL(address)
            }
            var request = URLRequest(url: url, timeoutInterval: 30)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            request.httpBody = body.trimmed.isEmpty
                ? try JSONSerialization.data(withJSONObject: payload.fields, options: [.sortedKeys])
                : Data(AutomationTemplate.render(body, payload: payload, encode: AutomationTemplate.jsonEscaped).utf8)
            let (_, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else { throw Failure.http(status) }
            return "posted to \(url.host ?? address)"
        }
    }

    /// Runs a process off the main thread and waits for it; the keyboard tap and the UI never wait on it.
    nonisolated static func runProcess(_ path: String, _ arguments: [String], stdin: String?, environment: [String: String]?,
                                       timeout: TimeInterval) async throws -> (status: Int32, stdout: String, stderr: String) {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = arguments
                if let environment { process.environment = environment }
                let output = Pipe(), errors = Pipe(), input = Pipe()
                process.standardOutput = output
                process.standardError = errors
                process.standardInput = input
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                if let stdin { input.fileHandleForWriting.write(Data(stdin.utf8)) }
                try? input.fileHandleForWriting.close()
                let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
                var stderrData = Data()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global(qos: .utility).async {
                    stderrData = errors.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                let stdoutData = output.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                process.waitUntilExit()
                deadline.cancel()
                continuation.resume(returning: (process.terminationStatus, String(decoding: stdoutData, as: UTF8.self),
                                                String(decoding: stderrData, as: UTF8.self)))
            }
        }
    }

    /// The payload's fields as the environment a script sees: BINDERS_TEXT, BINDERS_TITLE…, on top of Binders' own.
    nonisolated static func environment(_ fields: [String: String]) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        for (key, value) in fields { environment["BINDERS_" + key.uppercased()] = value }
        return environment
    }

    /// Posts JSON to an address, with any headers given, and returns what the server said. Only http and https.
    nonisolated static func post(_ address: String, body: Data, headers: [String: String] = [:]) async throws -> String {
        guard let url = URL(string: address), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
            throw Failure.badURL(address)
        }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        request.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw Failure.http(status) }
        return String(decoding: data.prefix(2_000), as: UTF8.self)
    }

    /// Runs a Shortcut with text as its input.
    nonisolated static func runShortcut(_ name: String, input: String) async throws -> String {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("binders-shortcut-\(UUID().uuidString).txt")
        try input.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let result = try await runProcess("/usr/bin/shortcuts", ["run", name, "--input-path", file.path], stdin: nil, environment: nil, timeout: 120)
        guard result.status == 0 else { throw Failure.shortcut(result.stderr.trimmed.isEmpty ? "exit \(result.status)" : result.stderr.trimmed) }
        return "ran “\(name)”"
    }

    /// Starts a process that may run for a long time, and outlive Binders: what it prints goes to a log file rather than a
    /// pipe, so a quit doesn't take it down. What it prints on standard error goes to `errors` when it's given, so a line
    /// there never splits one of its JSON lines; otherwise to the same log. It's stopped after `limit`, with SIGINT first and
    /// SIGTERM 10 seconds later when `interruptFirst` (as a CLI tool ends a turn cleanly); `exited` hears its status.
    nonisolated static func launch(_ path: String, _ arguments: [String], stdin: String?, environment: [String: String]?, directory: URL?,
                                   log: URL, errors: URL? = nil, limit: TimeInterval, interruptFirst: Bool = false,
                                   exited: @escaping @Sendable (Int32) -> Void) throws -> Process {
        try start(path, arguments, stdin: stdin, keepingInput: false, environment: environment, directory: directory, log: log, errors: errors,
                  limit: limit, interruptFirst: interruptFirst, exited: exited).process
    }

    /// `launch`, with its standard input kept open and handed back, for a run that takes your words while it works
    /// (`AgentLiveInput`): nothing is written to it here, and it closes when the writer is closed or Binders quits.
    nonisolated static func launchKeepingInput(_ path: String, _ arguments: [String], environment: [String: String]?, directory: URL?, log: URL,
                                               limit: TimeInterval, exited: @escaping @Sendable (Int32) -> Void) throws -> (process: Process, input: FileHandle) {
        let started = try start(path, arguments, stdin: nil, keepingInput: true, environment: environment, directory: directory, log: log, errors: nil,
                                limit: limit, interruptFirst: false, exited: exited)
        return (started.process, started.input)
    }

    nonisolated private static func start(_ path: String, _ arguments: [String], stdin: String?, keepingInput: Bool, environment: [String: String]?,
                                          directory: URL?, log: URL, errors: URL?, limit: TimeInterval, interruptFirst: Bool,
                                          exited: @escaping @Sendable (Int32) -> Void) throws -> (process: Process, input: FileHandle) {
        // A child that stops reading its input mustn't take Binders with it.
        signal(SIGPIPE, SIG_IGN)
        try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let output = try FileHandle(forWritingTo: log)
        var errorOutput: FileHandle?
        if let errors {
            FileManager.default.createFile(atPath: errors.path, contents: nil)
            errorOutput = try FileHandle(forWritingTo: errors)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let directory { process.currentDirectoryURL = directory }
        process.standardOutput = output
        process.standardError = errorOutput ?? output
        let input = Pipe()
        process.standardInput = input
        let separate = errorOutput
        process.terminationHandler = { finished in
            try? output.close()
            try? separate?.close()
            exited(finished.terminationStatus)
        }
        try process.run()
        if !keepingInput {
            DispatchQueue.global(qos: .utility).async {
                if let stdin { try? input.fileHandleForWriting.write(contentsOf: Data(stdin.utf8)) }
                try? input.fileHandleForWriting.close()
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + limit) {
            guard process.isRunning else { return }
            guard interruptFirst else { return process.terminate() }
            process.interrupt()
            DispatchQueue.global().asyncAfter(deadline: .now() + 10) { if process.isRunning { process.terminate() } }
        }
        return (process, input.fileHandleForWriting)
    }

    /// The names of the user's Shortcuts, for the editor's menu.
    nonisolated static func installedShortcuts() async -> [String] {
        guard let result = try? await runProcess("/usr/bin/shortcuts", ["list"], stdin: nil, environment: nil, timeout: 20), result.status == 0 else { return [] }
        return result.stdout.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}
