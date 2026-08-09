#if SIDECARBRIDGE_APP_STORE_SAFE
import Foundation

/// The Mac App Store companion is intentionally viewer-only. Apple does not
/// permit this app to use Accessibility APIs for remote mouse/keyboard
/// injection. The direct-distribution companion supplies the full pipeline
/// below and uses the user's explicit Accessibility approval.
final class RemoteInputPipeline {
    var isAuthorized: Bool { false }

    @discardableResult
    func requestAccess() -> Bool { false }

    func openAccessibilitySettings() {}
    func revealApplication() {}
    func releaseButtons() {}

    func submit(
        _ input: RemoteInputEvent,
        completion: @escaping (Bool) -> Void
    ) {
        completion(false)
    }
}
#else
import ApplicationServices
import AppKit
import Carbon
import CoreGraphics
import Foundation
import OSLog

private let remoteInputLog = Logger(
    subsystem: "io.sidecarbridge.mac",
    category: "RemoteInput"
)

final class RemoteInputPipeline {
    private let controller = RemoteInputController()
    private let queue = DispatchQueue(
        label: "SidecarBridge.RemoteInput",
        qos: .userInteractive
    )

    var isAuthorized: Bool { controller.isAuthorized }

    @discardableResult
    func requestAccess() -> Bool {
        controller.requestAccess()
    }

    func openAccessibilitySettings() {
        controller.openAccessibilitySettings()
    }

    func revealApplication() {
        controller.revealApplication()
    }

    func submit(
        _ input: RemoteInputEvent,
        completion: @escaping (Bool) -> Void
    ) {
        queue.async { [controller] in
            completion(controller.handle(input))
        }
    }

    func releaseButtons() {
        queue.async { [controller] in
            controller.releaseButtons()
        }
    }
}

