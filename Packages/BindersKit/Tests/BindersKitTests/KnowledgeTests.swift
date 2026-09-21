import XCTest
@testable import BindersKit

final class KnowledgeChunkerTests: XCTestCase {
    func testGroupsParagraphsUpToLimit() {
        let text = (1...6).map { "Paragraph \($0) " + String(repeating: "word ", count: 40) }.joined(separator: "\n")
        let chunks = KnowledgeChunker.chunks(text, maxWords: 100, label: "Summary")
        XCTAssertEqual(chunks.count, 3)
        XCTAssertTrue(chunks.allSatisfy { $0.speaker == "Summary" })
        XCTAssertTrue(chunks[0].text.hasPrefix("Paragraph 1"))
    }

    func testSplitsLongMonologues() {
        let long = (1...30).map { "Sentence number \($0) has several words in it." }.joined(separator: " ")
        let chunks = KnowledgeChunker.chunks(long, maxWords: 50)
        XCTAssertGreaterThan(chunks.count, 3)
        XCTAssertTrue(chunks.allSatisfy { $0.text.split(whereSeparator: \.isWhitespace).count <= 50 })
    }

    func testTranscriptChunksKeepTimestampsAndSpeakers() {
        let blocks = [
            TranscriptBlock(speaker: "Dana", start: 0, end: 5, text: String(repeating: "alpha ", count: 60)),
            TranscriptBlock(speaker: "You", start: 5, end: 9, text: String(repeating: "beta ", count: 60)),
            TranscriptBlock(speaker: "Dana", start: 65, end: 70, text: "Short reply."),
        ]
        let chunks = KnowledgeChunker.transcriptChunks(blocks, maxWords: 100)
        XCTAssertEqual(chunks.count, 2)
        XCTAssertEqual(chunks[0].startTime, 0)
        XCTAssertEqual(chunks[0].speaker, "Dana")
        XCTAssertEqual(chunks[1].startTime, 5)
        XCTAssertTrue(chunks[1].text.contains("Dana: Short reply."))
    }
}

final class RetrievalTests: XCTestCase {
    func testTopMatchesAndFusion() {
        let candidates: [(id: Int, vector: [Float])] = [
            (1, VectorMath.normalized([1, 0, 0])),
            (2, VectorMath.normalized([0.7, 0.7, 0])),
            (3, VectorMath.normalized([0, 0, 1])),
        ]
        let matches = VectorMath.topMatches(query: [2, 0.1, 0], candidates: candidates, limit: 2, minScore: 0.2)
        XCTAssertEqual(matches.map(\.id), [1, 2])

        let fused = RankFusion.reciprocalRank([[10, 20, 30], [30, 10, 40]])
        XCTAssertEqual(fused.first?.id, 10)
        XCTAssertEqual(Set(fused.map(\.id)), [10, 20, 30, 40])
        XCTAssertLessThan(fused.firstIndex { $0.id == 30 }!, fused.firstIndex { $0.id == 20 }!)
    }
}

final class EntityExtractionTests: XCTestCase {
    func testParsesFencedJsonAndCleans() {
        let output = """
        ```json
        {"entities":[{"name":"Daniel","type":"person"},{"name":"Apple Pay","type":"Product","aliases":["apple pay support"]},
        {"name":"the meeting","type":"topic"},{"name":"apple pay","type":"topic"},{"name":"Q3 Roadmap.","type":"weird"}],
        "relations":[{"from":"Daniel","to":"q3 roadmap","label":"owns"},{"from":"Daniel","to":"Nobody","label":"likes"}]}
        ```
        """
        let result = EntityExtraction.parse(output)
        XCTAssertEqual(result.entities.map(\.name), ["Daniel", "Apple Pay", "Q3 Roadmap"])
        XCTAssertEqual(result.entities[1].type, "product")
        XCTAssertEqual(result.entities[1].aliases, ["apple pay support"])
        XCTAssertEqual(result.entities[2].type, "topic")
        XCTAssertEqual(result.relations, [ExtractedRelation(from: "Daniel", to: "Q3 Roadmap", label: "owns")])
    }

