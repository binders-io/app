import XCTest
@testable import BindersKit

final class LoopGuardTests: XCTestCase {
    func testStopsOnceALineRepeatsThreeTimes() {
        let line = "* [ ] Samir — Send the email/reminder for the conference pass to Noah\n"
        XCTAssertFalse(LoopGuard.isLooping("## Action items\n" + line + line))
        XCTAssertTrue(LoopGuard.isLooping("## Action items\n" + line + line + line))
    }

    func testIgnoresThePartialLastLineAndShortLines() {
        let line = "- [ ] Dana — Book the venue\n"
        // The third copy hasn't finished streaming yet.
        XCTAssertFalse(LoopGuard.isLooping(line + line + "- [ ] Dana — Book the venue"))
        XCTAssertFalse(LoopGuard.isLooping("- Yes\n- Yes\n- Yes\n- Yes\n"))
    }

    func testNormalizeIgnoresMarkersCaseAndPunctuation() {
        XCTAssertEqual(LoopGuard.normalize("* [x]  Dana —  Book the venue."), "dana — book the venue")
        XCTAssertEqual(LoopGuard.normalize("3) Book the venue!"), "book the venue")
        XCTAssertTrue(LoopGuard.isBullet("- [ ] task"))
        XCTAssertFalse(LoopGuard.isBullet("-not a bullet"))
        XCTAssertTrue(LoopGuard.isCutOff("samir —"))
        XCTAssertFalse(LoopGuard.isCutOff("samir — do it"))
    }
}

final class SummaryRepeatTests: XCTestCase {
    func testDropsRepeatedAndTruncatedActionItems() {
        let repeated = "* [ ] Samir — Send the email/reminder for the conference pass to Noah"
        let output = """
        # Ignite planning

        ## Action items
        * [ ] Samir — Check with auditors to confirm the pen test plan
        \(repeated)
        * [ ] Samir — Send the email/remind for the conference pass to Noah
        \(repeated)
        \(repeated)
        * [ ] Samir —
        """
        let parsed = SummaryParser.parse(output)
        XCTAssertEqual(parsed.title, "Ignite planning")
        XCTAssertEqual(parsed.body, "## Action items\n* [ ] Samir — Check with auditors to confirm the pen test plan\n\(repeated)")
        XCTAssertEqual(parsed.droppedRepeats, 4)
    }

    func testKeepsDistinctItemsAndShortRepeatsInOtherSections() {
        let output = """
        ## Decisions
        - None
        ## Open questions
        - None
        ## Action items
        - [ ] Noah — Send the conference pass to Maya
        - [ ] Noah — Send the conference pass to Samir
        """
        let parsed = SummaryParser.parse(output)
        XCTAssertEqual(parsed.body, output)
        XCTAssertEqual(parsed.droppedRepeats, 0)
    }

    func testSpeakerLineVariants() {
        XCTAssertEqual(SummaryParser.speakerNames(in: "**SPEAKERS:** Speaker 1=Noah; speaker 2 = Samir"),
                       ["Speaker 1": "Noah", "Speaker 2": "Samir"])
        XCTAssertEqual(SummaryParser.speakerNames(in: "SPEAKERS: Speaker 1=unknown; Speaker 2=Speaker 2; Speaker 3=Lee?"), [:])
        XCTAssertEqual(SummaryParser.speakerNames(in: "The speakers: were friendly"), [:])
    }
}

final class TranscriptPartsTests: XCTestCase {
    private func segment(_ start: TimeInterval, words: Int = 5) -> TranscriptSegment {
        TranscriptSegment(channel: .system, start: start, end: start + 4, text: Array(repeating: "word", count: words).joined(separator: " "))
    }

    func testShortMeetingsStayInOnePart() {
        let parts = TranscriptFormatter.parts((0..<10).map { segment(Double($0) * 60) })
        XCTAssertEqual(parts.count, 1)
        XCTAssertEqual(parts[0].count, 10)
    }

