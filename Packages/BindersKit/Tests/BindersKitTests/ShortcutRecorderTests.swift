import XCTest
@testable import BindersKit

final class ShortcutRecorderTests: XCTestCase {
    private func down(_ code: UInt16, _ mods: ModifierSet = []) -> HotkeyInput { .keyDown(keyCode: code, modifiers: mods, isRepeat: false) }

    // MARK: Recording

    func testKeyCombinationsRecordOnKeyDown() {
        var recorder = ShortcutRecorder(isHold: false)
        XCTAssertEqual(recorder.handle(.flagsChanged(.option), at: 0), .listening("⌥"))
        XCTAssertEqual(recorder.handle(down(KeyCode.s, .option), at: 0.1), .recorded(Hotkey(modifiers: .option, keyCode: KeyCode.s)))
    }

    func testFnCountsAsAModifierWhenPressedAsAKey() {
        var recorder = ShortcutRecorder(isHold: false)
        _ = recorder.handle(.flagsChanged(.function), at: 0)
        XCTAssertEqual(recorder.handle(down(KeyCode.w, .function), at: 0.1), .recorded(.capture))
        // An arrow key carries the fn flag on its own; that isn't fn held.
        var arrows = ShortcutRecorder(isHold: false)
        _ = arrows.handle(.flagsChanged(.command), at: 0)
        XCTAssertEqual(arrows.handle(down(126, [.command, .function]), at: 0.1), .recorded(Hotkey(modifiers: .command, keyCode: 126)))
    }

    func testPlainKeysNeedAModifierButFunctionKeysDoNot() {
        var recorder = ShortcutRecorder(isHold: false)
        guard case .rejected = recorder.handle(down(KeyCode.s), at: 0) else { return XCTFail("a plain S isn't a shortcut") }
        guard case .rejected = recorder.handle(down(KeyCode.s, .shift), at: 0.2) else { return XCTFail("⇧S types a capital") }
        XCTAssertEqual(recorder.handle(down(96), at: 0.4), .recorded(Hotkey(modifiers: [], keyCode: 96)))   // F5
    }

    func testEscapeCancels() {
        var recorder = ShortcutRecorder(isHold: true)
        XCTAssertEqual(recorder.handle(down(KeyCode.escape), at: 0), .cancelled)
    }

    func testHoldShortcutsRecordModifiersOnRelease() {
        var recorder = ShortcutRecorder(isHold: true)
        XCTAssertEqual(recorder.handle(.flagsChanged(.function), at: 0), .listening("fn"))
        XCTAssertEqual(recorder.handle(.flagsChanged([.function, .control]), at: 0.2), .listening("fn ⌃"))
        XCTAssertEqual(recorder.handle(.flagsChanged(.function), at: 0.4), .listening("fn ⌃"))
        XCTAssertEqual(recorder.handle(.flagsChanged([]), at: 0.5), .recorded(.fnControl))
    }

    func testShiftAloneCannotHoldToTalk() {
        var recorder = ShortcutRecorder(isHold: true)
        _ = recorder.handle(.flagsChanged(.shift), at: 0)
        guard case .rejected = recorder.handle(.flagsChanged([]), at: 0.5) else { return XCTFail("shift alone") }
    }

    func testTogglesRecordADoubleTap() {
        var recorder = ShortcutRecorder(isHold: false)
        _ = recorder.handle(.flagsChanged(.option), at: 0)
        XCTAssertEqual(recorder.handle(.flagsChanged([]), at: 0.1), .awaitingSecondTap(.option))
        XCTAssertEqual(recorder.handle(.flagsChanged(.option), at: 0.25), .awaitingSecondTap(.option))
        XCTAssertEqual(recorder.handle(.flagsChanged([]), at: 0.32), .recorded(Hotkey(modifiers: .option, doubleTap: true)))
    }

    func testASingleTapOfAToggleIsNotEnough() {
        var recorder = ShortcutRecorder(isHold: false)
        _ = recorder.handle(.flagsChanged(.option), at: 0)
        XCTAssertEqual(recorder.handle(.flagsChanged([]), at: 0.1), .awaitingSecondTap(.option))
        XCTAssertNil(recorder.tick(at: 0.3))
        guard case .rejected = recorder.tick(at: 0.7) else { return XCTFail("one tap, then nothing") }
        // A slow second tap starts over instead of recording.
        _ = recorder.handle(.flagsChanged(.option), at: 1.0)
        XCTAssertEqual(recorder.handle(.flagsChanged([]), at: 1.1), .awaitingSecondTap(.option))
        _ = recorder.handle(.flagsChanged(.option), at: 2.0)
        XCTAssertEqual(recorder.handle(.flagsChanged([]), at: 2.1), .awaitingSecondTap(.option))
    }

    func testAKeyInBetweenIsACombinationNotATap() {
        var recorder = ShortcutRecorder(isHold: false)
        _ = recorder.handle(.flagsChanged(.option), at: 0)
        _ = recorder.handle(.flagsChanged([]), at: 0.1)
        _ = recorder.handle(.flagsChanged(.option), at: 0.2)
        XCTAssertEqual(recorder.handle(down(KeyCode.m, .option), at: 0.25), .recorded(.meeting))
    }

