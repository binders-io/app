import AppKit
import SwiftData
import BindersKit

extension SelfTest {
    /// The Manager on a local model (lane MG2), with a stand-in model that answers from a script, and Binders' own
    /// `--mcp` server as the run starts it: the role through Settings' yes, no cards for it, the model shown the request
    /// and the Manager's tools (not get_request or reply), a tool it calls done through the inbox and kept for Undo, a tool
    /// it hasn't and an answer Binders can't read told back to it, its reply the request's answer; a run past its steps,
    /// a model that fails, no model at all, and Stop. In a throwaway folder (BINDERS_DATA_DIR) only; no model runs.
    ///
    ///     BINDERS_DATA_DIR=$(mktemp -d) Binders --selftest-manager-local -notesShowMarkdown NO
    @MainActor
    static func managerLocalSelfTest() async -> Int32 {
        guard AppPaths.isDemo else {
            print("ERROR: set BINDERS_DATA_DIR to an empty folder; this test writes cards, agents and the Manager's file")
            return 1
        }
        var failures = 0
        func check(_ condition: Bool, _ label: String) {
            print("\(condition ? "PASS" : "FAIL"): \(label)")
            if !condition { failures += 1 }
        }
        let controller = DictationController()
        let registry = AgentRegistry.shared
        let manager = controller.manager
        func until(seconds: Double = 60, _ done: () -> Bool) async {
            let end = Date().addingTimeInterval(seconds)
            while !done(), Date() < end { try? await Task.sleep(for: .milliseconds(100)) }
        }
        // The app picks up what the server hands it through the inbox; here the test does, as it waits.
        manager.localPump = {
            let waiting = (try? FileManager.default.contentsOfDirectory(atPath: InboxCommands.directory.path)) ?? []
            for file in waiting where file.hasSuffix(".request.json") {
                await InboxCommands.apply(named: String(file.dropLast(".request.json".count)), controller: controller)
            }
        }
        let store = Store.shared
        let binder = BinderRecord(name: "Personal", colorIndex: 3)
        store.insert(binder)

        // The role, and no cards.
        let local = AgentProfile(name: "Manager", wake: .localModel(LocalModelWake(model: "stand-in")), manager: true)
        registry.upsert(local)
        check(!registry.isManager(local), "a local model with manager: true but without the alert's yes isn't the Manager")
        check(registry.upsert(local, isManager: true) == nil && registry.isManager(local) && manager.agent?.id == local.id,
              "Save with the alert's yes makes a local model the Manager")
        check(!local.takesCards(from: binder.id) && !registry.takers(for: binder.id).contains { $0.id == local.id },
              "a local model takes no cards")
        check(AgentsSections.describe(local.wake).contains("stand-in"), "Settings names its model")

        // A run: list_binders, create_task, a tool it hasn't, an answer that isn't a step, then its reply.
        let model = ScriptedModel { turn, _, user in
            switch turn {
            case 0: return #"{"action":"call","tool":"list_binders","arguments":[],"reply":""}"#
            case 1: return #"{"action":"call","tool":"create_task","arguments":[{"name":"title","value":"Book the dentist"},{"name":"binder","value":"Personal"}],"reply":""}"#
            case 2: return #"{"action":"call","tool":"delete_everything","arguments":[],"reply":""}"#
            case 3: return "Let me think about what to do next."
            default:
                return user.contains("no tool named delete_everything") && user.contains("couldn't read it as one step")
                    ? "```json\n{\"action\": \"reply\", \"tool\": \"\", \"arguments\": [], \"reply\": \"Made a card to book the dentist.\"}\n```"
                    : #"{"action":"reply","tool":"","arguments":[],"reply":"It wasn't told."}"#
            }
        }
        var asked: LocalModelWake?
        manager.localModel = { wake, _ in asked = wake; return model }
        let first = manager.ask("Make me a card to book the dentist", from: .mac)
        await until { manager.request(first.id)?.isOver == true }
        let done = manager.request(first.id)
        check(asked?.namedModel == "stand-in", "the run asks for the model the agent names")
        check(done?.status == .answered && done?.reply == "Made a card to book the dentist.",
              "its reply, in a code block, is the request's answer (\(done?.status.rawValue ?? "none"): \(done?.why ?? done?.reply ?? ""))")
        check(done?.agent == "Manager", "the request names the local model's agent")
        let system = model.prompts.first?.system ?? ""
        check(system.contains("- list_binders:") && system.contains("- create_task:") && system.contains("- propose_note_edit:"),
              "the model is shown the Manager's tools")
        check(!system.contains("- get_request:") && !system.contains("- reply:") && !system.contains("- claim_task:"),
              "not get_request, reply, or a tool the Manager hasn't")
        check(model.prompts.first?.user.contains("Make me a card to book the dentist") == true, "it reads the request as get_request gives it")
        check(model.prompts.count > 2 && model.prompts[2].user.contains("Personal"), "it reads what list_binders answered")
        let cards = (try? store.context.fetch(FetchDescriptor<TaskCard>())) ?? []
        let made = cards.first { $0.title == "Book the dentist" }
        check(made != nil && made?.binderID == binder.id, "create_task made the card in the binder it named")
        check(done?.changes.contains { $0.kind == .madeCard } == true && done?.changes.count == 1,
              "the card it made is kept with the request, for Undo")
        let undone = manager.undo(first.id)
        check(undone == "Put back 1 of 1 change." && manager.request(first.id)?.undoneAt != nil, "Undo puts the request back (\(undone))")

        // Past its steps: always another tool, so it's asked for its reply, and fails when it still calls one.
        let busy = ScriptedModel { _, _, _ in #"{"action":"call","tool":"list_binders","arguments":[],"reply":""}"# }
        manager.localModel = { _, _ in busy }
        let long = manager.ask("Keep looking", from: .iphone)
        await until(seconds: 120) { manager.request(long.id)?.isOver == true }
        check(manager.request(long.id)?.status == .failed && manager.request(long.id)?.why?.contains("within \(ManagerLocal.maxSteps) steps") == true,
              "a run that won't reply stops after \(ManagerLocal.maxSteps) tool calls (\(manager.request(long.id)?.why ?? ""))")
        check(busy.prompts.count == ManagerLocal.maxSteps + 1 && busy.prompts.last?.user.contains("You've used all") == true,
              "its last turn asks it for its reply")

        // A model that fails, and none at all.
        manager.localModel = { _, _ in ScriptedModel(failing: true) { _, _, _ in "" } }
        let broken = manager.ask("Anything", from: .mac)
        await until { manager.request(broken.id)?.isOver == true }
        check(manager.request(broken.id)?.status == .failed && manager.request(broken.id)?.why?.hasPrefix("The model didn't answer") == true,
              "a model that fails says so (\(manager.request(broken.id)?.why ?? ""))")
        manager.localModel = { _, _ in nil }
        let none = manager.ask("Anything", from: .mac)
        await until { manager.request(none.id)?.isOver == true }
        check(manager.request(none.id)?.status == .failed && manager.request(none.id)?.why?.contains("Settings → AI") == true,
              "with no model set, a request says where to set one")

        // A model whose context can't hold the instructions isn't asked.
        let tiny = ScriptedModel(context: 2_048) { _, _, _ in #"{"action":"reply","tool":"","arguments":[],"reply":"Hi"}"# }
        manager.localModel = { _, _ in tiny }
        let cramped = manager.ask("Anything", from: .mac)
        await until { manager.request(cramped.id)?.isOver == true }
        check(manager.request(cramped.id)?.status == .failed && manager.request(cramped.id)?.why?.contains("num_ctx") == true && tiny.prompts.isEmpty,
              "a model with too small a context isn't asked, and the request says how to fix it (\(manager.request(cramped.id)?.why ?? ""))")

        // Stop, while the model thinks.
        let slow = ScriptedModel { _, _, _ in
            try? await Task.sleep(for: .seconds(30))
            return #"{"action":"reply","tool":"","arguments":[],"reply":"Too late"}"#
        }
        manager.localModel = { _, _ in slow }
        let stopped = manager.ask("Take your time", from: .mac)
        await until { manager.request(stopped.id)?.status == .running && !slow.prompts.isEmpty }
        check(manager.undo(stopped.id).hasPrefix("It's still working"), "Undo waits until a request is over")
        manager.stop(stopped.id)
        await until { manager.request(stopped.id)?.isOver == true }
        check(manager.request(stopped.id)?.status == .stopped && manager.request(stopped.id)?.reply == nil, "Stop stops it, with no reply")

        print(failures == 0 ? "MANAGER_LOCAL_OK" : "MANAGER_LOCAL_FAILED \(failures)")
        return failures == 0 ? 0 : 1
    }
}

/// A model that answers from a script, by turn, and keeps what it was asked.
final class ScriptedModel: LLMClient, @unchecked Sendable {
    struct Prompt { var system: String; var user: String }
    private let lock = NSLock()
    private var asked: [Prompt] = []
    private let failing: Bool
    private let context: Int?
    private let script: @Sendable (Int, String, String) async -> String

    init(failing: Bool = false, context: Int? = nil, _ script: @escaping @Sendable (Int, String, String) async -> String) {
        self.failing = failing
        self.context = context
        self.script = script
    }

    func contextTokens() async -> Int? { context }

    var prompts: [Prompt] { lock.withLock { asked } }
    var model: String { "stand-in" }

    func complete(system: String, user: String, maxTokens: Int, temperature: Double, timeout: TimeInterval) async throws -> String {
        let turn = lock.withLock { asked.append(Prompt(system: system, user: user)); return asked.count - 1 }
        if failing { throw LLMError.http(500, "the stand-in fails") }
        return await script(turn, system, user)
    }

    func stream(system: String, user: String, maxTokens: Int, temperature: Double, timeout: TimeInterval,
                stopWhen: @escaping @Sendable (String) -> Bool) async throws -> String {
        try await complete(system: system, user: user, maxTokens: maxTokens, temperature: temperature, timeout: timeout)
    }

    func listModels() async throws -> [String] { [model] }

    func warmUp() async {}
}
