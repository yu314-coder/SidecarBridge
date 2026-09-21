import Foundation

/// Stateful conversion keeps held mouse buttons/modifiers intact during a drag.
struct RFBInput {
    var x = 0.5
    var y = 0.5
    private var buttons: UInt8 = 0
    private var heldModifiers: [UInt32] = []
    private var scrollX = 0.0
    private var scrollY = 0.0

    mutating func encode(_ event: RemoteInputEvent, width: Int, height: Int) -> Data {
        guard width > 0, height > 0 else { return Data() }
        var output = Data()
        func pointer(_ mask: UInt8) -> Data {
            RFBProtocol.pointer(x: Int(x * Double(width - 1)), y: Int(y * Double(height - 1)), buttons: mask)
        }
        func chord(_ symbol: UInt32, _ modifiers: [UInt32]) -> Data {
            var bytes = Data()
            let temporaryModifiers = modifiers.filter { !heldModifiers.contains($0) }
            for modifier in temporaryModifiers { bytes.append(RFBProtocol.key(modifier, down: true)) }
            bytes.append(RFBProtocol.key(symbol, down: true))
            bytes.append(RFBProtocol.key(symbol, down: false))
            for modifier in temporaryModifiers.reversed() { bytes.append(RFBProtocol.key(modifier, down: false)) }
            return bytes
        }
        if let value = event.x, value.isFinite { x = min(1, max(0, value)) }
        if let value = event.y, value.isFinite { y = min(1, max(0, value)) }
        let modifiers = (event.modifiers ?? []).compactMap { Self.modifiers[$0] }
        switch event.kind {
        case .pointerDelta:
            if let dx = event.deltaX, dx.isFinite { x = min(1, max(0, x + dx)) }
            if let dy = event.deltaY, dy.isFinite { y = min(1, max(0, y + dy)) }
            output.append(pointer(buttons))
        case .pointerMove, .primaryDrag:
            output.append(pointer(buttons))
        case .primaryDown:
            for modifier in heldModifiers.reversed() { output.append(RFBProtocol.key(modifier, down: false)) }
            heldModifiers = modifiers
            for modifier in heldModifiers { output.append(RFBProtocol.key(modifier, down: true)) }
            buttons |= 1; output.append(pointer(buttons))
        case .primaryUp, .releaseButtons:
            buttons = 0; output.append(pointer(0))
            for modifier in heldModifiers.reversed() { output.append(RFBProtocol.key(modifier, down: false)) }
            heldModifiers = []
        case .primaryClick, .primaryDoubleClick, .secondaryClick, .secondaryDoubleClick:
            let mask: UInt8 = (event.kind == .secondaryClick || event.kind == .secondaryDoubleClick) ? 4 : 1
            let count = (event.kind == .primaryDoubleClick || event.kind == .secondaryDoubleClick) ? 2 : 1
            let temporaryModifiers = modifiers.filter { !heldModifiers.contains($0) }
            for modifier in temporaryModifiers { output.append(RFBProtocol.key(modifier, down: true)) }
            for _ in 0..<count { output.append(pointer(buttons | mask)); output.append(pointer(buttons)) }
            for modifier in temporaryModifiers.reversed() { output.append(RFBProtocol.key(modifier, down: false)) }
        case .scroll:
            if let dx = event.deltaX, dx.isFinite { scrollX += min(500, max(-500, dx)) }
            if let dy = event.deltaY, dy.isFinite { scrollY += min(500, max(-500, dy)) }
            while abs(scrollY) >= 12 {
                let mask: UInt8 = scrollY > 0 ? 8 : 16
                output.append(pointer(buttons | mask)); output.append(pointer(buttons))
                scrollY += scrollY > 0 ? -12 : 12
            }
            while abs(scrollX) >= 12 {
                let mask: UInt8 = scrollX > 0 ? 32 : 64
                output.append(pointer(buttons | mask)); output.append(pointer(buttons))
                scrollX += scrollX > 0 ? -12 : 12
            }
        case .key:
            if let symbol = Self.keysym(key: event.key, hid: event.hidUsage) { output.append(chord(symbol, modifiers)) }
        case .text:
            for scalar in (event.text ?? "").prefix(4096).unicodeScalars {
                let symbol: UInt32 = scalar.value == 10 ? 0xff0d : (scalar.value <= 255 ? scalar.value : 0x01000000 | scalar.value)
                output.append(chord(symbol, modifiers))
            }
        case .cycleInputMode, .toggleChineseEnglishInputMode:
            output.append(chord(32, [0xffe3])) // macOS default input-source shortcut: Control-Space.
        case .inputMode: break // VNC has no API to select a named macOS input source.
        }
        return output
    }
    private static let modifiers: [String: UInt32] = ["command": 0xffe7, "control": 0xffe3, "option": 0xffe9, "shift": 0xffe1]
    static func keysym(key: String?, hid: Int?) -> UInt32? {
        let named: [String: UInt32] = ["return": 0xff0d, "enter": 0xff0d, "escape": 0xff1b,
            "delete": 0xff08, "backspace": 0xff08, "forwarddelete": 0xffff, "tab": 0xff09,
            "space": 32, "left": 0xff51, "up": 0xff52, "right": 0xff53, "down": 0xff54,
            "home": 0xff50, "end": 0xff57, "pageup": 0xff55, "pagedown": 0xff56, "help": 0xff63]
        if let key {
            if let value = named[key] { return value }
            if key.hasPrefix("f"), let number = Int(key.dropFirst()), (1...20).contains(number) { return 0xffbd + UInt32(number) }
            if key.unicodeScalars.count == 1, let scalar = key.unicodeScalars.first {
                return scalar.value <= 255 ? scalar.value : 0x01000000 | scalar.value
            }
        }
        guard let hid else { return nil }
        if (4...29).contains(hid) { return UInt32(hid - 4 + 97) }
        if (30...38).contains(hid) { return UInt32(hid - 30 + 49) }
        if hid == 39 { return 48 }
        if (58...69).contains(hid) { return UInt32(hid - 58) + 0xffbe }
        if let name = RemoteKeyboardInput.shortcutKeyName(forHIDUsage: hid) { return named[name] }
        let punctuation: [Int: UInt32] = [45:45,46:61,47:91,48:93,49:92,50:92,51:59,52:39,53:96,54:44,55:46,56:47,57:0xffe5,
            84:47,85:42,86:45,87:43,88:0xff0d,89:49,90:50,91:51,92:52,93:53,94:54,95:55,96:56,97:57,98:48,99:46]
        return punctuation[hid]
    }
}
