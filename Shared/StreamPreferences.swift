import Foundation

/// The capture request sent by the iPad to the Mac. These are targets, not
/// promises: ScreenCaptureKit and the physical display can deliver fewer
/// frames, and the Mac clamps the request for a nearby fallback link.
enum StreamResolutionPreference: String, CaseIterable, Identifiable {
    case adaptive
    case fullHD = "1080p"
    case twoK = "2k"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .adaptive: return "Adaptive"
        case .fullHD: return "1080p"
        case .twoK: return "2K"
        }
    }

    var detail: String {
        switch self {
        case .adaptive:
            return "Uses the iPad's native size up to 2360 pixels."
        case .fullHD:
            return "Caps capture at 1920 pixels for a lighter stream."
        case .twoK:
            return "Captures up to 2560 pixels when the Mac display supports it."
        }
    }

    /// A nil width lets the Mac use its adaptive cap. The Mac still limits
    /// this value to the connected display and transport's safe maximum.
    var maximumWidth: Int? {
        switch self {
        case .adaptive: return nil
        case .fullHD: return 1920
        case .twoK: return 2560
        }
    }
}

enum StreamFrameRatePreference: Int, CaseIterable, Identifiable {
    case fps30 = 30
    case fps60 = 60
    case fps90 = 90
    case fps120 = 120
    case fps144 = 144
    case fps165 = 165
    case fps240 = 240

    var id: Int { rawValue }

    var title: String {
        rawValue == 240 ? "No fixed cap (up to 240 FPS)" : "\(rawValue) FPS"
    }
}

/// Persists the viewer's cadence target and upgrades the old implicit 60-FPS
/// default once. Older builds stored 60 without recording whether the user
/// had selected it, which made an upgrade look permanently capped at 60 even
/// though the nearby path could already run at 120. The first build using
/// this store treats that unmarked value as the legacy default; any selection
/// made after the migration is retained exactly.
enum StreamPreferenceStore {
    static let resolutionKey = "streamResolutionPreference"
    static let frameRateKey = "streamFrameRatePreference"
    static let ultraModeKey = "streamUltraModeEnabled"
    private static let migrationKey = "streamFrameRatePreferenceV3Migrated"
    private static let explicitSelectionKey = "streamFrameRatePreferenceExplicit"

    static func loadFrameRate(
        defaults: UserDefaults = .standard
    ) -> StreamFrameRatePreference {
        migrateLegacyDefaultIfNeeded(defaults: defaults)
        return StreamFrameRatePreference(
            rawValue: defaults.integer(forKey: frameRateKey)
        ) ?? StreamPreferences.defaults.frameRate
    }

    static func saveFrameRate(
        _ frameRate: StreamFrameRatePreference,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(frameRate.rawValue, forKey: frameRateKey)
        defaults.set(true, forKey: explicitSelectionKey)
        defaults.set(true, forKey: migrationKey)
    }

    static func loadUltraMode(
        defaults: UserDefaults = .standard
    ) -> Bool {
        defaults.bool(forKey: ultraModeKey)
    }

    static func saveUltraMode(
        _ enabled: Bool,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(enabled, forKey: ultraModeKey)
    }

    private static func migrateLegacyDefaultIfNeeded(defaults: UserDefaults) {
        guard defaults.object(forKey: migrationKey) == nil else { return }
        let stored = defaults.integer(forKey: frameRateKey)
        let wasExplicit = defaults.bool(forKey: explicitSelectionKey)
        // A zero value is a fresh install. A 60 value is the implicit default
        // written by older releases. Do not overwrite an explicitly selected
        // value if a future/older build has already recorded that intent.
        if !wasExplicit && (stored == 0 || stored == StreamFrameRatePreference.fps60.rawValue) {
            defaults.set(StreamFrameRatePreference.fps120.rawValue, forKey: frameRateKey)
        }
        defaults.set(true, forKey: migrationKey)
    }
}

/// System-wide macOS memory pressure profile used to keep the capture and
/// encoder from competing with the rest of the user's workload. This is a
/// temporary safety cap; the saved stream preference is never overwritten.
enum StreamMemoryPressureLevel: String, Equatable {
    case normal
    case warning
    case critical

    var frameRateCeiling: Int {
        switch self {
        case .normal: return 120
        // Keep the high-cadence path alive while reducing the surface and
        // encoder budget below. A 30-FPS cap at the first yellow warning made
        // pressure transitions look like a frozen/1-FPS stream because the
        // sender and decoder were also being reset at the same time.
        case .warning: return 60
        // Keep the live-control cadence floor at 60 FPS even when macOS is
        // under critical pressure.  The pressure profile reduces the capture
        // surface and bitrate instead of deliberately switching the sender to
        // a keyframe-only-looking 30/1-FPS recovery cadence.
        case .critical: return 60
        }
    }