    // MARK: Double-taps in the live state machine

    private func machine(scratchpad: Hotkey? = Hotkey(modifiers: .option, doubleTap: true)) -> HotkeyStateMachine {
        var bindings = HotkeyBindings.default
        bindings.scratchpad = scratchpad
        return HotkeyStateMachine(bindings: bindings)
    }

    func testDoubleTappingModifiersRunsTheToggle() {
        var m = machine()
        XCTAssertEqual(m.handle(.flagsChanged(.option), at: 0).actions, [])
        XCTAssertEqual(m.handle(.flagsChanged([]), at: 0.1).actions, [])
        XCTAssertEqual(m.handle(.flagsChanged(.option), at: 0.3).actions, [])
        XCTAssertEqual(m.handle(.flagsChanged([]), at: 0.4).actions, [.toggleScratchpad])
    }

    func testTypingWithTheModifierIsNotADoubleTap() {
        var m = machine()
        _ = m.handle(.flagsChanged(.option), at: 0)
        _ = m.handle(.keyDown(keyCode: KeyCode.s, modifiers: .option, isRepeat: false), at: 0.05)
        _ = m.handle(.flagsChanged([]), at: 0.1)
        _ = m.handle(.flagsChanged(.option), at: 0.2)
        XCTAssertEqual(m.handle(.flagsChanged([]), at: 0.3).actions, [])
        // Two slow taps aren't a double-tap either.
        _ = m.handle(.flagsChanged(.option), at: 5)
        _ = m.handle(.flagsChanged([]), at: 5.1)
        _ = m.handle(.flagsChanged(.option), at: 6)
        XCTAssertEqual(m.handle(.flagsChanged([]), at: 6.1).actions, [])
    }

    func testHandsFreeToggleByDoubleTapStartsAndStops() {
        var bindings = HotkeyBindings.default
        bindings.handsFreeToggle = Hotkey(modifiers: .option, doubleTap: true)
        var m = HotkeyStateMachine(bindings: bindings)
        _ = m.handle(.flagsChanged(.option), at: 0)
        _ = m.handle(.flagsChanged([]), at: 0.1)
        _ = m.handle(.flagsChanged(.option), at: 0.2)
        XCTAssertEqual(m.handle(.flagsChanged([]), at: 0.3).actions, [.start(.dictation, handsFree: true)])
        _ = m.handle(.flagsChanged(.option), at: 5)
        _ = m.handle(.flagsChanged([]), at: 5.1)
        _ = m.handle(.flagsChanged(.option), at: 5.2)
        XCTAssertEqual(m.handle(.flagsChanged([]), at: 5.3).actions, [.stop])
    }

    func testDictationKeepsItsOwnDoubleTap() {
        var m = machine()
        _ = m.handle(.flagsChanged(.function), at: 0)
        _ = m.handle(.flagsChanged([]), at: 0.1)
        XCTAssertEqual(m.handle(.flagsChanged(.function), at: 0.3).actions, [.start(.dictation, handsFree: true)])
    }

    // MARK: Conflicts, display and saved settings

    func testConflicts() {
        let bindings = HotkeyBindings.default
        XCTAssertEqual(bindings.conflict(for: .meeting, in: .scratchpad), .meeting)
        XCTAssertNil(bindings.conflict(for: .scratchpad, in: .scratchpad))
        // Holding fn dictates and double-tapping it goes hands-free, so a toggle can't have it.
        XCTAssertEqual(bindings.conflict(for: Hotkey(modifiers: .function, doubleTap: true), in: .scratchpad), .dictation)
        XCTAssertNil(bindings.conflict(for: Hotkey(modifiers: .option, doubleTap: true), in: .scratchpad))
        var withTap = bindings
        withTap.scratchpad = Hotkey(modifiers: .option, doubleTap: true)
        XCTAssertEqual(withTap.conflict(for: Hotkey(modifiers: .option), in: .dictation), .scratchpad)
    }

    func testDisplay() {
        XCTAssertEqual(Hotkey(modifiers: .option, doubleTap: true).displayString(), "Double-tap ⌥")
        XCTAssertEqual(Hotkey.capture.displayString(), "fn W")
        XCTAssertEqual(Hotkey.meeting.displayString(), "⌥M")
    }

    func testShortcutsSavedBeforeDoubleTapsStillLoad() throws {
        let json = #"{"dictation":{"modifiers":1},"command":{"modifiers":3},"scratchpad":{"modifiers":4,"keyCode":1}}"#
        let bindings = try JSONDecoder().decode(HotkeyBindings.self, from: Data(json.utf8))
        XCTAssertEqual(bindings.dictation, .fn)
        XCTAssertEqual(bindings.scratchpad, .scratchpad)
        XCTAssertFalse(bindings.scratchpad?.doubleTap ?? true)
        let tap = Hotkey(modifiers: .option, doubleTap: true)
        XCTAssertEqual(try JSONDecoder().decode(Hotkey.self, from: JSONEncoder().encode(tap)), tap)
    }
}
