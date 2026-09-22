import Foundation

/// Live-video experiment. Never downscale a user's stream merely to enable
/// frame generation, and never synthesize across a stall.
enum FrameInterpolationPolicy {
    static let legacyMaximumDimension = 1920
    static let legacyMaximumPixelCount = 1920 * 1080

    static func supportsDimensions(width: Int, height: Int,
                                   maximumDimension: Int = legacyMaximumDimension,
                                   maximumPixelCount: Int = legacyMaximumPixelCount) -> Bool {
        guard width > 0, height > 0, maximumDimension > 0, maximumPixelCount > 0,
              width <= maximumDimension, height <= maximumDimension else { return false }
        // Division avoids overflowing if a malformed format description reports
        // an unexpectedly large dimension.
        return width <= maximumPixelCount / height
    }

    static func shouldInterpolate(interval: Double, processingTime: Double,
                                  refreshRate: Int) -> Bool {
        interval.isFinite && processingTime.isFinite && interval >= 1.0 / 65
            && interval <= 1.0 / 25 && processingTime >= 0
            && processingTime < interval * 0.75
            && Double(refreshRate) >= 1.8 / interval
    }

    static func needsResumeReset(connected: Bool, pipActive: Bool,
                                 lastFrameAge: Double) -> Bool {
        !connected || !pipActive || !lastFrameAge.isFinite || lastFrameAge > 1
    }
}
