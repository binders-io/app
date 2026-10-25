import Foundation
import SwiftData
import BindersKit

extension SelfTest {
    /// Who Distill's items are meant for (lane AS1), in a throwaway folder (BINDERS_DATA_DIR) with a stand-in reader, the
    /// router's stand-in decision model and stand-in agents that check the board (nothing is woken): the reader is told who
    /// can take work in the note's binder (your agents that take its cards with what each is for, you, the team's people),
    /// and with no one to tell, the prompt is as before; its reply names an agent, a teammate, "person", "either", a name
    /// that's no one here and an agent that doesn't take the binder's cards, and each item is meant for whom the rules say,
    /// with who picked it; the decision model reads an item's brief as well as its title, and a Put on Board card's
    /// details; the review sheet's words; Suggest Who Again fills only the blanks; "Distill with…"'s card lists who can
    /// take work.
    ///
    ///     BINDERS_DATA_DIR=<new empty folder> Binders --selftest-distill-who -notesShowMarkdown NO
    @MainActor
    static func distillWhoSelfTest() async -> Int32 {
        guard AppPaths.isDemo else {
            print("ERROR: set BINDERS_DATA_DIR to an empty folder; this test writes notes, cards and agents")
            return 1
        }
        let controller = DictationController()
        let run = DistillTestRun(controller: controller)
        let store = Store.shared
        let board = controller.board
        let service = controller.distill
        // v1's prompts and sizes, as this test was written for (lane DS8 made v2 the default; `--selftest-distill-fast` has it).
        service.format = .v1
        let registry = AgentRegistry.shared
        if registry.paused { registry.setPaused(false) }
        service.settleDelay = .seconds(600)
        let folder = AppPaths.support

        // MARK: Stand-ins
        let reader = DistillWhoReader()
        service.model = { reader }
        let standIn = RouterStandIn()
        let standIns = RouterStandIns()
        standIns.byChoice[.tev1] = standIn
        controller.router.models = DecisionModels(choice: .tev1, measures: DecisionMeasureStore(url: folder.appendingPathComponent("who-test-measures.json")),
                                                  fingerprints: FolderFingerprints(url: folder.appendingPathComponent("who-test-fingerprints.json")),
                                                  makeBackend: { standIns.make($0) })
        controller.router.budget = .seconds(3)

        let web = BinderRecord(name: "Web", colorIndex: 2)
        let elsewhere = BinderRecord(name: "Elsewhere", colorIndex: 3)
        let home = BinderRecord(name: "Home", colorIndex: 4)
        for binder in [web, elsewhere, home] { store.insert(binder) }
        // Agents that check the board themselves: none is ever woken by a command.
        let echo = AgentProfile(name: "Echo", wake: .board, binders: [web.id], purpose: "the checkout's web pages and payments")
        let penny = AgentProfile(name: "Penny", wake: .board, binders: [web.id], kinds: ["writing"])
        let other = AgentProfile(name: "Other", wake: .board, binders: [elsewhere.id], purpose: "builds and releases")
        for agent in [echo, penny, other] { run.check(registry.upsert(agent) == nil, "\(agent.name) is saved") }
        service.teamPeopleOverride = { binder in binder == web.id ? ["Sam"] : [] }

        let note = NoteItem(text: DistillWhoReader.noteText)
        note.binderID = web.id
        store.insert(note)
        service.setDistill(true, for: note)

        // MARK: What the reader is told
        let who = service.takers(for: web.id)
        run.check(who.names == ["Echo", "Penny", "You", "Sam"], "who can take work in Web: \(who.names)")
        // The decision model: sure no agent fits a footer by its title alone, sure it's Echo's with its brief.
        let footer = DistillWhoReader.items[3]
        standIn.set(footer.title, agent: [RouterQuestions.nobody: 0.96])
        standIn.set(DistillWhoState.state(title: footer.title, brief: footer.brief), agent: ["Echo": 0.98])
        let first = await service.distill(note)
        guard case .success(var proposal) = first else {
            run.check(false, "the stand-in reader reads the note: \(first)")
            return 1
        }
        // Lane DS8: who the decision model suggests comes after the proposal.
        await service.suggestionsDone(proposal.id)
        proposal = DistillStore.shared.distill(proposal.id, of: note.id) ?? proposal
        let system = reader.systems.first ?? ""
        run.check(system.contains(#"- "Echo", an AI agent: the checkout's web pages and payments."# + "\n"),
                  "the reader is told Echo's name and what it's for")
        run.check(system.contains(#"- "Penny", an AI agent: Kinds of work: writing."#), "Penny's kinds of work, with no What it's for")
        run.check(system.contains(#"- "You": "#) && system.contains(#"- "Sam": a teammate."#), "you and the team's people")
        run.check(!system.contains("Other"), "not an agent that doesn't take Web's cards")
        run.check(system.contains("even if a person approves it at the end") && !system.contains(DistillPrompt.forLine),
                  "for: a name, an agent even when a person approves at the end")
        run.check(reader.schemas.first.map { $0.contains(#""enum":["Echo","Penny","You","Sam","agent","person","either"]"#) } == true,
                  "held to the schema, for is one of the names or the three words")
        run.check(reader.portables.first.map { $0.contains(#""for":{"type":"string"}"#) } == true, "the portable schema's for is a string")

        func meant(_ title: String) -> String {
            proposal.items.first { $0.title == title }.map { "\($0.meantFor ?? "no one") by \($0.meantForHow ?? "-")" } ?? "missing"
        }
        let titles = DistillWhoReader.items.map(\.title)
        run.check(meant(titles[0]) == "Echo by reader", "an agent named in for, with space and in another case: \(meant(titles[0]))")
        run.check(meant(titles[1]) == "Penny by reader", "an agent with no What it's for, named: \(meant(titles[1]))")
        run.check(meant(titles[2]) == "You by reader", "\"person\": you, as before: \(meant(titles[2]))")
        run.check(meant(titles[3]) == "Echo by model", "\"either\": the decision model, reading the brief too: \(meant(titles[3]))")
        run.check(standIn.asked.contains { $0.state == DistillWhoState.state(title: footer.title, brief: footer.brief) && $0.state.contains("\n") },
                  "the decision model was asked with the title and the brief's start")
        run.check(meant(titles[4]) == "no one by -", "a name that's no one here: the decision model, unsure, no one: \(meant(titles[4]))")
        run.check(meant(titles[5]) == "Sam by reader", "a teammate named in for: \(meant(titles[5]))")
        run.check(meant(titles[6]) == "no one by -", "an agent that doesn't take Web's cards isn't used: \(meant(titles[6]))")
        run.check(meant(titles[7]) == "You by reader", "\"You\": you: \(meant(titles[7]))")
        run.check(board.cards(in: web.id).isEmpty, "nothing is on the board before Place on Board")
        run.check(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("echo.txt").path), "and nothing woke an agent")

        // MARK: The review sheet's words
        func picked(_ item: DistillItem) -> String? {
            DistillMeantFor.pickedLine(how: item.meantForHow, meantFor: item.meantFor, readBy: proposal.readBy, readByAgent: proposal.readByAgent)
        }
        run.check(picked(proposal.items[0]) == "Picked by the reader" && picked(proposal.items[3]) == "Suggested by the decision model"
                  && picked(proposal.items[4]) == nil, "For says who picked: the reader, the decision model, nothing for no one")
        let noPurpose = DistillMeantFor.noPurposeLine(service.withoutPurpose(in: web.id))
        run.check(noPurpose == "Penny has no What it's for, so Distill can only guess what to give it.", "the sheet names Penny: \(noPurpose ?? "nothing")")
        run.check(DistillMeantFor.noPurposeLine(service.withoutPurpose(in: elsewhere.id)) == nil, "and says nothing where every agent has one")

        // MARK: Suggest Who Again: only the blanks, never what you chose
        var reviewed = proposal
        let zed = reviewed.items[4], release = reviewed.items[6]
        // You left the release build with no one: Suggest Who Again leaves it so.
        reviewed.items[6].meantForHow = "you"
        // You chose Sam for the form instead.
        reviewed.items[0].meantFor = "Sam"
        reviewed.items[0].meantForHow = "you"
        service.save(reviewed)
        standIn.set(zed.title, agent: ["Penny": 0.98])
        standIn.set(release.title, agent: ["Echo": 0.98])
        let again = await service.suggestAgain(reviewed.items, binder: web.id)
        func after(_ index: Int) -> String { "\(again.items[index].meantFor ?? "no one") by \(again.items[index].meantForHow ?? "-")" }
        run.check(again.filled == 1 && after(4) == "Penny by model", "Suggest Who Again fills the blank: \(after(4)), \(again.filled) filled")
        run.check(after(6) == "no one by you", "not one you left with no one: \(after(6))")
        run.check(after(0) == "Sam by you" && after(5) == "Sam by reader" && after(2) == "You by reader", "nor any you or the reader chose")
        run.check(DistillReviewSheet.suggestedLine(filled: 1, asked: 1) == "Suggested who for 1 item."
                  && DistillReviewSheet.suggestedLine(filled: 0, asked: 2).hasPrefix("The decision model had no suggestion"),
                  "the sheet says what it found")
        service.dismiss(reviewed)

        // MARK: No agents, no team: the prompt as before
        let plain = NoteItem(text: DistillWhoReader.noteText)
        plain.binderID = home.id
        store.insert(plain)
        service.setDistill(true, for: plain)
        let before = reader.systems.count
        _ = await service.distill(plain)
        run.check(service.takers(for: home.id).isEmpty, "no one takes Home's work")
        run.check(reader.systems.count > before && reader.systems[before...].allSatisfy { $0 == DistillPrompt.system },
                  "so the reader's instructions are exactly as before")
        run.check(reader.schemas.last.map { $0 == DistillSchema.json(headings: DistillSections.sections(of: plain.text).compactMap(\.heading)) } == true,
                  "and so is the schema")

        // MARK: Put on Board: the decision model reads the card's details too
        let launch = NoteItem(text: "# Post the launch\n\nWrite it for the blog and the newsletter, then share it.")
        launch.binderID = web.id
        store.insert(launch)
        let launchState = "Post the launch\nWrite it for the blog and the newsletter, then share it."
        standIn.set(launchState, agent: ["Penny": 0.98])
        let card = board.create(from: launch, by: .you)
        controller.router.suggestLater(for: card, origin: .toBoard)
        for _ in 0..<30 where card.meantFor == nil { try? await Task.sleep(for: .milliseconds(100)) }
        run.check(standIn.asked.contains { $0.state == launchState }, "Put on Board asks with the title and the details' start, without the link back")
        run.check(card.meantFor == "Penny" && card.meantForByAgent && !board.timeline(card.id).contains { $0.kind == .woke },
                  "and suggests Penny, never starting her")
        run.check(CardRouter.state(for: card, origin: .mcp) == nil, "a card made another way is read by its title, as before")

        // MARK: Distill with…: the card lists who can take work
        if case .success(let request) = service.distill(note, with: echo) {
            run.check(request.details.contains("Who can take work in this binder:\n- \"Echo\", an AI agent: the checkout's web pages and payments.")
                      && request.details.contains("- \"Sam\": a teammate.") && request.details.contains("one of the names listed below"),
                      "the card asking Echo to distill lists who can take work")
            run.check(!request.details.contains(folder.path), "with no paths")
        } else {
            run.check(false, "Distill with Echo makes its card")
        }

        service.teamPeopleOverride = nil
        return run.failures == 0 ? 0 : 1
    }
}

/// The reader stand-in for `--selftest-distill-who`: it notes each question's instructions and schemas, and answers with
/// items meant for an agent, a teammate, "person", "either", someone who isn't here and an agent of another binder.
final class DistillWhoReader: LLMClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _systems: [String] = []
    private var _schemas: [String] = []
    private var _portables: [String] = []
    var systems: [String] { lock.withLock { _systems } }
    var schemas: [String] { lock.withLock { _schemas } }
    var portables: [String] { lock.withLock { _portables } }

    var model: String { "stand-in" }

    static let noteText = """
        # Launch

        ## Site

        The signup form, the footer and the fonts.

        ## Launch

        The post, the venue, the pricing copy, the release build and the dinner.
        """

    struct Item {
        var title: String
        var brief: String
        var section: String
        var forWord: String
    }

    static let items = [
        Item(title: "Build the signup form", brief: "Visitors can sign up on the site.", section: "Site", forWord: "  echo "),
        Item(title: "Draft the launch post", brief: "A post for the blog.", section: "Launch", forWord: "Penny"),
        Item(title: "Sign the venue contract", brief: "Someone signs for the venue.", section: "Launch", forWord: "person"),
        Item(title: "Tidy the footer links", brief: "Fix the broken links in the checkout's web pages.", section: "Site", forWord: "either"),
        Item(title: "Ask Zed about fonts", brief: "Which fonts we may use.", section: "Site", forWord: "Zed"),
        Item(title: "Review the pricing copy", brief: "Read the pricing page through.", section: "Launch", forWord: "sam"),
        Item(title: "Ship the release build", brief: "Build and release it.", section: "Launch", forWord: "Other"),
        Item(title: "Book the launch dinner", brief: "A table for the team.", section: "Launch", forWord: "You"),
    ]

    static var reply: String {
        let objects = items.map { item -> [String: Any] in
            ["title": item.title, "brief": item.brief, "done_when": "It's done.", "section": item.section, "quote": "", "waits_for": [Int](),
             "size": "small", "for": item.forWord]
        }
        let data = (try? JSONSerialization.data(withJSONObject: objects)) ?? Data("[]".utf8)
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    func complete(system: String, user: String, maxTokens: Int, temperature: Double, timeout: TimeInterval) async throws -> String {
        lock.withLock { _systems.append(system) }
        return Self.reply
    }

    func stream(system: String, user: String, maxTokens: Int, temperature: Double, timeout: TimeInterval,
                stopWhen: @escaping @Sendable (String) -> Bool) async throws -> String {
        lock.withLock { _systems.append(system) }
        return Self.reply
    }

    func stream(system: String, user: String, maxTokens: Int, temperature: Double, timeout: TimeInterval, schema: ReplySchema,
                stopWhen: @escaping @Sendable (String) -> Bool, onText: @escaping @Sendable (String) -> Void) async throws -> SchemaReply {
        lock.withLock {
            _systems.append(system)
            _schemas.append(schema.bounded)
            _portables.append(schema.portable)
        }
        return SchemaReply(text: Self.reply, held: true, why: nil)
    }

    func listModels() async throws -> [String] { [model] }
    func warmUp() async {}
}
