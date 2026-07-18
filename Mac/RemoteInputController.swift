import ApplicationServices
import AppKit
import CoreGraphics
import Foundation

final class RemoteInputController {
    var isAuthorized: Bool { AXIsProcessTrusted() }
    private var isPrimaryButtonDown = false
    private var scrollRemainderX = 0.0
    private var scrollRemainderY = 0.0

    @discardableResult
    func requestAccess() -> Bool {
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
    }

    func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    func revealApplication() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    @discardableResult
    func handle(_ input: RemoteInputEvent) -> Bool {
        guard isAuthorized else {
            requestAccess()
            return false
        }

        switch input.kind {
        case .pointerMove:
            guard let x = input.x, let y = input.y else { return false }
            movePointer(x: x, y: y)
        case .primaryDown:
            guard let x = input.x, let y = input.y else { return false }
            primaryButtonDown(x: x, y: y)
        case .primaryDrag:
            guard let x = input.x, let y = input.y else { return false }
            primaryButtonDrag(x: x, y: y)
        case .primaryUp:
            primaryButtonUp(x: input.x, y: input.y)
        case .primaryClick:
            if let x = input.x, let y = input.y { movePointer(x: x, y: y) }
            click(button: .left)
        case .primaryDoubleClick:
            if let x = input.x, let y = input.y { movePointer(x: x, y: y) }
            click(button: .left, count: 2)
        case .secondaryClick:
            if let x = input.x, let y = input.y { movePointer(x: x, y: y) }
            click(button: .right)
        case .scroll:
            scroll(x: input.deltaX ?? 0, y: input.deltaY ?? 0)
        case .text:
            if let text = input.text { type(text) }
        case .key:
            guard let key = input.key, let code = keyCode(for: key) else { return false }
            press(code: code, modifiers: flags(for: input.modifiers ?? []))
        }
        return true
    }

    func releaseButtons() {
        primaryButtonUp(x: nil, y: nil)
    }

    private func movePointer(x: Double, y: Double) {
        let bounds = CGDisplayBounds(CGMainDisplayID())
        let point = CGPoint(
            x: bounds.minX + min(max(x, 0), 1) * bounds.width,
            y: bounds.minY + min(max(y, 0), 1) * bounds.height
        )
        let event = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)
        event?.post(tap: .cghidEventTap)
    }

    private func click(button: CGMouseButton, count: Int = 1) {
        guard let location = CGEvent(source: nil)?.location else { return }
        let down: CGEventType = button == .right ? .rightMouseDown : .leftMouseDown
        let up: CGEventType = button == .right ? .rightMouseUp : .leftMouseUp
        for clickState in 1...max(count, 1) {
            let downEvent = CGEvent(
                mouseEventSource: nil,
                mouseType: down,
                mouseCursorPosition: location,
                mouseButton: button
            )
            downEvent?.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
            downEvent?.post(tap: .cghidEventTap)

            let upEvent = CGEvent(
                mouseEventSource: nil,
                mouseType: up,
                mouseCursorPosition: location,
                mouseButton: button
            )
            upEvent?.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
            upEvent?.post(tap: .cghidEventTap)
        }
    }

    private func primaryButtonDown(x: Double, y: Double) {
        let point = displayPoint(x: x, y: y)
        if isPrimaryButtonDown {
            CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        }
        CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        isPrimaryButtonDown = true
    }

    private func primaryButtonDrag(x: Double, y: Double) {
        let point = displayPoint(x: x, y: y)
        let eventType: CGEventType = isPrimaryButtonDown ? .leftMouseDragged : .mouseMoved
        CGEvent(mouseEventSource: nil, mouseType: eventType, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
    }

    private func primaryButtonUp(x: Double?, y: Double?) {
        guard isPrimaryButtonDown else { return }
        let point: CGPoint
        if let x, let y {
            point = displayPoint(x: x, y: y)
        } else {
            point = CGEvent(source: nil)?.location ?? .zero
        }
        CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        isPrimaryButtonDown = false
    }

    private func displayPoint(x: Double, y: Double) -> CGPoint {
        let bounds = CGDisplayBounds(CGMainDisplayID())
        return CGPoint(
            x: bounds.minX + min(max(x, 0), 1) * bounds.width,
            y: bounds.minY + min(max(y, 0), 1) * bounds.height
        )
    }

    private func scroll(x: Double, y: Double) {
        let accumulatedX = (x * 1.6) + scrollRemainderX
        let accumulatedY = (y * 1.6) + scrollRemainderY
        let wholeX = accumulatedX.rounded(.towardZero)
        let wholeY = accumulatedY.rounded(.towardZero)
        scrollRemainderX = accumulatedX - wholeX
        scrollRemainderY = accumulatedY - wholeY
        guard wholeX != 0 || wholeY != 0 else { return }

        let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: Int32(clamping: Int(wholeY)),
            wheel2: Int32(clamping: Int(wholeX)),
            wheel3: 0
        )
        event?.post(tap: .cghidEventTap)
    }

    private func type(_ text: String) {
        let characters = Array(text.utf16)
        guard !characters.isEmpty else { return }
        let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)
        down?.keyboardSetUnicodeString(stringLength: characters.count, unicodeString: characters)
        down?.post(tap: .cghidEventTap)
        let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
        up?.keyboardSetUnicodeString(stringLength: characters.count, unicodeString: characters)
        up?.post(tap: .cghidEventTap)
    }

    private func press(code: CGKeyCode, modifiers: CGEventFlags) {
        let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true)
        down?.flags = modifiers
        down?.post(tap: .cghidEventTap)
        let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false)
        up?.flags = modifiers
        up?.post(tap: .cghidEventTap)
    }

    private func flags(for modifiers: [String]) -> CGEventFlags {
        var result: CGEventFlags = []
        if modifiers.contains("command") { result.insert(.maskCommand) }
        if modifiers.contains("option") { result.insert(.maskAlternate) }
        if modifiers.contains("control") { result.insert(.maskControl) }
        if modifiers.contains("shift") { result.insert(.maskShift) }
        return result
    }

    private func keyCode(for key: String) -> CGKeyCode? {
        let map: [String: CGKeyCode] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7,
            "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
            "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22,
            "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
            "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "return": 36,
            "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43,
            "/": 44, "n": 45, "m": 46, ".": 47, "tab": 48, "space": 49,
            "`": 50, "delete": 51, "escape": 53, "home": 115, "pageUp": 116,
            "end": 119, "pageDown": 121, "left": 123, "right": 124, "down": 125, "up": 126
        ]
        return map[key]
    }
}