final class RemoteInputController {
    var isAuthorized: Bool { AXIsProcessTrusted() }
    private let eventSource = CGEventSource(stateID: .privateState)
    // A nil source makes CoreGraphics derive keyboard state from the current
    // HID system state. WindowServer's global shortcut recognizer ignores
    // some explicitly-created synthetic sources even though regular apps
    // still receive their key events.
    private let keyboardEventSource: CGEventSource? = nil
    private var isPrimaryButtonDown = false
    private var activePrimaryButtonFlags: CGEventFlags = []
    private var scrollRemainderX = 0.0
    private var scrollRemainderY = 0.0
    private let inputSourceController = RemoteInputSourceController()

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
        case .pointerDelta:
            guard let x = input.deltaX, let y = input.deltaY else { return false }
            movePointerBy(x: x, y: y)
        case .primaryDown:
            primaryButtonDown(
                x: input.x,
                y: input.y,
                clickCount: input.clickCount ?? 1,
                modifiers: input.modifiers ?? []
            )
        case .primaryDrag:
            guard let x = input.x, let y = input.y else { return false }
            primaryButtonDrag(
                x: x,
                y: y,
                clickCount: input.clickCount ?? 1,
                modifiers: input.modifiers ?? []
            )
        case .primaryUp:
            primaryButtonUp(
                x: input.x,
                y: input.y,
                clickCount: input.clickCount ?? 1,
                modifiers: input.modifiers ?? []
            )
        case .primaryClick:
            if let x = input.x, let y = input.y { movePointer(x: x, y: y) }
            click(button: .left, modifiers: input.modifiers ?? [])
        case .primaryDoubleClick:
            if let x = input.x, let y = input.y { movePointer(x: x, y: y) }
            click(button: .left, count: 2, modifiers: input.modifiers ?? [])
        case .secondaryClick:
            if let x = input.x, let y = input.y { movePointer(x: x, y: y) }
            click(button: .right, modifiers: input.modifiers ?? [])
        case .secondaryDoubleClick:
            if let x = input.x, let y = input.y { movePointer(x: x, y: y) }
            click(button: .right, count: 2, modifiers: input.modifiers ?? [])
        case .releaseButtons:
            releaseButtons()
        case .scroll:
            scroll(
                x: input.deltaX ?? 0,
                y: input.deltaY ?? 0,
                phase: input.scrollPhase,
                continuous: input.isContinuousScroll ?? true
            )
        case .text:
            guard let text = input.text else { return false }
            // NSPasteboard and NSAppleScript are AppKit APIs. Keep committed
            // Unicode insertion on main while the serial input queue waits.
            MainQueueExecutor.sync {
                type(text)
            }
            return true
        case .key:
            let code = input.hidUsage.flatMap(keyCode(forHIDUsage:))
                ?? input.key.flatMap(keyCode(for:))
            guard let code else { return false }
            return press(code: code, modifiers: flags(for: input.modifiers ?? []))
        case .inputMode:
            guard let language = input.text else { return false }
            return inputSourceController.select(language: language)
        case .cycleInputMode:
            return inputSourceController.cycle()
        case .toggleChineseEnglishInputMode:
            let expectation = inputSourceController.chineseEnglishToggleExpectation()
            if postInputSourceSwitchShortcut(),
               inputSourceController.waitForChineseEnglishToggle(expectation) {
                return true
            }
            remoteInputLog.notice(
                "System input-source shortcut did not confirm a change; trying direct TIS fallback"
            )
            return inputSourceController.toggleChineseEnglish()
        }
        return true
    }

    func releaseButtons() {
        let point = CGEvent(source: nil)?.location ?? .zero
        if isPrimaryButtonDown {
            CGEvent(
                mouseEventSource: eventSource,
                mouseType: .leftMouseUp,
                mouseCursorPosition: point,
                mouseButton: .left
            )?.post(tap: .cghidEventTap)
        }
        CGEvent(
            mouseEventSource: eventSource,
            mouseType: .rightMouseUp,
            mouseCursorPosition: point,
            mouseButton: .right
        )?.post(tap: .cghidEventTap)
        isPrimaryButtonDown = false
        activePrimaryButtonFlags = []
    }

    private func movePointer(x: Double, y: Double) {
        let bounds = CGDisplayBounds(CGMainDisplayID())
        let point = CGPoint(
            x: bounds.minX + min(max(x, 0), 1) * bounds.width,
            y: bounds.minY + min(max(y, 0), 1) * bounds.height
        )
        let event = CGEvent(
            mouseEventSource: eventSource,
            mouseType: isPrimaryButtonDown ? .leftMouseDragged : .mouseMoved,
            mouseCursorPosition: point,
            mouseButton: .left
        )
        event?.post(tap: .cghidEventTap)
    }

    private func movePointerBy(x: Double, y: Double) {
        guard let current = CGEvent(source: nil)?.location else { return }
        let bounds = CGDisplayBounds(CGMainDisplayID())
        let sensitivity = 1.15
        let point = CGPoint(
            x: min(max(current.x + x * bounds.width * sensitivity, bounds.minX), bounds.maxX - 1),
            y: min(max(current.y + y * bounds.height * sensitivity, bounds.minY), bounds.maxY - 1)
        )
        let event = CGEvent(
            mouseEventSource: eventSource,
            mouseType: isPrimaryButtonDown ? .leftMouseDragged : .mouseMoved,
            mouseCursorPosition: point,
            mouseButton: .left
        )
        event?.post(tap: .cghidEventTap)
    }

    private func click(
        button: CGMouseButton,
        count: Int = 1,
        modifiers: [String] = []
    ) {
        guard let location = CGEvent(source: nil)?.location else { return }
        if button == .right, isPrimaryButtonDown {
            primaryButtonUp(x: nil, y: nil, clickCount: 1, modifiers: [])
        }
        let down: CGEventType = button == .right ? .rightMouseDown : .leftMouseDown
        let up: CGEventType = button == .right ? .rightMouseUp : .leftMouseUp
        let eventFlags = flags(for: modifiers)
        for clickState in 1...max(count, 1) {
            let downEvent = CGEvent(
                mouseEventSource: eventSource,
                mouseType: down,
                mouseCursorPosition: location,
                mouseButton: button
            )
            downEvent?.flags = eventFlags
            downEvent?.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
            downEvent?.post(tap: .cghidEventTap)

            let upEvent = CGEvent(
                mouseEventSource: eventSource,
                mouseType: up,
                mouseCursorPosition: location,
                mouseButton: button
            )
            upEvent?.flags = eventFlags
            upEvent?.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
            upEvent?.post(tap: .cghidEventTap)
        }
    }

    private func primaryButtonDown(
        x: Double?,
        y: Double?,
        clickCount: Int,
        modifiers: [String]
    ) {
        let point: CGPoint
        if let x, let y {
            point = displayPoint(x: x, y: y)
        } else {
            point = CGEvent(source: nil)?.location ?? .zero
        }
        if isPrimaryButtonDown {
            CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        }
        let event = CGEvent(
            mouseEventSource: eventSource,
            mouseType: .leftMouseDown,
            mouseCursorPosition: point,
            mouseButton: .left
        )
        activePrimaryButtonFlags = flags(for: modifiers)
        event?.flags = activePrimaryButtonFlags
        event?.setIntegerValueField(.mouseEventClickState, value: Int64(max(clickCount, 1)))
        event?.post(tap: .cghidEventTap)
        isPrimaryButtonDown = true
    }

    private func primaryButtonDrag(
        x: Double,
        y: Double,
        clickCount: Int,
        modifiers: [String]
    ) {
        let point = displayPoint(x: x, y: y)
        let eventType: CGEventType = isPrimaryButtonDown ? .leftMouseDragged : .mouseMoved
        let event = CGEvent(
            mouseEventSource: eventSource,
            mouseType: eventType,
            mouseCursorPosition: point,
            mouseButton: .left
        )
        let currentFlags = flags(for: modifiers)
        event?.flags = activePrimaryButtonFlags.union(currentFlags)
        event?.setIntegerValueField(.mouseEventClickState, value: Int64(max(clickCount, 1)))
        event?.post(tap: .cghidEventTap)
    }

    private func primaryButtonUp(
        x: Double?,
        y: Double?,
        clickCount: Int,
        modifiers: [String]
    ) {
        guard isPrimaryButtonDown else { return }
        let point: CGPoint
        if let x, let y {
            point = displayPoint(x: x, y: y)
        } else {
            point = CGEvent(source: nil)?.location ?? .zero
        }
        let event = CGEvent(
            mouseEventSource: eventSource,
            mouseType: .leftMouseUp,
            mouseCursorPosition: point,
            mouseButton: .left
        )
        event?.flags = activePrimaryButtonFlags.union(flags(for: modifiers))
        event?.setIntegerValueField(.mouseEventClickState, value: Int64(max(clickCount, 1)))
        event?.post(tap: .cghidEventTap)
        isPrimaryButtonDown = false
        activePrimaryButtonFlags = []
    }

    private func displayPoint(x: Double, y: Double) -> CGPoint {
        let bounds = CGDisplayBounds(CGMainDisplayID())
        return CGPoint(
            x: bounds.minX + min(max(x, 0), 1) * bounds.width,
            y: bounds.minY + min(max(y, 0), 1) * bounds.height
        )
    }

    private func scroll(
        x: Double,
        y: Double,
        phase: RemoteScrollPhase?,
        continuous: Bool
    ) {
        if phase == .began {
            scrollRemainderX = 0
            scrollRemainderY = 0
        }
        let scale = continuous ? 1.0 : 1.8
        let accumulatedX = (x * scale) + scrollRemainderX
        let accumulatedY = (y * scale) + scrollRemainderY
        let wholeX = accumulatedX.rounded(.towardZero)
        let wholeY = accumulatedY.rounded(.towardZero)
        scrollRemainderX = accumulatedX - wholeX
        scrollRemainderY = accumulatedY - wholeY
        guard wholeX != 0 || wholeY != 0 || phase != nil else { return }

        let event = CGEvent(
            scrollWheelEvent2Source: eventSource,
            units: .pixel,
            wheelCount: 2,
            wheel1: Int32(clamping: Int(wholeY)),
            wheel2: Int32(clamping: Int(wholeX)),
            wheel3: 0
        )
        event?.setIntegerValueField(
            .scrollWheelEventIsContinuous,
            value: continuous ? 1 : 0
        )
        if let phase {
            let cgPhase: CGScrollPhase
            switch phase {
            case .began: cgPhase = .began
            case .changed: cgPhase = .changed
            case .ended: cgPhase = .ended
            case .cancelled: cgPhase = .cancelled
            }
            event?.setIntegerValueField(
                .scrollWheelEventScrollPhase,
                value: Int64(cgPhase.rawValue)
            )
        }
        event?.post(tap: .cghidEventTap)
        if phase == .ended || phase == .cancelled {
            scrollRemainderX = 0
            scrollRemainderY = 0
        }
    }

    private func type(_ text: String) {
        let requiresReliableUnicodeInsertion = text.unicodeScalars.contains {
            !$0.isASCII
        }

        // Some custom controls do not expose AXSelectedText and Apple notes
        // that application frameworks may ignore Unicode attached to
        // synthetic keyboard events. A normal paste is the most compatible
        // fallback, especially for committed CJK text.
        if insertTextUsingAccessibility(text) {
            remoteInputLog.notice(
                "Remote text route=accessibility utf16Count=\(text.utf16.count, privacy: .public)"
            )
            return
        }

        if requiresReliableUnicodeInsertion,
           pasteTextPreservingClipboard(text) {
            remoteInputLog.notice(
                "Remote text route=paste utf16Count=\(text.utf16.count, privacy: .public)"
            )
            return
        }

        // Keep Quartz as the final fallback for secure fields or unusual
        // pasteboards that cannot be snapshotted safely.
        for characters in unicodeEventChunks(text) {
            let down = CGEvent(keyboardEventSource: keyboardEventSource, virtualKey: 0, keyDown: true)
            down?.flags = []
            down?.keyboardSetUnicodeString(stringLength: characters.count, unicodeString: characters)
            down?.post(tap: .cghidEventTap)
            let up = CGEvent(keyboardEventSource: keyboardEventSource, virtualKey: 0, keyDown: false)
            up?.flags = []
            up?.keyboardSetUnicodeString(stringLength: characters.count, unicodeString: characters)
            up?.post(tap: .cghidEventTap)
        }
        remoteInputLog.notice(
            "Remote text route=quartz utf16Count=\(text.utf16.count, privacy: .public)"
        )
    }

    private func insertTextUsingAccessibility(_ text: String) -> Bool {
        let systemWideElement = AXUIElementCreateSystemWide()
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWideElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        ) == .success,
        let focusedValue else {
            return false
        }

        let focusedElement = focusedValue as! AXUIElement
        var isSettable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(
            focusedElement,
            kAXSelectedTextAttribute as CFString,
            &isSettable
        ) == .success,
        isSettable.boolValue else {
            return false
        }

        return AXUIElementSetAttributeValue(
            focusedElement,
            kAXSelectedTextAttribute as CFString,
            text as CFString
        ) == .success
    }

    private struct PasteboardSnapshot {
        let items: [[NSPasteboard.PasteboardType: Data]]
    }

    private func pasteTextPreservingClipboard(_ text: String) -> Bool {
        guard !text.isEmpty else { return true }
        let pasteboard = NSPasteboard.general
        guard let snapshot = snapshotPasteboard(pasteboard) else {
            return false
        }

        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            restorePasteboard(snapshot, to: pasteboard)
            return false
        }
        let ownedChangeCount = pasteboard.changeCount

        guard postPasteShortcut() else {
            if pasteboard.changeCount == ownedChangeCount {
                restorePasteboard(snapshot, to: pasteboard)
            }
            return false
        }

        // AppKit usually consumes paste synchronously, but Chromium and other
        // cross-platform controls may request pasteboard data on a later run
        // loop. Keep ownership long enough for those controls, then restore
        // only if no user or application has taken ownership in the meantime.
        Thread.sleep(forTimeInterval: 0.35)
        if pasteboard.changeCount == ownedChangeCount {
            restorePasteboard(snapshot, to: pasteboard)
        }
        return true
    }

    private func postPasteShortcut() -> Bool {
        // System Events is also used for the Control-arrow shortcuts because
        // WindowServer and some cross-platform controls reject otherwise
        // valid synthetic Quartz shortcuts. Never put the remote text itself
        // in the AppleScript source.
        let script = """
        tell application "System Events"
            keystroke "v" using command down
        end tell
        """
        var error: NSDictionary?
        let result = NSAppleScript(source: script)?.executeAndReturnError(&error)
        if result != nil, error == nil {
            return true
        }
        if let error {
            NSLog("SidecarBridge paste shortcut via System Events failed: %@", error)
        }
        return press(code: 9, modifiers: .maskCommand)
    }

    private func snapshotPasteboard(_ pasteboard: NSPasteboard) -> PasteboardSnapshot? {
        var copiedItems: [[NSPasteboard.PasteboardType: Data]] = []
        for item in pasteboard.pasteboardItems ?? [] {
            var copiedRepresentations: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                guard let data = item.data(forType: type) else {
                    // Do not risk destroying a promised or otherwise
                    // unavailable representation just to inject remote text.
                    return nil
                }
                copiedRepresentations[type] = data
            }
            copiedItems.append(copiedRepresentations)
        }
        return PasteboardSnapshot(items: copiedItems)
    }

    private func restorePasteboard(
        _ snapshot: PasteboardSnapshot,
        to pasteboard: NSPasteboard
    ) {
        pasteboard.clearContents()
        guard !snapshot.items.isEmpty else { return }

        let restoredItems = snapshot.items.map { representations in
            let item = NSPasteboardItem()
            for (type, data) in representations {
                item.setData(data, forType: type)
            }
            return item
        }
        pasteboard.writeObjects(restoredItems)
    }

    private func unicodeEventChunks(_ text: String) -> [[UniChar]] {
        let units = Array(text.utf16)
        guard !units.isEmpty else { return [] }

        // CGEvent keyboard Unicode payloads are limited. Keep each event at
        // 20 UTF-16 units and never split a surrogate pair between events.
        var chunks: [[UniChar]] = []
        var start = 0
        while start < units.count {
            var end = min(start + 20, units.count)
            if end < units.count,
               end > start,
               (0xD800...0xDBFF).contains(units[end - 1]) {
                end -= 1
            }
            chunks.append(Array(units[start..<end]))
            start = end
        }
        return chunks
    }

    @discardableResult
    private func press(code: CGKeyCode, modifiers: CGEventFlags) -> Bool {
        if modifiers == .maskControl, (123...126).contains(code) {
            return postSystemControlArrow(code: code)
        }
        let modifierKeys: [(flag: CGEventFlags, code: CGKeyCode)] = [
            (.maskCommand, 55),
            (.maskAlternate, 58),
            (.maskControl, 59),
            (.maskShift, 56)
        ]
        let selected = modifierKeys.filter { modifiers.contains($0.flag) }
        var activeFlags: CGEventFlags = []
        for modifier in selected {
            activeFlags.insert(modifier.flag)
            guard let event = CGEvent(
                keyboardEventSource: keyboardEventSource,
                virtualKey: modifier.code,
                keyDown: true
            ) else { return false }
            event.flags = activeFlags
            event.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 0.006)
        }

        guard let down = CGEvent(keyboardEventSource: keyboardEventSource, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: keyboardEventSource, virtualKey: code, keyDown: false) else {
            releaseModifierKeys(selected, activeFlags: activeFlags)
            return false
        }
        down.flags = activeFlags
        down.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.008)
        up.flags = activeFlags
        up.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.006)

        releaseModifierKeys(selected, activeFlags: activeFlags)
        return true
    }

    private func postSystemControlArrow(code: CGKeyCode) -> Bool {
        // WindowServer deliberately ignores synthesized Quartz events for
        // Mission Control and Spaces on current macOS releases. Ask the
        // system keyboard process to perform the user's configured shortcut
        // instead. The sandbox entitlement limits this Apple Event target to
        // System Events, and macOS still requires explicit user approval.
        let script = """
        tell application "System Events"
            key code \(code) using control down
        end tell
        """
        var error: NSDictionary?
        let result = NSAppleScript(source: script)?.executeAndReturnError(&error)
        if let error {
            NSLog("SidecarBridge system shortcut failed: %@", error)
        }
        return result != nil && error == nil
    }

    private func postInputSourceSwitchShortcut() -> Bool {
        // A real Control-Space action is applied to the focused application's
        // text-input context. TISSelectInputSource can return noErr yet be
        // ignored by WindowServer for a sandboxed app, especially when the
        // focused app restores a per-document input source.
        let script = """
        tell application "System Events"
            key code 49 using control down
        end tell
        """
        var error: NSDictionary?
        let result = NSAppleScript(source: script)?.executeAndReturnError(&error)
        if result != nil, error == nil {
            return true
        }
        if let error {
            NSLog("SidecarBridge input-source shortcut failed: %@", error)
        }
        return press(code: 49, modifiers: .maskControl)
    }

    private func releaseModifierKeys(
        _ selected: [(flag: CGEventFlags, code: CGKeyCode)],
        activeFlags initialFlags: CGEventFlags
    ) {
        var activeFlags = initialFlags
        for modifier in selected.reversed() {
            activeFlags.remove(modifier.flag)
            let event = CGEvent(
                keyboardEventSource: keyboardEventSource,
                virtualKey: modifier.code,
                keyDown: false
            )
            event?.flags = activeFlags
            event?.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 0.004)
        }
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
            "`": 50, "delete": 51, "escape": 53, "home": 115, "pageup": 116,
            "end": 119, "pagedown": 121, "left": 123, "right": 124, "down": 125, "up": 126
        ]
        return map[key.lowercased()]
    }

    private func keyCode(forHIDUsage usage: Int) -> CGKeyCode? {
        RemoteKeyboardInput.macVirtualKeyCode(forHIDUsage: usage)
            .map { CGKeyCode($0) }
    }
}

