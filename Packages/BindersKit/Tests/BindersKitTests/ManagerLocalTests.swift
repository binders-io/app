import XCTest
@testable import BindersKit

final class ManagerLocalTests: XCTestCase {
    private let moveItem: [String: Any] = [
        "name": "move_item", "description": "Moves a note or folder.",
        "inputSchema": ["type": "object", "required": ["item"],
                        "properties": ["item": ["type": "string", "description": "Its id."],
                                       "folder": ["type": "string", "description": "Where to."],
                                       "limit": ["type": "integer"], "pinned": ["type": "boolean"], "ids": ["type": "array"],
                                       "column": ["type": "string", "enum": ["backlog", "ready"]]]],
    ]

    func testAToolIsReadFromItsListing() throws {
        let tool = try XCTUnwrap(ManagerLocal.Tool(listed: moveItem))
        XCTAssertEqual(tool.name, "move_item")
        XCTAssertEqual(tool.arguments.first?.name, "item", "required arguments come first")
        XCTAssertEqual(tool.arguments.first { $0.name == "column" }?.options, ["backlog", "ready"])
        XCTAssertNil(ManagerLocal.Tool(listed: ["description": "no name"]))
        let system = ManagerLocal.system(tools: [tool])
        XCTAssertTrue(system.contains("- move_item: Moves a note or folder. Arguments: item (string, required): Its id."))
        XCTAssertTrue(system.contains("column (string, one of backlog / ready)"))
    }

