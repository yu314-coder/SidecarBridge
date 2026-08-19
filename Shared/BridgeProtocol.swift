import Darwin
import Foundation
import CoreGraphics

/// Geometry shared by the iPad input surface, the virtual cursor overlay, and
/// the Mac event injector. Keeping the letterbox and normalization math in one
/// place prevents the overlay from slowly disagreeing with the touch surface
/// when the stream aspect ratio or viewer zoom changes.
enum RemoteDisplayGeometry {
    static func contentRect(in size: CGSize, aspectRatio: CGFloat) -> CGRect {
        guard size.width > 0, size.height > 0, aspectRatio > 0 else {
            return CGRect(origin: .zero, size: size)
        }
        let viewAspect = size.width / size.height
        if viewAspect > aspectRatio {
            let width = size.height * aspectRatio
            return CGRect(
                x: (size.width - width) / 2,
                y: 0,
                width: width,
                height: size.height
            )
        }
        let height = size.width / aspectRatio
        return CGRect(
            x: 0,
            y: (size.height - height) / 2,
            width: size.width,
            height: height
        )
    }

    static func normalizedPoint(
        _ point: CGPoint,
        in size: CGSize,
        aspectRatio: CGFloat,
        zoomScale: CGFloat = 1,
        zoomOffset: CGSize = .zero
    ) -> CGPoint? {
        guard size.width > 0, size.height > 0, aspectRatio > 0 else { return nil }

        // Match the older stable viewer path: undo SwiftUI's center scale and
        // offset first, then apply the untransformed letterbox. This is less
        // sensitive to fractional CGRect edges than testing a separately
        // transformed rectangle and is exactly how the image layer is laid
        // out by SwiftUI.
        let scale = max(zoomScale, 1)
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let untransformedPoint = CGPoint(
            x: center.x + (point.x - center.x - zoomOffset.width) / scale,
            y: center.y + (point.y - center.y - zoomOffset.height) / scale
        )
        let rect = contentRect(in: size, aspectRatio: aspectRatio)
        guard rect.width > 0, rect.height > 0, rect.contains(untransformedPoint) else { return nil }
        return CGPoint(
            x: (untransformedPoint.x - rect.minX) / rect.width,
            y: (untransformedPoint.y - rect.minY) / rect.height
        )
    }

    /// The exact rectangle occupied by the rendered screen after the same
    /// center-scale and offset used by the SwiftUI viewer. Keeping this
    /// explicit avoids subtle safe-area/letterbox drift between the image and
    /// the UIKit input surface.
    static func transformedContentRect(
        in size: CGSize,
        aspectRatio: CGFloat,
        zoomScale: CGFloat = 1,
        zoomOffset: CGSize = .zero
    ) -> CGRect {
        let base = contentRect(in: size, aspectRatio: aspectRatio)
        guard base.width > 0, base.height > 0 else { return base }
        let scale = max(zoomScale, 1)
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        return CGRect(
            x: center.x + (base.minX - center.x) * scale + zoomOffset.width,
            y: center.y + (base.minY - center.y) * scale + zoomOffset.height,
            width: base.width * scale,
            height: base.height * scale
        )
    }

    static func normalizedDelta(
        from previous: CGPoint,
        to current: CGPoint,
        in size: CGSize,
        aspectRatio: CGFloat,
        zoomScale: CGFloat = 1
    ) -> CGPoint? {
        guard size.width > 0, size.height > 0, aspectRatio > 0 else { return nil }
        let base = contentRect(in: size, aspectRatio: aspectRatio)
        guard base.width > 0, base.height > 0 else { return nil }
        let scale = max(zoomScale, 1)
        return CGPoint(
            x: (current.x - previous.x) / max(base.width * scale, 1),
            y: (current.y - previous.y) / max(base.height * scale, 1)
        )
    }

