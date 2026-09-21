import XCTest

final class StreamQualityPolicyTests: XCTestCase {
    func testUpscalingPolicyRequiresSupportAndLargerOutput() {
        let input = DisplayUpscalingPolicy.diagnosticInput
        let output = DisplayUpscalingPolicy.diagnosticOutput
        XCTAssertTrue(DisplayUpscalingPolicy.shouldUpscale(enabled: true, supported: true, input: input, output: output))
        XCTAssertFalse(DisplayUpscalingPolicy.shouldUpscale(enabled: false, supported: true, input: input, output: output))
        XCTAssertFalse(DisplayUpscalingPolicy.shouldUpscale(enabled: true, supported: false, input: input, output: output))
        XCTAssertFalse(DisplayUpscalingPolicy.shouldUpscale(enabled: true, supported: true, input: output, output: input))
    }
    func testLiveUpscalingStatusReportsPresentedResolution() {
        XCTAssertEqual(
            DisplayUpscalingPolicy.activeOutputDescription(
                from: "Active • 1920 × 1080 → 2360 × 1328 • 7.8 ms"
            ),
            "2360 × 1328"
        )
        XCTAssertNil(DisplayUpscalingPolicy.activeOutputDescription(from: "Ready • waiting for a 1080p frame"))
        XCTAssertNil(DisplayUpscalingPolicy.activeOutputDescription(from: "Fallback renderer • unavailable"))
    }
    func testModeratePressureKeeps2KAndCriticalKeeps1080pTarget() {
        XCTAssertEqual(StreamQualityPolicy.captureWidth(preferred: 3840, resolution: .adaptive, memory: .normal), 3840)
        XCTAssertEqual(StreamQualityPolicy.captureWidth(preferred: 3840, resolution: .twoK, memory: .warning), 2560)
        XCTAssertEqual(StreamQualityPolicy.captureWidth(preferred: 3840, resolution: .fourK, memory: .critical), 1920)
        XCTAssertEqual(StreamQualityPolicy.captureWidth(preferred: 1440, resolution: .fourK, memory: .normal), 3840)
    }
    func testHiDPISourceUsesPixelsNotLogicalPoints() {
        XCTAssertEqual(StreamQualityPolicy.sourcePixels(points: CGSize(width: 1920, height: 1080), scale: 2),
                       CGSize(width: 3840, height: 2160))
        XCTAssertEqual(StreamQualityPolicy.sourcePixels(points: CGSize(width: 1920, height: 1080), scale: 1),
                       CGSize(width: 1920, height: 1080))
    }
    func testExplicitQualityRestoresAfterPressure() {
        let widths = [StreamMemoryPressureLevel.normal, .warning, .critical, .normal].map {
            StreamQualityPolicy.captureWidth(preferred: 3840, resolution: .fourK, memory: $0)
        }
        XCTAssertEqual(widths, [3840, 2560, 1920, 3840])
    }
    func testWarningRetainsTextBudgetInsteadOfDroppingTo22Percent() {
        let normal = StreamQualityPolicy.bitrate(width: 2560, height: 1440, frameRate: 60, isNearby: true, memory: .normal, backpressure: .normal)
        let warning = StreamQualityPolicy.bitrate(width: 2560, height: 1440, frameRate: 60, isNearby: true, memory: .warning, backpressure: .normal)
        XCTAssertGreaterThanOrEqual(Double(warning) / Double(normal), 0.79)
        XCTAssertLessThan(warning, normal)
    }
    func testCongestionStillLowersBudgetAndCapsRemainBounded() {
        let congested = StreamQualityPolicy.bitrate(width: 1920, height: 1080, frameRate: 60, isNearby: true, memory: .critical, backpressure: .severe)
        XCTAssertLessThan(congested, 6_000_000)
        XCTAssertGreaterThanOrEqual(congested, 2_000_000)
        XCTAssertEqual(StreamQualityPolicy.bitrate(width: 3840, height: 2160, frameRate: 240, isNearby: true, memory: .normal, backpressure: .normal), 36_000_000)
        XCTAssertEqual(StreamQualityPolicy.bitrate(width: 3840, height: 2160, frameRate: 240, isNearby: false, memory: .normal, backpressure: .normal), 48_000_000)
    }
    func testRecoveryIsSlowAndCriticalPressureIsPrompt() {
        XCTAssertEqual(StreamPressureTransitionPolicy.delay(from: .normal, to: .warning, sinceLastChange: 100), 3)
        XCTAssertEqual(StreamPressureTransitionPolicy.delay(from: .warning, to: .normal, sinceLastChange: 100), 12)
        XCTAssertEqual(StreamPressureTransitionPolicy.delay(from: .critical, to: .warning, sinceLastChange: 100), 12)
        XCTAssertEqual(StreamPressureTransitionPolicy.delay(from: .warning, to: .critical, sinceLastChange: 0), 0.1)
        XCTAssertEqual(StreamPressureTransitionPolicy.delay(from: .normal, to: .warning, sinceLastChange: 1), 7)
    }
    func testPeakBudgetAllowsBoundedKeyFrameHeadroom() {
        XCTAssertEqual(StreamQualityPolicy.peakBytesPerSecond(averageBitrate: 12_000_000), 2_250_000)
        XCTAssertEqual(StreamQualityPolicy.peakBytesPerSecond(averageBitrate: 120_000_000), 11_250_000)
    }
}