    func testArgumentsTakeTheirTypes() throws {
        let tool = try XCTUnwrap(ManagerLocal.Tool(listed: moveItem))
        let typed = tool.typed(["item": " A1 ", "limit": "3", "pinned": "yes", "ids": "a, b", "unknown": "x", "folder": ""])
        XCTAssertEqual(typed["item"] as? String, "A1")
        XCTAssertEqual(typed["limit"] as? Int, 3)
        XCTAssertEqual(typed["pinned"] as? Bool, true)
        XCTAssertEqual(typed["ids"] as? [String], ["a", "b"])
        XCTAssertNil(typed["unknown"], "a name the tool doesn't take is left out")
        XCTAssertNil(typed["folder"], "an empty value is left out")
        XCTAssertEqual(tool.typed(["ids": #"["x","y"]"#])["ids"] as? [String], ["x", "y"])
        XCTAssertNil(tool.typed(["limit": "many"])["limit"])
    }

    func testStepsAreReadAsTheSchemaHasThemAndAsModelsWriteThem() {
        XCTAssertEqual(ManagerLocal.parse(#"{"action":"call","tool":"list_tasks","arguments":[{"name":"binder","value":"Work"}],"reply":""}"#),
                       .call(tool: "list_tasks", arguments: ["binder": "Work"]))
        XCTAssertEqual(ManagerLocal.parse(#"{"action":"reply","tool":"","arguments":[],"reply":" Done. "}"#), .reply("Done."))
        XCTAssertEqual(ManagerLocal.parse("Sure!\n```json\n{\"tool\": \"mcp__binders__get_task\", \"arguments\": {\"id\": \"C1\", \"n\": 2, \"all\": true}}\n```"),
                       .call(tool: "get_task", arguments: ["id": "C1", "n": "2", "all": "true"]))
        XCTAssertEqual(ManagerLocal.parse(#"{"name": "list_binders"}"#), .call(tool: "list_binders", arguments: [:]))
        XCTAssertEqual(ManagerLocal.parse(#"{"reply": "All tidy."}"#), .reply("All tidy."))
        XCTAssertEqual(ManagerLocal.parse(#"I'll use {braces} then {"tool":"list_notes","arguments":"{\"binder\":\"Home\"}"}"#),
                       .call(tool: "list_notes", arguments: ["binder": "Home"]), "a stray brace before the step, and arguments as text")
        XCTAssertEqual(ManagerLocal.parse(#"{"action":"reply","reply":"Says {not a step} inside"}"#), .reply("Says {not a step} inside"))
        XCTAssertNil(ManagerLocal.parse("I'm not sure what to do."))
        XCTAssertNil(ManagerLocal.parse(#"{"action":"reply","reply":""}"#))
    }

    func testTheSchemaHoldsTheToolToOneOffered() throws {
        let text = ManagerLocal.schema(tools: ["list_tasks", "reply"], bounded: false)
        let schema = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        XCTAssertEqual((properties["tool"] as? [String: Any])?["enum"] as? [String], ["", "list_tasks", "reply"])
        XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
        XCTAssertEqual(Set(schema["required"] as? [String] ?? []), ["action", "tool", "arguments", "reply"])
        XCTAssertFalse(text.contains("maxLength"), "the portable schema has no lengths")
        XCTAssertTrue(ManagerLocal.schema(tools: [], bounded: true).contains("maxItems"))
    }

    func testOlderStepsAreCutThenLeftOutToFit() {
        let long = String(repeating: "x", count: 3_000)
        let turns = (1...6).map { ManagerLocal.Turn(tool: "get_note", arguments: ["id": "N\($0)"], answer: "note \($0) " + long) }
        let whole = ManagerLocal.user(request: "Tidy Work", turns: turns, budget: 100_000, last: false)
        XCTAssertTrue(whole.contains("1. get_note(id=\"N1\") →"))
        XCTAssertTrue(whole.hasSuffix("What's your next step? One JSON object."))
        let cut = ManagerLocal.user(request: "Tidy Work", turns: turns, budget: 9_000, last: false)
        XCTAssertLessThanOrEqual(cut.count, 9_000)
        XCTAssertTrue(cut.contains("6. get_note(id=\"N6\")") && cut.contains("5. get_note"), "the latest steps stay")
        XCTAssertTrue(cut.contains("Tidy Work"), "the request always stays")
        let tight = ManagerLocal.user(request: "Tidy Work", turns: turns, budget: 4_000, last: true)
        XCTAssertTrue(tight.contains("earlier steps left out to fit"))
        XCTAssertFalse(tight.contains("1. get_note"))
        XCTAssertTrue(tight.contains("You've used all \(ManagerLocal.maxSteps) tool calls"))
        let chatty = ManagerLocal.user(request: "Tidy Work. " + String(repeating: "earlier ", count: 2_000), turns: turns, budget: 6_000, last: false)
        XCTAssertLessThanOrEqual(chatty.count, 6_000, "a long conversation is cut too")
        XCTAssertTrue(chatty.contains("Tidy Work.") && chatty.contains("cut to fit"))
        XCTAssertTrue(chatty.contains("6. get_note"), "the last step stays, its answer cut")
        XCTAssertEqual(ManagerLocal.user(request: "Hi", turns: [], budget: 1_000, last: false),
                       "The request, as get_request gives it:\nHi\n\nWhat's your first step? One JSON object.")
    }

    func testALocalModelIsKeptAndTakesNoCards() throws {
        let agent = AgentProfile(name: "Manager", wake: .localModel(LocalModelWake(model: " qwen3:14b ")), manager: true)
        let data = try JSONEncoder().encode(agent)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains(#""localModel":{"model":" qwen3:14b "}"#))
        let read = try JSONDecoder().decode(AgentProfile.self, from: data)
        XCTAssertEqual(read, agent)
        XCTAssertEqual(read.wake.kind, "localModel")
        if case .localModel(let wake) = read.wake { XCTAssertEqual(wake.namedModel, "qwen3:14b") } else { XCTFail() }
        XCTAssertNil(LocalModelWake(model: "  ").namedModel)
        XCTAssertFalse(agent.takesCards(from: nil))
        XCTAssertFalse(agent.takesCards(from: UUID()))
        XCTAssertEqual(agent.workKinds, [])
        XCTAssertNil(agent.whatItsFor)
        XCTAssertNotEqual(AgentConsent.fingerprint(agent, reads: AgentReads()),
                          AgentConsent.fingerprint(AgentProfile(id: agent.id, name: "Manager", wake: .localModel(LocalModelWake(model: "llama3"))), reads: AgentReads()),
                          "another model asks again")
    }
}