    static func displayPoint(for normalized: CGPoint, in bounds: CGRect) -> CGPoint {
        let maximumX = max(bounds.width - 1, 0)
        let maximumY = max(bounds.height - 1, 0)
        return CGPoint(
            x: bounds.minX + min(max(normalized.x, 0), 1) * maximumX,
            y: bounds.minY + min(max(normalized.y, 0), 1) * maximumY
        )
    }

    static func normalizedPoint(_ point: CGPoint, in bounds: CGRect) -> CGPoint? {
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        return CGPoint(
            x: min(max((point.x - bounds.minX) / bounds.width, 0), 1),
            y: min(max((point.y - bounds.minY) / bounds.height, 0), 1)
        )
    }
}

enum BridgeConstants {
    static let serviceType = "sb-screen"
    static let lanServiceType = "_sb-direct._tcp"
    static let directPort: UInt16 = 45_454
    // Bonjour TXT metadata is diagnostic only. Authentication still happens
    // through the encrypted handshake, but advertising the protocol/build
    // lets the mobile UI distinguish an old Mac binary before pairing fails.
    static let protocolTXTKey = "sbp"
    static let buildTXTKey = "build"
    // A Bonjour result can be filtered or resolved through the wrong active
    // interface when a Mac has Ethernet and Wi-Fi enabled together. The Mac
    // therefore advertises its private IPv4 candidates as a small hint. They
    // are still authenticated by the normal encrypted handshake before use.
    static let hostsTXTKey = "hosts"
}

enum BridgeNetworkMetadata {
    /// Returns private IPv4 addresses that can be reached from a local peer.
    /// Virtual-only and loopback interfaces are intentionally excluded.
    static func localPrivateIPv4Addresses() -> [String] {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return [] }
        defer { freeifaddrs(pointer) }

        var addresses = Set<String>()
        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let interface = current {
            defer { current = interface.pointee.ifa_next }
            guard let address = interface.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET),
                  (interface.pointee.ifa_flags & UInt32(IFF_UP)) != 0,
                  (interface.pointee.ifa_flags & UInt32(IFF_LOOPBACK)) == 0 else {
                continue
            }

            let name = String(cString: interface.pointee.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("bridge") else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(
                address,
                socklen_t(address.pointee.sa_len),
                &host,
                socklen_t(host.count),
                nil,
                0,
                NI_NUMERICHOST
            ) == 0 else { continue }

            let value = String(cString: host)
            let parts = value.split(separator: ".").compactMap { Int($0) }
            guard parts.count == 4,
                  parts.allSatisfy({ (0...255).contains($0) }),
                  isPrivateIPv4(parts) else { continue }
            addresses.insert(value)
        }
        return addresses.sorted()
    }

    /// Encodes a bounded TXT/discovery value. Private addresses are the only
    /// values emitted, so this never publishes a public or virtual endpoint.
    static func encodedLocalPrivateIPv4Addresses() -> String? {
        let value = localPrivateIPv4Addresses().joined(separator: ",")
        return value.isEmpty ? nil : value
    }

    static func decodePrivateIPv4Addresses(_ value: String?) -> [String] {
        guard let value else { return [] }
        var result = Set<String>()
        for raw in value.split(separator: ",") {
            let candidate = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = candidate.split(separator: ".").compactMap { Int($0) }
            guard parts.count == 4,
                  parts.allSatisfy({ (0...255).contains($0) }),
                  isPrivateIPv4(parts) else { continue }
            result.insert(candidate)
        }
        return result.sorted()
    }

    private static func isPrivateIPv4(_ parts: [Int]) -> Bool {
        parts[0] == 10 ||
            (parts[0] == 172 && (16...31).contains(parts[1])) ||
            (parts[0] == 192 && parts[1] == 168)
    }
}

struct BridgePeerIdentity: Codable, Equatable {
    let deviceID: String
    let deviceName: String
    let deviceKind: String

