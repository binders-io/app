import XCTest

/// The Binders keyboard, typing into a note: the first dictation goes through the app, the next straight from the
/// keyboard while the microphone is ready. Needs the keyboard enabled with Full Access and chosen as the last keyboard
/// used (scripts/phone-keyboard-sim.sh), and a Mac paired or not: the words are cleaned up either way.
final class KeyboardTests: XCTestCase {
    func testDictatingWithTheKeyboard() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-open", "newnote", "-keyboardText", "Um so send the pricing deck by Thursday."]
        app.launch()

        let mic = app.descendants(matching: .any)["keyboard-mic"]
        XCTAssertTrue(mic.waitForExistence(timeout: 15), "The Binders keyboard isn't showing")
        attach("keyboard")

        // First time: the app opens to listen and shows what it hears. You stop in the keyboard, which types it.
        mic.tap()
        XCTAssertTrue(app.staticTexts["Listening for the keyboard"].waitForExistence(timeout: 15), "The app didn't start listening")
        XCTAssertTrue(app.staticTexts["Um so send the pricing deck by Thursday."].waitForExistence(timeout: 10), "The words didn't show")
        attach("listening in the app")
        let stop = app.descendants(matching: .any)["keyboard-stop"]
        XCTAssertTrue(stop.waitForExistence(timeout: 10), "The keyboard doesn't know the app is listening")
        stop.tap()
        let note = app.textViews.firstMatch
        XCTAssertTrue(wait(for: note, toMatch: ".*pricing deck.*"), "Nothing was typed: \(note.value ?? "")")
        XCTAssertFalse((note.value as? String ?? "").hasPrefix("Um"), "It wasn't cleaned up: \(note.value ?? "")")
        attach("typed")

        // Again, with the microphone ready: the keyboard alone.
        mic.tap()
        XCTAssertTrue(stop.waitForExistence(timeout: 10), "The keyboard didn't start listening")
        attach("listening in the keyboard")
        stop.tap()
        XCTAssertTrue(wait(for: note, toMatch: ".*pricing deck.*pricing deck.*"), "The second dictation wasn't typed: \(note.value ?? "")")
        attach("typed twice")

        // And it types: a capital after the full stop, two spaces for a full stop of its own.
        for key in ["space", "O", "k", "space", "space"] { app.buttons[key].tap() }
        XCTAssertTrue(wait(for: note, toMatch: ".*Thursday\\. Ok\\. $"), "Typing went wrong: \(note.value ?? "")")
        attach("typed by hand")
    }

    private func wait(for element: XCUIElement, toMatch pattern: String, timeout: TimeInterval = 30) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value MATCHES %@", "(?s)" + pattern), object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
