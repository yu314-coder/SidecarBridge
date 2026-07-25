import SwiftUI
import UIKit

final class PointerPressGestureRecognizer: UIGestureRecognizer {
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard state == .possible, touches.count == 1 else {
            state = .failed
            return
        }
        state = .began
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard state == .began || state == .changed else { return }
        state = .changed
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard state == .began || state == .changed else { return }
        state = .ended
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        guard state == .began || state == .changed else { return }
        state = .cancelled
    }
}

struct RemoteInputSurface: UIViewRepresentable {
    let contentAspectRatio: CGFloat
    let zoomScale: CGFloat
    let zoomOffset: CGSize
    let pointerButtonMapping: RemotePointerButtonMapping
    let calibrateNextPointerClick: Bool
    let showsSoftwareKeyboard: Bool
    let onInput: (RemoteInputEvent) -> Void
    let onPointerCalibration: (RemotePointerButtonMapping) -> Void
    let onZoom: (CGFloat, CGPoint) -> Void
    let onViewportPan: (CGSize) -> Void

    func makeUIView(context: Context) -> InputView {
        InputView(
            contentAspectRatio: contentAspectRatio,
            zoomScale: zoomScale,
            zoomOffset: zoomOffset,
            pointerButtonMapping: pointerButtonMapping,
            calibrateNextPointerClick: calibrateNextPointerClick,
            showsSoftwareKeyboard: showsSoftwareKeyboard,
            onInput: onInput,
            onPointerCalibration: onPointerCalibration,
            onZoom: onZoom,
            onViewportPan: onViewportPan
        )
    }

    func updateUIView(_ uiView: InputView, context: Context) {
        uiView.contentAspectRatio = contentAspectRatio
        uiView.zoomScale = zoomScale
        uiView.zoomOffset = zoomOffset
        uiView.pointerButtonMapping = pointerButtonMapping
        uiView.calibrateNextPointerClick = calibrateNextPointerClick
        uiView.showsSoftwareKeyboard = showsSoftwareKeyboard
        uiView.onInput = onInput
        uiView.onPointerCalibration = onPointerCalibration
        uiView.onZoom = onZoom
        uiView.onViewportPan = onViewportPan
        uiView.accessibilityValue = "Zoom \(Int((zoomScale * 100).rounded())) percent"
        uiView.reclaimKeyboardFocus()
    }
}

final class InputView: UIView, UIKeyInput, UIGestureRecognizerDelegate {
    var onInput: (RemoteInputEvent) -> Void
    var onPointerCalibration: (RemotePointerButtonMapping) -> Void
    var onZoom: (CGFloat, CGPoint) -> Void
    var onViewportPan: (CGSize) -> Void
    var contentAspectRatio: CGFloat
    var zoomScale: CGFloat
    var zoomOffset: CGSize
    var pointerButtonMapping: RemotePointerButtonMapping
    var calibrateNextPointerClick: Bool
    var showsSoftwareKeyboard: Bool {
        didSet {
            guard showsSoftwareKeyboard != oldValue else { return }
            if isFirstResponder {
                reloadInputViews()
            } else {
                reclaimKeyboardFocus()
            }
        }
    }
    var hasText: Bool { true }
    private var lastPointerTime: TimeInterval = 0
    private var isPrimaryDragging = false
    private var activePrimaryClickCount = 1
    private var activePointerButton: RemotePointerButton?
    private var activePointerLastPoint: CGPoint?
    private var pointerPressConsumedByCalibration = false
    private var lastPrimaryPressTime: TimeInterval = 0
    private var lastPrimaryPressLocation = CGPoint.zero
    private var lastPrimaryClickCount = 0
    private var lastSecondaryPressTime: TimeInterval = 0
    private var lastSecondaryPressLocation = CGPoint.zero
    private var lastSecondaryClickCount = 0
    private let suppressedSoftwareKeyboardView = UIView(frame: .zero)
    private let pointerEmissionInterval = 1.0 / 120.0