    var stableKey: String {
        let trimmedID = deviceID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedID.isEmpty { return trimmedID }
        return "\(deviceKind.lowercased()):\(deviceName.lowercased())"
    }

    var isValidForAuthentication: Bool {
        let identifierLength = deviceID.utf8.count
        let nameLength = deviceName.utf8.count
        let kindLength = deviceKind.utf8.count
        return (1...128).contains(identifierLength) &&
            (1...128).contains(nameLength) &&
            (1...32).contains(kindLength)
    }
}

enum LocalNetworkAccessState: Equatable {
    case checking
    case granted
    case denied
    case unavailable(String)

    var isGranted: Bool { self == .granted }
    var needsPermission: Bool { self == .denied }
}

enum ControlKind: String, Codable, Equatable {
    case hello
    case trySidecar
    case startFallback
    case stopFallback
    case status
    case input
    case requestSystemInformation
    case systemInformation
    case requestClipboard
    case clipboardText
    case clipboardError
}

struct ControlMessage: Codable, Equatable {
    let kind: ControlKind
    var detail: String?

    init(_ kind: ControlKind, detail: String? = nil) {
        self.kind = kind
        self.detail = detail
    }
}

/// Clipboard messages stay deliberately small so a copy operation cannot
/// monopolize the control channel. Larger files should use FileTransferEngine.
enum ClipboardTransfer {
    static let maximumTextBytes = 48 * 1_024

    static func prepare(_ text: String) -> String {
        guard text.utf8.count > maximumTextBytes else { return text }

        var result = ""
        var byteCount = 0
        for scalar in text.unicodeScalars {
            let value = String(scalar)
            let scalarBytes = value.utf8.count
            guard byteCount + scalarBytes <= maximumTextBytes else { break }
            result.append(contentsOf: value)
            byteCount += scalarBytes
        }
        return result
    }
}

enum RemoteInputKind: String, Codable, Equatable {
    case pointerMove
    case pointerDelta
    case primaryDown
    case primaryDrag
    case primaryUp
    case primaryClick
    case primaryDoubleClick
    case secondaryClick
    case secondaryDoubleClick
    case releaseButtons
    case scroll
    case text
    case key
    case inputMode
    case cycleInputMode
    case toggleChineseEnglishInputMode
}

enum RemoteScrollPhase: String, Codable, Equatable {
    case began
    case changed
    case ended
    case cancelled
}

enum RemotePointerButton: String, Codable, Equatable, Hashable {
    case primary
    case secondary
}

enum RemotePointerButtonMapping: String, Codable, Equatable, Hashable {
    case system
    case swapped

    func resolvedButton(for reportedButton: RemotePointerButton) -> RemotePointerButton {
        guard self == .swapped else { return reportedButton }
        return reportedButton == .primary ? .secondary : .primary
    }

    static func calibrated(reportedLeftButton: RemotePointerButton) -> Self {
        reportedLeftButton == .primary ? .system : .swapped
    }
}

struct RemoteInputEvent: Codable, Equatable {
    let kind: RemoteInputKind
    var sequence: UInt64?
    var x: Double?
    var y: Double?
    var deltaX: Double?
    var deltaY: Double?
    var text: String?
    var key: String?
    var hidUsage: Int?
    var modifiers: [String]?
    var clickCount: Int? = nil
    var scrollPhase: RemoteScrollPhase? = nil
    var isContinuousScroll: Bool? = nil

    static func pointer(x: Double, y: Double) -> Self {
        Self(kind: .pointerMove, sequence: nil, x: x, y: y)
    }

    static func pointerDelta(x: Double, y: Double) -> Self {
        Self(kind: .pointerDelta, sequence: nil, deltaX: x, deltaY: y)
    }

    static func click(
        secondary: Bool = false,
        x: Double? = nil,
        y: Double? = nil,
        modifiers: [String] = []
    ) -> Self {
        Self(
            kind: secondary ? .secondaryClick : .primaryClick,
            sequence: nil,
            x: x,
            y: y,
            modifiers: RemoteKeyboardInput.normalizedModifiers(modifiers)
        )
    }

