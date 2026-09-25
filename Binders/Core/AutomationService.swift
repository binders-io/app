import AppKit
import Foundation
import BindersKit

/// The user's rules, and running them. Rules live in automations.json in the data folder: readable, versionable, shareable.
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

        var errorDescription: String? {
            switch self {
            case .badURL(let url): "Not a valid URL: \(url)"
            case .shortcut(let detail): "Shortcut failed: \(detail)"
            case .script(let status, let detail): "Script exited with \(status)\(detail.isEmpty ? "" : ": \(detail)")"
            case .http(let status): "The server answered \(status)"
            }
        }
    }

    private(set) var rules: [AutomationRule] = []
    private(set) var outcomes: [UUID: Outcome] = [:]
    /// Shows a line in the Flow bar: text and symbol.
    @ObservationIgnored var notify: ((String, String) -> Void)?
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

    func upsert(_ rule: AutomationRule) {
        if let index = rules.firstIndex(where: { $0.id == rule.id }) { rules[index] = rule } else { rules.append(rule) }
        save()
    }

    func remove(_ id: UUID) {
        rules.removeAll { $0.id == id }
        outcomes[id] = nil
        save()
    }

    func setEnabled(_ id: UUID, _ enabled: Bool) {
        guard let index = rules.firstIndex(where: { $0.id == id }) else { return }
        rules[index].isEnabled = enabled
        save()
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

    /// Runs every enabled rule for the event, without waiting. Only failures are shown.
    func fire(_ event: AutomationEvent, payload: AutomationPayload) {
        var payload = payload
        payload.event = event.rawValue
        for rule in rules where rule.isEnabled {
            guard case .event(let name) = rule.trigger, name == event else { continue }
            Task { await self.run(rule, payload: payload, quietly: true) }
        }
    }

    /// Runs one rule; what happened is kept for the editor and shown in the Flow bar.
    @discardableResult
    func run(_ rule: AutomationRule, payload: AutomationPayload, quietly: Bool = false) async -> Outcome {
        let outcome: Outcome
        do {
            outcome = Outcome(at: Date(), ok: true, message: try await perform(rule.action, payload: payload))
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

    private func perform(_ action: AutomationRule.Action, payload: AutomationPayload) async throws -> String {
        switch action {
        case .openURL(let template):
            let rendered = AutomationTemplate.render(template, payload: payload, encode: AutomationTemplate.percentEncoded)
            guard let url = URL(string: rendered), url.scheme != nil else { throw Failure.badURL(rendered) }
            NSWorkspace.shared.open(url)
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

    /// The names of the user's Shortcuts, for the editor's menu.
    nonisolated static func installedShortcuts() async -> [String] {
        guard let result = try? await runProcess("/usr/bin/shortcuts", ["list"], stdin: nil, environment: nil, timeout: 20), result.status == 0 else { return [] }
        return result.stdout.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}
