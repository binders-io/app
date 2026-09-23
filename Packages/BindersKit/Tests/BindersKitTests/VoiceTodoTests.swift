import XCTest
@testable import BindersKit

/// To-dos and calendar events said aloud: the time comes off the end, the rest is the thing.
final class VoiceTodoTests: XCTestCase {
    // Tuesday 15 September 2026, 10:00 local.
    private var now: Date {
        var components = DateComponents()
        components.year = 2026; components.month = 9; components.day = 15; components.hour = 10
        return Calendar.current.date(from: components)!
    }

    private func stamp(_ date: Date?) -> String {
        guard let date else { return "nil" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    func testSplitDueTakesTheTimeOffTheEnd() {
        let split = CommitmentDetection.splitDue("call Sam tomorrow at 3 pm", relativeTo: now)
        XCTAssertEqual(split.task, "call Sam")
        XCTAssertEqual(split.due, "tomorrow at 3 pm")
        XCTAssertEqual(stamp(split.dueAt), "2026-09-16 15:00")

        let friday = CommitmentDetection.splitDue("send the deck by Friday", relativeTo: now)
        XCTAssertEqual(friday.task, "send the deck")
        XCTAssertEqual(stamp(friday.dueAt), "2026-09-18 17:00")

        let inDays = CommitmentDetection.splitDue("renew the passport in 2 weeks", relativeTo: now)
        XCTAssertEqual(inDays.task, "renew the passport")
        XCTAssertEqual(stamp(inDays.dueAt), "2026-09-29 17:00")
    }

    func testSplitDueLeavesTasksWithoutATimeAlone() {
        let plain = CommitmentDetection.splitDue("buy 3 apples", relativeTo: now)
        XCTAssertEqual(plain.task, "buy 3 apples")
        XCTAssertNil(plain.dueAt)

        // "Boston" is not a time word, so the whole phrase stays the task even though "Friday" is in it.
        let city = CommitmentDetection.splitDue("book the flight to Boston Friday", relativeTo: now)
        XCTAssertEqual(city.task, "book the flight to Boston")
        XCTAssertEqual(city.due, "Friday")

        let single = CommitmentDetection.splitDue("tomorrow", relativeTo: now)
        XCTAssertEqual(single.task, "tomorrow")
        XCTAssertNil(single.dueAt)
    }

    func testTimesSaidAsWords() {
        // Speech recognition writes "eleven a.m.", not "11 am".
        XCTAssertEqual(CommitmentDetection.normalizeSpokenTime("Monday, eleven a.m."), "Monday, 11 am")
        XCTAssertEqual(CommitmentDetection.normalizeSpokenTime("half past ten"), "10:30")
        XCTAssertEqual(CommitmentDetection.normalizeSpokenTime("a quarter to eleven"), "10:45")
        XCTAssertEqual(CommitmentDetection.normalizeSpokenTime("ten o'clock"), "10:00")
        XCTAssertEqual(CommitmentDetection.normalizeSpokenTime("at three"), "at 3")
        XCTAssertEqual(CommitmentDetection.normalizeSpokenTime("in two days"), "in two days")

        let appointment = CommitmentDetection.splitDue("doctor 's appointment and Monday, eleven a.m.", relativeTo: now)
        XCTAssertEqual(stamp(appointment.dueAt), "2026-09-21 11:00")
        XCTAssertEqual(CalendarEventExtraction.cleanTitle(appointment.task), "Doctor's appointment")

        XCTAssertEqual(stamp(CommitmentDetection.dueDate(from: "Thursday at 10", relativeTo: now)), "2026-09-17 10:00")
        XCTAssertEqual(stamp(CommitmentDetection.dueDate(from: "Thursday at 3", relativeTo: now)), "2026-09-17 15:00")
        XCTAssertEqual(stamp(CommitmentDetection.dueDate(from: "tomorrow three thirty", relativeTo: now)), "2026-09-16 15:30")
        XCTAssertEqual(stamp(CommitmentDetection.dueDate(from: "Sept 20", relativeTo: now)), "2026-09-20 17:00")
    }

    func testEventParsedFromModelReply() {
        let reply = """
        Here you go: {"title":"Lunch with Sam","when":"tomorrow at noon","duration_minutes":90,"location":"Tasca"}
        """
        let event = CalendarEventExtraction.parse(reply, now: now)
        XCTAssertEqual(event?.title, "Lunch with Sam")
        XCTAssertEqual(stamp(event?.start), "2026-09-16 12:00")
        XCTAssertEqual(stamp(event?.end), "2026-09-16 13:30")
        XCTAssertEqual(event?.location, "Tasca")
        XCTAssertEqual(event?.allDay, false)

        let dayOnly = CalendarEventExtraction.parse(#"{"title":"Offsite","when":"next Tuesday","duration_minutes":null,"location":null}"#, now: now)
        XCTAssertEqual(dayOnly?.allDay, true)
        XCTAssertEqual(stamp(dayOnly?.start), "2026-09-22 00:00")

        let spoken = CalendarEventExtraction.parse(#"{"title":"doctor 's appointment","when":"Monday, eleven a.m.","duration_minutes":null,"location":null}"#, now: now)
        XCTAssertEqual(spoken?.title, "Doctor's appointment")
        XCTAssertEqual(stamp(spoken?.start), "2026-09-21 11:00")
    }

    func testModelAnswersThatAreNotTimesAreRejected() {
        // A model given no time answers with the present, or a date it made up that has passed.
        let present = "{\"title\":\"Send the invoice\",\"when\":\"\(now.formatted(date: .complete, time: .shortened))\",\"duration_minutes\":null,\"location\":null}"
        XCTAssertNil(CalendarEventExtraction.parse(present, now: now))
        XCTAssertNil(CalendarEventExtraction.parse(#"{"title":"Call","when":"yesterday at noon","duration_minutes":null,"location":null}"#, now: now))
        XCTAssertNil(CalendarEventExtraction.parse(#"{"title":"Call","when":null,"duration_minutes":null,"location":null}"#, now: now))
        XCTAssertNil(CalendarEventExtraction.parse(#"{"title":null}"#, now: now))
        XCTAssertNil(CalendarEventExtraction.parse("no json here", now: now))
    }

    func testDeterministicWithoutAModel() {
        let lunch = CalendarEventExtraction.deterministic("a lunch with Sam tomorrow at noon", now: now)
        XCTAssertEqual(lunch?.title, "Lunch with Sam")
        XCTAssertEqual(stamp(lunch?.start), "2026-09-16 12:00")
        XCTAssertEqual(stamp(lunch?.end), "2026-09-16 13:00")
        XCTAssertEqual(lunch?.allDay, false)

        let dentist = CalendarEventExtraction.deterministic("dentist Friday", now: now)
        XCTAssertEqual(dentist?.title, "Dentist")
        XCTAssertEqual(dentist?.allDay, true)
        XCTAssertEqual(stamp(dentist?.start), "2026-09-18 00:00")

        let appointment = CalendarEventExtraction.deterministic("Doctor 's appointment on Monday, eleven a.m.", now: now)
        XCTAssertEqual(appointment?.title, "Doctor's appointment")
        XCTAssertEqual(stamp(appointment?.start), "2026-09-21 11:00")

        XCTAssertNil(CalendarEventExtraction.deterministic("lunch with Sam", now: now))
        XCTAssertNil(CalendarEventExtraction.deterministic("let's meet Thursday at 10 to go over the plan", now: now))
    }
}