    static func doubleClick(
        secondary: Bool = false,
        x: Double? = nil,
        y: Double? = nil,
        modifiers: [String] = []
    ) -> Self {
        Self(
            kind: secondary ? .secondaryDoubleClick : .primaryDoubleClick,
            sequence: nil,
            x: x,
            y: y,
            modifiers: RemoteKeyboardInput.normalizedModifiers(modifiers)
        )
    }

    static func primaryDown(
        x: Double,
        y: Double,
        clickCount: Int = 1,
        modifiers: [String] = []
    ) -> Self {
        Self(
            kind: .primaryDown,
            sequence: nil,
            x: x,
            y: y,
            modifiers: RemoteKeyboardInput.normalizedModifiers(modifiers),
            clickCount: max(clickCount, 1)
        )
    }

    static func primaryDownAtCurrentPointer(
        clickCount: Int = 1,
        modifiers: [String] = []
    ) -> Self {
        Self(
            kind: .primaryDown,
            sequence: nil,
            modifiers: RemoteKeyboardInput.normalizedModifiers(modifiers),
            clickCount: max(clickCount, 1)
        )
    }

    static func primaryDrag(
        x: Double,
        y: Double,
        clickCount: Int = 1,
        modifiers: [String] = []
    ) -> Self {
        Self(
            kind: .primaryDrag,
            sequence: nil,
            x: x,
            y: y,
            modifiers: RemoteKeyboardInput.normalizedModifiers(modifiers),
            clickCount: max(clickCount, 1)
        )
    }

    static func primaryUp(
        x: Double? = nil,
        y: Double? = nil,
        clickCount: Int = 1,
        modifiers: [String] = []
    ) -> Self {
        Self(
            kind: .primaryUp,
            sequence: nil,
            x: x,
            y: y,
            modifiers: RemoteKeyboardInput.normalizedModifiers(modifiers),
            clickCount: max(clickCount, 1)
        )
    }

    static func releaseButtons() -> Self {
        Self(kind: .releaseButtons, sequence: nil)
    }

    static func scroll(
        x: Double,
        y: Double,
        phase: RemoteScrollPhase? = nil,
        continuous: Bool? = nil
    ) -> Self {
        Self(
            kind: .scroll,
            sequence: nil,
            deltaX: x,
            deltaY: y,
            scrollPhase: phase,
            isContinuousScroll: continuous
        )
    }

    static func text(_ text: String) -> Self {
        Self(kind: .text, sequence: nil, text: text)
    }

    static func key(_ key: String, modifiers: [String] = []) -> Self {
        Self(
            kind: .key,
            sequence: nil,
            key: key.lowercased(),
            modifiers: RemoteKeyboardInput.normalizedModifiers(modifiers)
        )
    }

    static func hardwareKey(hidUsage: Int, modifiers: [String] = []) -> Self {
        Self(
            kind: .key,
            sequence: nil,
            hidUsage: hidUsage,
            modifiers: RemoteKeyboardInput.normalizedModifiers(modifiers)
        )
    }

    static func inputMode(language: String) -> Self {
        Self(
            kind: .inputMode,
            sequence: nil,
            text: RemoteKeyboardInput.normalizedLanguage(language)
        )
    }

    static func cycleInputMode() -> Self {
        Self(kind: .cycleInputMode, sequence: nil)
    }

    static func toggleChineseEnglishInputMode() -> Self {
        Self(kind: .toggleChineseEnglishInputMode, sequence: nil)
    }

    var isContinuousInput: Bool {
        switch kind {
        case .pointerMove, .pointerDelta, .primaryDrag, .scroll:
            return true
        default:
            return false
        }
    }

    var shouldAcknowledge: Bool {
        guard let sequence else { return false }
        return !isCoalescibleInput || sequence.isMultiple(of: 12)
    }