    func testSalvagesRepliesWithOneMalformedObject() {
        // Real gemma4 output: the "Marketing" object is missing `":` after aliases, which breaks strict JSON decoding.
        let output = #"{"entities":[{"name":"Daniel","type":"person","aliases":[]},{"name":"Mobile App","type":"product","aliases":["new mobile app"]},{"name":"Apple Pay","type":"product","aliases":[]},{"name":"Product","type":"team","aliases":["product team"]},{"name":"Marketing","type":"team","aliases[]},{"name":"Payments Integration","type":"project","aliases":["payments integration"]}],"relations":[{"from":"Daniel","to":"Mobile App","label":"is developing"},{"from":"Daniel","to":"Product","label":"works with"}]}"#
        let result = EntityExtraction.parse(output)
        XCTAssertEqual(result.entities.map(\.name), ["Daniel", "Mobile App", "Apple Pay", "Marketing", "Payments Integration"])
        XCTAssertEqual(result.entities[1].aliases, ["new mobile app"])
        XCTAssertEqual(result.entities[3].type, "team")
        XCTAssertEqual(result.relations, [ExtractedRelation(from: "Daniel", to: "Mobile App", label: "is developing")])
    }

    func testGarbageYieldsEmptyResult() {
        XCTAssertEqual(EntityExtraction.parse("Sorry, I can't help with that."), ExtractionResult())
    }

    func testNormalizationAndWholeWordMatching() {
        XCTAssertEqual(EntityExtraction.normalize("The Q3 Roadmap!"), "q3 roadmap")
        XCTAssertEqual(EntityExtraction.normalize("Café Déjà"), "cafe deja")
        let haystack = EntityExtraction.haystack("We shipped Apple Pay; the applepay team cheered.")
        XCTAssertTrue(EntityExtraction.contains(haystack: haystack, key: "apple pay"))
        XCTAssertFalse(EntityExtraction.contains(haystack: haystack, key: "pay team"))
        XCTAssertFalse(EntityExtraction.contains(haystack: haystack, key: "apple payments"))
    }

    func testWikiLinks() {
        XCTAssertEqual(WikiLinks.targets(in: "Ask [[Dana]] about [[Q3 Roadmap|the roadmap]] and [[dana]] again"), ["Dana", "Q3 Roadmap"])
    }
}

final class KnowledgeIntentTests: XCTestCase {
    func testDetectsLookups() {
        XCTAssertEqual(KnowledgeQueryIntent.query(from: "Look up the beta tester list."), "the beta tester list")
        XCTAssertEqual(KnowledgeQueryIntent.query(from: "search my meetings for Apple Pay"), "Apple Pay")
        XCTAssertEqual(KnowledgeQueryIntent.query(from: "Remind me about the pricing experiment"), "the pricing experiment")
        XCTAssertEqual(KnowledgeQueryIntent.query(from: "What did we decide about Apple Pay?"), "What did we decide about Apple Pay")
        XCTAssertEqual(KnowledgeQueryIntent.query(from: "who was in the standup yesterday"), "who was in the standup yesterday")
        XCTAssertEqual(KnowledgeQueryIntent.query(from: "Who owns the beta tester list?"), "Who owns the beta tester list")
        XCTAssertEqual(KnowledgeQueryIntent.query(from: "when is the announcement email due"), "when is the announcement email due")
        XCTAssertTrue(KnowledgeQueryIntent.isQuestion("what's Daniel working on"))
        XCTAssertFalse(KnowledgeQueryIntent.isQuestion("make this shorter"))
    }

    func testIgnoresEditingCommands() {
        XCTAssertNil(KnowledgeQueryIntent.query(from: "make this more concise"))
        XCTAssertNil(KnowledgeQueryIntent.query(from: "search google for ramen"))
        XCTAssertNil(KnowledgeQueryIntent.query(from: "what is the capital of France"))
    }

    func testAnswerPromptNumbersSources() {
        let prompt = KnowledgePrompts.answerUserPrompt(question: "When?", contexts: [
            KnowledgeContext(label: "Meeting A", text: "Ship Oct 15"),
            KnowledgeContext(label: "Note B", text: "Beta list"),
        ])
        XCTAssertTrue(prompt.contains("[1] Meeting A\nShip Oct 15"))
        XCTAssertTrue(prompt.contains("[2] Note B\nBeta list"))
        XCTAssertTrue(prompt.hasSuffix("Question: When?"))
    }
}

final class GraphLayoutTests: XCTestCase {
    func testLayoutIsBoundedDeterministicAndPullsLinkedNodesTogether() {
        let nodes = (0..<12).map { GraphNode(id: "n\($0)", weight: 1) }
        let edges = [GraphEdge(from: "n0", to: "n1", weight: 3), GraphEdge(from: "n1", to: "n2")]
        let first = GraphLayout.layout(nodes: nodes, edges: edges)
        let second = GraphLayout.layout(nodes: nodes, edges: edges)
        XCTAssertEqual(first.count, 12)
        for point in first.values {
            XCTAssertTrue((0...1).contains(point.x) && (0...1).contains(point.y))
            XCTAssertFalse(point.x.isNaN || point.y.isNaN)
        }
        XCTAssertEqual(first["n5"], second["n5"])
        func distance(_ a: String, _ b: String) -> Double {
            let d = first[a]! - first[b]!
            return (d.x * d.x + d.y * d.y).squareRoot()
        }
        XCTAssertLessThan(distance("n0", "n1"), distance("n0", "n7"))
    }

