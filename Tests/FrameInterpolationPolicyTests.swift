import XCTest

final class FrameInterpolationPolicyTests: XCTestCase {
    func testResolutionLimitsPreserveNativeQuality() {
        XCTAssertTrue(FrameInterpolationPolicy.supportsDimensions(width: 1920, height: 1080))
        XCTAssertTrue(FrameInterpolationPolicy.supportsDimensions(width: 1080, height: 1920))
        XCTAssertFalse(FrameInterpolationPolicy.supportsDimensions(width: 3840, height: 2160))
        XCTAssertFalse(FrameInterpolationPolicy.supportsDimensions(width: 1920, height: 1920))
        XCTAssertFalse(FrameInterpolationPolicy.supportsDimensions(width: 0, height: 1080))
    }

    func testRuntimeDeviceLimitsPermitHigherResolution() {
        let eightMegapixels = 3840 * 2160
        XCTAssertTrue(FrameInterpolationPolicy.supportsDimensions(
            width: 2560, height: 1440, maximumDimension: 4096, maximumPixelCount: eightMegapixels))
        XCTAssertTrue(FrameInterpolationPolicy.supportsDimensions(
            width: 3840, height: 2160, maximumDimension: 4096, maximumPixelCount: eightMegapixels))
        XCTAssertFalse(FrameInterpolationPolicy.supportsDimensions(
            width: 4097, height: 1080, maximumDimension: 4096, maximumPixelCount: 12_000_000))
        XCTAssertFalse(FrameInterpolationPolicy.supportsDimensions(
            width: 3840, height: 2160, maximumDimension: 4096, maximumPixelCount: 8_000_000))
    }

    func testGenerationNeedsHeadroomAndFreshFrames() {
        XCTAssertTrue(FrameInterpolationPolicy.shouldInterpolate(interval: 1/60, processingTime: 0.005, refreshRate: 120))
        XCTAssertTrue(FrameInterpolationPolicy.shouldInterpolate(interval: 1/30, processingTime: 0.005, refreshRate: 60))
        XCTAssertTrue(FrameInterpolationPolicy.shouldInterpolate(interval: 1/60, processingTime: 0.020, refreshRate: 120))
        XCTAssertFalse(FrameInterpolationPolicy.shouldInterpolate(interval: 1/60, processingTime: 0.050, refreshRate: 120))
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