private struct ChineseEnglishToggleExpectation {
    let previousSourceID: String?
    let wantsChinese: Bool
}

private final class RemoteInputSourceController {
    private var lastChineseSourceID: String?
    private var lastEnglishSourceID: String?

    func cycle() -> Bool {
        MainQueueExecutor.sync {
            cycleOnMain()
        }
    }

    func toggleChineseEnglish() -> Bool {
        MainQueueExecutor.sync {
            toggleChineseEnglishOnMain()
        }
    }

    func chineseEnglishToggleExpectation() -> ChineseEnglishToggleExpectation {
        MainQueueExecutor.sync {
            dispatchPrecondition(condition: .onQueue(.main))
            let current = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
            return ChineseEnglishToggleExpectation(
                previousSourceID: stringProperty(
                    current,
                    key: kTISPropertyInputSourceID
                ),
                wantsChinese: !languagesProperty(current)
                    .contains(where: isChineseLanguage)
            )
        }
    }

    func waitForChineseEnglishToggle(
        _ expectation: ChineseEnglishToggleExpectation,
        timeout: TimeInterval = 0.8
    ) -> Bool {
        // This method runs on the serial remote-input queue. Waiting here is
        // deliberate: the next physical key must not overtake the Mac input
        // source change or it will be interpreted as English.
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        repeat {
            let matched = MainQueueExecutor.sync {
                dispatchPrecondition(condition: .onQueue(.main))
                let current = TISCopyCurrentKeyboardInputSource()
                    .takeRetainedValue()
                let currentID = stringProperty(
                    current,
                    key: kTISPropertyInputSourceID
                )
                let languages = languagesProperty(current)
                let targetMatches = expectation.wantsChinese
                    ? languages.contains(where: isChineseLanguage)
                    : languages.contains(where: isEnglishLanguage)
                guard targetMatches,
                      currentID != expectation.previousSourceID else {
                    return false
                }
                remember(current)
                remoteInputLog.notice(
                    "Confirmed focused macOS input source id=\(currentID ?? "unknown", privacy: .public)"
                )
                return true
            }
            if matched {
                return true
            }
            Thread.sleep(forTimeInterval: 0.025)
        } while ProcessInfo.processInfo.systemUptime < deadline
        return false
    }

