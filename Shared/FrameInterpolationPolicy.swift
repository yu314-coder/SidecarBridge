import Foundation

/// Conservative live-video experiment. Never downscale a user's 4K stream
/// merely to enable frame generation, and never synthesize across a stall.
enum FrameInterpolationPolicy {
    static func supportsDimensions(width: Int, height: Int) -> Bool {
        width > 0 && height > 0 && width <= 1920 && height <= 1920
            && width * height <= 1920 * 1080
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
