import XCTest
@testable import BindersKit

/// Lane DS9: Distill you can see. An item's lines found in the note, the stretch a part reads, when a reading in the
/// background is due and what holds it back, cards flying one after another, and what the Distill button says.
final class DistillListTests: XCTestCase {
    private let note = """
        # Checkout

        We're rebuilding checkout.

        ## Payment form
        - Put address, delivery and card on one page instead of three.
        - Check card numbers as they're typed.

        ## Retry
        When the bank declines, keep what was typed and offer Retry.

        ## Rollout
        Ship behind a flag to 10% of visitors.
        """

    private func line(_ text: String, _ range: NSRange) -> String { (text as NSString).substring(with: range) }

    // MARK: An item's lines

    func testAnItemsSourceLinesAreFoundAsWholeLinesInNoteOrder() {
        let source = "Check card numbers as they're typed.\nPut address, delivery and card on one page instead of three."
        let lines = DistillSpots.lines(quote: nil, source: source, section: "Payment form", in: note)
        XCTAssertEqual(lines.map { line(note, $0) }, ["- Put address, delivery and card on one page instead of three.", "- Check card numbers as they're typed."],
                       "each line whole, its list marker included, in the note's order")
    }

    func testTheQuoteIsUsedWhenTheSourceIsntThere() {
        let lines = DistillSpots.lines(quote: "keep what was typed", source: "A brief someone wrote by hand.", section: "Retry", in: note)
        XCTAssertEqual(lines.map { line(note, $0) }, ["When the bank declines, keep what was typed and offer Retry."])
        XCTAssertEqual(DistillSpots.lines(quote: "Nothing like this", source: nil, section: "Retry", in: note), [], "words the note doesn't have: nothing")
        XCTAssertEqual(DistillSpots.lines(quote: nil, source: nil, section: nil, in: ""), [])
    }

    func testTheSameLineIsListedOnce() {
        let lines = DistillSpots.lines(quote: "Ship behind a flag", source: "Ship behind a flag to 10% of visitors.\nShip behind a flag", section: "Rollout", in: note)
        XCTAssertEqual(lines.count, 1)
    }

    func testAPartsSpanRunsFromItsHeadingToItsLastLine() {
        let part = DistillLines("## Payment form\n- Put address, delivery and card on one page instead of three.\n- Check card numbers as they're typed.\n\n## Retry\nWhen the bank declines, keep what was typed and offer Retry.")
        let span = DistillSpots.span(of: part, in: note)
        XCTAssertNotNil(span)
        let words = span.map { line(note, $0) } ?? ""
        XCTAssertTrue(words.hasPrefix("## Payment form"), words)
        XCTAssertTrue(words.hasSuffix("offer Retry."), words)
        XCTAssertFalse(words.contains("Rollout"))
        XCTAssertNil(DistillSpots.span(of: DistillLines("Words the note never had."), in: note))
    }

    // MARK: In the background

    func testOnlyAChangeOfWordsCounts() {
        XCTAssertEqual(DistillBackground.changed(from: note, to: note), 0)
        XCTAssertFalse(DistillBackground.meaningful(from: note, to: note.replacingOccurrences(of: "\n\n", with: "\n\n\n   ")), "space alone")
        XCTAssertFalse(DistillBackground.meaningful(from: note, to: note.replacingOccurrences(of: "one page", with: "**one page**")), "bold alone")
        XCTAssertFalse(DistillBackground.meaningful(from: "- [ ] Write it", to: "- [x] Write it"), "a tick")
        XCTAssertFalse(DistillBackground.meaningful(from: note, to: note.replacingOccurrences(of: "three.", with: "three!")), "a character or two")
        XCTAssertTrue(DistillBackground.meaningful(from: note, to: note + "\n- Send a receipt by email."), "a new line of words")
        XCTAssertTrue(DistillBackground.meaningful(from: note, to: note.replacingOccurrences(of: "10%", with: "25% of visitors in Europe, then")))
        XCTAssertGreaterThanOrEqual(DistillBackground.changed(from: "abc", to: "abcdefgh"), 5)
    }

    func testWhatHoldsItBack() {
        typealias C = DistillBackground.Conditions
        XCTAssertNil(DistillBackground.pause(C()))
        XCTAssertEqual(DistillBackground.pause(C(enabled: false)), .off)
        XCTAssertEqual(DistillBackground.pause(C(dictating: true)), .dictating)
        XCTAssertEqual(DistillBackground.pause(C(recording: true)), .recording)
        XCTAssertEqual(DistillBackground.pause(C(capturing: true)), .capturing)
        XCTAssertEqual(DistillBackground.pause(C(onBattery: true, battery: 0.15)), .battery)
        XCTAssertNil(DistillBackground.pause(C(onBattery: true, battery: 0.5)), "on battery with plenty left")
        XCTAssertNil(DistillBackground.pause(C(onBattery: false, battery: 0.1)), "charging")
        XCTAssertEqual(DistillBackground.pause(C(lowPower: true)), .lowPower)
        XCTAssertEqual(DistillBackground.pause(C(hot: true)), .hot)
        XCTAssertEqual(DistillBackground.pause(C(foreground: true)), .foreground)
        for pause in [DistillBackground.Pause.off, .dictating, .recording, .capturing, .battery, .lowPower, .hot, .foreground] {
            XCTAssertFalse(pause.words.contains("!"))
            XCTAssertTrue(pause.words.hasSuffix("."))
        }
    }