    func select(language: String) -> Bool {
        // HIToolbox's Text Input Source APIs are main-queue-only. Remote
        // input normally arrives on SidecarBridge.RemoteInput, so synchronously
        // hop to main while that serial queue waits. This both avoids
        // _dispatch_assert_queue_fail and preserves ordering with the next key.
        return MainQueueExecutor.sync {
            selectOnMain(language: language)
        }
    }

    private func selectOnMain(language: String) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        let normalized = RemoteKeyboardInput.normalizedLanguage(language)
        guard !normalized.isEmpty else { return false }

        if let enabled = TISCopyInputSourceForLanguage(normalized as CFString)?
            .takeRetainedValue(),
           booleanProperty(enabled, key: kTISPropertyInputSourceIsSelectCapable) {
            if select(enabled, language: normalized) {
                return true
            }
            remoteInputLog.notice(
                "Direct macOS input source rejected language=\(normalized, privacy: .public); trying selectable child"
            )
        }

        // TISCopyInputSourceForLanguage can return the non-selectable parent of
        // an input method (for example, "Chinese, Traditional"). Prefer an
        // enabled selectable child such as Zhuyin before looking at disabled
        // installed sources.
        if let enabledChild = preferredSource(
            for: normalized,
            includeAllInstalled: false
        ) {
            return select(enabledChild, language: normalized)
        }

