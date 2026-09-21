import XCTest
@testable import BindersKit

final class SpeechChunkerTests: XCTestCase {
    private func tone(_ seconds: Double, amplitude: Float = 0.2) -> [Float] {
        (0..<Int(seconds * 16_000)).map { Float(sin(Double($0) * 0.07)) * amplitude }
    }

    private func silence(_ seconds: Double) -> [Float] {
        [Float](repeating: 0, count: Int(seconds * 16_000))
    }

    func testWaitsForMoreAudioWhenNoPause() {
        let audio = tone(6)
        XCTAssertNil(SpeechChunker.nextBoundary(audio[...]))
    }

    func testSplitsInsideAPauseAfterMinimumLength() {
        let audio = tone(4) + silence(1) + tone(3)
        let boundary = SpeechChunker.nextBoundary(audio[...])!
        XCTAssertGreaterThan(boundary, 4 * 16_000)
        XCTAssertLessThan(boundary, 5 * 16_000)
    }

    func testIgnoresPausesBeforeMinimumLength() {
        let audio = tone(1) + silence(1) + tone(2)
        XCTAssertNil(SpeechChunker.nextBoundary(audio[...]))
    }

    func testForcesSplitAtMaximumLength() {
        let audio = tone(30)
        let boundary = SpeechChunker.nextBoundary(audio[...])!
        XCTAssertLessThanOrEqual(boundary, 25 * 16_000)
        XCTAssertGreaterThan(boundary, 19 * 16_000)
    }

    func testFinalFlushTakesEverything() {
        let audio = tone(2)
        XCTAssertEqual(SpeechChunker.nextBoundary(audio[...], isFinal: true), audio.count)
    }

    func testWorksOnSlicesWithOffsetIndices() {
        let audio = tone(10) + tone(4) + silence(1) + tone(2)
        let slice = audio[(10 * 16_000)...]
        let boundary = SpeechChunker.nextBoundary(slice)!
        XCTAssertGreaterThan(boundary, 4 * 16_000)
        XCTAssertLessThan(boundary, 5 * 16_000)
    }
}

final class MeetingPostProcessingTests: XCTestCase {
    func testEchoFilterDropsLeakedRemoteSpeech() {
        let segments = [
            TranscriptSegment(channel: .system, start: 0, end: 6, text: "Can everyone see my screen with the quarterly numbers"),
            TranscriptSegment(channel: .microphone, start: 0.4, end: 6.2, text: "everyone see my screen with the quarterly numbers"),
            TranscriptSegment(channel: .microphone, start: 7, end: 9, text: "Yes, looks good to me"),
        ]
        let filtered = EchoFilter.removeEcho(from: segments)
        XCTAssertEqual(filtered.map(\.text), ["Can everyone see my screen with the quarterly numbers", "Yes, looks good to me"])
    }

    func testEchoFilterKeepsShortRepliesOverLongerSpeech() {
        let segments = [
            TranscriptSegment(channel: .system, start: 0, end: 8, text: "So yeah we agreed to ship on Friday and then review metrics"),
            TranscriptSegment(channel: .microphone, start: 3, end: 3.5, text: "Yeah."),
        ]
        XCTAssertEqual(EchoFilter.removeEcho(from: segments).count, 2)
    }

    func testSpeakerAssignmentByOverlap() {
        let segments = [
            TranscriptSegment(channel: .system, start: 0, end: 4, text: "Hi, I'm Dana."),
            TranscriptSegment(channel: .microphone, start: 4, end: 6, text: "Hey Dana."),
            TranscriptSegment(channel: .system, start: 6, end: 10, text: "And I'm Lee."),
            TranscriptSegment(channel: .system, start: 10, end: 12, text: "Great to meet you."),
        ]
        let turns = [
            SpeakerTurn(speakerID: "S7", start: 0, end: 4.5),
            SpeakerTurn(speakerID: "S2", start: 5.8, end: 10.2),
            SpeakerTurn(speakerID: "S7", start: 10.2, end: 12),
        ]
        let labeled = SpeakerAssigner.assign(segments, turns: turns, channel: .system)
        XCTAssertEqual(labeled.map(\.speaker), ["Speaker 1", "You", "Speaker 2", "Speaker 1"])
    }