    var isCoalescibleInput: Bool {
        switch kind {
        case .pointerMove, .pointerDelta, .primaryDrag:
            return true
        case .scroll:
            return scrollPhase == nil || scrollPhase == .changed
        default:
            return false
        }
    }
}

struct RemoteInputCoalescer {
    private(set) var pending: [RemoteInputEvent] = []

    var count: Int { pending.count }
    var isEmpty: Bool { pending.isEmpty }

    mutating func enqueue(_ input: RemoteInputEvent) {
        guard input.isCoalescibleInput else {
            pending.append(input)
            return
        }

        let segmentStart = (pending.lastIndex { !$0.isCoalescibleInput }?.advanced(by: 1)) ?? 0
        let candidateIndices = pending.indices.reversed().filter { $0 >= segmentStart }

        switch input.kind {
        case .pointerMove, .primaryDrag:
            if let index = candidateIndices.first(where: { pending[$0].kind == input.kind }) {
                pending[index] = input
            } else {
                pending.append(input)
            }
        case .pointerDelta:
            if let index = candidateIndices.first(where: { pending[$0].kind == .pointerDelta }) {
                var accumulated = input
                accumulated.deltaX = (pending[index].deltaX ?? 0) + (input.deltaX ?? 0)
                accumulated.deltaY = (pending[index].deltaY ?? 0) + (input.deltaY ?? 0)
                pending[index] = accumulated
            } else {
                pending.append(input)
            }
        case .scroll:
            if let index = candidateIndices.first(where: {
                pending[$0].kind == .scroll &&
                    pending[$0].isContinuousScroll == input.isContinuousScroll
            }) {
                var accumulated = input
                accumulated.deltaX = (pending[index].deltaX ?? 0) + (input.deltaX ?? 0)
                accumulated.deltaY = (pending[index].deltaY ?? 0) + (input.deltaY ?? 0)
                pending[index] = accumulated
            } else {
                pending.append(input)
            }
        default:
            pending.append(input)
        }
    }

    mutating func popFirst() -> RemoteInputEvent? {
        guard !pending.isEmpty else { return nil }
        return pending.removeFirst()
    }

    mutating func removeAll() {
        pending.removeAll(keepingCapacity: true)
    }
}

struct RemoteClickSequenceTracker {
    private var completedAt: TimeInterval = 0
    private var completedX = 0.0
    private var completedY = 0.0
    private var completedCount = 0

    func nextCount(
        x: Double,
        y: Double,
        at timestamp: TimeInterval,
        interval: TimeInterval,
        maximumDistance: Double
    ) -> Int {
        let nearby = hypot(x - completedX, y - completedY) <= maximumDistance
        return timestamp - completedAt <= interval && nearby
            ? min(completedCount + 1, 2)
            : 1
    }

    mutating func complete(
        count: Int,
        x: Double,
        y: Double,
        beganAt: TimeInterval,
        endedAt: TimeInterval,
        interval: TimeInterval,
        movedBeyondClickSlop: Bool
    ) {
        guard !movedBeyondClickSlop, endedAt - beganAt <= interval else {
            reset()
            return
        }
        completedAt = endedAt
        completedX = x
        completedY = y
        completedCount = max(count, 1)
    }

    mutating func reset() {
        completedAt = 0
        completedX = 0
        completedY = 0
        completedCount = 0
    }
}

enum RemoteKeyboardInput {
    private static let modifierOrder = ["command", "option", "control", "shift"]

    static func normalizedModifiers(_ modifiers: [String]) -> [String] {
        let requested = Set(modifiers.map { $0.lowercased() })
        return modifierOrder.filter(requested.contains)
    }

