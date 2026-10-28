import AppKit
import SwiftData
import SwiftUI
import BindersKit

extension SelfTest {
    /// A binder's Assistant, with a stand-in model that answers from a script: the binder's contents in its instructions
    /// and no other binder's, the binder pinned on the tools that take one, an item in another binder or a tool it hasn't
    /// turned down, its reply the answer with what it read as sources, a follow-up carrying the conversation, a run past its
    /// steps, a model that fails, no model at all, and Stop; then the tab drawn. In a throwaway folder (BINDERS_DATA_DIR)
    /// only; no model runs.
    ///
    ///     BINDERS_DATA_DIR=$(mktemp -d) Binders --selftest-assistant <folder for drawings> -notesShowMarkdown NO
    @MainActor
    static func assistantSelfTest(drawingTo directory: URL) async -> Int32 {
        guard AppPaths.isDemo else {
            print("ERROR: set BINDERS_DATA_DIR to an empty folder; this test writes binders, meetings and notes")
            return 1
        }
        var failures = 0
        func check(_ condition: Bool, _ label: String) {
            print("\(condition ? "PASS" : "FAIL"): \(label)")
            if !condition { failures += 1 }
        }
        let controller = DictationController()
        let assistant = AssistantService.shared
        let settings = AppSettings.shared
        func until(seconds: Double = 30, _ done: () -> Bool) async {
            let end = Date().addingTimeInterval(seconds)
            while !done(), Date() < end { try? await Task.sleep(for: .milliseconds(50)) }
        }

        // Two binders: the one asked about, and one it mustn't see.
        let store = Store.shared
        let launch = BinderRecord(name: "Acme launch", colorIndex: 2)
        launch.whatGoesHere = "The Acme launch: pricing, dates and the booth"
        let personal = BinderRecord(name: "Personal", colorIndex: 4)
        store.insert(launch)
        store.insert(personal)
        let meeting = MeetingRecord(title: "Pricing review", appName: "Zoom", templateID: "general")
        meeting.binderID = launch.id
        meeting.status = "done"
        meeting.createdAt = Date().addingTimeInterval(-86_400 * 2)
        meeting.summary = "## Decisions\n- Launch price is $49 a seat\n- Annual plans get two months free\n"
        store.insert(meeting)
        for (index, line) in ["We land on forty-nine a seat?", "Yes, forty-nine, and annual gets two months free."].enumerated() {
            store.insert(MeetingSegmentRecord(meetingID: meeting.id, segment: TranscriptSegment(channel: .microphone, start: Double(index) * 6,
                                                                                        end: Double(index) * 6 + 5, text: line, speaker: index == 0 ? "You" : "Speaker 2")))
        }
        let plan = NoteItem(text: "# Launch plan\n\nBooth at the Expo on the 14th. Sam owns the demo.\n")
        plan.binderID = launch.id
        store.insert(plan)
        let secret = NoteItem(text: "# Dentist\n\nCall back about the crown.\n")
        secret.binderID = personal.id
        store.insert(secret)
        store.save()

        // A conversation: list_notes naming the other binder, the other binder's note, a tool it hasn't, an answer that
        // isn't a step, the meeting's transcript, then its reply.
        // The answer is asked for on its own, freely, once the steps say they're ready.
        let answering: @Sendable (String) -> Bool = { $0.contains("Write only the answer") }
        let ready = #"{"action":"reply","tool":"","arguments":[],"reply":"ready"}"#
        let model = ScriptedModel { turn, system, user in
            if answering(system) {
                let saw = user.contains("Launch plan") && !user.contains("Call back about the crown") && user.contains("nothing with that id in this binder")
                    && user.contains("no tool named add_todo") && user.contains("couldn't read it as one step") && user.contains("forty-nine")
                return saw ? "**$49 a seat**, decided in Pricing review.\n\n- Annual plans get two months free" : "WRONG"
            }
            switch turn {
            case 0: return #"{"action":"call","tool":"list_notes","arguments":[{"name":"binder","value":"Personal"}],"reply":""}"#
            case 1: return #"{"action":"call","tool":"get_note","arguments":[{"name":"id","value":"\#(secret.id.uuidString)"}],"reply":""}"#
            case 2: return #"{"action":"call","tool":"add_todo","arguments":[{"name":"text","value":"x"}],"reply":""}"#
            case 3: return "Let me look at the meeting."
            case 4: return #"{"action":"call","tool":"get_meeting","arguments":[{"name":"id","value":"\#(meeting.id.uuidString)"},{"name":"include_transcript","value":"true"}],"reply":""}"#
            default: return ready
            }
        }
        assistant.localModel = { model }
        assistant.ask("What price did we land on?", binder: launch, knowledge: controller.knowledge, settings: settings)
        check(assistant.conversation(launch.id).isRunning, "asking starts a run")
        await until { !assistant.conversation(launch.id).isRunning }
        let first = assistant.conversation(launch.id)
        check(first.messages.map(\.role) == [.user, .assistant], "the question and its answer")
        check(first.messages.last?.text == "**$49 a seat**, decided in Pricing review.\n\n- Annual plans get two months free" && first.messages.last?.failed == false,
              "the answer is written freely, line breaks and all, once it read only this binder and was told what it couldn't do")
        check(answering(model.prompts.last?.system ?? "") && model.prompts.count == 7, "the steps, then the answer asked for on its own")
        let sources = first.messages.last?.sources.map(\.id) ?? []
        check(sources.contains(meeting.id.uuidString) && sources.contains(plan.id.uuidString) && !sources.contains(secret.id.uuidString),
              "what it read are the sources, and nothing from another binder (\(sources.count))")
        let opening = model.prompts.first?.user ?? ""
        check(opening.contains("Launch price is $49 a seat") && opening.contains("Booth at the Expo") && first.steps.first?.hasPrefix("Searching") == true,
              "Binders reads the binder before the model's first step")
        check(first.steps.contains("Reading the transcript of “Pricing review”"), "it says what it read, by title")
        let system = model.prompts.first?.system ?? ""
        check(system.contains("“Acme launch”") && system.contains("The Acme launch: pricing, dates and the booth"), "the instructions name the binder and what it's for")
        check(system.contains(meeting.id.uuidString) && system.contains(plan.id.uuidString) && !system.contains(secret.id.uuidString),
              "the instructions list this binder's meetings and notes, and not another binder's")
        let offered = system.components(separatedBy: "\n").filter { $0.hasPrefix("- ") && $0.contains(": ") }.compactMap { line in
            MCPServer.tools.first { line.hasPrefix("- \($0.name): ") }?.name
        }
        check(Set(offered) == Set(BinderAssistant.tools) && MCPServer.tools.filter { offered.contains($0.name) }.allSatisfy(\.readOnly),
              "only the reading tools are offered (\(offered.sorted().joined(separator: ", ")))")

        // A follow-up carries the conversation.
        let followUp = ScriptedModel { _, system, user in
            guard answering(system) else { return ready }
            let carried = user.contains("You asked: What price did we land on?") && user.contains("It answered: **$49 a seat**")
            return carried ? "Two months free on annual." : "WRONG"
        }
        assistant.localModel = { followUp }
        assistant.ask("And the annual plan?", binder: launch, knowledge: controller.knowledge, settings: settings)
        await until { !assistant.conversation(launch.id).isRunning }
        check(assistant.conversation(launch.id).messages.last?.text == "Two months free on annual.", "a follow-up sees the conversation before it")
        check(assistant.conversation(personal.id).messages.isEmpty, "each binder has its own conversation")

        // Past its steps: the answer from what it read, rather than nothing.
        let looping = ScriptedModel { _, system, _ in
            answering(system) ? "From what I read: one note, about the dentist." : #"{"action":"call","tool":"list_meetings","arguments":[],"reply":""}"#
        }
        assistant.localModel = { looping }
        assistant.ask("Loop", binder: personal, knowledge: controller.knowledge, settings: settings)
        await until { !assistant.conversation(personal.id).isRunning }
        let looped = assistant.conversation(personal.id).messages.last
        check(looped?.failed == false && looped?.text == "From what I read: one note, about the dentist."
              && looping.prompts.count == BinderAssistant.maxSteps + 2, "a run past its steps answers from what it read")

        // A model that fails, one too small, and none at all.
        assistant.localModel = { ScriptedModel(failing: true) { _, _, _ in "" } }
        assistant.ask("Fail", binder: personal, knowledge: controller.knowledge, settings: settings)
        await until { !assistant.conversation(personal.id).isRunning }
        check(assistant.conversation(personal.id).messages.last?.text.hasPrefix("The model didn't answer") == true, "a model that fails says so")
        assistant.localModel = { ScriptedModel(context: 1_024) { _, _, _ in "" } }
        assistant.ask("Tiny", binder: personal, knowledge: controller.knowledge, settings: settings)
        await until { !assistant.conversation(personal.id).isRunning }
        check(assistant.conversation(personal.id).messages.last?.text.contains("larger context") == true, "a model too small to hold the instructions isn't asked")
        assistant.localModel = { nil }
        assistant.ask("None", binder: personal, knowledge: controller.knowledge, settings: settings)
        await until { !assistant.conversation(personal.id).isRunning }
        check(assistant.conversation(personal.id).messages.last?.text.hasPrefix("Choose a language model") == true, "no model: where to choose one")

        // Stop.
        let slow = ScriptedModel { _, _, _ in
            try? await Task.sleep(for: .seconds(20))
            return #"{"action":"reply","tool":"","arguments":[],"reply":"late"}"#
        }
        assistant.localModel = { slow }
        assistant.ask("Slow", binder: personal, knowledge: controller.knowledge, settings: settings)
        try? await Task.sleep(for: .milliseconds(300))
        assistant.stop(personal.id)
        await until(seconds: 5) { !assistant.conversation(personal.id).isRunning }
        check(!assistant.conversation(personal.id).isRunning && assistant.conversation(personal.id).messages.last?.text == "Stopped.", "Stop ends the run")
        assistant.clear(personal.id)
        check(assistant.conversation(personal.id).messages.isEmpty, "New Conversation forgets it")

        // Drawn: the conversation, an empty tab, at a usual size and the window's smallest, light and dark.
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        func draw(_ binder: BinderRecord, _ name: String, size: NSSize, dark: Bool) async {
            let navigation = HubNavigation()
            navigation.binderID = binder.id
            navigation.selection = .binder
            navigation.pendingBinderTab = .assistant
            let view = HubView().environment(navigation).environment(controller).environment(controller.meetings)
                .environment(controller.knowledge).environment(controller.team).environment(controller.capture)
                .environment(controller.commitments).environment(settings).modelContainer(store.container)
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let hosting = NSHostingView(rootView: view)
            window.contentView = hosting
            window.orderFrontRegardless()
            try? await Task.sleep(for: .milliseconds(1_800))
            check(window.frame.width <= size.width + 0.5, "\(name): the page fits \(Int(size.width)) pt (\(Int(window.frame.width)))")
            snapshot(hosting, name: name, directory: directory)
            window.close()
        }
        await draw(launch, "assistant-conversation", size: NSSize(width: 1280, height: 800), dark: false)
        await draw(launch, "assistant-conversation-dark", size: NSSize(width: 1280, height: 800), dark: true)
        await draw(personal, "assistant-empty", size: NSSize(width: 1280, height: 800), dark: false)
        await draw(launch, "assistant-smallest", size: HubWindowController.smallestSize, dark: false)
        assistant.localModel = nil

        print(failures == 0 ? "ASSISTANT_OK" : "ASSISTANT_FAILED \(failures)")
        return failures == 0 ? 0 : 1
    }
}
