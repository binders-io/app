import XCTest
@testable import BindersKit

final class HotkeyStateMachineTests: XCTestCase {
    var machine = HotkeyStateMachine(bindings: .default)

    override func setUp() {
        machine = HotkeyStateMachine(bindings: .default)
    }

    private func flags(_ mods: ModifierSet, _ t: TimeInterval) -> [HotkeyAction] {
        machine.handle(.flagsChanged(mods), at: t).actions
    }

    func testHoldToTalk() {
        XCTAssertEqual(flags(.function, 0), [.start(.dictation, handsFree: false)])
        XCTAssertEqual(flags([], 2), [.stop])
        XCTAssertEqual(machine.state, .idle)
    }

    func testQuickTapCancelsSilently() {
        _ = flags(.function, 0)
        XCTAssertEqual(flags([], 0.1), [.cancel(silent: true)])
        XCTAssertEqual(machine.state, .tapped(at: 0.1))
    }

    func testDoubleTapLocksHandsFreeAndNextPressStops() {
        _ = flags(.function, 0)
        _ = flags([], 0.1)
        XCTAssertEqual(flags(.function, 0.3), [.start(.dictation, handsFree: true)])
        XCTAssertEqual(flags([], 0.4), [])
        XCTAssertEqual(machine.state, .handsFree(mode: .dictation, awaitingRelease: false))
        XCTAssertEqual(flags([], 5), [])
        XCTAssertEqual(flags(.function, 10), [.stop])
        XCTAssertEqual(flags([], 10.1), [])
        XCTAssertEqual(machine.state, .idle)
    }

    func testSlowSecondTapIsNormalHold() {
        _ = flags(.function, 0)
        _ = flags([], 0.1)
        XCTAssertEqual(flags(.function, 1.0), [.start(.dictation, handsFree: false)])
    }

    func testFnThenControlSwitchesToCommand() {
        XCTAssertEqual(flags(.function, 0), [.start(.dictation, handsFree: false)])
        XCTAssertEqual(flags([.function, .control], 0.05), [.switchMode(.command)])
        XCTAssertEqual(flags(.function, 1.5), [.stop])
        // Still holding fn: must not start a new dictation.
        XCTAssertEqual(machine.state, .waitingForRelease)
        XCTAssertEqual(flags([], 1.6), [])
        XCTAssertEqual(machine.state, .idle)
    }

    func testControlThenFnStartsCommandDirectly() {
        XCTAssertEqual(flags(.control, 0), [])
        XCTAssertEqual(flags([.control, .function], 0.1), [.start(.command, handsFree: false)])
    }

    func testFnWithOtherKeyCancels() {
        _ = flags(.function, 0)
        let result = machine.handle(.keyDown(keyCode: 123, modifiers: .function, isRepeat: false), at: 0.3)
        XCTAssertEqual(result.actions, [.cancel(silent: true)])
        XCTAssertFalse(result.consume)
        XCTAssertEqual(flags([], 0.5), [])
        XCTAssertEqual(machine.state, .idle)
    }

    func testResyncStopsSessionWhoseReleaseWasMissed() {
        _ = flags(.function, 0)
        XCTAssertEqual(machine.handle(.resync([]), at: 3).actions, [.stop])
        XCTAssertEqual(machine.state, .idle)
    }

    func testResyncWhileStillHeldKeepsRecording() {
        _ = flags(.function, 0)
        XCTAssertEqual(machine.handle(.resync(.function), at: 3).actions, [])
        XCTAssertEqual(machine.state, .holding(mode: .dictation, since: 0))
    }

    func testResyncReleasesHeldComboHotkey() {
        machine.bindings.dictation = Hotkey(modifiers: [.option], keyCode: KeyCode.space)
        _ = machine.handle(.keyDown(keyCode: KeyCode.space, modifiers: .option, isRepeat: false), at: 0)
        XCTAssertEqual(machine.handle(.resync([]), at: 2).actions, [.stop])
    }

    func testArrowKeysWithImplicitFnFlagDoNotStartDictation() {
        let result = machine.handle(.keyDown(keyCode: 123, modifiers: .function, isRepeat: false), at: 0)
        XCTAssertEqual(result.actions, [])
        XCTAssertEqual(machine.handle(.keyUp(keyCode: 123, modifiers: .function), at: 0.1).actions, [])
        XCTAssertEqual(machine.state, .idle)
    }

    func testEscapeCancelsHandsFreeAndIsConsumed() {
        _ = flags(.function, 0); _ = flags([], 0.1); _ = flags(.function, 0.2); _ = flags([], 0.3)
        let result = machine.handle(.keyDown(keyCode: KeyCode.escape, modifiers: [], isRepeat: false), at: 3)
        XCTAssertEqual(result.actions, [.cancel(silent: false)])
        XCTAssertTrue(result.consume)
        XCTAssertEqual(machine.state, .idle)
    }