    func testDisconnectedGroupsStayTogetherAndKeepLabelMargin() {
        // A star of ten around one meeting, plus a separate meeting with two entities.
        var nodes = [GraphNode(id: "a", weight: 10), GraphNode(id: "b", weight: 2)]
        var edges: [GraphEdge] = []
        for index in 0..<10 {
            nodes.append(GraphNode(id: "a\(index)", weight: 1))
            edges.append(GraphEdge(from: "a", to: "a\(index)"))
        }
        for index in 0..<2 {
            nodes.append(GraphNode(id: "b\(index)", weight: 1))
            edges.append(GraphEdge(from: "b", to: "b\(index)"))
        }
        let layout = GraphLayout.layout(nodes: nodes, edges: edges)
        let hubs = layout["a"]! - layout["b"]!
        XCTAssertLessThan((hubs.x * hubs.x + hubs.y * hubs.y).squareRoot(), 0.8)
        for point in layout.values {
            XCTAssertTrue((0.1...0.9).contains(point.x) && (0.1...0.9).contains(point.y))
        }
    }
}

final class GraphSimulationTests: XCTestCase {
    private func sample() -> ([GraphNode], [GraphEdge]) {
        let nodes = (0..<12).map { GraphNode(id: "n\($0)", weight: Double($0 % 3 + 1)) }
        // Two clusters of six, one link between them.
        var edges: [GraphEdge] = []
        for cluster in [0, 6] { for i in 1..<6 { edges.append(GraphEdge(from: "n\(cluster)", to: "n\(cluster + i)")) } }
        edges.append(GraphEdge(from: "n0", to: "n6"))
        return (nodes, edges)
    }

    func testBloomsSpreadsAndSettlesWithLinkedNodesCloser() {
        let (nodes, edges) = sample()
        var simulation = GraphSimulation(nodes: nodes, edges: edges)
        let start = simulation.positions
        XCTAssertLessThan(hypot(start[3].x - 0.5, start[3].y - 0.5), 0.1)
        var lastSpeed = 1.0
        for _ in 0..<400 { lastSpeed = simulation.step() }
        XCTAssertTrue(simulation.isSettled)
        XCTAssertLessThan(lastSpeed, 1e-3)
        let p = simulation.positions
        for i in 0..<p.count {
            XCTAssertTrue((0.06...0.94).contains(p[i].x) && (0.06...0.94).contains(p[i].y))
            for j in (i + 1)..<p.count { XCTAssertGreaterThan(hypot(p[i].x - p[j].x, p[i].y - p[j].y), 0.02) }
        }
        func mean(_ pairs: [(Int, Int)]) -> Double {
            pairs.map { hypot(p[$0.0].x - p[$0.1].x, p[$0.0].y - p[$0.1].y) }.reduce(0, +) / Double(pairs.count)
        }
        let within = mean((1...5).flatMap { i in (1...5).filter { $0 > i }.map { (i, $0) } })      // leaves of the first cluster
        let across = mean((1...5).flatMap { i in (7...11).map { (i, $0) } })                      // leaves across the two clusters
        XCTAssertLessThan(within, across)
    }

    func testPinnedNodeStaysAndScatterRestartsTheBloom() {
        let (nodes, edges) = sample()
        var simulation = GraphSimulation(nodes: nodes, edges: edges)
        simulation.pin(4, at: SIMD2(0.2, 0.8))
        for _ in 0..<200 { simulation.step() }
        XCTAssertEqual(simulation.positions[4], SIMD2(0.2, 0.8))
        simulation.release(4)
        simulation.reheat()
        XCTAssertFalse(simulation.isSettled)
        for _ in 0..<50 { simulation.step() }
        XCTAssertNotEqual(simulation.positions[4], SIMD2(0.2, 0.8))
        simulation.scatter()
        XCTAssertLessThan(hypot(simulation.positions[9].x - 0.5, simulation.positions[9].y - 0.5), 0.1)
        XCTAssertEqual(simulation.index(of: "n7"), 7)
        var empty = GraphSimulation(nodes: [], edges: [])
        XCTAssertEqual(empty.step(), 0)
    }
}
