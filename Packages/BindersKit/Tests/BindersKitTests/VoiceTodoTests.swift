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

    func testEventParsedFromModelReply() {
        let reply = """
        Here you go: {"title":"Lunch with Sam","start":"2026-09-16T12:00","end":"2026-09-16T13:30","all_day":false,"location":"Tasca"}
        """
        let event = CalendarEventExtraction.parse(reply, now: now)
        XCTAssertEqual(event?.title, "Lunch with Sam")
        XCTAssertEqual(stamp(event?.start), "2026-09-16 12:00")
        XCTAssertEqual(stamp(event?.end), "2026-09-16 13:30")
        XCTAssertEqual(event?.location, "Tasca")
        XCTAssertEqual(event?.allDay, false)
    }

    func testEventParsedWithDefaultsAndAllDay() {
        let noEnd = CalendarEventExtraction.parse(#"{"title":"Dentist","start":"2026-09-18T09:00","end":null,"all_day":false,"location":null}"#, now: now)
        XCTAssertEqual(stamp(noEnd?.end), "2026-09-18 10:00")
        XCTAssertNil(noEnd?.location)

        let allDay = CalendarEventExtraction.parse(#"{"title":"Offsite","start":"2026-09-22","end":null,"all_day":true,"location":null}"#, now: now)
        XCTAssertEqual(allDay?.allDay, true)
        XCTAssertEqual(stamp(allDay?.start), "2026-09-22 00:00")

        XCTAssertNil(CalendarEventExtraction.parse(#"{"title":null}"#, now: now))
        XCTAssertNil(CalendarEventExtraction.parse("no json here", now: now))
    }

    func testFallbackWithoutAModel() {
        let lunch = CalendarEventExtraction.fallback("a lunch with Sam tomorrow at noon", now: now)
        XCTAssertEqual(lunch?.title, "Lunch with Sam")
        XCTAssertEqual(stamp(lunch?.start), "2026-09-16 12:00")
        XCTAssertEqual(stamp(lunch?.end), "2026-09-16 13:00")
        XCTAssertEqual(lunch?.allDay, false)

        let dentist = CalendarEventExtraction.fallback("dentist Friday", now: now)
        XCTAssertEqual(dentist?.title, "Dentist")
        XCTAssertEqual(dentist?.allDay, true)
        XCTAssertEqual(stamp(dentist?.start), "2026-09-18 00:00")

        XCTAssertNil(CalendarEventExtraction.fallback("lunch with Sam", now: now))
    }
}
