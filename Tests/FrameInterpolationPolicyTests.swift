import XCTest

final class FrameInterpolationPolicyTests: XCTestCase {
    func testResolutionLimitsPreserveNativeQuality() {
        XCTAssertTrue(FrameInterpolationPolicy.supportsDimensions(width: 1920, height: 1080))
        XCTAssertTrue(FrameInterpolationPolicy.supportsDimensions(width: 1080, height: 1920))
        XCTAssertFalse(FrameInterpolationPolicy.supportsDimensions(width: 3840, height: 2160))
        XCTAssertFalse(FrameInterpolationPolicy.supportsDimensions(width: 1920, height: 1920))
        XCTAssertFalse(FrameInterpolationPolicy.supportsDimensions(width: 0, height: 1080))
    }

    func testGenerationNeedsHeadroomAndFreshFrames() {
        XCTAssertTrue(FrameInterpolationPolicy.shouldInterpolate(interval: 1/60, processingTime: 0.005, refreshRate: 120))
        XCTAssertTrue(FrameInterpolationPolicy.shouldInterpolate(interval: 1/30, processingTime: 0.005, refreshRate: 60))
        XCTAssertFalse(FrameInterpolationPolicy.shouldInterpolate(interval: 1/60, processingTime: 0.020, refreshRate: 120))
        XCTAssertFalse(FrameInterpolationPolicy.shouldInterpolate(interval: 1/60, processingTime: 0.005, refreshRate: 60))
        XCTAssertFalse(FrameInterpolationPolicy.shouldInterpolate(interval: 1, processingTime: 0.005, refreshRate: 120))
        XCTAssertFalse(FrameInterpolationPolicy.shouldInterpolate(interval: .nan, processingTime: 0, refreshRate: 120))
    }

    func testHealthyPiPDoesNotRestartVideoOnReturn() {
        XCTAssertFalse(FrameInterpolationPolicy.needsResumeReset(connected: true, pipActive: true, lastFrameAge: 0.1))
        XCTAssertTrue(FrameInterpolationPolicy.needsResumeReset(connected: true, pipActive: true, lastFrameAge: 4))
        XCTAssertTrue(FrameInterpolationPolicy.needsResumeReset(connected: false, pipActive: true, lastFrameAge: 0.1))
        XCTAssertTrue(FrameInterpolationPolicy.needsResumeReset(connected: true, pipActive: false, lastFrameAge: 0.1))
    }
}
