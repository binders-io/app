import XCTest
@testable import BindersKit

/// The JSON schema Distill's replies are held to (lane DS3), and reading the object it makes.
final class DistillSchemaTests: XCTestCase {
    private func object(_ json: String) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any], json)
    }

    private func item(_ schema: [String: Any]) throws -> [String: Any] {
        let items = try XCTUnwrap((schema["properties"] as? [String: Any])?["items"] as? [String: Any])
        return try XCTUnwrap(items["items"] as? [String: Any])
    }

    private func field(_ name: String, _ schema: [String: Any]) throws -> [String: Any] {
        try XCTUnwrap((try item(schema)["properties"] as? [String: Any])?[name] as? [String: Any], name)
    }

    private func headings(_ spec: DistillBench.Spec) -> [String] {
        DistillSections.sections(of: spec.text).compactMap(\.heading)
    }

    func testTheShapeMatchesThePromptsFields() throws {
        let schema = try object(DistillSchema.json(headings: ["Payment form", "Rollout"]))
        XCTAssertEqual(schema["type"] as? String, "object")
        XCTAssertEqual(schema["required"] as? [String], ["items"])
        XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
        let list = try XCTUnwrap((schema["properties"] as? [String: Any])?["items"] as? [String: Any])
        XCTAssertEqual(list["type"] as? String, "array")
        XCTAssertEqual(list["maxItems"] as? Int, DistillPrompt.maxItems)
        let item = try item(schema)
        let fields = ["title", "brief", "done_when", "section", "quote", "waits_for", "size", "for"]
        XCTAssertEqual(Set((item["properties"] as? [String: Any])?.keys.map { $0 } ?? []), Set(fields))
        XCTAssertEqual(item["required"] as? [String], fields, "every field, in the prompt's order")
        XCTAssertEqual(item["additionalProperties"] as? Bool, false)
        XCTAssertEqual(try field("size", schema)["enum"] as? [String], ["small", "medium", "large"])
        XCTAssertEqual(try field("for", schema)["enum"] as? [String], ["agent", "person", "either"])
        let waits = try field("waits_for", schema)
        XCTAssertEqual(waits["type"] as? String, "array")
        XCTAssertEqual((waits["items"] as? [String: Any])?["type"] as? String, "integer")
        XCTAssertEqual((waits["items"] as? [String: Any])?["minimum"] as? Int, 1)
        XCTAssertNil(try field("title", schema)["maxLength"], "no lengths: xgrammar compiles them slowly")
        XCTAssertFalse(DistillSchema.json(headings: ["A"]).contains("maxLength"))
        // The text keeps the prompt's order, which a grammar writes them in.
        let text = DistillSchema.json(headings: [])
        let positions = fields.compactMap { text.range(of: "\"\($0)\":{")?.lowerBound }
        XCTAssertEqual(positions.count, fields.count)
        XCTAssertEqual(positions, positions.sorted())
    }

    func testHeadingsBecomeTheSectionsEnum() throws {
        let schema = try object(DistillSchema.json(headings: ["Goal", "Payment form", "", "Goal", "Rollout"]))
        XCTAssertEqual(try field("section", schema)["enum"] as? [String], ["Goal", "Payment form", "Rollout", ""],
                       "in order, repeats and empty ones left out, the opening last")
        XCTAssertEqual(try field("section", schema)["type"] as? String, "string")
    }

    func testANoteWithNoHeadingsHasOnlyTheOpening() throws {
        let schema = try object(DistillSchema.json(headings: []))
        XCTAssertEqual(try field("section", schema)["enum"] as? [String], [""])
        XCTAssertEqual(DistillSchema.sections([]), [""])
    }

    func testHeadingsAreEscaped() throws {
        let odd = ["Say \"hello\"", #"Paths like C:\temp and a/b"#, "Tabs\tand ünïcödé", "Ação: <b>bold</b> & {braces} [1]"]
        let json = DistillSchema.json(headings: odd)
        let schema = try object(json)
        XCTAssertEqual(try field("section", schema)["enum"] as? [String], odd + [""])
        XCTAssertTrue(json.contains(#"Say \"hello\""#))
        XCTAssertTrue(json.contains(#"a/b"#), "slashes left as they are")
    }

    func testPortableLeavesOutLengthsAndCounts() throws {
        let json = DistillSchema.json(headings: ["A"], bounded: false)
        for word in ["maxLength", "maxItems", "minimum", "maximum"] { XCTAssertFalse(json.contains(word), word) }
        let schema = try object(json)
        XCTAssertEqual(try field("section", schema)["enum"] as? [String], ["A", ""])
        XCTAssertEqual(try item(schema)["additionalProperties"] as? Bool, false, "strict mode wants every object closed")
    }

    func testReadInPartsAWaitMayNameATitle() throws {
        let schema = try object(DistillSchema.json(headings: ["A"], waitsByTitle: true))
        let waits = try field("waits_for", schema)
        let choices = try XCTUnwrap((waits["items"] as? [String: Any])?["anyOf"] as? [[String: Any]])
        XCTAssertEqual(choices.compactMap { $0["type"] as? String }, ["integer", "string"])
    }

    func testAnAskCarriesTheNotesHeadings() async throws {
        let spec = DistillBench.specs[0]
        let asked = AskLog()
        _ = try await DistillRun.read(title: "Checkout redesign", text: spec.text, budget: DistillBudget.forContext(nil)) { ask in
            await asked.add(ask)
            return DistillSchemaTests.reply
        }
        let first = await asked.asks.first
        let ask = try XCTUnwrap(first)
        XCTAssertEqual(ask.headings, headings(spec))
        let schema = try object(ask.schema(bounded: true))
        XCTAssertEqual(try field("section", schema)["enum"] as? [String], headings(spec) + [""])
        XCTAssertNil((try field("waits_for", schema)["items"] as? [String: Any])?["anyOf"], "read whole, a wait is a number")
        XCTAssertFalse(ask.stopWhenHeld(String(repeating: "x", count: 50_000)), "a reply held to the schema isn't stopped for its length")
        XCTAssertTrue(ask.stopWhen(String(repeating: "x", count: 50_000)))
    }

    // MARK: Reading the object

    static let reply = """
        {"items": [
          {"title": "Combine checkout into one page", "brief": "Address, delivery and card together.", "done_when": "Checkout is one page.", "section": "Payment form", "waits_for": [], "size": "medium", "for": "agent"},
          {"title": "Ship behind a flag to 10% of visitors", "brief": "Once the form is done.", "done_when": "10% see it.", "section": "Rollout", "waits_for": [1], "size": "small", "for": "agent"},
          {"title": "Decide on 100%", "brief": "Compare abandonment, then decide.", "done_when": "Decided.", "section": "Rollout", "waits_for": [2], "size": "small", "for": "person"}
        ]}
        """

    func testTheObjectIsReadAsTheListIs() {
        let spec = DistillBench.specs[0]
        let read = DistillReading.read(Self.reply, headings: headings(spec))
        XCTAssertFalse(read.noList)
        XCTAssertFalse(read.cutOff)
        XCTAssertEqual(read.items.map(\.title), ["Combine checkout into one page", "Ship behind a flag to 10% of visitors", "Decide on 100%"])
        XCTAssertEqual(read.items.map(\.section), ["Payment form", "Rollout", "Rollout"])
        XCTAssertEqual(read.items.map(\.waitsFor), [[], [0], [1]])
        XCTAssertEqual(read.items.last?.hint, .person)
        // The same items as a bare list read the same.
        let bare = DistillReading.read(Self.reply.replacingOccurrences(of: "{\"items\": [", with: "[").replacingOccurrences(of: "]}", with: "]"),
                                       headings: headings(spec))
        XCTAssertEqual(bare.items, read.items)
    }

    func testAnEmptyObjectIsNoWorkNotNoList() {
        for reply in [#"{"items": []}"#, #"{"items":[]}"#, "{\n  \"items\": [\n  ]\n}"] {
            let read = DistillReading.read(reply, headings: [])
            XCTAssertFalse(read.noList, reply)
            XCTAssertTrue(read.items.isEmpty, reply)
        }
    }

    func testAnObjectCutOffKeepsItsWholeItems() {
        let cut = String(Self.reply.prefix(upTo: Self.reply.range(of: "{\"title\": \"Decide")!.upperBound)) + "on a hundred"
        let read = DistillReading.read(cut, headings: headings(DistillBench.specs[0]))
        XCTAssertTrue(read.cutOff)
        XCTAssertEqual(read.items.count, 2)
    }

    func testAStringWithBracketsDoesntConfuseTheReader() {
        let reply = #"{"items":[{"title":"Fix [the] link","brief":"See {this}.","done_when":"Fixed.","section":"","waits_for":[],"size":"small","for":"agent"}]}"#
        let read = DistillReading.read(reply, headings: [])
        XCTAssertEqual(read.items.map(\.title), ["Fix [the] link"])
        XCTAssertNil(read.items.first?.section)
    }

    // MARK: The bench's note shapes

    func testTheShapesGoldIsFoundByACarefulReply() throws {
        XCTAssertEqual(DistillBench.shapes.map(\.name), ["Dictated, no headings", "To-do list", "Meeting summary"])
        for spec in DistillBench.shapes {
            let items: [[String: Any]] = spec.gold.map { gold in
                ["title": gold.words.joined(separator: " "), "brief": "", "done_when": "", "section": gold.section ?? "",
                 "waits_for": gold.waits.map { $0 + 1 }, "size": "small", "for": gold.person ? "person" : "agent"]
            }
            let reply = String(decoding: try JSONSerialization.data(withJSONObject: ["items": items]), as: UTF8.self)
            let score = DistillBench.score(DistillReading.read(reply, headings: headings(spec)), spec: spec)
            XCTAssertEqual(score.found, spec.gold.count, spec.name)
            XCTAssertEqual(score.rightSection, spec.gold.count, spec.name)
            XCTAssertEqual(score.waitsFound, score.waitsPossible, spec.name)
            XCTAssertEqual(score.personSaid, score.personFound, spec.name)
            XCTAssertFalse(score.emptyOnWork)
        }
        XCTAssertTrue(DistillBench.shapes.allSatisfy { headings($0).isEmpty || $0.name == "Meeting summary" },
                      "the dictated note and the list have no headings")
    }

    func testAFalseEmptyIsCounted() {
        let spec = DistillBench.shapes[0]
        let score = DistillBench.score(DistillReading.read(#"{"items": []}"#, headings: []), spec: spec)
        XCTAssertTrue(score.emptyOnWork)
        let documentation = DistillBench.specs.first { $0.gold.isEmpty }!
        XCTAssertFalse(DistillBench.score(DistillReading.read("[]", headings: []), spec: documentation).emptyOnWork,
                       "nothing in a note that asks for nothing is right")
        XCTAssertTrue(DistillBench.summary([score]).last?.hasPrefix("no work found in a note that asks for some: 1 of 1") == true)
    }
}

private actor AskLog {
    var asks: [DistillRun.Ask] = []
    func add(_ ask: DistillRun.Ask) { asks.append(ask) }
}