    func testSpeakerTurnsMergeDropBlipsAndClipOverlaps() {
        let turns = [
            SpeakerTurn(speakerID: "B", start: 0, end: 3),
            SpeakerTurn(speakerID: "B", start: 3.4, end: 6),
            SpeakerTurn(speakerID: "A", start: 6.1, end: 6.3),
            SpeakerTurn(speakerID: "A", start: 5.5, end: 9),
            SpeakerTurn(speakerID: "B", start: 9.2, end: 12),
        ]
        let merged = SpeakerTurns.merge(turns)
        XCTAssertEqual(merged, [
            SpeakerTurn(speakerID: "B", start: 0, end: 6),
            SpeakerTurn(speakerID: "A", start: 6, end: 9),
            SpeakerTurn(speakerID: "B", start: 9.2, end: 12),
        ])
        XCTAssertEqual(SpeakerTurns.labels(for: merged), ["B": "Speaker 1", "A": "Speaker 2"])
    }

    func testBlocksMergeAndApplyNames() {
        let segments = [
            TranscriptSegment(channel: .system, start: 0, end: 3, text: "First.", speaker: "Speaker 1"),
            TranscriptSegment(channel: .system, start: 3.5, end: 5, text: "Second.", speaker: "Speaker 1"),
            TranscriptSegment(channel: .microphone, start: 6, end: 7, text: "Mine."),
        ]
        let blocks = TranscriptFormatter.blocks(segments, names: ["Speaker 1": "Dana"])
        XCTAssertEqual(blocks.map(\.speaker), ["Dana", "You"])
        XCTAssertEqual(blocks.first?.text, "First. Second.")
        XCTAssertEqual(TranscriptFormatter.plainText(segments, names: ["Speaker 1": "Dana"]), "[00:00] Dana: First. Second.\n[00:06] You: Mine.")
        XCTAssertEqual(TranscriptFormatter.timestamp(3_725), "1:02:05")
    }

    func testSummaryParserExtractsTitleAndSpeakers() {
        let output = """
        <think>planning</think>
        # Q3 launch planning with design

        ## Decisions
        - Launch moves to November

        SPEAKERS: Speaker 1=Dana; speaker 2=Lee; Speaker 3=Unknown
        """
        let parsed = SummaryParser.parse(output)
        XCTAssertEqual(parsed.title, "Q3 launch planning with design")
        XCTAssertEqual(parsed.body, "## Decisions\n- Launch moves to November")
        XCTAssertEqual(parsed.speakerNames, ["Speaker 1": "Dana", "Speaker 2": "Lee"])
    }

    func testCleanTitle() {
        XCTAssertEqual(MeetingPrompts.cleanTitle("Title: \"Q3 Launch Sync.\"\n"), "Q3 Launch Sync")
        XCTAssertEqual(MeetingPrompts.cleanTitle("## Hiring plan review"), "Hiring plan review")
        XCTAssertNil(MeetingPrompts.cleanTitle("   "))
    }

    func testSummaryParserWithoutTitle() {
        let parsed = SummaryParser.parse("## Summary\nShort chat.")
        XCTAssertNil(parsed.title)
        XCTAssertEqual(parsed.body, "## Summary\nShort chat.")
    }

    func testMarkdownExport() {
        let markdown = MeetingMarkdown.document(
            title: "Sync", dateText: "Sep 13", duration: 1_500, appName: "Zoom", attendees: ["Dana"],
            summary: "## Summary\nAll good.", notes: "ask about budget",
            segments: [TranscriptSegment(channel: .microphone, start: 65, end: 67, text: "Hello")], names: [:])
        XCTAssertTrue(markdown.hasPrefix("# Sync\n\n*Sep 13 · 25 min · Zoom*"))
        XCTAssertTrue(markdown.contains("**Attendees:** Dana"))
        XCTAssertTrue(markdown.contains("## My notes\n\nask about budget"))
        XCTAssertTrue(markdown.contains("**[01:05] You:** Hello"))
    }

    func testMeetingDetectorPrefersNativeApps() {
        XCTAssertEqual(MeetingDetector.meetingApp(capturingInput: ["com.google.Chrome.helper", "us.zoom.xos"])?.name, "Zoom")
        XCTAssertEqual(MeetingDetector.meetingApp(capturingInput: ["com.google.Chrome.helper"])?.name, "Chrome (web meeting)")
        XCTAssertNil(MeetingDetector.meetingApp(capturingInput: ["com.apple.VoiceMemos", "io.binders.mac"]))
    }

    func testPromptsIncludeNotesAndTemplate() {
        let system = MeetingPrompts.summarySystemPrompt(template: .standup)
        XCTAssertTrue(system.contains("## Updates by person"))
        let user = MeetingPrompts.summaryUserPrompt(title: "Standup", date: nil, appName: "Zoom", attendees: ["Dana"],
                                                    userNotes: "blockers!", transcript: "[00:00] You: hi")
        XCTAssertTrue(user.contains("blockers!"))
        XCTAssertTrue(user.contains("Attendees: Dana"))
        XCTAssertEqual(MeetingTemplate.template(id: "nope"), .general)
    }
}
