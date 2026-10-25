import XCTest
@testable import BindersKit

/// Who Distill's reader is told can take work (lane AS1): the prompt's block, the schema's names, reading names, who
/// picked, and what the decision model reads.
final class DistillTakersTests: XCTestCase {
    private let takers = DistillTakers(
        agents: [DistillTakers.Agent(name: "Echo", whatFor: "the checkout's web pages and payments", kinds: "coding"),
                 DistillTakers.Agent(name: "Penny", whatFor: nil, kinds: "writing, outreach"),
                 DistillTakers.Agent(name: "Quiet", whatFor: nil, kinds: nil)],
        people: ["Sam"])

    private func object(_ json: String) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any], json)
    }

    private func forField(_ json: String) throws -> [String: Any] {
        let schema = try object(json)
        let items = try XCTUnwrap((schema["properties"] as? [String: Any])?["items"] as? [String: Any])
        let item = try XCTUnwrap(items["items"] as? [String: Any])
        return try XCTUnwrap((item["properties"] as? [String: Any])?["for"] as? [String: Any])
    }

    // MARK: The prompt

    func testNoOneListedLeavesThePromptAsItWas() {
        XCTAssertTrue(DistillPrompt.system.contains(DistillPrompt.forLine), "the line `system(who:)` replaces is in the prompt")
        XCTAssertEqual(DistillPrompt.system(who: nil), DistillPrompt.system)
        XCTAssertEqual(DistillPrompt.system(who: .none), DistillPrompt.system)
        XCTAssertEqual(DistillPrompt.system(who: DistillTakers(agents: [], people: ["  ", "You", "person"])), DistillPrompt.system,
                       "nobody but you and the words: as before")
        XCTAssertNil(DistillTakers.none.block)
        XCTAssertEqual(DistillTakers.none.names, [])
    }

    func testTheBlockListsAgentsYouAndTeammates() throws {
        let system = DistillPrompt.system(who: takers)
        let block = try XCTUnwrap(takers.block)
        XCTAssertTrue(system.contains(block + "\n\nRules:\n"), "the list comes before the rules")
        XCTAssertFalse(system.contains(DistillPrompt.forLine), "for no longer says only agent, person or either")
        XCTAssertTrue(system.contains(takers.forLine))
        XCTAssertTrue(block.contains(#"- "Echo", an AI agent: the checkout's web pages and payments. Kinds of work: coding."#), block)
        XCTAssertTrue(block.contains(#"- "Penny", an AI agent: Kinds of work: writing, outreach."#), block)
        XCTAssertTrue(block.contains(#"- "Quiet", an AI agent: nothing says what it's for."#), block)
        XCTAssertTrue(block.contains(#"- "You": "#), block)
        XCTAssertTrue(block.contains(#"- "Sam": a teammate."#), block)
        XCTAssertTrue(takers.forLine.contains("even if a person approves it at the end"))
        XCTAssertTrue(takers.forLine.contains("Name a teammate when the note says the work is theirs."))
        XCTAssertTrue(takers.forLine.contains(#""person" if it needs a human"#))
        // Without teammates, nothing about them; without agents, nothing about agents.
        let alone = DistillTakers(agents: takers.agents, people: [])
        XCTAssertFalse(alone.forLine.contains("teammate"))
        let teamOnly = DistillTakers(agents: [], people: ["Sam"])
        XCTAssertFalse(teamOnly.forLine.contains("Name an agent"))
        XCTAssertEqual(teamOnly.names, ["You", "Sam"])
    }

    func testNamesAreTrimmedOnceEachAndWhatItsForIsCut() {
        let long = String(repeating: "word ", count: 60)
        let list = DistillTakers(agents: [DistillTakers.Agent(name: " Echo ", whatFor: long, kinds: nil),
                                          DistillTakers.Agent(name: "echo", whatFor: "again", kinds: nil),
                                          DistillTakers.Agent(name: "Either", whatFor: "a word", kinds: nil)],
                                 people: ["Sam", "sam", "ECHO", "Two\nlines"])
        XCTAssertEqual(list.agents.map(\.name), ["Echo"])
        XCTAssertEqual(list.people, ["Sam"])
        XCTAssertEqual(list.names, ["Echo", "You", "Sam"])
        XCTAssertEqual(list.others, ["Echo", "Sam"])
        let what = list.agents[0].whatFor ?? ""
        XCTAssertLessThanOrEqual(what.count, DistillTakers.whatForLimit + 1)
        XCTAssertTrue(what.hasSuffix("…"))
    }

    func testAnAgentFromItsProfile() {
        let typed = AgentProfile(name: "Echo", wake: .board, purpose: "  the web shop  ", kinds: ["coding", "research"])
        XCTAssertEqual(DistillTakers.Agent(typed), DistillTakers.Agent(name: "Echo", whatFor: "the web shop", kinds: "coding, research"))
        let derived = AgentProfile(name: "Coder", wake: .claudeCode(ClaudeCodeWake(repository: "/Users/someone/Code/shop/")))
        let agent = DistillTakers.Agent(derived)
        XCTAssertEqual(agent.whatFor, "code in the shop repository")
        XCTAssertFalse(DistillTakers(agents: [agent], people: []).block?.contains("/Users") ?? true, "no paths")
    }

    // MARK: The schema

    func testHeldToTheSchemaForIsOneOfTheNames() throws {
        let held = try forField(DistillSchema.json(headings: ["A"], names: takers.names))
        XCTAssertEqual(held["enum"] as? [String], ["Echo", "Penny", "Quiet", "You", "Sam", "agent", "person", "either"])
        let portable = try forField(DistillSchema.json(headings: ["A"], bounded: false, names: takers.names))
        XCTAssertEqual(portable["type"] as? String, "string")
        XCTAssertNil(portable["enum"], "the portable form stays a string")
        // No one listed: exactly as before.
        XCTAssertEqual(DistillSchema.json(headings: ["A"], names: []), DistillSchema.json(headings: ["A"]))
        XCTAssertEqual(try forField(DistillSchema.json(headings: ["A"]))["enum"] as? [String], ["agent", "person", "either"])
    }

    func testAnAskCarriesWhoAndTheBudgetMakesRoom() async throws {
        let spec = DistillBench.specs[0]
        let asked = WhoAskLog()
        _ = try await DistillRun.read(title: "Checkout redesign", text: spec.text, budget: DistillBudget.forContext(nil), who: takers) { ask in
            await asked.add(ask)
            return DistillSchemaTests.reply
        }
        let firstAsk = await asked.asks.first
        let ask = try XCTUnwrap(firstAsk)
        XCTAssertEqual(ask.system, DistillPrompt.system(who: takers))
        XCTAssertEqual(try forField(ask.schema(bounded: true))["enum"] as? [String], DistillSchema.forNames(takers.names))
        // No one: the ask is as it was.
        let before = WhoAskLog()
        _ = try await DistillRun.read(title: "Checkout redesign", text: spec.text, budget: DistillBudget.forContext(nil), who: .none) { ask in
            await before.add(ask)
            return DistillSchemaTests.reply
        }
        let firstPlain = await before.asks.first
        let plain = try XCTUnwrap(firstPlain)
        XCTAssertEqual(plain.system, DistillPrompt.system)
        XCTAssertNil(plain.who)
        XCTAssertEqual(plain.schema(bounded: true), DistillSchema.json(headings: plain.headings))
        // In a small context, a part holds less once the list takes room in the instructions.
        let small = DistillBudget.forContext(7_000)
        let text = "# Long\n\n" + (1...40).map { "## Part \($0)\n\n" + String(repeating: "Words about part \($0). ", count: 12) }.joined(separator: "\n\n")
        let none = try await DistillRun.read(title: "Long", text: text, budget: small) { _ in "[]" }
        let many = DistillTakers(agents: (1...12).map { DistillTakers.Agent(name: "Agent \($0)", whatFor: String(repeating: "does things ", count: 12), kinds: nil) },
                                 people: [])
        let listed = try await DistillRun.read(title: "Long", text: text, budget: small, who: many) { _ in "[]" }
        XCTAssertLessThan(listed.capacity, none.capacity, "the list's room comes out of each part")
    }

    // MARK: Reading `for`

    func testNamesAreReadWhateverTheirCaseAndSpace() {
        let reply = """
            [{"title": "Build the form", "for": "  echo "},
             {"title": "Write the post", "for": "Bot"},
             {"title": "Call the bank", "for": "person"},
             {"title": "Tidy the copy", "for": "either"},
             {"title": "Ask Zed", "for": "Zed"},
             {"title": "Decide", "for": "You"}]
            """
        let read = DistillReading.read(reply, headings: [], names: ["Echo", "Bot", "Sam"])
        XCTAssertEqual(read.items.map(\.forName), ["Echo", "Bot", nil, nil, "Zed", nil])
        XCTAssertEqual(read.items.map(\.hint), [.either, .either, .person, .either, .either, .person], "a name reads as either, as before")
        // Without names, "Bot" is the loose word for an agent, as before.
        XCTAssertEqual(DistillReading.read(reply, headings: []).items[1].hint, .agent)
        XCTAssertEqual(DistillReading.read(reply, headings: []).items[0].forName, "echo")
    }

    // MARK: Precedence

    func testTheReadersNameWinsThenPersonThenTheModel() {
        let here = ["Echo", "Sam"]
        func resolve(_ name: String) -> String? { DistillWho.match(name, among: here) }
        XCTAssertEqual(DistillMeantFor.reader(hint: nil, name: "echo", resolve: resolve), .named("Echo"))
        XCTAssertEqual(DistillMeantFor.reader(hint: .either, name: "sam", resolve: resolve), .named("Sam"))
        XCTAssertEqual(DistillMeantFor.reader(hint: .person, name: nil, resolve: resolve), .you)
        XCTAssertEqual(DistillMeantFor.reader(hint: .agent, name: nil, resolve: resolve), .ask)
        XCTAssertEqual(DistillMeantFor.reader(hint: .either, name: nil, resolve: resolve), .ask)
        XCTAssertEqual(DistillMeantFor.reader(hint: .either, name: "Zed", resolve: resolve), .ask, "a name that's no one here: the model")
        XCTAssertEqual(DistillMeantFor.reader(hint: nil, name: nil, resolve: resolve), .ask)
    }

    func testWhoPickedInAFewWords() {
        XCTAssertEqual(DistillMeantFor.pickedLine(how: "reader", meantFor: "Echo", readBy: "qwen3", readByAgent: false), "Picked by the reader")
        XCTAssertEqual(DistillMeantFor.pickedLine(how: "reader", meantFor: "Echo", readBy: "Scribe", readByAgent: true), "Picked by Scribe")
        XCTAssertEqual(DistillMeantFor.pickedLine(how: "model", meantFor: "You", readBy: "qwen3", readByAgent: false), "Suggested by the decision model")
        XCTAssertEqual(DistillMeantFor.pickedLine(how: "you", meantFor: "Sam", readBy: "qwen3", readByAgent: false), "Your choice")
        XCTAssertNil(DistillMeantFor.pickedLine(how: "you", meantFor: nil, readBy: "qwen3", readByAgent: false))
        XCTAssertNil(DistillMeantFor.pickedLine(how: nil, meantFor: "Echo", readBy: "qwen3", readByAgent: false))
        XCTAssertEqual(DistillMeantFor.noPurposeLine(["Penny"]), "Penny has no What it's for, so Distill can only guess what to give it.")
        XCTAssertEqual(DistillMeantFor.noPurposeLine(["Penny", "Coder"]), "Penny and Coder have no What it's for, so Distill can only guess what to give them.")
        XCTAssertEqual(DistillMeantFor.noPurposeLine(["A", "B", "C"]), "A, B and C have no What it's for, so Distill can only guess what to give them.")
        XCTAssertNil(DistillMeantFor.noPurposeLine([]))
    }

    // MARK: What the decision model reads

    func testTheStateIsTheTitleAndTheBriefsStart() {
        XCTAssertEqual(DistillWhoState.state(title: "Post the launch", brief: ""), "Post the launch")
        XCTAssertEqual(DistillWhoState.state(title: "Post the launch", brief: "Write it for **LinkedIn**, see [the plan](https://x.y)."),
                       "Post the launch\nWrite it for LinkedIn, see the plan.")
        let long = (1...60).map { "Sentence \($0) says a little more." }.joined(separator: " ")
        let state = DistillWhoState.state(title: "T", brief: long)
        XCTAssertLessThanOrEqual(state.count, DistillWhoState.briefLimit + 3)
        XCTAssertLessThan(state.count, RouterQuestions.stateLimit / 2)
        XCTAssertTrue(state.hasSuffix("more."), "cut at a sentence's end: \(state.suffix(30))")
        let words = String(repeating: "word ", count: 200)
        XCTAssertTrue(DistillWhoState.state(title: "T", brief: words).hasSuffix("word…"))
    }

    func testACardsStateLeavesBinderslinesOut() {
        let id = UUID()
        let whole = NoteCards.details(text: "# Fix the mobile menu\n\nIt overlaps the logo.", noteID: id.uuidString)
        XCTAssertEqual(DistillWhoState.cardState(title: "Fix the mobile menu", details: whole), "Fix the mobile menu\nIt overlaps the logo.")
        let piece = NoteSelectionCards.pieces(text: "# Plan\n\n## Launch\n\n- Post the launch on the blog\n", selection: NSRange(location: 19, length: 28),
                                              noteID: id, eachLine: false)
        XCTAssertEqual(piece.count, 1)
        XCTAssertEqual(DistillWhoState.cardState(title: piece[0].title, details: piece[0].details), piece[0].title, "only its title: its words are its title")
        let agents = NoteCards.details(text: "# A\n\nB", noteID: id.uuidString, agent: AgentMark(madeBy: "Helper"))
        XCTAssertEqual(DistillWhoState.cardState(title: "A", details: agents), "A")
        XCTAssertEqual(DistillWhoState.cardState(title: "A", details: "Placed by Echo, which the binder lets place work items: no one has reviewed it yet.\n\nDo it.\n\n**Done when:** done.\n\nDistilled from [N](binders://note/x)"),
                       "A\nDo it. Done when: done.")
    }

    // MARK: The card asking an agent to distill

    func testTheRequestCardListsWhoCanTakeWork() {
        let id = UUID()
        let plain = DistillCards.requestDetails(noteText: "# N\n\nText", note: id)
        XCTAssertEqual(DistillCards.requestDetails(noteText: "# N\n\nText", note: id, who: .none), plain, "no one listed: as before")
        XCTAssertTrue(plain.contains("for (agent, person or either)"))
        let listed = DistillCards.requestDetails(noteText: "# N\n\nText", note: id, who: takers)
        XCTAssertTrue(listed.contains("Who can take work in this binder:\n- \"Echo\", an AI agent: the checkout's web pages and payments."), listed)
        XCTAssertTrue(listed.contains("one of the names listed below"))
        XCTAssertTrue(listed.contains("- \"Sam\": a teammate."))
        XCTAssertTrue(listed.hasSuffix("Text"))
    }
}

private actor WhoAskLog {
    var asks: [DistillRun.Ask] = []
    func add(_ ask: DistillRun.Ask) { asks.append(ask) }
}
