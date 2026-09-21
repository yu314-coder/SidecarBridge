import XCTest

final class TouchPointerAccumulatorTests: XCTestCase {
    func testThrottledSamplesKeepAllMovement() {
        var pending = TouchPointerAccumulator()
        for _ in 0..<10 { pending.add(x: 0.001, y: -0.002) }
        let delta = pending.take()
        XCTAssertEqual(delta.x, 0.01, accuracy: 0.000001)
        XCTAssertEqual(delta.y, -0.02, accuracy: 0.000001)
        XCTAssertEqual(pending.take().x, 0)
    }
    func testCancellationDoesNotLeakIntoNextGesture() {
        var pending = TouchPointerAccumulator()
        pending.add(x: 1, y: 2)
        pending.reset()
        pending.add(x: -0.1, y: 0.2)
        let delta = pending.take()
        XCTAssertEqual(delta.x, -0.1)
        XCTAssertEqual(delta.y, 0.2)
    }
}
