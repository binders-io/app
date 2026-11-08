import AppIntents
import BindersKit
import Foundation
import UIKit

/// "Ask Binders": a question answered from your binders by Binders on your Mac, said back by Siri. It reads your binders,
/// so it needs the iPhone unlocked.
struct AskBindersIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask Binders"
    // App Store Connect refuses an intent description that names a platform (ITMS-90626 "cannot contain 'mac'").
    static let description = IntentDescription("Ask your binders something. Binders answers from your notes, meetings and captures.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Question", requestValueDialog: "What do you want to ask?")
    var question: String

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let reply = await BindersSiri.said(question, asking: true)
        // Siri says the answer alone; the value, for a shortcut, keeps the titles of where it came from.
        return .result(value: reply.full, dialog: IntentDialog(stringLiteral: reply.spoken))
    }
}

/// "Tell Binders": a to-do, an idea or a note for your Mac, as if you'd said "Binders, …" near your iPhone. Done at once,
/// with Undo in the app; kept for your Mac when it's away. It works with the iPhone locked, so it only ever says what it
/// kept: answers are Ask's, which needs the iPhone unlocked.
struct TellBindersIntent: AppIntent {
    static let title: LocalizedStringResource = "Tell Binders"
    static let description = IntentDescription("Tell Binders a to-do, an idea or a note, and it files it in your binders.")

    @Parameter(title: "What to tell it", requestValueDialog: "What should I tell Binders?")
    var text: String

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let reply = await BindersSiri.said(text, asking: false)
        return .result(value: reply.full, dialog: IntentDialog(stringLiteral: reply.spoken))
    }
}

struct BindersShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: AskBindersIntent(), phrases: ["Ask \(.applicationName)", "Ask \(.applicationName) a question"],
                    // Your Mac's model reading your binders, not an agent's work: not the sparkle.
                    shortTitle: "Ask Binders", systemImageName: "text.magnifyingglass")
        AppShortcut(intent: TellBindersIntent(), phrases: ["Tell \(.applicationName)", "Tell \(.applicationName) something"],
                    shortTitle: "Tell Binders", systemImageName: "text.bubble")
    }
}

/// What Siri says back: the Mac's answer or what it did, through the same path as something said to the iPhone with
/// "Binders, …".
@MainActor
enum BindersSiri {
    /// What Siri says, and what the intent gives back, which may say more: an answer's sources after it.
    struct Reply {
        let spoken: String
        let full: String

        init(_ text: String) {
            spoken = text
            full = text
        }

        init(spoken: String, full: String) {
            self.spoken = spoken
            self.full = full
        }
    }

    static func said(_ words: String, asking: Bool) async -> Reply {
        let text = words.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return Reply(asking ? "Ask me something about your binders." : "Tell me what to keep.") }
        guard let connection = MacConnection.current, connection.hasBrain else { return Reply("Pair Binders with your Mac, or sign in to your hub, first.") }
        guard connection.takesMoments else {
            // A Mac before moments: the question to Ask, the rest kept as a dictation.
            if asking, let reply = try? await connection.request("tools/call", ["name": "ask_knowledge", "arguments": ["question": text]]) as? [String: Any],
               let content = (reply["content"] as? [[String: Any]])?.first?["text"] as? String,
               let answer = (try? JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any])?["answer"] as? String {
                return Reply(spoken: CaptureOutcome.speakable(answer), full: answer)
            }
            return Reply(await connection.keepDictation(text, heard: text, app: "Siri") ? "Kept on \(connection.brainPhrase)." : "Kept for \(connection.brainPhrase).")
        }
        let payload = MomentPayload(heard: Date(), text: text, device: UIDevice.current.model, engine: "siri", wake: true,
                                    kind: asking ? MomentKind.question.rawValue : nil)
        guard let outcome = await connection.momentNow(payload, said: text) else {
            MomentCenter.shared.keptForLater(payload)
            return Reply("\(connection.brainName ?? "\(MacConnection.BrainWords)") is out of reach. I kept it, and it goes when \(connection.brainPhrase) is back.")
        }
        MomentCenter.shared.record(payload, outcome: outcome)
        if outcome.state == "working" { return Reply("\(MacConnection.BrainWords) is still working on it. It'll be in Binders shortly.") }
        // Told, not asked: only what it kept is said back, the same whatever your binders hold, as Tell is heard with the
        // iPhone locked too. Answers are Ask's.
        if !asking {
            return Reply(outcome.state == "acted" && !outcome.line.isEmpty ? outcome.line : "Nothing kept from that. To ask your binders something, say “Ask Binders”.")
        }
        guard !outcome.line.isEmpty else { return Reply("Nothing in your binders about that.") }
        // The answer alone is read out: the titles of its sources follow it on a line of their own.
        return Reply(spoken: outcome.spoken.isEmpty ? outcome.line : outcome.spoken, full: outcome.line)
    }
}
