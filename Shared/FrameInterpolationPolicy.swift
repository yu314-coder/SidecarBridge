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
            // The processor runs after the source frame arrives. A modest
            // presentation delay lets a 4K frame take longer than one source
            // interval without making its midpoint unusable.
            && processingTime < min(0.05, interval * 2.5)
            && Double(refreshRate) >= 1.8 / interval
    }

    static func needsResumeReset(connected: Bool, pipActive: Bool,
                                 lastFrameAge: Double) -> Bool {
        !connected || !pipActive || !lastFrameAge.isFinite || lastFrameAge > 1
    }
}
