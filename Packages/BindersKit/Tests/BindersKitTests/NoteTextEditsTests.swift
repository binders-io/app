import XCTest
@testable import BindersKit

/// What changed from one text to another (as Automerge's splices, in scalars), the three-way merge an editor uses when a
/// teammate's change lands on its typing, and where a cursor goes.
final class NoteTextEditsTests: XCTestCase {
    // MARK: Edits and splices

    func testTypingIsOneSpliceInScalars() {
        let old = "# Launch\n\nShip on Friday.\n"
        let new = "# Launch\n\nShip on Friday, after the review.\n"
        let splices = TextEdits.splices(from: old, to: new)
        XCTAssertEqual(splices, [TextSplice(start: 24, delete: 0, insert: ", after the review")])
        XCTAssertEqual(TextEdits.apply(splices, to: old), new)
        // Counted in Unicode scalars, as Automerge counts: a flag is two, an accent typed apart is one more.
        let flag = "🇬🇧 Plan\n", accent = "Cafe\u{301} plan\n"
        XCTAssertEqual(TextEdits.splices(from: flag, to: flag + "More\n"), [TextSplice(start: 8, delete: 0, insert: "More\n")])
        XCTAssertEqual(TextEdits.splices(from: accent, to: accent.replacingOccurrences(of: "plan", with: "menu")),
                       [TextSplice(start: 6, delete: 4, insert: "menu")])
        XCTAssertEqual(TextEdits.splices(from: "same", to: "same"), [])
    }

    func testEditsFarApartStayApartSoTypingElsewhereSurvives() {
        let old = (1...30).map { "Line \($0)" }.joined(separator: "\n") + "\n"
        var lines = (1...30).map { "Line \($0)" }
        lines[2] = "Line 3, changed"
        lines[25] = "Line 26 too"
        lines.insert("A new line", at: 15)
        let new = lines.joined(separator: "\n") + "\n"
        let splices = TextEdits.splices(from: old, to: new)
        XCTAssertEqual(splices.count, 3, "three places, three splices: \(splices)")
        XCTAssertEqual(splices.map(\.insert), [", changed", "A new line\n", " too"])
        XCTAssertEqual(TextEdits.apply(splices, to: old), new)
        // A whole note replaced by an agent's update_note touches only what it changed.
        let whole = old.replacingOccurrences(of: "Line 20\n", with: "Line twenty\n")
        XCTAssertEqual(TextEdits.splices(from: old, to: whole).count, 1)
    }

    func testSplicesTurnAnyTextIntoAnyOther() {
        var generator = SeededGenerator(seed: 42)
        let words = ["alpha", "beta", "## Heading", "- item", "🇬🇧", "e\u{301}", "\n", "\n\n", " ", "x", "Café", "日本"]
        func random(_ count: Int) -> String { (0..<count).map { _ in words.randomElement(using: &generator)! }.joined() }
        for _ in 0..<300 {
            let old = random(Int.random(in: 0...40, using: &generator))
            var new = old
            for _ in 0..<Int.random(in: 0...4, using: &generator) {
                let scalars = Array(new.unicodeScalars)
                let at = Int.random(in: 0...scalars.count, using: &generator)
                let cut = Int.random(in: 0...min(6, scalars.count - at), using: &generator)
                var view = String.UnicodeScalarView()
                view.append(contentsOf: scalars[..<at])
                view.append(contentsOf: random(Int.random(in: 0...3, using: &generator)).unicodeScalars)
                view.append(contentsOf: scalars[(at + cut)...])
                new = String(view)
            }
            XCTAssertEqual(TextEdits.apply(TextEdits.splices(from: old, to: new), to: old), new)
        }
    }

    func testACursorMovesWithTheWordsAroundIt() {
        let old = "Hello world"
        let edits = TextEdits.utf16(from: old, to: "Hello there world")
        XCTAssertEqual(TextEdits.map(3, through: edits), 3, "before what came in, it stays")
        XCTAssertEqual(TextEdits.map(5, through: edits), 5, "right where words came in, it stays before them")
        XCTAssertEqual(TextEdits.map(8, through: edits), 14, "after, it moves along")
        let replaced = TextEdits.utf16(from: "Ship on Friday now", to: "Ship on Monday now")
        XCTAssertEqual(TextEdits.map(10, through: replaced), 11, "inside what was replaced (Fri): the end of what replaced it (Mon)")
        XCTAssertEqual(TextEdits.map(18, through: replaced), 18)
    }

    // MARK: The editor's three-way merge

    func testBothSidesKeepTheirWords() {
        let base = "# Plan\n\nWe ship Friday.\n\n## Risks\n\nNone yet.\n"
        let mine = base.replacingOccurrences(of: "None yet.", with: "None yet. The venue may move.")
        let theirs = base.replacingOccurrences(of: "We ship Friday.", with: "We ship Friday, after the review.")
        let merged = TextMerge.merge(base: base, mine: mine, theirs: theirs)
        XCTAssertEqual(merged, "# Plan\n\nWe ship Friday, after the review.\n\n## Risks\n\nNone yet. The venue may move.\n")
        XCTAssertEqual(TextMerge.merge(base: base, mine: base, theirs: theirs), theirs)
        XCTAssertEqual(TextMerge.merge(base: base, mine: mine, theirs: base), mine)
        // Typing at the same place: theirs first, then what was typed here.
        let one = TextMerge.merge(base: "Hello", mine: "Hello Sam", theirs: "Hello Dana")
        XCTAssertEqual(one, "Hello Dana Sam")
        // Both changed the same words: theirs stay, what was typed here follows. Nothing typed is lost.
        XCTAssertEqual(TextMerge.merge(base: "Ship on Friday.", mine: "Ship on Monday.", theirs: "Ship on Tuesday."), "Ship on Tuesday Monday.")
        // Typed right after letters the other side changed: both, where each put them.
        XCTAssertEqual(TextMerge.merge(base: "Ship on Friday.", mine: "Ship on Fri-day.", theirs: "Ship on Monday."), "Ship on Mon-day.")
        // Typed inside letters the other side replaced: both, as whole words.
        XCTAssertEqual(TextMerge.merge(base: "Ship on Friday.", mine: "Ship on Frriday.", theirs: "Ship on Monday."), "Ship on Monday Frriday.")
        // Changes in different words of one line stay as they are.
        XCTAssertEqual(TextMerge.merge(base: "one two three", mine: "one 2 three", theirs: "one two 3"), "one 2 3")
    }
}

/// A small seeded random number generator, so a test that tries many texts tries the same ones every time.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 | 1 }
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}
