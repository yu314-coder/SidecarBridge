import SwiftUI
import UIKit

struct RemoteInputSurface: UIViewRepresentable {
    let contentAspectRatio: CGFloat
    let onInput: (RemoteInputEvent) -> Void

    func makeUIView(context: Context) -> InputView {
        InputView(contentAspectRatio: contentAspectRatio, onInput: onInput)
    }

    func updateUIView(_ uiView: InputView, context: Context) {
        uiView.contentAspectRatio = contentAspectRatio
        uiView.onInput = onInput
    }
}

final class InputView: UIView, UIKeyInput, UIGestureRecognizerDelegate {
    var onInput: (RemoteInputEvent) -> Void
    var contentAspectRatio: CGFloat
    var hasText: Bool { true }
    private var lastPointerTime: TimeInterval = 0
    private var isPrimaryDragging = false

    init(contentAspectRatio: CGFloat, onInput: @escaping (RemoteInputEvent) -> Void) {
        self.contentAspectRatio = contentAspectRatio
        self.onInput = onInput
        super.init(frame: .zero)
        backgroundColor = .clear
        isMultipleTouchEnabled = true
        configureGestures()
    }

    required init?(coder: NSCoder) { nil }

    override var canBecomeFirstResponder: Bool { true }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            becomeFirstResponder()
        } else {
            finishPrimaryDrag(at: nil)
        }
    }

    func insertText(_ text: String) {
        onInput(.text(text))
    }

    func deleteBackward() {
        onInput(.key("delete"))
    }

    override var keyCommands: [UIKeyCommand]? {
        var commands = [
            command(UIKeyCommand.inputUpArrow),
            command(UIKeyCommand.inputDownArrow),
            command(UIKeyCommand.inputLeftArrow),
            command(UIKeyCommand.inputRightArrow),
            command(UIKeyCommand.inputEscape),
            command("\r"),
            command("\t")
        ]
        for key in ["a", "c", "v", "x", "z"] {
            commands.append(command(key, modifiers: .command))
            commands.append(command(key, modifiers: [.command, .shift]))
        }
        return commands
    }

    private func command(_ input: String, modifiers: UIKeyModifierFlags = []) -> UIKeyCommand {
        let command = UIKeyCommand(input: input, modifierFlags: modifiers, action: #selector(handleKeyCommand(_:)))
        command.wantsPriorityOverSystemBehavior = true
        return command
    }

    @objc private func handleKeyCommand(_ sender: UIKeyCommand) {
        guard let input = sender.input else { return }
        let key: String
        switch input {
        case UIKeyCommand.inputUpArrow: key = "up"
        case UIKeyCommand.inputDownArrow: key = "down"
        case UIKeyCommand.inputLeftArrow: key = "left"
        case UIKeyCommand.inputRightArrow: key = "right"
        case UIKeyCommand.inputEscape: key = "escape"
        case "\r": key = "return"
        case "\t": key = "tab"
        default: key = input.lowercased()
        }
        var modifiers: [String] = []
        if sender.modifierFlags.contains(.command) { modifiers.append("command") }
        if sender.modifierFlags.contains(.alternate) { modifiers.append("option") }
        if sender.modifierFlags.contains(.control) { modifiers.append("control") }
        if sender.modifierFlags.contains(.shift) { modifiers.append("shift") }
        onInput(.key(key, modifiers: modifiers))
    }

    private func configureGestures() {
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(handleHover(_:)))
        addGestureRecognizer(hover)

        let pointerDoubleClick = UITapGestureRecognizer(target: self, action: #selector(handlePrimaryDoubleClick(_:)))
        pointerDoubleClick.numberOfTapsRequired = 2
        pointerDoubleClick.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        pointerDoubleClick.buttonMaskRequired = .primary
        addGestureRecognizer(pointerDoubleClick)

        let pointerPrimaryClick = UITapGestureRecognizer(target: self, action: #selector(handlePrimaryClick(_:)))
        pointerPrimaryClick.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        pointerPrimaryClick.buttonMaskRequired = .primary
        pointerPrimaryClick.require(toFail: pointerDoubleClick)
        addGestureRecognizer(pointerPrimaryClick)

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

        let secondary = UITapGestureRecognizer(target: self, action: #selector(handleSecondaryClick(_:)))
        secondary.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        secondary.buttonMaskRequired = .secondary
        addGestureRecognizer(secondary)

        let pointerDrag = UIPanGestureRecognizer(target: self, action: #selector(handlePrimaryDrag(_:)))
        pointerDrag.minimumNumberOfTouches = 1
        pointerDrag.maximumNumberOfTouches = 1
        pointerDrag.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        addGestureRecognizer(pointerDrag)

        let scroll = UIPanGestureRecognizer(target: self, action: #selector(handleScroll(_:)))
        scroll.allowedTouchTypes = []
        scroll.allowedScrollTypesMask = .all
        scroll.cancelsTouchesInView = false
        scroll.delegate = self
        addGestureRecognizer(scroll)

        let touchScroll = UIPanGestureRecognizer(target: self, action: #selector(handleScroll(_:)))
        touchScroll.minimumNumberOfTouches = 2
        touchScroll.maximumNumberOfTouches = 2
        touchScroll.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        touchScroll.cancelsTouchesInView = false
        touchScroll.delegate = self
        addGestureRecognizer(touchScroll)

        let touchDrag = UIPanGestureRecognizer(target: self, action: #selector(handlePrimaryDrag(_:)))
        touchDrag.minimumNumberOfTouches = 1
        touchDrag.maximumNumberOfTouches = 1
        touchDrag.allowedTouchTypes = [
            NSNumber(value: UITouch.TouchType.direct.rawValue),
            NSNumber(value: UITouch.TouchType.stylus.rawValue)
        ]
        addGestureRecognizer(touchDrag)
    }

    @objc private func handleHover(_ recognizer: UIHoverGestureRecognizer) {
        guard !isPrimaryDragging,
              recognizer.state == .began || recognizer.state == .changed else { return }
        sendPointer(at: recognizer.location(in: self))
    }

    @objc private func handlePrimaryDrag(_ recognizer: UIPanGestureRecognizer) {
        let point = recognizer.location(in: self)
        switch recognizer.state {
        case .began:
            guard let normalized = normalizedPoint(point) else { return }
            becomeFirstResponder()
            isPrimaryDragging = true
            lastPointerTime = 0
            onInput(.primaryDown(x: normalized.x, y: normalized.y))
        case .changed:
            guard isPrimaryDragging, let normalized = normalizedPoint(point) else { return }
            let now = ProcessInfo.processInfo.systemUptime
            guard now - lastPointerTime >= 1.0 / 60.0 else { return }
            lastPointerTime = now
            onInput(.primaryDrag(x: normalized.x, y: normalized.y))
        case .ended, .cancelled, .failed:
            finishPrimaryDrag(at: normalizedPoint(point))
        default:
            break
        }
    }

    private func finishPrimaryDrag(at point: CGPoint?) {
        guard isPrimaryDragging else { return }
        isPrimaryDragging = false
        onInput(.primaryUp(x: point.map { Double($0.x) }, y: point.map { Double($0.y) }))
    }

    private func sendPointer(at point: CGPoint) {
        guard let normalized = normalizedPoint(point) else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastPointerTime >= 1.0 / 60.0 else { return }
        lastPointerTime = now
        onInput(.pointer(x: normalized.x, y: normalized.y))
    }

    @objc private func handlePrimaryClick(_ recognizer: UITapGestureRecognizer) {
        becomeFirstResponder()
        guard let point = normalizedPoint(recognizer.location(in: self)) else { return }
        onInput(.click(x: point.x, y: point.y))
    }

    @objc private func handleSecondaryClick(_ recognizer: UITapGestureRecognizer) {
        becomeFirstResponder()
        guard let point = normalizedPoint(recognizer.location(in: self)) else { return }
        onInput(.click(secondary: true, x: point.x, y: point.y))
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

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        gestureRecognizer is UIPanGestureRecognizer || otherGestureRecognizer is UIPanGestureRecognizer
    }

    private func normalizedPoint(_ point: CGPoint) -> CGPoint? {
        guard bounds.width > 0, bounds.height > 0, contentAspectRatio > 0 else { return nil }
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
