import XCTest
@testable import BindersKit

final class HubBrainTests: XCTestCase {
    func testReadsAnAnswerWithItsSourcesAndCitesThem() throws {
        let json = """
        {"answer":{"text":"It ships Friday, and Sam books the garage.","parts":[{"text":"It ships Friday","sources":[2]},{"text":", and Sam books the garage.","sources":[1,2]}]},
         "sources":[{"n":1,"binder":"web","binderName":"Web","kind":"note","id":"note-cap-1","title":"Van tyres","context":"Web › Captures","text":"Sam will book","url":"https://hub.test/web/#/notes/note-cap-1"},
                    {"n":2,"binder":"web","binderName":"Web","kind":"card","id":"card-1","title":"Ship it","text":"Friday","url":"https://hub.test/web/#/work/card-1"}],
         "model":"claude-opus-5-5 (Anthropic)","searchedBy":"words and meaning"}
        """
        let answer = try XCTUnwrap(HubBrain.answer(from: Data(json.utf8)))
        XCTAssertEqual(answer.sources.map(\.item), ["note-cap-1", "card-1"])
        XCTAssertEqual(answer.sources[1].context, nil)
        XCTAssertEqual(HubBrain.citedText(try XCTUnwrap(answer.answer)), "It ships Friday [2], and Sam books the garage. [1, 2]")
        XCTAssertEqual(answer.model, "claude-opus-5-5 (Anthropic)")
    }

    func testSaysWhyThereIsNoAnswer() throws {
        let bare = try XCTUnwrap(HubBrain.answer(from: Data(#"{"sources":[],"searchedBy":"words"}"#.utf8)))
        XCTAssertEqual(bare.noAnswerLine, "Nothing in your binders matches that.")
        let failed = try XCTUnwrap(HubBrain.answer(from: Data(#"{"sources":[{"n":1,"binder":"b","binderName":"B","kind":"note","id":"n","title":"T","text":"x","url":"u"}],"searchedBy":"words","problem":"Anthropic is busy."}"#.utf8)))
        XCTAssertEqual(failed.noAnswerLine, "No answer: Anthropic is busy. The passages that match best:")
    }

    func testACaptureRequestKeepsToWhatTheHubTakes() throws {
        let long = String(repeating: "x", count: 400)
        let request = HubCaptureRequest(kind: "meeting", text: "words", title: long, recordedAt: Date(timeIntervalSince1970: 0), durationSeconds: -3,
                                        device: "Mac", speakers: Array(repeating: "Ana", count: 30), sourceId: "mac-meeting-1")
        XCTAssertEqual(request.title?.count, 300)
        XCTAssertEqual(request.durationSeconds, 0)
        XCTAssertEqual(request.speakers?.count, 20)
        XCTAssertEqual(request.recordedAt, "1970-01-01T00:00:00.000Z")
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any]
        XCTAssertEqual(encoded?["sourceId"] as? String, "mac-meeting-1")
        XCTAssertNil(encoded?["folder"], "nothing sent for what isn't set")
    }

    func testWritesATranscriptWithWhoSaidWhat() {
        let segments = [TranscriptSegment(channel: .microphone, start: 0, end: 3, text: "We need tyres.", speaker: "Speaker 1"),
                        TranscriptSegment(channel: .microphone, start: 65, end: 70, text: "I'll book it.", speaker: "Speaker 2")]
        let text = HubCaptureRequest.transcript(segments, names: ["Speaker 1": "You"])
        XCTAssertTrue(text.contains("You:** We need tyres."), text)
        XCTAssertTrue(text.contains("Speaker 2:** I'll book it."), text)
    }
}
