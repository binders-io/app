import XCTest
@testable import BindersKit

final class AutomationTests: XCTestCase {
    // Tuesday 15 September 2026, 10:00 local.
    private var now: Date {
        var components = DateComponents()
        components.year = 2026; components.month = 9; components.day = 15; components.hour = 10
        return Calendar.current.date(from: components)!
    }

    func testPhraseRemainder() {
        XCTAssertEqual(AutomationTemplate.remainder(of: "Send to Things buy milk tomorrow.", afterPhrase: "send to things"), "buy milk tomorrow")
        XCTAssertEqual(AutomationTemplate.remainder(of: "hey send to things: buy milk", afterPhrase: "send to things"), "buy milk")
        XCTAssertEqual(AutomationTemplate.remainder(of: "Start focus mode", afterPhrase: "start focus mode"), "")
        XCTAssertNil(AutomationTemplate.remainder(of: "send to thingsville", afterPhrase: "send to things"))
        XCTAssertNil(AutomationTemplate.remainder(of: "please send to things buy milk", afterPhrase: "send to things"))
        XCTAssertNil(AutomationTemplate.remainder(of: "anything", afterPhrase: "   "))
    }

    func testSpokenPayloadSplitsTheTime() {
        let payload = AutomationPayload.spoken("buy milk tomorrow at 3 pm", now: now)
        XCTAssertEqual(payload.text, "buy milk tomorrow at 3 pm")
        XCTAssertEqual(payload.title, "buy milk")
        XCTAssertEqual(payload.when, "tomorrow at 3 pm")
        XCTAssertTrue(payload.date.hasPrefix("2026-09-16T15:00:00"), payload.date)

        let plain = AutomationPayload.spoken("buy milk", now: now)
        XCTAssertEqual(plain.title, "buy milk")
        XCTAssertEqual(plain.when, "")
        XCTAssertEqual(plain.date, "")
    }

    func testTemplatesAndEncodings() {
        let payload = AutomationPayload(text: "buy milk & eggs", title: "buy milk", when: "tomorrow", app: "Slack")
        XCTAssertEqual(AutomationTemplate.render("{title} ({when}) from {app}", payload: payload), "buy milk (tomorrow) from Slack")
        XCTAssertEqual(AutomationTemplate.render("things:///add?title={text}", payload: payload, encode: AutomationTemplate.percentEncoded),
                       "things:///add?title=buy%20milk%20%26%20eggs")
        let body = AutomationTemplate.render(#"{"content":"{text}","said":"{note}"}"#, payload: AutomationPayload(text: "He said \"go\"\nnow"),
                                             encode: AutomationTemplate.jsonEscaped)
        XCTAssertEqual(body, #"{"content":"He said \"go\"\nnow","said":"{note}"}"#)
        XCTAssertNotNil(try? JSONSerialization.jsonObject(with: Data(body.utf8)))
    }

    func testRulesRoundTripAsJSON() throws {
        let rules = [
            AutomationRule(name: "Things", trigger: .phrase(text: "send to things"), action: .openURL(template: "things:///add?title={text}")),
            AutomationRule(name: "Notes to Notion", isEnabled: false, trigger: .event(name: .meetingReady),
                           action: .shortcut(name: "File meeting", input: "{title}\n{summary}")),
            AutomationRule(name: "Ping", trigger: .event(name: .todoAdded), action: .webhook(url: "https://example.test/hook", body: "")),
            AutomationRule(name: "Log", trigger: .phrase(text: "log"), action: .script(command: "echo \"$BINDERS_TEXT\" >> ~/log.txt")),
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(rules)
        let decoded = try JSONDecoder().decode([AutomationRule].self, from: data)
        XCTAssertEqual(decoded, rules)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("\"phrase\""), "the file should read like what it is")
        XCTAssertTrue(text.contains("\"meetingReady\""))
    }
}

final class MCPCoreTests: XCTestCase {
    private let tools = [
        MCPTool(name: "search", description: "Search", parameters: [
            MCPToolParameter(name: "query", description: "What to look for", required: true),
            MCPToolParameter(name: "limit", type: "integer", description: "How many"),
        ]),
    ]

    private func handle(_ message: [String: Any], call: @escaping (String, [String: Any]) async throws -> String = { _, _ in "ok" }) async -> [String: Any]? {
        await MCPCore.handle(message, serverName: "binders", serverVersion: "0.2.0", instructions: "Test.", tools: tools, call: call)
    }

    func testInitializeEchoesASupportedVersion() async {
        let reply = await handle(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-03-26"]])
        let result = reply?["result"] as? [String: Any]
        XCTAssertEqual(result?["protocolVersion"] as? String, "2025-03-26")
        XCTAssertEqual((result?["serverInfo"] as? [String: Any])?["name"] as? String, "binders")
        XCTAssertNotNil((result?["capabilities"] as? [String: Any])?["tools"])

        let unknown = await handle(["jsonrpc": "2.0", "id": 2, "method": "initialize", "params": ["protocolVersion": "1999-01-01"]])
        XCTAssertEqual((unknown?["result"] as? [String: Any])?["protocolVersion"] as? String, "2025-06-18")
    }

    func testNotificationsGetNoReply() async {
        let reply = await handle(["jsonrpc": "2.0", "method": "notifications/initialized"])
        XCTAssertNil(reply)
    }

    func testToolsListDescribesParameters() async {
        let reply = await handle(["jsonrpc": "2.0", "id": "a", "method": "tools/list"])
        let list = (reply?["result"] as? [String: Any])?["tools"] as? [[String: Any]]
        XCTAssertEqual(list?.count, 1)
        let schema = list?.first?["inputSchema"] as? [String: Any]
        XCTAssertEqual(schema?["required"] as? [String], ["query"])
        let limit = (schema?["properties"] as? [String: Any])?["limit"] as? [String: Any]
        XCTAssertEqual(limit?["type"] as? String, "integer")
    }

    func testToolsCallRunsTheToolAndReportsFailures() async {
        let ok = await handle(["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": ["name": "search", "arguments": ["query": "pricing"]]]) { name, arguments in
            "\(name):\(arguments["query"] as? String ?? "")"
        }
        let content = ((ok?["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first
        XCTAssertEqual(content?["text"] as? String, "search:pricing")
        XCTAssertEqual((ok?["result"] as? [String: Any])?["isError"] as? Bool, false)

        let failed = await handle(["jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": ["name": "search", "arguments": [:]]]) { _, _ in
            throw MCPCore.ToolFailure("query is required")
        }
        XCTAssertEqual((failed?["result"] as? [String: Any])?["isError"] as? Bool, true)

        let missing = await handle(["jsonrpc": "2.0", "id": 5, "method": "tools/call", "params": ["name": "nope"]])
        XCTAssertEqual((missing?["error"] as? [String: Any])?["code"] as? Int, -32602)
    }

    func testUnknownMethodAndParseError() async {
        let reply = await handle(["jsonrpc": "2.0", "id": 6, "method": "something/else"])
        XCTAssertEqual((reply?["error"] as? [String: Any])?["code"] as? Int, -32601)
        XCTAssertEqual((MCPCore.parseError()["error"] as? [String: Any])?["code"] as? Int, -32700)
    }
}