    /// Ultra mode keeps its cadence while the pressure profile reduces the
    /// capture surface, bitrate, and VideoToolbox in-flight window. Lowering
    /// cadence to the generic 60-FPS warning ceiling made a yellow memory
    /// notification look like an ultra stream that could never reach 90/120.
    static func frameRateCeiling(
        _ level: StreamMemoryPressureLevel,
        ultraModeEnabled: Bool
    ) -> Int {
        guard ultraModeEnabled else { return level.frameRateCeiling }
        switch level {
        case .normal: return StreamCadencePolicy.maximumFrameRate
        case .warning: return StreamCadencePolicy.ultraConstrainedFrameRateCeiling
        case .critical: return StreamCadencePolicy.ultraSevereFrameRateCeiling
        }
    }

    var bitrateMultiplier: Double {
        switch self {
        case .normal: return 1.0
        // A warning is a reason to reduce encoder/network working-set size,
        // not a reason to let the stream enter a keyframe-only recovery loop.
        // Keep enough bitrate for text while leaving headroom for the Mac's
        // other applications and the input channel.
        case .warning: return 0.22
        case .critical: return 0.10
        }
    }

    /// A lower capture width is the most effective way to keep a Mac from
    /// paging large IOSurface and encoder buffers. This is a temporary cap;
    /// the user's selected quality is restored after pressure clears.
    var captureWidthCeiling: Int? {
        switch self {
        case .normal: return nil
        // Yellow pressure is already enough for ScreenCaptureKit and
        // VideoToolbox to evict large IOSurfaces on older Macs. Move to a
        // 1080p-class surface once (the caller debounces this media boundary)
        // instead of leaving a 2K surface alive and hoping a bitrate change
        // alone will make the encoder catch up.
        case .warning: return 1920
        case .critical: return 1280
        }
    }

    var detail: String {
        switch self {
        case .normal:
            return "Memory pressure normal — selected stream target is active."
        case .warning:
            return "macOS memory pressure — stream temporarily capped at 1920 px and 60 FPS with a lighter bitrate to keep video live."
        case .critical:
            return "Critical memory pressure — stream temporarily capped at 1280 px while preserving a 60 FPS target."
        }
    }

    func detail(ultraModeEnabled: Bool) -> String {
        guard ultraModeEnabled else { return detail }
        switch self {
        case .normal:
            return "Memory pressure normal — ultra cadence target is active."
        case .warning:
            return "Memory pressure warning — ultra stream is using a 1920-pixel surface and 120-FPS target."
        case .critical:
            return "Critical memory pressure — ultra stream is using a 1280-pixel surface and 90-FPS target."
        }
    }
}

struct StreamPreferences: Equatable {
    static let defaults = StreamPreferences(
        resolution: .adaptive,
        // Prefer the highest useful cadence by default. Direct local links
        // clamp this to the connected display's refresh rate, while nearby
        // P2P can use the full 120-FPS target and background/PiP applies a
        // separate 60-FPS ceiling.
        frameRate: .fps120
    )

    var resolution: StreamResolutionPreference
    var frameRate: StreamFrameRatePreference
    /// Developer-only high-cadence mode. It is intentionally part of the
    /// wire preference so the Mac, not only the iPad UI, controls capture,
    /// VideoToolbox, and transport ceilings consistently.
    var ultraModeEnabled = false

    var encodedDetail: String {
        var detail = "stream-preferences:resolution=\(resolution.rawValue);fps=\(frameRate.rawValue)"
        if ultraModeEnabled {
            detail += ";ultra=1"
        }
        return detail
    }

    /// Parses the deliberately small semicolon-separated hello extension.
    /// Unknown keys are ignored so a future sender can add capabilities
    /// without making this build reject the connection.
    static func parse(_ detail: String) -> StreamPreferences? {
        let prefix = "stream-preferences:"
        guard detail.hasPrefix(prefix) else { return nil }

        var resolution: StreamResolutionPreference?
        var frameRate: StreamFrameRatePreference?
        var ultraModeEnabled = false
        for component in detail.dropFirst(prefix.count).split(separator: ";") {
            let pair = component.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2 else { continue }
            switch pair[0].lowercased() {
            case "resolution", "quality":
                resolution = StreamResolutionPreference(rawValue: pair[1].lowercased())
            case "fps", "framerate", "frame-rate":
                if let value = Int(pair[1]) {
                    frameRate = StreamFrameRatePreference(rawValue: value)
                }
            case "ultra", "ultra-fps", "ultra-mode":
                ultraModeEnabled = ["1", "true", "yes", "on"].contains(pair[1].lowercased())
            default:
                continue
            }
        }

        guard let resolution, let frameRate,
              ultraModeEnabled || frameRate.rawValue <= StreamCadencePolicy.nearbyFrameRateCeiling else {
            return nil
        }
        return StreamPreferences(
            resolution: resolution,
            frameRate: frameRate,
            ultraModeEnabled: ultraModeEnabled
        )
    }
}

