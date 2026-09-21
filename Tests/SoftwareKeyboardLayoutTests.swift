import XCTest

final class SoftwareKeyboardLayoutTests: XCTestCase {
    func testOfflineDiagnosticTypesAndDeletesWithoutExecutingShortcuts() {
        var state = KeyboardDiagnosticState()
        state.record("a", modifiers: ["shift"])
        state.record("space")
        state.record("b")
        state.record("delete")
        state.record("return")
        state.record("v", modifiers: ["command"])
        state.record("Next input source")
        XCTAssertEqual(state.text, "A \n")
        XCTAssertEqual(state.keyCount, 7)
        XCTAssertEqual(state.events[1], "command + v")
    }

    func testOfflineDiagnosticBoundsItsHistoryAndBuffer() {
        var state = KeyboardDiagnosticState()
        for _ in 0..<5_100 { state.record("a") }
        XCTAssertEqual(state.text.count, 5_000)
        XCTAssertEqual(state.events.count, 20)
    }
    func testCompactKeyboardUsesShorterNativeLikeDock() {
        XCTAssertEqual(SoftwareKeyboardLayout.panelSize(in: CGSize(width: 393, height: 852)).height, 336)
        XCTAssertEqual(SoftwareKeyboardLayout.panelSize(in: CGSize(width: 1024, height: 1366)).height, 400)
        XCTAssertLessThanOrEqual(SoftwareKeyboardLayout.panelSize(in: CGSize(width: 852, height: 393)).height, 393 / 2.0)
    }
    func testCustomKeyboardSuppressesSystemKeyboardEvenWithHardwareAttached() {
        for hardware in [false, true] {
            XCTAssertFalse(SoftwareKeyboardLayout.usesSystemInputView(customKeyboardVisible: true, hardwareKeyboard: hardware))
        }
        XCTAssertTrue(SoftwareKeyboardLayout.usesSystemInputView(customKeyboardVisible: false, hardwareKeyboard: true))
        XCTAssertFalse(SoftwareKeyboardLayout.usesSystemInputView(customKeyboardVisible: false, hardwareKeyboard: false))
    }

    func testBasicLayoutContainsEveryLetterAndDigitExactlyOnce() {
        let keys = SoftwareKeyboardLayout.letters.joined()
        XCTAssertEqual(Set(keys), Set("abcdefghijklmnopqrstuvwxyz0123456789"))
        XCTAssertEqual(keys.count, 36)
    }

    func testShiftedSymbolsKeepUnderlyingPhysicalKeyMapping() {
        XCTAssertEqual(SoftwareKeyboardLayout.title(for: "a", shift: true), "A")
        XCTAssertEqual(SoftwareKeyboardLayout.title(for: "1", shift: true), "!")
        XCTAssertEqual(SoftwareKeyboardLayout.title(for: "/", shift: true), "?")
        XCTAssertEqual(SoftwareKeyboardLayout.title(for: "1", shift: false), "1")
        let keys = Set(SoftwareKeyboardLayout.punctuation.joined().map(String.init))
        XCTAssertTrue(Set(SoftwareKeyboardLayout.shifted.keys).isSubset(of: keys))
    }
}