    func testSplitsByDurationAndByWords() {
        let byTime = TranscriptFormatter.parts((0..<50).map { segment(Double($0) * 60) }, maxSeconds: 20 * 60)
        XCTAssertEqual(byTime.count, 3)
        XCTAssertEqual(byTime.map(\.count), [20, 20, 10])
        let byWords = TranscriptFormatter.parts((0..<10).map { segment(Double($0) * 5, words: 100) }, maxWords: 250)
        XCTAssertEqual(byWords.map(\.count), [2, 2, 2, 2, 2])
        XCTAssertEqual(TranscriptFormatter.parts([]).count, 0)
    }
}

final class NotesPromptTests: XCTestCase {
    func testSummaryPromptCarriesPartNotesAndOwnerRule() {
        XCTAssertTrue(MeetingPrompts.summarySystemPrompt(template: .general).contains("Every action item once"))
        let user = MeetingPrompts.summaryUserPrompt(title: nil, date: nil, appName: nil, attendees: [], userNotes: "",
                                                    transcript: "[00:00] You: hi", partNotes: ["- Noah — Book venue [12:00]", "- Nothing"])
        XCTAssertTrue(user.contains("### Part 1\n- Noah — Book venue [12:00]"))
        XCTAssertTrue(user.contains("### Part 2\n- Nothing"))
        XCTAssertTrue(user.range(of: "<part_notes>")!.lowerBound < user.range(of: "<transcript>")!.lowerBound)
        XCTAssertFalse(MeetingPrompts.summaryUserPrompt(title: nil, date: nil, appName: nil, attendees: [], userNotes: "",
                                                        transcript: "x").contains("part_notes"))
    }

    func testSpeakerAndPartPrompts() {
        let user = MeetingPrompts.speakerUserPrompt(attendees: ["Noah"], userNotes: "Noah and Samir are on the call", transcript: "[00:00] Speaker 1: hi")
        XCTAssertTrue(user.contains("Attendees: Noah"))
        XCTAssertTrue(user.contains("Noah and Samir are on the call"))
        XCTAssertTrue(MeetingPrompts.speakerSystemPrompt().contains("SPEAKERS: Speaker 1=Name"))
        XCTAssertTrue(MeetingPrompts.partNotesUserPrompt(index: 2, count: 6, transcript: "t").hasPrefix("Part 2 of 6"))
        XCTAssertTrue(MeetingPrompts.partNotesSystemPrompt().contains("## Commitments"))
    }
}

final class RescuedTrackTests: XCTestCase {
    private func segment(_ channel: AudioChannel, _ speaker: String, _ start: TimeInterval, _ end: TimeInterval) -> TranscriptSegment {
        TranscriptSegment(channel: channel, start: start, end: end, text: "words", speaker: speaker)
    }

    func testVoiceThatTalksWhileTheOtherSideIsQuietBecomesYou() {
        let others = [segment(.system, "Speaker 1", 0, 12), segment(.system, "Speaker 2", 20, 32)]
        // Local diarization of the outside recording: its "Speaker 1" is the far end leaking in, "Speaker 2" is the user.
        let mine = [segment(.microphone, "Speaker 1", 0, 11), segment(.microphone, "Speaker 1", 21, 31),
                    segment(.microphone, "Speaker 2", 12, 19), segment(.microphone, "Speaker 2", 33, 40)]
        let labeled = RescuedTrack.label(mine, others: others)
        XCTAssertEqual(labeled.map(\.speaker), ["Speaker 3", "Speaker 3", "You", "You"])
    }

    func testSingleVoiceIsYouAndEmptyInputPassesThrough() {
        let mine = [segment(.microphone, "Speaker 1", 0, 5)]
        XCTAssertEqual(RescuedTrack.label(mine, others: []).map(\.speaker), ["You"])
        XCTAssertTrue(RescuedTrack.label([], others: []).isEmpty)
    }
}

final class NotesEditingTests: XCTestCase {
    func testToggleFlipsOnlyTheGivenTaskLine() {
        let notes = "## Action items\n- [ ] Noah — order stickers\n* [x] You — send slides\n- plain bullet"
        let once = NotesEditing.toggleCheckbox(in: notes, line: 1)
        XCTAssertEqual(once.components(separatedBy: "\n")[1], "- [x] Noah — order stickers")
        XCTAssertEqual(NotesEditing.toggleCheckbox(in: once, line: 1), notes)
        XCTAssertEqual(NotesEditing.toggleCheckbox(in: notes, line: 2).components(separatedBy: "\n")[2], "* [ ] You — send slides")
        XCTAssertEqual(NotesEditing.toggleCheckbox(in: notes, line: 3), notes)
        XCTAssertEqual(NotesEditing.toggleCheckbox(in: notes, line: 9), notes)
        XCTAssertEqual(NotesEditing.toggleCheckbox(in: "  - [X] nested", line: 0), "  - [ ] nested")
    }