/// Control-channel markers for presentation-only changes. These are kept
/// separate from the transport handshake so changing a viewer preference can
/// reset the decoder without tearing down the authenticated input session.
enum StreamSessionSignal {
    static let videoRefresh = "video-refresh"
}

/// Sender-side congestion feedback. This is deliberately separate from
/// macOS memory pressure: a healthy Mac can still have a link or decoder that
/// cannot drain a 120-FPS stream. The sender lowers cadence only as far as
/// necessary, then returns to the user's target after the queue recovers.
enum StreamBackpressureLevel: Equatable {
    case normal
    case constrained
    case severe

    var frameRateCeiling: Int {
        switch self {
        case .normal: return 120
        case .constrained: return 60
        // Severe transport pressure must not lower the advertised cadence to
        // 60 FPS. Keep the capture clock at 60 and shed work at the bounded
        // encoder/transport queues instead; dropping the clock here made the
        // next IDR look like a one-FPS stream.
        case .severe: return 60
        }
    }
}

/// Cadence rules shared by the capture and display sides of the stream.
///
/// Sixty FPS is the live-control target floor for an active viewer whenever
/// the display and route can sustain it. A target higher than the connected
/// display can still be clamped; foreground nearby Multipeer may target up to
/// 120 FPS (or up to 240 FPS in the developer-only ultra mode). A transient
/// queue warning keeps ultra mode at 120 FPS and a genuine severe stall steps
/// down only to 90 FPS; the non-ultra path uses the conservative 60-FPS cap.
/// The app never deliberately switches an active or PiP stream to a 2/15 FPS
/// power-saving mode.
enum StreamCadencePolicy {
    static let maximumFrameRate = 240
    /// Do not intentionally throttle a live session below 60 FPS. A display
    /// with a lower physical refresh rate can still deliver fewer samples,
    /// but the capture/encoder/transport policy must not turn memory or link
    /// pressure into the observed one-FPS keyframe cadence.
    static let minimumLiveFrameRate = 60
    /// iPadOS keeps a PiP surface alive in the background, but its scheduler
    /// is not a reliable 90/120-FPS presentation target. Keep that path at a
    /// responsive 60-FPS ceiling instead of intentionally falling back to a
    /// 60-FPS stream.
    static let backgroundFrameRateCeiling = 60
    /// Foreground AWDL/Multipeer may target the full 120-FPS preference. The
    /// sender and receiver queues remain bounded. Non-ultra transport
    /// backpressure can temporarily lower the active cadence to 60 FPS; ultra
    /// mode uses the 120/90-FPS recovery ceilings below instead.
    static let nearbyFrameRateCeiling = 120
    /// The developer-only ultra mode raises the nearby ceiling to the
    /// highest cadence representable by the current protocol and capture
    /// configuration. The physical display can still deliver fewer frames.
    static let ultraFrameRateCeiling = 240

    /// A transient transport warning must not turn an ultra session into a
    /// 60-FPS/keyframe-only stream. 120 FPS is the stable high-cadence target
    /// while a local queue is draining; only a severe stall steps down to 90
    /// FPS so the session keeps moving and can recover without oscillating.
    static let ultraConstrainedFrameRateCeiling = 120
    static let ultraSevereFrameRateCeiling = 90

    static func backpressureFrameRateCeiling(
        _ level: StreamBackpressureLevel,
        ultraModeEnabled: Bool
    ) -> Int {
        guard ultraModeEnabled else { return level.frameRateCeiling }
        switch level {
        case .normal:
            return ultraFrameRateCeiling
        case .constrained:
            return ultraConstrainedFrameRateCeiling
        case .severe:
            return ultraSevereFrameRateCeiling
        }
    }

