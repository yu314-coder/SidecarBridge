import XCTest

final class KeyboardCursorFollowTests: XCTestCase {
    private func offset(_ cursor: CGPoint, current: CGSize = .zero, immediate: Bool = false) -> CGSize {
        KeyboardCursorFollow.nextOffset(cursor: cursor, content: CGRect(x: 0, y: 200, width: 1000, height: 600),
            viewport: CGSize(width: 1000, height: 1000), scale: 1, offset: current,
            visibleTop: 100, visibleBottom: 600, travel: CGSize(width: 0, height: 450), immediate: immediate)
    }
    func testCursorInsideSafeAreaDoesNotMoveView() {
        XCTAssertEqual(offset(CGPoint(x: 0.5, y: 0.5)), .zero)
    }
    func testCoveredCursorSmoothlyRevealedWithoutOvershoot() {
        let cursor = CGPoint(x: 0.5, y: 1)
        let target = offset(cursor, immediate: true)
        var value = offset(cursor)
        XCTAssertLessThan(value.height, 0)
        XCTAssertGreaterThan(value.height, target.height)
        for _ in 0..<40 { value = offset(cursor, current: value) }
        XCTAssertEqual(value.height, target.height, accuracy: 0.5)
        XCTAssertEqual(value.width, 0)
        XCTAssertLessThanOrEqual(800 + value.height, 564.5)
    }
    func testUpperEdgeMovesViewBackDown() {
        XCTAssertGreaterThan(offset(CGPoint(x: 0.5, y: 0), current: CGSize(width: 0, height: -300)).height, -300)
    }
}