    func testEscapeIgnoredWhenIdle() {
        let result = machine.handle(.keyDown(keyCode: KeyCode.escape, modifiers: [], isRepeat: false), at: 0)
        XCTAssertEqual(result.actions, [])
        XCTAssertFalse(result.consume)
    }

    func testPasteLastComboConsumed() {
        let down = machine.handle(.keyDown(keyCode: KeyCode.v, modifiers: [.control, .command], isRepeat: false), at: 0)
        XCTAssertEqual(down.actions, [.pasteLast])
        XCTAssertTrue(down.consume)
        let plain = machine.handle(.keyDown(keyCode: KeyCode.v, modifiers: [.command], isRepeat: false), at: 1)
        XCTAssertEqual(plain.actions, [])
        XCTAssertFalse(plain.consume)
    }

    func testMeetingShortcutAndLegacySettingsDecoding() throws {
        let result = machine.handle(.keyDown(keyCode: KeyCode.m, modifiers: .option, isRepeat: false), at: 0)
        XCTAssertEqual(result.actions, [.toggleMeeting])
        XCTAssertTrue(result.consume)

        let legacy = #"{"dictation":{"modifiers":1},"pasteLast":{"modifiers":18,"keyCode":9}}"#
        let decoded = try JSONDecoder().decode(HotkeyBindings.self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded.meeting, .meeting)
        let cleared = try JSONDecoder().decode(HotkeyBindings.self, from: Data(#"{"dictation":{"modifiers":1},"meeting":null}"#.utf8))
        XCTAssertNil(cleared.meeting)
    }

    func testComboDictationHotkey() {
        machine.bindings.dictation = Hotkey(modifiers: [.option], keyCode: KeyCode.space)
        let down = machine.handle(.keyDown(keyCode: KeyCode.space, modifiers: .option, isRepeat: false), at: 0)
        XCTAssertEqual(down.actions, [.start(.dictation, handsFree: false)])
        XCTAssertTrue(down.consume)
        XCTAssertTrue(machine.handle(.keyDown(keyCode: KeyCode.space, modifiers: .option, isRepeat: true), at: 0.5).consume)
        let up = machine.handle(.keyUp(keyCode: KeyCode.space, modifiers: .option), at: 1)
        XCTAssertEqual(up.actions, [.stop])
        XCTAssertTrue(up.consume)
    }

    func testHandsFreeToggleCombo() {
        machine.bindings.handsFreeToggle = Hotkey(modifiers: [.control, .option], keyCode: KeyCode.space)
        let start = machine.handle(.keyDown(keyCode: KeyCode.space, modifiers: [.control, .option], isRepeat: false), at: 0)
        XCTAssertEqual(start.actions, [.start(.dictation, handsFree: true)])
        let stop = machine.handle(.keyDown(keyCode: KeyCode.space, modifiers: [.control, .option], isRepeat: false), at: 4)
        XCTAssertEqual(stop.actions, [.stop])
    }
}


final class CaptureHotkeyTests: XCTestCase {
    func testFnWTogglesCaptureAndCancelsTheDictationHold() {
        var machine = HotkeyStateMachine(bindings: .default)
        // Holding fn starts dictation; tapping W while holding turns that into a capture toggle instead.
        let pressed = machine.handle(.flagsChanged(.function), at: 0)
        XCTAssertEqual(pressed.actions, [.start(.dictation, handsFree: false)])
        let combo = machine.handle(.keyDown(keyCode: KeyCode.w, modifiers: [.function], isRepeat: false), at: 0.1)
        XCTAssertEqual(combo.actions, [.cancel(silent: true), .toggleCapture])
        XCTAssertTrue(combo.consume)
        _ = machine.handle(.keyUp(keyCode: KeyCode.w, modifiers: [.function]), at: 0.2)
        let released = machine.handle(.flagsChanged([]), at: 0.3)
        XCTAssertTrue(released.actions.isEmpty)
        XCTAssertEqual(machine.state, .idle)
    }

    func testOldSavedBindingsGetTheCaptureDefault() throws {
        let json = #"{"dictation":{"modifiers":1},"command":{"modifiers":3},"pasteLast":{"modifiers":18,"keyCode":9},"scratchpad":{"modifiers":4,"keyCode":1}}"#
        let bindings = try JSONDecoder().decode(HotkeyBindings.self, from: Data(json.utf8))
        XCTAssertEqual(bindings.capture, .capture)
        XCTAssertEqual(bindings.meeting, .meeting)
    }
}