    init(
        contentAspectRatio: CGFloat,
        zoomScale: CGFloat,
        zoomOffset: CGSize,
        pointerButtonMapping: RemotePointerButtonMapping,
        calibrateNextPointerClick: Bool,
        showsSoftwareKeyboard: Bool,
        onInput: @escaping (RemoteInputEvent) -> Void,
        onPointerCalibration: @escaping (RemotePointerButtonMapping) -> Void,
        onZoom: @escaping (CGFloat, CGPoint) -> Void,
        onViewportPan: @escaping (CGSize) -> Void
    ) {
        self.contentAspectRatio = contentAspectRatio
        self.zoomScale = zoomScale
        self.zoomOffset = zoomOffset
        self.pointerButtonMapping = pointerButtonMapping
        self.calibrateNextPointerClick = calibrateNextPointerClick
        self.showsSoftwareKeyboard = showsSoftwareKeyboard
        self.onInput = onInput
        self.onPointerCalibration = onPointerCalibration
        self.onZoom = onZoom
        self.onViewportPan = onViewportPan
        super.init(frame: .zero)
        backgroundColor = .clear
        isMultipleTouchEnabled = true
        isAccessibilityElement = true
        accessibilityLabel = "Remote Mac screen"
        accessibilityValue = "Zoom \(Int((zoomScale * 100).rounded())) percent"
        accessibilityHint = "Direct touch controls the Mac. Use the viewer controls for named click, zoom, file transfer, and stream actions."
        accessibilityTraits = [.allowsDirectInteraction, .adjustable]
        accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: "Left click", target: self, selector: #selector(accessibilityLeftClick)),
            UIAccessibilityCustomAction(name: "Double-click", target: self, selector: #selector(accessibilityDoubleClick)),
            UIAccessibilityCustomAction(name: "Right click", target: self, selector: #selector(accessibilityRightClick))
        ]
        configureGestures()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(inputContextDidBecomeActive(_:)),
            name: UIWindow.didBecomeKeyNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(inputContextDidBecomeActive(_:)),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(remoteInputWillResignActive(_:)),
            name: UIApplication.willResignActiveNotification,
            object: nil
        )
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override var canBecomeFirstResponder: Bool { true }
    override var inputView: UIView? {
        showsSoftwareKeyboard ? nil : suppressedSoftwareKeyboardView
    }

    override func accessibilityIncrement() {
        onZoom(1.25, CGPoint(x: 0.5, y: 0.5))
    }

    override func accessibilityDecrement() {
        onZoom(0.8, CGPoint(x: 0.5, y: 0.5))
    }

    @objc private func accessibilityLeftClick() -> Bool {
        onInput(.click())
        return true
    }

    @objc private func accessibilityDoubleClick() -> Bool {
        onInput(.doubleClick())
        return true
    }

    @objc private func accessibilityRightClick() -> Bool {
        onInput(.click(secondary: true))
        return true
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            reclaimKeyboardFocus()
        } else {
            releaseRemoteButtons()
        }
    }