    static func normalizedLanguage(_ language: String) -> String {
        language
            .replacingOccurrences(of: "_", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func supportsRemoteHIDUsage(_ usage: Int) -> Bool {
        macVirtualKeyCode(forHIDUsage: usage) != nil
    }

    static func isLanguageSwitchHIDUsage(_ usage: Int) -> Bool {
        // The Chinese iPad Magic Keyboard labels its Caps Lock position
        // "中/英". Apple reports that physical position as keyboardCapsLock
        // (USB HID usage 57), while iPadOS gives it language-switch semantics.
        // Treat it as an input-source key before the generic HID-to-Mac mapping
        // can consume it as Caps Lock. LANG1...LANG9 cover dedicated language
        // keys on other regional keyboards.
        usage == 57 || (144...152).contains(usage)
    }

    static func isChineseEnglishToggleHIDUsage(_ usage: Int) -> Bool {
        usage == 57
    }

    static func isDedicatedLanguageSwitchHIDUsage(_ usage: Int) -> Bool {
        (144...152).contains(usage)
    }

    static func isInputModeSwitchShortcut(
        hidUsage: Int,
        modifiers: [String]
    ) -> Bool {
        // Apple documents Control-Space as the external-keyboard shortcut for
        // cycling keyboards. Require Control alone so modified Space shortcuts
        // remain available to the remote Mac.
        hidUsage == 44 && normalizedModifiers(modifiers) == ["control"]
    }

    static func nextInputSourceID(
        currentID: String?,
        orderedIDs: [String]
    ) -> String? {
        guard !orderedIDs.isEmpty else { return nil }
        guard let currentID,
              let currentIndex = orderedIDs.firstIndex(of: currentID) else {
            return orderedIDs[0]
        }
        return orderedIDs[(currentIndex + 1) % orderedIDs.count]
    }

    static func macVirtualKeyCode(forHIDUsage usage: Int) -> UInt16? {
        let map: [Int: UInt16] = [
            4: 0, 5: 11, 6: 8, 7: 2, 8: 14, 9: 3, 10: 5, 11: 4,
            12: 34, 13: 38, 14: 40, 15: 37, 16: 46, 17: 45, 18: 31,
            19: 35, 20: 12, 21: 15, 22: 1, 23: 17, 24: 32, 25: 9,
            26: 13, 27: 7, 28: 16, 29: 6,
            30: 18, 31: 19, 32: 20, 33: 21, 34: 23, 35: 22, 36: 26,
            37: 28, 38: 25, 39: 29,
            40: 36, 41: 53, 42: 51, 43: 48, 44: 49, 45: 27, 46: 24,
            47: 33, 48: 30, 49: 42, 50: 10, 51: 41, 52: 39, 53: 50,
            54: 43, 55: 47, 56: 44, 57: 57,
            58: 122, 59: 120, 60: 99, 61: 118, 62: 96, 63: 97,
            64: 98, 65: 100, 66: 101, 67: 109, 68: 103, 69: 111,
            73: 114, 74: 115, 75: 116, 76: 117, 77: 119, 78: 121,
            79: 124, 80: 123, 81: 125, 82: 126,
            83: 71, 84: 75, 85: 67, 86: 78, 87: 69, 88: 76,
            89: 83, 90: 84, 91: 85, 92: 86, 93: 87, 94: 88,
            95: 89, 96: 91, 97: 92, 98: 82, 99: 65, 103: 81
        ]
        return map[usage]
    }

    static func event(
        text: String? = nil,
        key: String? = nil,
        hidUsage: Int? = nil,
        modifiers: [String] = []
    ) -> RemoteInputEvent? {
        let normalized = normalizedModifiers(modifiers)
        // UIKit reports a Magic Keyboard shortcut as a HID usage plus its
        // modifier snapshot. Convert special keys to their semantic names as
        // soon as a modifier is present. This avoids relying on the focused
        // Mac app to reinterpret a raw HID position and makes combinations
        // such as Control-arrow, Option-Tab, and Shift-Delete deterministic.
        if let hidUsage,
           !normalized.isEmpty,
           let shortcutKey = shortcutKeyName(forHIDUsage: hidUsage) {
            return .key(shortcutKey, modifiers: normalized)
        }
        if let hidUsage, supportsRemoteHIDUsage(hidUsage) {
            return .hardwareKey(hidUsage: hidUsage, modifiers: normalized)
        }
        if let key, !key.isEmpty {
            return .key(key.lowercased(), modifiers: normalized)
        }
        guard let text, !text.isEmpty else { return nil }
        return .text(text)
    }

    static func shortcutKeyName(forHIDUsage usage: Int) -> String? {
        switch usage {
        case 40: return "return"
        case 41: return "escape"
        case 42: return "delete"
        case 43: return "tab"
        case 44: return "space"
        case 73: return "help"
        case 74: return "home"
        case 75: return "pageup"
        case 76: return "forwarddelete"
        case 77: return "end"
        case 78: return "pagedown"
        case 79: return "right"
        case 80: return "left"
        case 81: return "down"
        case 82: return "up"
        default: return nil
        }
    }
}

enum RemoteSessionLifecyclePolicy {
    static let streamResumeRetentionInterval: TimeInterval = 5 * 60

    static func shouldRecoverStaleConnection(
        isViewerBackgrounded: Bool,
        peerSupportsHeartbeat: Bool,
        secondsSinceActivity: TimeInterval,
        timeout: TimeInterval = 9
    ) -> Bool {
        !isViewerBackgrounded
            && peerSupportsHeartbeat
            && secondsSinceActivity > timeout
    }

    static func shouldRetainStreamAfterDisconnect(isStreaming: Bool) -> Bool {
        isStreaming
    }
}

extension ControlMessage {
    static func input(_ event: RemoteInputEvent) -> ControlMessage? {
        guard let data = try? JSONEncoder().encode(event),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return ControlMessage(.input, detail: json)
    }

    var remoteInputEvent: RemoteInputEvent? {
        guard kind == .input, let detail, let data = detail.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(RemoteInputEvent.self, from: data)
    }

    static func clipboardText(_ text: String) -> ControlMessage {
        ControlMessage(.clipboardText, detail: ClipboardTransfer.prepare(text))
    }

    var clipboardTextPayload: String? {
        guard kind == .clipboardText,
              let detail,
              detail.utf8.count <= ClipboardTransfer.maximumTextBytes else { return nil }
        return detail
    }
}

enum BridgePacket: Equatable {
    case control(ControlMessage)
    case jpeg(Data)
    case video(VideoFrame)
    case file(FileTransferPacket)
    case authentication(PairingMessage)
}

enum FileTransferKind: String, Codable, Equatable {
    case begin
    case chunk
    case acknowledgement
    case complete
    case cancel
}

struct FileTransferPacket: Codable, Equatable {
    let kind: FileTransferKind
    let transferID: UUID
    var name: String?
    var totalSize: Int64?
    var offset: Int64?
    var payload: Data?
    var message: String?
    var sha256: Data? = nil
}

struct VideoFrame: Equatable {
    let sequence: UInt64
    let width: Int
    let height: Int
    let isKeyFrame: Bool
    let parameterSets: [Data]
    let sampleData: Data
}

enum PacketCodec {
    private static let maximumVideoDimension = 8_192
    private static let maximumVideoParameterSetCount = 8
    private static let maximumVideoParameterSetSize = 1 * 1024 * 1024
    private static let controlMarker: UInt8 = 1
    private static let jpegMarker: UInt8 = 2
    private static let videoMarker: UInt8 = 3
    private static let fileMarker: UInt8 = 4
    private static let authenticationMarker: UInt8 = 5

    private struct VideoHeader: Codable {
        let sequence: UInt64
        let width: Int
        let height: Int
        let isKeyFrame: Bool
        let parameterSets: [Data]
    }

    static func encode(_ packet: BridgePacket) throws -> Data {
        switch packet {
        case .control(let message):
            var data = Data([controlMarker])
            data.append(try JSONEncoder().encode(message))
            return data
        case .jpeg(let jpeg):
            var data = Data([jpegMarker])
            data.append(jpeg)
            return data
        case .video(let frame):
            let header = try JSONEncoder().encode(VideoHeader(
                sequence: frame.sequence,
                width: frame.width,
                height: frame.height,
                isKeyFrame: frame.isKeyFrame,
                parameterSets: frame.parameterSets
            ))
            guard header.count <= Int(UInt32.max) else { throw PacketError.invalidVideoFrame }
            var data = Data([videoMarker])
            let headerLength = UInt32(header.count).bigEndian
            withUnsafeBytes(of: headerLength) { data.append(contentsOf: $0) }
            data.append(header)
            data.append(frame.sampleData)
            return data
        case .file(let transfer):
            var data = Data([fileMarker])
            data.append(try JSONEncoder().encode(transfer))
            return data
        case .authentication(let message):
            var data = Data([authenticationMarker])
            data.append(try JSONEncoder().encode(message))
            return data
        }
    }

    static func decode(_ data: Data) throws -> BridgePacket {
        guard let marker = data.first else { throw PacketError.empty }
        let payload = data.dropFirst()

        switch marker {
        case controlMarker:
            let message = try JSONDecoder().decode(ControlMessage.self, from: payload)
            guard (message.detail?.utf8.count ?? 0) <= 64 * 1024 else {
                throw PacketError.invalidControlMessage
            }
            return .control(message)
        case jpegMarker:
            guard !payload.isEmpty else { throw PacketError.emptyFrame }
            return .jpeg(Data(payload))
        case videoMarker:
            let videoData = Data(payload)
            guard videoData.count >= 5 else { throw PacketError.invalidVideoFrame }
            let headerLength = videoData.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            let headerEnd = 4 + Int(headerLength)
            guard headerLength > 0, videoData.count > headerEnd else { throw PacketError.invalidVideoFrame }
            let header = try JSONDecoder().decode(VideoHeader.self, from: videoData[4..<headerEnd])
            guard (1...maximumVideoDimension).contains(header.width),
                  (1...maximumVideoDimension).contains(header.height),
                  header.parameterSets.count <= maximumVideoParameterSetCount,
                  header.parameterSets.allSatisfy({
                      !$0.isEmpty && $0.count <= maximumVideoParameterSetSize
                  }),
                  videoData.count - headerEnd <= LANWire.maximumPayloadSize else {
                throw PacketError.invalidVideoFrame
            }
            return .video(VideoFrame(
                sequence: header.sequence,
                width: header.width,
                height: header.height,
                isKeyFrame: header.isKeyFrame,
                parameterSets: header.parameterSets,
                sampleData: Data(videoData[headerEnd...])
            ))
        case fileMarker:
            return .file(try JSONDecoder().decode(FileTransferPacket.self, from: payload))
        case authenticationMarker:
            let message = try JSONDecoder().decode(PairingMessage.self, from: payload)
            guard message.isStructurallyValid else { throw PacketError.invalidAuthenticationMessage }
            return .authentication(message)
        default:
            throw PacketError.unknownMarker(marker)
        }
    }

    enum PacketError: LocalizedError, Equatable {
        case empty
        case emptyFrame
        case invalidVideoFrame
        case invalidControlMessage
        case invalidAuthenticationMessage
        case unknownMarker(UInt8)

        var errorDescription: String? {
            switch self {
            case .empty: return "The packet is empty."
            case .emptyFrame: return "The frame has no image data."
            case .invalidVideoFrame: return "The video frame is malformed."
            case .invalidControlMessage: return "The control packet is too large."
            case .invalidAuthenticationMessage: return "The authentication packet is malformed."
            case .unknownMarker(let marker): return "Unknown packet marker: \(marker)."
            }
        }
    }
}