    func testTaskDetection() {
        XCTAssertTrue(NotesEditing.isTask("* [ ] open"))
        XCTAssertTrue(NotesEditing.isChecked("  - [X] done"))
        XCTAssertFalse(NotesEditing.isChecked("- [ ] open"))
        XCTAssertFalse(NotesEditing.isTask("- bullet"))
        XCTAssertFalse(NotesEditing.isTask("[ ] no marker"))
    }
}

final class NoteDigestTests: XCTestCase {
    func testEligibilityNeedsLengthAndQuiet() {
        XCTAssertTrue(NoteDigest.isEligible(wordCount: 40, secondsSinceEdit: 90))
        XCTAssertFalse(NoteDigest.isEligible(wordCount: 39, secondsSinceEdit: 900))
        XCTAssertFalse(NoteDigest.isEligible(wordCount: 400, secondsSinceEdit: 10))
    }

    func testDigestPromptsCarryTheNoteAndTheShape() {
        XCTAssertTrue(NotePrompts.digestSystemPrompt().contains("## To-dos"))
        let user = NotePrompts.digestUserPrompt(date: "Sep 15", text: "call Noah about the booth")
        XCTAssertTrue(user.hasPrefix("Written: Sep 15"))
        XCTAssertTrue(user.contains("<note>\ncall Noah about the booth\n</note>"))
        XCTAssertFalse(NotePrompts.digestUserPrompt(date: nil, text: "x").contains("Written"))
        // A digest goes through the same parser as meeting notes, so a looping model can't fill it with repeats.
        let parsed = SummaryParser.parse("# Booth follow-up\n\n## To-dos\n- [ ] Call Noah\n- [ ] Call Noah\n- [ ] Call Noah")
        XCTAssertEqual(parsed.title, "Booth follow-up")
        XCTAssertEqual(parsed.body, "## To-dos\n- [ ] Call Noah")
    }
}


final class TaskLineTests: XCTestCase {
    func testOwnersComeOffTheFrontOfTaskLines() {
        XCTAssertEqual(NotesEditing.task(from: "- [ ] Noah — order a large amount of stickers"),
                       TaskLine(owner: "Noah", text: "order a large amount of stickers", done: false))
        XCTAssertEqual(NotesEditing.task(from: "* [x] **Samir Haddad** – run the smoke suite"),
                       TaskLine(owner: "Samir Haddad", text: "run the smoke suite", done: true))
        XCTAssertEqual(NotesEditing.task(from: "- [ ] You - share the opencode config"),
                       TaskLine(owner: "You", text: "share the opencode config", done: false))
        // Prose with a hyphen keeps its whole text; a capitalised first word is not an owner.
        XCTAssertEqual(NotesEditing.task(from: "- [ ] Check with auditors - only if needed"),
                       TaskLine(owner: nil, text: "Check with auditors - only if needed", done: false))
        XCTAssertEqual(NotesEditing.task(from: "- [ ] Put booth number 1748 on the HubSpot demo page."),
                       TaskLine(owner: nil, text: "Put booth number 1748 on the HubSpot demo page.", done: false))
        XCTAssertNil(NotesEditing.task(from: "- plain bullet"))
    }

    func testDailyWordsFillsQuietDays() {
        let calendar = Calendar(identifier: .gregorian)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let records = [UsageRecord(date: now, words: 120, duration: 60), UsageRecord(date: now.addingTimeInterval(-86_400 * 3), words: 30, duration: 20),
                       UsageRecord(date: now.addingTimeInterval(-86_400 * 3 + 100), words: 5, duration: 5)]
        let days = StatsCalculator.dailyWords(records, days: 5, now: now, calendar: calendar)
        XCTAssertEqual(days.count, 5)
        XCTAssertEqual(days.map(\.words), [0, 35, 0, 0, 120])
        XCTAssertEqual(days.last?.date, calendar.startOfDay(for: now))
    }
}