    func reclaimKeyboardFocus() {
        guard window != nil, !isFirstResponder else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.window?.isKeyWindow == true,
                  UIApplication.shared.applicationState == .active,
                  !self.isFirstResponder else { return }
            self.becomeFirstResponder()
        }
    }

    @objc private func inputContextDidBecomeActive(_ notification: Notification) {
        reclaimKeyboardFocus()
    }

    @objc private func remoteInputWillResignActive(_ notification: Notification) {
        releaseRemoteButtons()
    }

    func insertText(_ text: String) {
        guard let event = RemoteKeyboardInput.event(text: text) else { return }
        onInput(event)
    }

    func deleteBackward() {
        onInput(.key("delete"))
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var unhandled = Set<UIPress>()
        for press in presses {
            guard let hardwareKey = press.key,
                  let remoteEvent = remoteEvent(for: hardwareKey) else {
                unhandled.insert(press)
                continue
            }
            onInput(remoteEvent)
        }
        if !unhandled.isEmpty {
            super.pressesBegan(unhandled, with: event)
        }
    }

    private func remoteEvent(for hardwareKey: UIKey) -> RemoteInputEvent? {
        let input = hardwareKey.charactersIgnoringModifiers
        let specialKey: String?
        switch input {
        case UIKeyCommand.inputUpArrow: specialKey = "up"
        case UIKeyCommand.inputDownArrow: specialKey = "down"
        case UIKeyCommand.inputLeftArrow: specialKey = "left"
        case UIKeyCommand.inputRightArrow: specialKey = "right"
        case UIKeyCommand.inputEscape: specialKey = "escape"
        case "\r", "\n": specialKey = "return"
        case "\t": specialKey = "tab"
        case "\u{8}", "\u{7f}": specialKey = "delete"
        default: specialKey = nil
        }

        var modifiers: [String] = []
        if hardwareKey.modifierFlags.contains(.command) { modifiers.append("command") }
        if hardwareKey.modifierFlags.contains(.alternate) { modifiers.append("option") }
        if hardwareKey.modifierFlags.contains(.control) { modifiers.append("control") }
        if hardwareKey.modifierFlags.contains(.shift) { modifiers.append("shift") }

        if let specialKey {
            return RemoteKeyboardInput.event(key: specialKey, modifiers: modifiers)
        }

        let hasShortcutModifier = hardwareKey.modifierFlags.intersection([.command, .alternate, .control]).isEmpty == false
        if hasShortcutModifier {
            return RemoteKeyboardInput.event(
                key: input == " " ? "space" : input,
                modifiers: modifiers
            )
        }

        // `characters` already contains Shift/Caps Lock and the active keyboard
        // layout. Sending it as text avoids accidentally carrying a modifier
        // into the following keystroke.
        return RemoteKeyboardInput.event(text: hardwareKey.characters)
    }

    private func configureGestures() {
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(handleHover(_:)))
        addGestureRecognizer(hover)

        let pointerPress = PointerPressGestureRecognizer(
            target: self,
            action: #selector(handlePointerPress(_:))
        )
        pointerPress.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        pointerPress.cancelsTouchesInView = false
        pointerPress.delegate = self
        addGestureRecognizer(pointerPress)

        let touchDoubleClick = UITapGestureRecognizer(target: self, action: #selector(handlePrimaryDoubleClick(_:)))
        touchDoubleClick.numberOfTapsRequired = 2
        touchDoubleClick.allowedTouchTypes = [
            NSNumber(value: UITouch.TouchType.direct.rawValue),
            NSNumber(value: UITouch.TouchType.stylus.rawValue)
        ]
        addGestureRecognizer(touchDoubleClick)

        let touchPrimaryClick = UITapGestureRecognizer(target: self, action: #selector(handlePrimaryClick(_:)))
        touchPrimaryClick.allowedTouchTypes = [
            NSNumber(value: UITouch.TouchType.direct.rawValue),
            NSNumber(value: UITouch.TouchType.stylus.rawValue)
        ]
        touchPrimaryClick.require(toFail: touchDoubleClick)
        addGestureRecognizer(touchPrimaryClick)

        let scroll = UIPanGestureRecognizer(target: self, action: #selector(handleScroll(_:)))
        scroll.allowedTouchTypes = []
        scroll.allowedScrollTypesMask = .all
        scroll.cancelsTouchesInView = false
        scroll.delegate = self
        addGestureRecognizer(scroll)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.cancelsTouchesInView = false
        pinch.delegate = self
        addGestureRecognizer(pinch)

        let touchScroll = UIPanGestureRecognizer(target: self, action: #selector(handleScroll(_:)))
        touchScroll.minimumNumberOfTouches = 2
        touchScroll.maximumNumberOfTouches = 2
        touchScroll.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        touchScroll.cancelsTouchesInView = false
        touchScroll.delegate = self
        addGestureRecognizer(touchScroll)

        let viewportPan = UIPanGestureRecognizer(target: self, action: #selector(handleViewportPan(_:)))
        viewportPan.minimumNumberOfTouches = 3
        viewportPan.maximumNumberOfTouches = 3
        viewportPan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        viewportPan.cancelsTouchesInView = false
        viewportPan.delegate = self
        addGestureRecognizer(viewportPan)

        let touchDrag = UIPanGestureRecognizer(target: self, action: #selector(handlePrimaryDrag(_:)))
        touchDrag.minimumNumberOfTouches = 1
        touchDrag.maximumNumberOfTouches = 1
        touchDrag.allowedTouchTypes = [
            NSNumber(value: UITouch.TouchType.direct.rawValue),
            NSNumber(value: UITouch.TouchType.stylus.rawValue)
        ]
        touchDrag.delegate = self
        addGestureRecognizer(touchDrag)

        let touchHold = UILongPressGestureRecognizer(target: self, action: #selector(handleTouchHold(_:)))
        touchHold.minimumPressDuration = 0.22
        touchHold.allowableMovement = 18
        touchHold.allowedTouchTypes = [
            NSNumber(value: UITouch.TouchType.direct.rawValue),
            NSNumber(value: UITouch.TouchType.stylus.rawValue)
        ]
        touchHold.cancelsTouchesInView = false
        touchHold.delegate = self
        addGestureRecognizer(touchHold)
        touchPrimaryClick.require(toFail: touchHold)
        touchDoubleClick.require(toFail: touchHold)
    }

    @objc private func handleHover(_ recognizer: UIHoverGestureRecognizer) {
        guard !isPrimaryDragging,
              recognizer.state == .began || recognizer.state == .changed else { return }
        sendPointer(at: recognizer.location(in: self))
    }

    @objc private func handlePointerPress(_ recognizer: PointerPressGestureRecognizer) {
        let location = recognizer.location(in: self)
        switch recognizer.state {
        case .began:
            guard let reportedButton = reportedButton(for: recognizer.buttonMask) else { return }
            becomeFirstResponder()
            if calibrateNextPointerClick {
                pointerPressConsumedByCalibration = true
                onPointerCalibration(.calibrated(reportedLeftButton: reportedButton))
                return
            }
            guard activePointerButton == nil,
                  let point = normalizedPoint(location) else { return }
            let resolvedButton = pointerButtonMapping.resolvedButton(for: reportedButton)
            activePointerButton = resolvedButton
            activePointerLastPoint = point
            activePrimaryClickCount = nextPointerClickCount(for: resolvedButton, at: location)
            lastPointerTime = 0
            if resolvedButton == .primary {
                isPrimaryDragging = true
                onInput(.primaryDown(
                    x: point.x,
                    y: point.y,
                    clickCount: activePrimaryClickCount
                ))
            }
        case .changed:
            guard activePointerButton == .primary,
                  isPrimaryDragging,
                  let point = normalizedPoint(location) else { return }
            activePointerLastPoint = point
            let now = ProcessInfo.processInfo.systemUptime
            guard now - lastPointerTime >= pointerEmissionInterval else { return }
            lastPointerTime = now
            onInput(.primaryDrag(
                x: point.x,
                y: point.y,
                clickCount: activePrimaryClickCount
            ))
        case .ended:
            if pointerPressConsumedByCalibration {
                pointerPressConsumedByCalibration = false
                activePointerButton = nil
                activePointerLastPoint = nil
                return
            }
            let point = normalizedPoint(location) ?? activePointerLastPoint
            if activePointerButton == .primary {
                finishPrimaryDrag(at: point)
            } else if activePointerButton == .secondary, let point {
                if activePrimaryClickCount >= 2 {
                    onInput(.doubleClick(secondary: true, x: point.x, y: point.y))
                } else {
                    onInput(.click(secondary: true, x: point.x, y: point.y))
                }
            }
            activePointerButton = nil
            activePointerLastPoint = nil
            activePrimaryClickCount = 1
        case .cancelled, .failed:
            if activePointerButton == .primary {
                finishPrimaryDrag(at: activePointerLastPoint)
            }
            pointerPressConsumedByCalibration = false
            activePointerButton = nil
            activePointerLastPoint = nil
            activePrimaryClickCount = 1
        default:
            break
        }
    }

    private func reportedButton(for mask: UIEvent.ButtonMask) -> RemotePointerButton? {
        if mask.contains(.primary) { return .primary }
        if mask.contains(.secondary) { return .secondary }
        return nil
    }

    private func nextPointerClickCount(
        for button: RemotePointerButton,
        at location: CGPoint
    ) -> Int {
        let now = ProcessInfo.processInfo.systemUptime
        let interval = 0.38
        let maximumDistance: CGFloat = 44
        switch button {
        case .primary:
            let nearby = hypot(
                location.x - lastPrimaryPressLocation.x,
                location.y - lastPrimaryPressLocation.y
            ) <= maximumDistance
            lastPrimaryClickCount = now - lastPrimaryPressTime <= interval && nearby
                ? min(lastPrimaryClickCount + 1, 2)
                : 1
            lastPrimaryPressTime = now
            lastPrimaryPressLocation = location
            return lastPrimaryClickCount
        case .secondary:
            let nearby = hypot(
                location.x - lastSecondaryPressLocation.x,
                location.y - lastSecondaryPressLocation.y
            ) <= maximumDistance
            lastSecondaryClickCount = now - lastSecondaryPressTime <= interval && nearby
                ? min(lastSecondaryClickCount + 1, 2)
                : 1
            lastSecondaryPressTime = now
            lastSecondaryPressLocation = location
            return lastSecondaryClickCount
        }
    }

    @objc private func handleTouchHold(_ recognizer: UILongPressGestureRecognizer) {
        let point = recognizer.location(in: self)
        switch recognizer.state {
        case .began:
            guard !isPrimaryDragging, let normalized = normalizedPoint(point) else { return }
            becomeFirstResponder()
            activePrimaryClickCount = 1
            isPrimaryDragging = true
            lastPointerTime = 0
            onInput(.primaryDown(x: normalized.x, y: normalized.y))
        case .changed:
            guard isPrimaryDragging, let normalized = normalizedPoint(point) else { return }
            let now = ProcessInfo.processInfo.systemUptime
            guard now - lastPointerTime >= pointerEmissionInterval else { return }
            lastPointerTime = now
            onInput(.primaryDrag(x: normalized.x, y: normalized.y))
        case .ended, .cancelled, .failed:
            finishPrimaryDrag(at: normalizedPoint(point))
        default:
            break
        }
    }

    @objc private func handlePrimaryDrag(_ recognizer: UIPanGestureRecognizer) {
        let point = recognizer.location(in: self)
        switch recognizer.state {
        case .began:
            guard let normalized = normalizedPoint(point) else { return }
            becomeFirstResponder()
            isPrimaryDragging = true
            activePrimaryClickCount = 1
            lastPointerTime = 0
            onInput(.primaryDown(x: normalized.x, y: normalized.y, clickCount: activePrimaryClickCount))
        case .changed:
            guard isPrimaryDragging, let normalized = normalizedPoint(point) else { return }
            let now = ProcessInfo.processInfo.systemUptime
            guard now - lastPointerTime >= pointerEmissionInterval else { return }
            lastPointerTime = now
            onInput(.primaryDrag(x: normalized.x, y: normalized.y, clickCount: activePrimaryClickCount))
        case .ended, .cancelled, .failed:
            finishPrimaryDrag(at: normalizedPoint(point))
        default:
            break
        }
    }

    private func finishPrimaryDrag(at point: CGPoint?) {
        guard isPrimaryDragging else { return }
        isPrimaryDragging = false
        onInput(.primaryUp(
            x: point.map { Double($0.x) },
            y: point.map { Double($0.y) },
            clickCount: activePrimaryClickCount
        ))
        activePrimaryClickCount = 1
    }

    private func releaseRemoteButtons() {
        finishPrimaryDrag(at: nil)
        onInput(.releaseButtons())
    }

    private func sendPointer(at point: CGPoint) {
        guard let normalized = normalizedPoint(point) else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastPointerTime >= pointerEmissionInterval else { return }
        lastPointerTime = now
        onInput(.pointer(x: normalized.x, y: normalized.y))
    }

    @objc private func handlePrimaryClick(_ recognizer: UITapGestureRecognizer) {
        becomeFirstResponder()
        guard let point = normalizedPoint(recognizer.location(in: self)) else { return }
        onInput(.click(x: point.x, y: point.y))
    }

    @objc private func handlePrimaryDoubleClick(_ recognizer: UITapGestureRecognizer) {
        becomeFirstResponder()
        guard let point = normalizedPoint(recognizer.location(in: self)) else { return }
        onInput(.doubleClick(x: point.x, y: point.y))
    }

    @objc private func handleScroll(_ recognizer: UIPanGestureRecognizer) {
        let delta = recognizer.translation(in: self)
        recognizer.setTranslation(.zero, in: self)
        guard delta != .zero else { return }
        onInput(.scroll(x: delta.x, y: delta.y))
    }

    @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
        guard recognizer.state == .began || recognizer.state == .changed else { return }
        let factor = recognizer.scale
        recognizer.scale = 1
        guard factor.isFinite, factor > 0 else { return }
        let point = recognizer.location(in: self)
        onZoom(factor, CGPoint(
            x: point.x / max(bounds.width, 1),
            y: point.y / max(bounds.height, 1)
        ))
    }

    @objc private func handleViewportPan(_ recognizer: UIPanGestureRecognizer) {
        guard recognizer.state == .began || recognizer.state == .changed else { return }
        let delta = recognizer.translation(in: self)
        recognizer.setTranslation(.zero, in: self)
        guard delta != .zero else { return }
        onViewportPan(CGSize(width: delta.x, height: delta.y))
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        if gestureRecognizer is UILongPressGestureRecognizer ||
            otherGestureRecognizer is UILongPressGestureRecognizer ||
            gestureRecognizer is PointerPressGestureRecognizer ||
            otherGestureRecognizer is PointerPressGestureRecognizer {
            return false
        }
        if gestureRecognizer is UIPinchGestureRecognizer || otherGestureRecognizer is UIPinchGestureRecognizer {
            return false
        }
        return gestureRecognizer is UIPanGestureRecognizer || otherGestureRecognizer is UIPanGestureRecognizer
    }

    private func normalizedPoint(_ point: CGPoint) -> CGPoint? {
        guard bounds.width > 0, bounds.height > 0, contentAspectRatio > 0 else { return nil }
        let scale = max(zoomScale, 1)
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let point = CGPoint(
            x: center.x + (point.x - center.x - zoomOffset.width) / scale,
            y: center.y + (point.y - center.y - zoomOffset.height) / scale
        )
        let viewAspect = bounds.width / bounds.height
        let contentRect: CGRect
        if viewAspect > contentAspectRatio {
            let width = bounds.height * contentAspectRatio
            contentRect = CGRect(x: (bounds.width - width) / 2, y: 0, width: width, height: bounds.height)
        } else {
            let height = bounds.width / contentAspectRatio
            contentRect = CGRect(x: 0, y: (bounds.height - height) / 2, width: bounds.width, height: height)
        }
        guard contentRect.contains(point) else { return nil }
        return CGPoint(
            x: (point.x - contentRect.minX) / contentRect.width,
            y: (point.y - contentRect.minY) / contentRect.height
        )
    }
}