    // MARK: Flying cards

    func testCardsSetOffOneAfterAnother() {
        var flights = DistillFlights()
        let now = Date(timeIntervalSince1970: 1000)
        let a = flights.start(at: now)
        let b = flights.start(at: now)
        let c = flights.start(at: now.addingTimeInterval(0.05))
        XCTAssertEqual(a, now)
        XCTAssertEqual(b.timeIntervalSince(a), DistillFlights.gap, accuracy: 0.0001, "found together: a moment apart")
        XCTAssertEqual(c.timeIntervalSince(b), DistillFlights.gap, accuracy: 0.0001, "never piling up")
        let later = flights.start(at: now.addingTimeInterval(5))
        XCTAssertEqual(later, now.addingTimeInterval(5), "found later: off at once")
    }

    func testAFlightEasesAlongItsCurve() {
        let start = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(DistillFlights.progress(started: start, now: start.addingTimeInterval(-1)), 0)
        XCTAssertEqual(DistillFlights.progress(started: start, now: start), 0)
        XCTAssertEqual(DistillFlights.progress(started: start, now: start.addingTimeInterval(DistillFlights.duration / 2)), 0.5, accuracy: 0.001)
        XCTAssertEqual(DistillFlights.progress(started: start, now: start.addingTimeInterval(10)), 1)
        XCTAssertLessThan(DistillFlights.progress(started: start, now: start.addingTimeInterval(0.1)), 0.1, "it lifts gently")
        let from = CGPoint(x: 100, y: 400), to = CGPoint(x: 700, y: 200)
        XCTAssertEqual(DistillFlights.point(from: from, to: to, lift: 80, t: 0), from)
        XCTAssertEqual(DistillFlights.point(from: from, to: to, lift: 80, t: 1), to)
        let middle = DistillFlights.point(from: from, to: to, lift: 80, t: 0.5)
        XCTAssertLessThan(middle.y, (from.y + to.y) / 2, "it rises on the way")
        XCTAssertEqual(middle.x, 400, accuracy: 0.5)
    }

    func testTheGlowFadesAndTheSweepGoesRound() {
        let found = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(DistillFlights.glow(found: found, now: found), 1)
        XCTAssertLessThan(DistillFlights.glow(found: found, now: found.addingTimeInterval(0.7)), 0.5)
        XCTAssertEqual(DistillFlights.glow(found: found, now: found.addingTimeInterval(DistillFlights.glow + 0.1)), 0)
        let top = DistillFlights.sweep(started: found, now: found)
        let lower = DistillFlights.sweep(started: found, now: found.addingTimeInterval(1.3))
        XCTAssertLessThan(top, 0)
        XCTAssertGreaterThan(lower, top)
        XCTAssertEqual(DistillFlights.sweep(started: found, now: found.addingTimeInterval(2.6)), top, accuracy: 0.0001, "round again")
    }

    // MARK: The button

    func testTheButtonsFace() {
        let now = Date(timeIntervalSince1970: 100)
        XCTAssertEqual(DistillButtonFace.face(reading: nil, newItems: 0, upToDateUntil: nil, now: now), .idle)
        XCTAssertEqual(DistillButtonFace.face(reading: 4, newItems: 3, upToDateUntil: nil, now: now), .reading(items: 4), "reading wins")
        XCTAssertEqual(DistillButtonFace.face(reading: nil, newItems: 3, upToDateUntil: nil, now: now), .new(3))
        XCTAssertEqual(DistillButtonFace.face(reading: nil, newItems: 3, upToDateUntil: now.addingTimeInterval(1), now: now), .upToDate)
        XCTAssertEqual(DistillButtonFace.face(reading: nil, newItems: 0, upToDateUntil: now.addingTimeInterval(-1), now: now), .idle, "a moment, then gone")
        XCTAssertEqual(DistillButtonFace.idle.title, "Distill")
        XCTAssertEqual(DistillButtonFace.new(3).title, "3 new")
        XCTAssertEqual(DistillButtonFace.upToDate.title, "Up to date")
        XCTAssertEqual(DistillButtonFace.reading(items: 1).spoken, "Distilling, 1 item so far")
    }
}
