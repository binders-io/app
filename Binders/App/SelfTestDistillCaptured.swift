import Foundation
import BindersKit

extension SelfTest {
    /// Part of `--selftest-distill-more`: Binders' model reading a note after an agent proposed from it, and made a card
    /// from it. The model is told what's captured already and repeats none of it, even in other words; an item whose
    /// section the agent named loosely goes under the heading its quote is in; the card the agent made with create_task
    /// links back to the note; and the note marks the waiting items, as proposed, and the card at their words.
    @MainActor
    static func distillCapturedChecks(_ run: DistillTestRun) async {
        let controller = run.controller
        let service = controller.distill
        let scribe = BoardActor(name: "Scribe", kind: .agent)
        let help = BinderRecord(name: "Help", colorIndex: 3)
        Store.shared.insert(help)
        let note = NoteItem(text: """
            # Help centre

            ## Articles
            Write an article on refunds.
            Write an article on delivery times.

            ## Search
            Add search to the help centre.
            Put a contact form under the search.
            """)
        note.binderID = help.id
        Store.shared.insert(note)
        service.setDistill(true, for: note)

        // An agent proposes first, naming a section the note doesn't have.
        let proposed = await run.call("propose_work_items", ["id": note.id.uuidString, "items": [
            ["title": "Write the refunds article", "section": "Help articles", "quote": "Write an article on refunds."],
            ["title": "Add search to the help centre", "section": "Search", "quote": "Add search to the help centre."],
        ]], as: scribe)
        let agents = DistillStore.shared.file(for: note.id).distills.last
        run.check(proposed.ok && agents?.readBy == "Scribe" && agents?.items.map(\.section) == ["Articles", "Search"],
                  "an agent's section that matches no heading goes under the one its quote is in: \(agents?.items.map { $0.section ?? "none" } ?? [])")

        // A card it makes from the note with create_task is among the note's cards, at its words.
        let made = await run.call("create_task", ["title": "Write the delivery times article", "note": note.id.uuidString,
                                                  "quote": "Write an article on delivery times."], as: scribe)
        let card = DistillBoard.cards(of: note.id).first { $0.title == "Write the delivery times article" }
        run.check(made.ok && card?.noteMembership?.tie == .put && card?.distilledFrom?.section == "Articles"
                  && card?.distilledFrom?.quote == "Write an article on delivery times." && card?.binderID == help.id,
                  "create_task with the note links the card back to it: \(made.text.prefix(120))")
        run.check(card?.details.contains("binders://note/\(note.id.uuidString)") == true, "and its details lead to the note")
        let refused = await run.call("create_task", ["title": "Something", "note": UUID().uuidString], as: scribe)
        run.check(!refused.ok, "not with a note that isn't there: \(refused.text.prefix(80))")

        // The note marks what's waiting for review, and the card.
        let work = DistillNoteMarks.work(for: note, controller: controller, shown: true)
        let marked = work?.cards ?? []
        run.check(marked.filter(\.chip.proposed).map(\.title) == ["Write the refunds article", "Add search to the help centre"],
                  "the note marks the agent's items as proposed: \(marked.map(\.title))")
        run.check(marked.contains { $0.id == card?.id && !$0.chip.proposed }, "and the card")
        let placement = DistillMarks.place(marked.map { DistillMarks.Card(id: $0.id.uuidString, quote: $0.quote, section: $0.section) }, in: note.text)
        run.check(placement.lines.count == 3 && placement.atHeading.isEmpty && placement.nowhere.isEmpty,
                  "each at its own line: \(placement.lines.count) lines, \(placement.atHeading.count) at a heading")
        run.check(DistillMarks.chip(marked.filter(\.chip.proposed).prefix(1).map(\.chip)) == "Proposed", "its chip says Proposed")
        run.check(DistillNoteMarks.work(for: note, controller: controller, shown: false) == nil, "and nothing with Show Work in the Note off")

        // Binders' model reads it now: told what's captured, by the agent and on the board, and it repeats none of it.
        let model = CapturedModelStandIn()
        let result = await service.distill(note, client: model)
        let asked = model.prompts.joined(separator: "\n")
        run.check(asked.contains("Already captured from this note") && asked.contains("\"Write the refunds article\" (Articles)")
                  && asked.contains("\"Write the delivery times article\" (Articles)") && asked.contains("\"Add search to the help centre\" (Search)"),
                  "the model is told what's captured already: \(asked.components(separatedBy: "\n").first { $0.hasPrefix("Already") }?.prefix(200) ?? "nothing")")
        guard case .success(let record) = result else {
            run.check(false, "the model reads the note: \(result)")
            return
        }
        run.check(record.items.map(\.title) == ["Put a contact form under the search"],
                  "it proposes only what no one captured, nothing the agent proposed in other words: \(record.items.map(\.title))")
        run.check(service.coalesce(note.id) == 0, "nothing waiting repeats anything")

        // Put aside whole, the agent's proposal still counts.
        if var put = DistillStore.shared.distill(agents?.id ?? UUID(), of: note.id) {
            put.status = .dismissed
            DistillStore.shared.save(put)
        }
        let again = await service.distill(note, full: true, client: model)
        if case .success(let after) = again {
            run.check(after.items.isEmpty, "a proposal put aside isn't proposed again: \(after.items.map(\.title))")
        } else if case .failure(let problem) = again {
            run.check(problem == .unchanged, "a proposal put aside isn't proposed again: \(problem)")
        }
    }
}

/// The model for `distillCapturedChecks`: reads the note's work as a model would, the agent's items in other words among
/// it, and keeps what it was asked.
final class CapturedModelStandIn: LLMClient, @unchecked Sendable {
    private let lock = NSLock()
    private var asked: [String] = []
    var prompts: [String] { lock.withLock { asked } }

    var model: String { "captured-stand-in" }

    func complete(system: String, user: String, maxTokens: Int, temperature: Double, timeout: TimeInterval) async throws -> String {
        lock.withLock { asked.append(user) }
        return Self.reply
    }

    func stream(system: String, user: String, maxTokens: Int, temperature: Double, timeout: TimeInterval,
                stopWhen: @escaping @Sendable (String) -> Bool) async throws -> String {
        lock.withLock { asked.append(user) }
        return Self.reply
    }

    func listModels() async throws -> [String] { [model] }
    func warmUp() async {}

    static let reply = """
        [
          {"title": "Write an article about refunds", "section": "Articles", "quote": "Write an article on refunds.", "for": "agent"},
          {"title": "Write an article about delivery times", "section": "Articles", "quote": "Write an article on delivery times.", "for": "agent"},
          {"title": "Add search to the help centre", "section": "Search", "for": "agent"},
          {"title": "Put a contact form under the search", "section": "Search", "quote": "Put a contact form under the search.", "for": "agent"}
        ]
        """
}