        guard let installed = preferredSource(
            for: normalized,
            includeAllInstalled: true
        ) else {
            remoteInputLog.error(
                "No macOS input source is installed for language=\(normalized, privacy: .public)"
            )
            return false
        }

        enableParentIfNeeded(for: installed)
        if !booleanProperty(installed, key: kTISPropertyInputSourceIsEnabled) {
            let status = TISEnableInputSource(installed)
            guard status == noErr else {
                remoteInputLog.error(
                    "Could not enable macOS input source language=\(normalized, privacy: .public) status=\(status, privacy: .public)"
                )
                return false
            }
        }
        return select(installed, language: normalized)
    }

    private func cycleOnMain() -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        let filter = [
            kTISPropertyInputSourceCategory as String:
                kTISCategoryKeyboardInputSource
        ] as CFDictionary
        let sources = TISCreateInputSourceList(filter, false)
            .takeRetainedValue() as! [TISInputSource]
        let selectable = sources.filter {
            booleanProperty($0, key: kTISPropertyInputSourceIsSelectCapable)
                && booleanProperty($0, key: kTISPropertyInputSourceIsEnabled)
        }
        let sourceIDs = selectable.compactMap {
            stringProperty($0, key: kTISPropertyInputSourceID)
        }
        let current = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        let currentID = stringProperty(current, key: kTISPropertyInputSourceID)
        guard let nextID = RemoteKeyboardInput.nextInputSourceID(
            currentID: currentID,
            orderedIDs: sourceIDs
        ),
        let next = selectable.first(where: {
            stringProperty($0, key: kTISPropertyInputSourceID) == nextID
        }) else {
            remoteInputLog.error("No enabled macOS input source is available to cycle")
            return false
        }

        let language = languagesProperty(next).first ?? "next"
        remoteInputLog.notice(
            "Cycling macOS input source current=\(currentID ?? "unknown", privacy: .public) next=\(nextID, privacy: .public)"
        )
        return select(next, language: language)
    }

    private func toggleChineseEnglishOnMain() -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        let filter = [
            kTISPropertyInputSourceCategory as String:
                kTISCategoryKeyboardInputSource
        ] as CFDictionary
        let selectable = (
            TISCreateInputSourceList(filter, false).takeRetainedValue()
                as! [TISInputSource]
        ).filter {
            booleanProperty($0, key: kTISPropertyInputSourceIsSelectCapable)
                && booleanProperty($0, key: kTISPropertyInputSourceIsEnabled)
        }
        let current = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        remember(current)

        let wantsEnglish = languagesProperty(current)
            .contains(where: isChineseLanguage)
        let rememberedID = wantsEnglish
            ? lastEnglishSourceID
            : lastChineseSourceID
        let target = selectable.first {
            stringProperty($0, key: kTISPropertyInputSourceID) == rememberedID
        } ?? preferredChineseEnglishSource(
            from: selectable,
            wantsEnglish: wantsEnglish
        )

        guard let target else {
            remoteInputLog.error(
                "No enabled \(wantsEnglish ? "English" : "Chinese", privacy: .public) input source is available"
            )
            return false
        }
        let targetLanguage = languagesProperty(target).first
            ?? (wantsEnglish ? "en" : "zh")
        remoteInputLog.notice(
            "中/英 switching macOS input source to \(targetLanguage, privacy: .public)"
        )
        return select(target, language: targetLanguage)
    }

    private func preferredChineseEnglishSource(
        from sources: [TISInputSource],
        wantsEnglish: Bool
    ) -> TISInputSource? {
        if wantsEnglish {
            return sources.first {
                languagesProperty($0).contains(where: isEnglishLanguage)
            }
        }
        return sources.first {
            let sourceID = stringProperty($0, key: kTISPropertyInputSourceID)
            return sourceID == "com.apple.inputmethod.TCIM.Zhuyin"
                && languagesProperty($0).contains(where: isChineseLanguage)
        } ?? sources.first {
            languagesProperty($0).contains(where: isChineseLanguage)
        }
    }

    private func select(_ source: TISInputSource, language: String) -> Bool {
        let status = TISSelectInputSource(source)
        let sourceID = stringProperty(source, key: kTISPropertyInputSourceID) ?? "unknown"
        if status == noErr {
            remember(source)
            remoteInputLog.notice(
                "Selected macOS input source language=\(language, privacy: .public) id=\(sourceID, privacy: .public)"
            )
            return true
        }
        remoteInputLog.error(
            "Could not select macOS input source language=\(language, privacy: .public) id=\(sourceID, privacy: .public) status=\(status, privacy: .public)"
        )
        return false
    }

    private func remember(_ source: TISInputSource) {
        guard let sourceID = stringProperty(
            source,
            key: kTISPropertyInputSourceID
        ) else { return }
        let languages = languagesProperty(source)
        if languages.contains(where: isChineseLanguage) {
            lastChineseSourceID = sourceID
        } else if languages.contains(where: isEnglishLanguage) {
            lastEnglishSourceID = sourceID
        }
    }

    private func isChineseLanguage(_ language: String) -> Bool {
        let normalized = RemoteKeyboardInput.normalizedLanguage(language)
            .lowercased()
        return normalized == "zh" || normalized.hasPrefix("zh-")
    }

    private func isEnglishLanguage(_ language: String) -> Bool {
        let normalized = RemoteKeyboardInput.normalizedLanguage(language)
            .lowercased()
        return normalized == "en" || normalized.hasPrefix("en-")
    }

    private func preferredSource(
        for language: String,
        includeAllInstalled: Bool
    ) -> TISInputSource? {
        let canonical = language.lowercased()
        let preferredID: String?
        if canonical.hasPrefix("zh-hans") || canonical == "zh-cn" {
            preferredID = "com.apple.inputmethod.SCIM.ITABC"
        } else if canonical.hasPrefix("zh-hant") || canonical == "zh-tw" {
            preferredID = "com.apple.inputmethod.TCIM.Zhuyin"
        } else {
            preferredID = nil
        }

        let sources = TISCreateInputSourceList(
            nil,
            includeAllInstalled
        ).takeRetainedValue() as! [TISInputSource]
        let candidates = sources.filter {
            booleanProperty($0, key: kTISPropertyInputSourceIsSelectCapable)
        }
        if let preferredID,
           let preferred = candidates.first(where: {
               stringProperty($0, key: kTISPropertyInputSourceID) == preferredID
           }) {
            return preferred
        }

        return candidates.first { source in
            languagesProperty(source).contains { candidate in
                languagesMatch(candidate, canonical)
            }
        }
    }

    private func enableParentIfNeeded(for source: TISInputSource) {
        guard let sourceID = stringProperty(source, key: kTISPropertyInputSourceID)
        else { return }
        let parentID: String?
        if sourceID.hasPrefix("com.apple.inputmethod.SCIM.") {
            parentID = "com.apple.inputmethod.SCIM"
        } else if sourceID.hasPrefix("com.apple.inputmethod.TCIM.") {
            parentID = "com.apple.inputmethod.TCIM"
        } else {
            parentID = nil
        }
        guard let parentID else { return }

        let filter = [kTISPropertyInputSourceID as String: parentID] as CFDictionary
        let parents = TISCreateInputSourceList(filter, true).takeRetainedValue()
            as! [TISInputSource]
        guard let parent = parents.first,
              !booleanProperty(parent, key: kTISPropertyInputSourceIsEnabled) else {
            return
        }
        _ = TISEnableInputSource(parent)
    }

    private func languagesMatch(_ candidate: String, _ requested: String) -> Bool {
        let normalizedCandidate = candidate
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()
        return normalizedCandidate == requested
            || normalizedCandidate.hasPrefix(requested + "-")
            || requested.hasPrefix(normalizedCandidate + "-")
    }

    private func stringProperty(
        _ source: TISInputSource,
        key: CFString
    ) -> String? {
        guard let pointer = TISGetInputSourceProperty(source, key) else {
            return nil
        }
        return Unmanaged<CFString>.fromOpaque(pointer)
            .takeUnretainedValue() as String
    }

    private func languagesProperty(_ source: TISInputSource) -> [String] {
        guard let pointer = TISGetInputSourceProperty(
            source,
            kTISPropertyInputSourceLanguages
        ) else { return [] }
        return Unmanaged<CFArray>.fromOpaque(pointer)
            .takeUnretainedValue() as! [String]
    }

    private func booleanProperty(
        _ source: TISInputSource,
        key: CFString
    ) -> Bool {
        guard let pointer = TISGetInputSourceProperty(source, key) else {
            return false
        }
        return Unmanaged<CFBoolean>.fromOpaque(pointer)
            .takeUnretainedValue() == kCFBooleanTrue
    }
}
#endif
