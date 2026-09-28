import XCTest
@testable import BindersKit

final class NoteTemplateTests: XCTestCase {
    func testFillsInTheDayAndTheBinder() {
        let template = NoteTemplate(name: "Test", body: "# Kickoff\n{{date}} at {{time}} in {{binder}}; see [[{{today}}]]")
        var components = DateComponents(year: 2026, month: 9, day: 28, hour: 14, minute: 30)
        components.timeZone = .current
        let date = Calendar.current.date(from: components)!
        let filled = template.filled(date: date, binder: "Harbor launch", locale: Locale(identifier: "en_US"))
        XCTAssertTrue(filled.contains("Monday, September 28, 2026"), filled)
        XCTAssertTrue(filled.contains("2:30"), filled)
        XCTAssertTrue(filled.contains("in Harbor launch"))
        XCTAssertTrue(filled.contains("[[2026-09-28]]"))
        XCTAssertFalse(filled.contains("{{"))
    }

    func testBuiltInsHaveUniqueNamesAndStartWithATitle() {
        let names = NoteTemplate.builtIn.map(\.name)
        XCTAssertEqual(Set(names).count, names.count)
        XCTAssertTrue(NoteTemplate.builtIn.allSatisfy { $0.body.hasPrefix("# ") })
        XCTAssertTrue(NoteTemplate.builtIn.contains { $0.name == "Reading notes" })
    }

    func testTheDigestFollowsATemplatesSections() {
        let note = NoteTemplate.builtIn.first { $0.name == "1:1" }!.body
        XCTAssertEqual(NoteTemplate.sections(of: note), ["How things are going", "Updates", "Blockers", "Action items"])
        XCTAssertTrue(NotePrompts.digestUserPrompt(date: nil, text: note).contains("**How things are going**"))
        XCTAssertFalse(NotePrompts.digestUserPrompt(date: nil, text: "Just a thought about pricing.").contains("sections"))
    }
}
