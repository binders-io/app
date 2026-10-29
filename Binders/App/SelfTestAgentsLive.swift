import Foundation
import BindersKit

extension SelfTest {
    /// Your words into a run while it works (the Agents page's terminal): a stand-in for claude in the throwaway folder that
    /// takes stream-json on its input, as Claude Code does with --input-format stream-json. It echoes each message back
    /// (--replay-user-messages), answers each with its own result, and ends when its input closes. The run's prompt goes in
    /// as the first message; a comment while it works goes straight in; its input closes after the last answer; and the
    /// run's end is handled as ever, with no second run for words it already had. A chat's run takes your words the same
    /// way, each reply going into the chat as it comes. Never the real claude.
    @MainActor
    static func liveInputSelfTest(check: (Bool, String) -> Void, controller: DictationController, binder: BinderRecord) async {
        let manager = FileManager.default
        let folder = AppPaths.support
        let board = controller.board
        let registry = AgentRegistry.shared
        let repository = folder.appendingPathComponent("live-repo")
        try? manager.createDirectory(at: repository.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let bin = folder.appendingPathComponent("live-bin")
        try? manager.createDirectory(at: bin, withIntermediateDirectories: true)
        let fake = bin.appendingPathComponent("claude")
        let script = #"""
            #!/bin/sh
            # A stand-in for claude that takes its input as stream-json (--input-format): each message it reads it echoes back,
            # as --replay-user-messages does, and answers with a result; it ends when its input closes.
            here="$(cd "$(dirname "$0")/.." && pwd)"
            printf '%s\n' "$*" > "$here/live-args.txt"
            printf '%s\n' '{"type":"system","subtype":"init","session_id":"live-session"}'
            n=0
            while IFS= read -r line; do
              n=$((n+1))
              printf '%s\n' "$line" >> "$here/live-in.txt"
              printf '%s\n' "$line"
              printf '{"type":"assistant","message":{"id":"a%s","content":[{"type":"text","text":"Answer %s"}]}}\n' "$n" "$n"
              sleep "$(cat "$here/live-sleep.txt" 2>/dev/null || echo 0)"
              printf '{"type":"result","subtype":"success","is_error":false,"result":"Answer %s","duration_ms":1500,"total_cost_usd":0.01}\n' "$n"
            done
            printf 'closed after %s\n' "$n" > "$here/live-end.txt"
            exit 0
            """#
        try? script.write(to: fake, atomically: true, encoding: .utf8)
        try? manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        func setting(_ name: String, _ value: String) { try? value.write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        func lines(_ name: String) -> [String] {
            ((try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        }
        func wait(_ seconds: Double, until done: () -> Bool) async {
            let end = Date().addingTimeInterval(seconds)
            while !done(), Date() < end { try? await Task.sleep(for: .milliseconds(100)) }
        }
        let agent = AgentProfile(name: "Claude Code · live", wake: .claudeCode(ClaudeCodeWake(repository: repository.path, permissionMode: "acceptEdits",
                                                                                              executable: fake.path, inFolder: true)),
                                 preset: "claude-code", wakesPerHour: 30)
        check(registry.upsert(agent) == nil, "live: a Claude Code agent with the stand-in is saved: \(registry.problem(with: agent) ?? "")")
        check(AgentDispatcher.takesLiveInput(ClaudeCodeWake(repository: repository.path, executable: fake.path)),
              "live: a stand-in that reads stream-json takes your words while it works")

        // A card run: its prompt is the first message, as JSON.
        setting("live-sleep.txt", "3")
        let card = board.create(title: "Fold Done into a strip", binderID: binder.id, column: .backlog, by: .you)
        board.give(card, to: agent.name, by: .you)
        await wait(15) { !lines("live-in.txt").isEmpty }
        let first = lines("live-in.txt").first.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        let prompt = (first?["message"] as? [String: Any])?["content"] as? String ?? ""
        check(first?["type"] as? String == "user" && prompt.hasPrefix(AgentWake.promptMarker) && prompt.contains(card.id.uuidString),
              "live: the run's prompt goes in as a stream-json message: \(lines("live-in.txt").first ?? "nothing")")
        check(lines("live-args.txt").first?.contains("--input-format stream-json --replay-user-messages") == true,
              "live: and it's started to take its input as messages, echoed back")
        check(controller.agents.takesLive(card.id) && controller.agents.commentReach(for: card, events: board.timeline(card.id)) == .live(agent.name),
              "live: while it works, your words go straight in, as the composer says")

        // Your words while it works: straight into the run, and on the card.
        board.comment(card, text: "Keep the column titles visible.", by: .you)
        check(controller.agents.outcomes[card.id]?.message == "Sent into \(agent.name)'s running session", "live: a comment while it works goes into the run now")
        await wait(30) { !controller.agents.isWorking(on: card.id) }
        let sent = lines("live-in.txt")
        check(sent.count == 2 && sent.last?.contains("Keep the column titles visible.") == true, "live: the run read it: \(sent.count) messages")
        check(lines("live-end.txt") == ["closed after 2"], "live: its input closed once both had their answers, and it ended: \(lines("live-end.txt"))")
        check(controller.agents.outcomes[card.id]?.message.hasPrefix("Finished") == true && !controller.agents.takesLive(card.id),
              "live: the run's end is handled as ever: \(controller.agents.outcomes[card.id]?.message ?? "")")
        check(board.timeline(card.id).contains { $0.kind == .comment && $0.text == "Keep the column titles visible." }, "live: your words are on the card too")
        try? await Task.sleep(for: .seconds(3))
        check(board.timeline(card.id).filter { $0.kind == .woke }.count == 1, "live: and no second run carries words it already had")

        // The terminal shows the run as it went: Binders' prompt in a line, your words, each answer and each turn's end.
        let logs = AgentTerminalLogs()
        logs.follow(AgentDoing.runLogs(links: card.links, card: card.id, logs: AgentPlaces.logs.path).map { URL(fileURLWithPath: $0) }, tool: .claude)
        try? await Task.sleep(for: .milliseconds(1_500))
        let yours = board.timeline(card.id).filter { CardConversation.isYours($0.conversation) }.map { ($0.createdAt, $0.text) }
        let (runs, after) = logs.runs(yours: yours)
        let shown = AgentTerminal.blocks(runs).map(\.kind)
        logs.stop()
        check(shown.contains { if case .binders = $0 { true } else { false } } && shown.filter { $0 == .you("Keep the column titles visible.") }.count == 1
              && after.isEmpty, "live: the terminal shows Binders' prompt in a line and your words once: \(shown.count) lines")
        check(shown.filter { if case .end(true, _) = $0 { true } else { false } }.count == 2 && shown.contains(.said("Answer 2")),
              "live: each answer and each turn's end")

        // Look in from Terminal: the run's folder and session, in a script Binders writes and opens.
        var opened: URL?
        let keep = TerminalLookIn.open
        TerminalLookIn.open = { opened = $0 }
        let receipt = "Started Claude Code in \(repository.path), the folder itself (acceptEdits, made ready for it). To look in: claude --resume 3f2a3c55-1111-4222-8333-944455556666 there."
        let lookCard = board.create(title: "Look in", binderID: binder.id, by: .you)
        board.woke(lookCard, agent: agent.name, text: receipt, log: nil)
        board.woke(lookCard, agent: "Someone else", text: "Started Claude Code in /tmp/elsewhere (plan). To look in: claude --resume 11111111-1111-4111-8111-111111111111 there.", log: nil)
        let look = TerminalLookIn.card(lookCard, timeline: board.timeline(lookCard.id), agent: agent)
        check(look == TerminalLookIn.Command(folder: repository.path, command: "\(fake.path) --resume 3f2a3c55-1111-4222-8333-944455556666"),
              "look in: its own last run's folder and session, with its own program: \(String(describing: look))")
        if let look, let url = TerminalLookIn.run(look, title: "Claude Code · live: Look in", name: "card-look") {
            let written = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let mode = (try? manager.attributesOfItem(atPath: url.path))?[.posixPermissions] as? Int
            check(opened == url && url.pathExtension == "command" && mode == 0o700, "look in: a script Terminal opens, yours alone")
            check(written.hasPrefix("#!/bin/zsh -l\n") && written.contains("cd \(repository.path) || exit 1\n") && written.hasSuffix("--resume 3f2a3c55-1111-4222-8333-944455556666\n"),
                  "look in: it goes to the folder and resumes the session: \(written)")
            try? manager.removeItem(at: url)
        } else {
            check(false, "look in: the script was written")
        }
        TerminalLookIn.open = keep

        // A chat's run takes your words the same way: each reply goes in as it comes.
        setting("live-sleep.txt", "2")
        try? manager.removeItem(at: folder.appendingPathComponent("live-in.txt"))
        try? manager.removeItem(at: folder.appendingPathComponent("live-end.txt"))
        guard case .success(let chat) = controller.chats.send("What's left on the release?", to: agent.name, via: "mac") else {
            return check(false, "live: a chat with it starts")
        }
        await wait(15) { !lines("live-in.txt").isEmpty }
        check(controller.chats.takesLive(chat.id), "live: a chat's run takes your words while it works")
        _ = controller.chats.send("And the changelog?", to: agent.name, chat: chat.id, via: "mac")
        check(controller.chats.chat(chat.id)?.messages.last?.delivered == true, "live: a message while it answers goes straight in")
        await wait(30) { controller.chats.chat(chat.id)?.status != .running }
        let replies = controller.chats.chat(chat.id)?.messages.filter { $0.from == .agent }.map(\.text) ?? []
        check(replies == ["Answer 1", "Answer 2"] && lines("live-end.txt") == ["closed after 2"],
              "live: each reply goes into the chat as it comes, and the run ends after the last: \(replies)")
        check(controller.chats.chat(chat.id)?.why == nil, "live: with nothing to say about it")
        registry.remove(agent.id)
    }
}