    static func effectiveFrameRate(
        requested: Int,
        displayRefreshRate: Int,
        isNearby: Bool,
        viewerIsBackgrounded: Bool,
        waitingForViewerResume: Bool,
        memoryPressure: StreamMemoryPressureLevel = .normal,
        backpressure: StreamBackpressureLevel = .normal,
        ultraModeEnabled: Bool = false
    ) -> Int {
        let maximum = ultraModeEnabled ? ultraFrameRateCeiling : nearbyFrameRateCeiling
        let safeRequested = min(max(requested, minimumLiveFrameRate), maximum)
        let safeDisplayRate = min(max(displayRefreshRate, minimumLiveFrameRate), 240)
        let foreground = isNearby
            ? min(safeRequested, ultraModeEnabled ? ultraFrameRateCeiling : nearbyFrameRateCeiling)
            : min(safeRequested, safeDisplayRate)
        let backpressureCeiling = backpressureFrameRateCeiling(
            backpressure,
            ultraModeEnabled: ultraModeEnabled
        )
        // Ultra mode has its own pressure ceilings. The generic memory
        // profile's 120-FPS normal/warning value is a non-ultra safety default;
        // applying it to every ultra state would silently cap a healthy 240
        // request and would make yellow pressure look like a hard 60-FPS cap.
        let memoryCeiling = StreamMemoryPressureLevel.frameRateCeiling(
            memoryPressure,
            ultraModeEnabled: ultraModeEnabled
        )
        let pressureCappedForeground = min(
            foreground,
            min(memoryCeiling, backpressureCeiling)
        )

        // PiP/background and the short resume grace window use a responsive
        // 60-FPS ceiling. This is intentionally not a low-power 2/15 FPS
        // mode: those explicit throttles were the source of very low 1% lows.
        if viewerIsBackgrounded || waitingForViewerResume {
            return max(minimumLiveFrameRate, min(pressureCappedForeground, backgroundFrameRateCeiling))
        }
        return max(minimumLiveFrameRate, pressureCappedForeground)
    }

    static func decoderQueueDepth(for frameRate: Int) -> Int {
        let safeRate = min(max(frameRate, minimumLiveFrameRate), maximumFrameRate)
        // This is a latency buffer, not a frame-rate buffer. A deep queue
        // keeps presenting old samples after a brief render hiccup. Keep the
        // display close to the live edge; the display controller drops only
        // not-yet-rendered samples and waits for an IDR without blanking the
        // last image already on screen.
        if safeRate >= 240 { return 24 }
        if safeRate >= 120 { return 16 }
        if safeRate >= 60 { return 12 }
        return 8
    }

    static func captureQueueDepth(for frameRate: Int) -> Int {
        // Keep the capture source supplied while VideoToolbox is completing a
        // high-cadence callback. Two surfaces starve ScreenCaptureKit on some
        // Macs and make the encoder appear to alternate between 2 and 60 FPS;
        // three is still a small bounded queue, while 240 FPS gets one extra
        // surface for its shorter interval.
        return frameRate >= 240 ? 4 : 3
    }

    /// Keep enough Network.framework sends in flight to cover a short local
    /// scheduling/ACK gap at high cadence without allowing an unbounded TCP
    /// backlog. These are transport windows, not display queues.
    static func senderInFlightWindow(for frameRate: Int) -> Int {
        let safeRate = min(max(frameRate, minimumLiveFrameRate), maximumFrameRate)
        // TCP send completion is a local protocol-stack signal, not a display
        // acknowledgement. Keep this window deliberately short so a busy
        // receiver cannot turn H.264 frames into a multi-second RAM backlog.
        if safeRate >= 240 { return 16 }
        if safeRate >= 120 { return 12 }
        if safeRate >= 90 { return 10 }
        if safeRate >= 60 { return 8 }
        return 4
    }

    static func senderPendingWindow(for frameRate: Int) -> Int {
        senderInFlightWindow(for: frameRate) + 1
    }

    static func receiverPendingWindow(for frameRate: Int) -> Int {
        let safeRate = min(max(frameRate, minimumLiveFrameRate), maximumFrameRate)
        // The receiver queue is measured in frames, not bytes. Keep it below
        // the one-second keyframe interval so a main-thread hiccup cannot
        // retain a long chain of stale full-resolution samples.
        if safeRate >= 240 { return 36 }
        if safeRate >= 120 { return 24 }
        if safeRate >= 90 { return 20 }
        if safeRate >= 60 { return 16 }
        return 10
    }

    /// `contentProcessed` can legitimately take longer while macOS is under
    /// memory pressure. This guard is only for a real connection stall; it
    /// must not turn one delayed local send into a periodic 1-FPS IDR stream.
    static let senderStallTimeout: TimeInterval = 4.0
}
