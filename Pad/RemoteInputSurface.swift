import SwiftUI
import GameController
import OSLog
import UIKit
import UIKit.UIGestureRecognizerSubclass

private let remoteTextLog = Logger(
    subsystem: "io.sidecarbridge.mac",
    category: "RemoteText"
)

final class PointerPressGestureRecognizer: UIGestureRecognizer {
    private var trackedTouch: UITouch?
    private(set) var preciseLocation = CGPoint.zero
    private(set) var reportedButtonMask: UIEvent.ButtonMask = []

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        guard state == .possible, trackedTouch == nil, let touch = touches.first else {
            for touch in touches { ignore(touch, for: event) }
            return
        }
        guard touches.count == 1 else {
            state = .failed
            return
        }
        trackedTouch = touch
        capture(touch, with: event)
        state = .began
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesMoved(touches, with: event)
        guard let trackedTouch,
              touches.contains(trackedTouch),
              state == .began || state == .changed else { return }
        capture(event.coalescedTouches(for: trackedTouch)?.last ?? trackedTouch, with: event)
        state = .changed
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        guard let trackedTouch,
              touches.contains(trackedTouch),
              state == .began || state == .changed else { return }
        capture(trackedTouch, with: event)
        state = .ended
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        guard state == .began || state == .changed else { return }
        state = .cancelled
    }

    override func reset() {
        super.reset()
        trackedTouch = nil
        preciseLocation = .zero
        reportedButtonMask = []
    }

    private func capture(_ touch: UITouch, with event: UIEvent) {
        preciseLocation = touch.preciseLocation(in: view)
        reportedButtonMask = event.buttonMask
    }
}

final class DirectTouchGestureRecognizer: UIGestureRecognizer {
    private var trackedTouch: UITouch?
    private(set) var preciseLocation = CGPoint.zero

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        if let trackedTouch {
            for touch in touches where touch != trackedTouch {
                ignore(touch, for: event)
            }
            if state == .began || state == .changed {
                state = .cancelled
            }
            return
        }
        guard state == .possible, touches.count == 1, let touch = touches.first else {
            state = .failed
            return
        }
        trackedTouch = touch
        capture(touch, with: event)
        state = .began
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesMoved(touches, with: event)
        guard let trackedTouch,
              touches.contains(trackedTouch),
              state == .began || state == .changed else { return }
        capture(event.coalescedTouches(for: trackedTouch)?.last ?? trackedTouch, with: event)
        state = .changed
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        guard let trackedTouch,
              touches.contains(trackedTouch),
              state == .began || state == .changed else { return }
        capture(trackedTouch, with: event)
        state = .ended
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        guard state == .began || state == .changed else { return }
        state = .cancelled
    }

    override func reset() {
        super.reset()
        trackedTouch = nil
        preciseLocation = .zero
    }

    private func capture(_ touch: UITouch, with event: UIEvent) {
        preciseLocation = touch.preciseLocation(in: view)
    }
}

final class RemoteScrollGestureRecognizer: UIPanGestureRecognizer {
    var representsContinuousScroll = true
}

final class RemoteHoldGestureRecognizer: UILongPressGestureRecognizer {
    var consumesDirectTouch = false
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

private final class RemoteTextInputView: UITextView {
    static let compositionAnchor = String(repeating: "1", count: 64)

    var showsSoftwareKeyboard = false {
        didSet {
            updateInputView()
        }
    }
    // Start with UIKit's real input view. GCKeyboard.coalesced is not a
    // reliable signal for the keyboard built into an iPad Magic Keyboard, and
    // replacing inputView too early prevents the system-owned Globe key from
    // publishing its UITextInputMode change.
    var hasHardwareKeyboard = true {
        didSet {
            updateInputView()
        }
    }
    var onDeleteAtAnchor: (() -> Void)?
    var onHardwareKeyDown: ((UIKey) -> Bool)?
    var onHardwareKeyUp: ((UIKey) -> Bool)?
    var onControlArrow: ((String) -> Void)?
    var onInputModeSwitch: (() -> Void)?
    var onTextInputStateChanged: (() -> Void)?

    private let suppressedSoftwareKeyboardView = UIView(frame: .zero)

    private func updateInputView() {
        // A zero-sized custom input view suppresses the on-screen keyboard, but
        // it also disconnects the standard text-input system that tracks the
        // Magic Keyboard's Globe/input-source key. Keep UIKit's real input view
        // while hardware is attached; iPadOS already hides its software
        // keyboard in that state.
        let usesSystemInputView = showsSoftwareKeyboard || hasHardwareKeyboard
        if usesSystemInputView {
            guard inputView != nil else { return }
            inputView = nil
        } else {
            guard inputView !== suppressedSoftwareKeyboardView else { return }
            inputView = suppressedSoftwareKeyboardView
        }
        if isFirstResponder {
            reloadInputViews()
        }
    }

    override var keyCommands: [UIKeyCommand]? {
        [
            controlArrowCommand(UIKeyCommand.inputUpArrow, title: "Control–Up"),
            controlArrowCommand(UIKeyCommand.inputDownArrow, title: "Control–Down"),
            controlArrowCommand(UIKeyCommand.inputLeftArrow, title: "Control–Left"),
            controlArrowCommand(UIKeyCommand.inputRightArrow, title: "Control–Right"),
            inputModeSwitchCommand()
        ]
    }

    override func deleteBackward() {
        // While an IME has marked text, Backspace must edit the local
        // composition (for example, the uncommitted pinyin). Keep a protected
        // anchor in the backing document so UIKit always has surrounding text
        // for multistage input; only forward deletion at that boundary.
        if markedTextRange == nil,
           selectedRange.length == 0,
           selectedRange.location <= Self.compositionAnchor.utf16.count {
            onDeleteAtAnchor?()
            return
        }
        super.deleteBackward()
    }

    override func insertText(_ text: String) {
        super.insertText(text)
        // Candidate confirmation is not guaranteed to produce a separate
        // UITextViewDelegate change after the marked range disappears.
        onTextInputStateChanged?()
    }

    override func unmarkText() {
        super.unmarkText()
        // A hardware Chinese input method can commit by only ending its marked
        // range. Observe that transition directly so the text is not held
        // until the next English keystroke.
        onTextInputStateChanged?()
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var unhandled = Set<UIPress>()
        for press in presses {
            guard let key = press.key, onHardwareKeyDown?(key) == true else {
                unhandled.insert(press)
                continue
            }
        }
        if !unhandled.isEmpty {
            super.pressesBegan(unhandled, with: event)
        }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled = unhandledHardwareKeyReleases(presses)
        if !unhandled.isEmpty {
            super.pressesEnded(unhandled, with: event)
        }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled = unhandledHardwareKeyReleases(presses)
        if !unhandled.isEmpty {
            super.pressesCancelled(unhandled, with: event)
        }
    }

    private func unhandledHardwareKeyReleases(
        _ presses: Set<UIPress>
    ) -> Set<UIPress> {
        var unhandled = Set<UIPress>()
        for press in presses {
            guard let key = press.key, onHardwareKeyUp?(key) == true else {
                unhandled.insert(press)
                continue
            }
        }
        return unhandled
    }

    private func controlArrowCommand(_ input: String, title: String) -> UIKeyCommand {
        let command = UIKeyCommand(
            input: input,
            modifierFlags: [.control],
            action: #selector(handleControlArrow(_:))
        )
        command.discoverabilityTitle = title
        return command
    }

    private func inputModeSwitchCommand() -> UIKeyCommand {
        let command = UIKeyCommand(
            input: " ",
            modifierFlags: [.control],
            action: #selector(handleInputModeSwitch(_:))
        )
        command.discoverabilityTitle = "Switch Mac Input Source"
        command.wantsPriorityOverSystemBehavior = true
        return command
    }

    @objc private func handleControlArrow(_ command: UIKeyCommand) {
        let key: String
        switch command.input {
        case UIKeyCommand.inputUpArrow: key = "up"
        case UIKeyCommand.inputDownArrow: key = "down"
        case UIKeyCommand.inputLeftArrow: key = "left"
        case UIKeyCommand.inputRightArrow: key = "right"
        default: return
        }
        onControlArrow?(key)
    }

    @objc private func handleInputModeSwitch(_ command: UIKeyCommand) {
        onInputModeSwitch?()
    }
}

final class InputView: UIView, UITextViewDelegate, UIGestureRecognizerDelegate {
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
            textInputView.showsSoftwareKeyboard = showsSoftwareKeyboard
            if showsSoftwareKeyboard {
                didSuppressUnexpectedSoftwareKeyboard = false
            } else {
                didSuppressUnexpectedSoftwareKeyboard = true
                textInputView.hasHardwareKeyboard = false
            }
            reclaimKeyboardFocus()
        }
    }
    private var lastPointerTime: TimeInterval = 0
    private var isPrimaryDragging = false
    private var activePrimaryClickCount = 1
    private var activePointerButton: RemotePointerButton?
    private var activePointerLastPoint: CGPoint?
    private var activePointerStartLocation = CGPoint.zero
    private var activePointerStartedAt: TimeInterval = 0
    private var activePointerExceededClickSlop = false
    private var pointerPressConsumedByCalibration = false
    private var primaryClickTracker = RemoteClickSequenceTracker()
    private var secondaryClickTracker = RemoteClickSequenceTracker()
    private var directTouchClickTracker = RemoteClickSequenceTracker()
    private var directTouchStartLocation = CGPoint.zero
    private var directTouchLastLocation = CGPoint.zero
    private var directTouchHoldLastLocation = CGPoint.zero
    private var directTouchStartedAt: TimeInterval = 0
    private var directTouchMovedBeyondClickSlop = false
    private var directTouchConsumedByHold = false
    private let textInputView = RemoteTextInputView(frame: .zero)
    private var lastCommittedInputBuffer = RemoteTextInputView.compositionAnchor
    private var isUpdatingInputBuffer = false
    private var pendingTextCommitGeneration = 0
    private var pendingIMECommitGeneration = 0
    private let pointerEmissionInterval = 1.0 / 120.0
    private let pointerDoubleClickInterval: TimeInterval = 0.42
    private let pointerDoubleClickDistance = 44.0
    private let pointerClickSlop: CGFloat = 8
    private let directTouchClickSlop: CGFloat = 12
    private var gameControllerControlIsDown = false
    private var lastControlArrow: (key: String, time: TimeInterval)?
    private var lastInputModeSwitchAt: TimeInterval = 0
    private var lastForwardedInputLanguage: String?
    private var inputLanguageState = RemoteInputLanguageState()
    private var macOwnsInputMode = false
    private var didSuppressUnexpectedSoftwareKeyboard = false
    private var hardwareKeyRepeatTasks: [Int: Task<Void, Never>] = [:]
    private let hardwareKeyRepeatDelay = Duration.milliseconds(420)
    private let hardwareKeyRepeatInterval = Duration.milliseconds(45)

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
        configureTextInput()
        configureGestures()
        configureHardwareKeyboard()
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
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(hardwareKeyboardDidConnect(_:)),
            name: .GCKeyboardDidConnect,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(hardwareKeyboardDidConnect(_:)),
            name: .GCKeyboardDidDisconnect,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(inputModeDidChange(_:)),
            name: UITextInputMode.currentInputModeDidChangeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(softwareKeyboardWillShow(_:)),
            name: UIResponder.keyboardWillShowNotification,
            object: nil
        )
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        hardwareKeyRepeatTasks.values.forEach { $0.cancel() }
        GCKeyboard.coalesced?.keyboardInput?.keyChangedHandler = nil
        NotificationCenter.default.removeObserver(self)
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
            configureHardwareKeyboard()
            reclaimKeyboardFocus()
        } else {
            releaseRemoteButtons()
        }
    }

    func reclaimKeyboardFocus() {
        guard window != nil, !textInputView.isFirstResponder else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.window?.isKeyWindow == true,
                  UIApplication.shared.applicationState == .active,
                  !self.textInputView.isFirstResponder else { return }
            self.textInputView.becomeFirstResponder()
        }
    }

    @objc private func inputContextDidBecomeActive(_ notification: Notification) {
        reclaimKeyboardFocus()
    }

    @objc private func remoteInputWillResignActive(_ notification: Notification) {
        releaseRemoteButtons()
    }

    @objc private func hardwareKeyboardDidConnect(_ notification: Notification) {
        configureHardwareKeyboard()
        synchronizeRemoteInputMode()
    }

    @objc private func inputModeDidChange(_ notification: Notification) {
        macOwnsInputMode = false
        let announcedLanguage = (notification.object as? UITextInputMode)?
            .primaryLanguage
        // The Magic Keyboard Globe/Switch Keyboard key is consumed by
        // iPadOS, so it doesn't have a public UIKeyCommand input. Apple does
        // publish this notification for the resulting mode change. Cycle the
        // Mac first even when the new mode has no language (for example,
        // Emoji), then reconcile to the exact language when UIKit provides it.
        if lastForwardedInputLanguage != nil {
            forwardInputModeSwitch(source: "uikit-input-mode-notification")
        }
        synchronizeRemoteInputMode(
            language: announcedLanguage,
            force: true
        )
    }

    @objc private func softwareKeyboardWillShow(_ notification: Notification) {
        guard !showsSoftwareKeyboard,
              let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey]
                as? CGRect,
              frame.height > 100 else { return }
        // Only suppress a real on-screen keyboard. A Magic Keyboard normally
        // keeps this path untouched, preserving Globe/input-mode events.
        didSuppressUnexpectedSoftwareKeyboard = true
        textInputView.hasHardwareKeyboard = false
    }

    private func configureTextInput() {
        textInputView.delegate = self
        textInputView.showsSoftwareKeyboard = showsSoftwareKeyboard
        textInputView.backgroundColor = .clear
        textInputView.textColor = .clear
        textInputView.tintColor = .clear
        textInputView.alpha = 0.01
        textInputView.autocorrectionType = .no
        textInputView.autocapitalizationType = .none
        textInputView.smartDashesType = .no
        textInputView.smartQuotesType = .no
        textInputView.smartInsertDeleteType = .no
        textInputView.isScrollEnabled = false
        textInputView.isAccessibilityElement = false
        textInputView.accessibilityElementsHidden = true
        textInputView.text = RemoteTextInputView.compositionAnchor
        textInputView.selectedRange = NSRange(
            location: RemoteTextInputView.compositionAnchor.utf16.count,
            length: 0
        )
        textInputView.onDeleteAtAnchor = { [weak self] in
            self?.onInput(.key("delete"))
        }
        textInputView.onControlArrow = { [weak self] key in
            self?.sendControlArrow(key)
        }
        textInputView.onInputModeSwitch = { [weak self] in
            self?.forwardInputModeSwitch(source: "control-space")
        }
        textInputView.onHardwareKeyDown = { [weak self] key in
            self?.handleHardwareKeyDown(key) ?? false
        }
        textInputView.onHardwareKeyUp = { [weak self] key in
            self?.handleHardwareKeyUp(key) ?? false
        }
        textInputView.onTextInputStateChanged = { [weak self, weak textInputView] in
            guard let self, let textInputView else { return }
            self.scheduleIMECommitPoll(from: textInputView)
        }
        addSubview(textInputView)
        synchronizeRemoteInputMode(force: true)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // The view must remain in the responder hierarchy for UITextInput, but
        // it should never cover or intercept the remote screen's gestures.
        textInputView.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
    }

    func textViewDidChange(_ textView: UITextView) {
        guard !isUpdatingInputBuffer else { return }
        scheduleCommittedTextFlush(from: textView)
    }

    private func scheduleCommittedTextFlush(from textView: UITextView) {
        guard !isUpdatingInputBuffer else { return }
        pendingTextCommitGeneration += 1
        let generation = pendingTextCommitGeneration

        // UIKit can notify its delegate before an IME has finished updating
        // markedTextRange. Wait one run-loop before deciding that text is
        // committed so provisional pinyin is never cleared or sent remotely.
        DispatchQueue.main.async { [weak self, weak textView] in
            guard let self,
                  let textView,
                  generation == self.pendingTextCommitGeneration else { return }
            self.flushCommittedText(from: textView)
        }
    }

    private func scheduleIMECommitPoll(from textView: UITextView) {
        guard !isUpdatingInputBuffer else { return }
        pendingIMECommitGeneration += 1
        let generation = pendingIMECommitGeneration
        pollForIMECommit(from: textView, generation: generation, attempt: 0)
    }

    private func pollForIMECommit(
        from textView: UITextView,
        generation: Int,
        attempt: Int
    ) {
        let delay = attempt == 0 ? 0.0 : 0.016
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak textView] in
            guard let self,
                  let textView,
                  generation == self.pendingIMECommitGeneration else { return }
            if self.flushCommittedText(from: textView) {
                return
            }
            guard attempt < 75 else {
                remoteTextLog.error("IME commit timed out without a committed delta")
                return
            }
            self.pollForIMECommit(
                from: textView,
                generation: generation,
                attempt: attempt + 1
            )
        }
    }

    @discardableResult
    private func flushCommittedText(from textView: UITextView) -> Bool {
        guard textView.markedTextRange == nil else { return false }

        let currentBuffer = textView.text ?? ""
        let delta = RemoteTextDelta.between(lastCommittedInputBuffer, and: currentBuffer)
        guard !delta.isEmpty else { return false }
        lastCommittedInputBuffer = currentBuffer

        for _ in 0..<delta.deleteCount {
            onInput(.key("delete"))
        }
        if let event = RemoteKeyboardInput.event(text: delta.insertedText) {
            onInput(event)
        }
        remoteTextLog.notice(
            "Committed remote text insertedCharacters=\(delta.insertedText.count, privacy: .public) deletions=\(delta.deleteCount, privacy: .public)"
        )

        // Preserve surrounding text across ordinary commits so Chinese,
        // Japanese, and Korean input methods keep a stable document context.
        // Rebase only after substantial growth, and never during composition.
        if currentBuffer.utf16.count > 4096 {
            rebaseInputBuffer(textView)
        }
        return true
    }

    func textView(
        _ textView: UITextView,
        shouldChangeTextIn range: NSRange,
        replacementText text: String
    ) -> Bool {
        guard text == "\n", textView.markedTextRange == nil else { return true }
        onInput(.key("return"))
        return false
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
        scheduleIMECommitPoll(from: textView)
        guard !isUpdatingInputBuffer,
              textView.markedTextRange == nil,
              textView.selectedRange.location
                < RemoteTextInputView.compositionAnchor.utf16.count else { return }
        textView.selectedRange = NSRange(
            location: RemoteTextInputView.compositionAnchor.utf16.count,
            length: 0
        )
    }

    private func rebaseInputBuffer(_ textView: UITextView) {
        pendingTextCommitGeneration += 1
        isUpdatingInputBuffer = true
        textView.text = RemoteTextInputView.compositionAnchor
        textView.selectedRange = NSRange(
            location: RemoteTextInputView.compositionAnchor.utf16.count,
            length: 0
        )
        lastCommittedInputBuffer = RemoteTextInputView.compositionAnchor
        isUpdatingInputBuffer = false
    }

    private func handleHardwareKeyDown(_ hardwareKey: UIKey) -> Bool {
        let hidUsage = hardwareKey.keyCode.rawValue
        let modifiers = remoteModifiers(for: hardwareKey)
        if RemoteKeyboardInput.isInputModeSwitchShortcut(
            hidUsage: hidUsage,
            modifiers: modifiers
        ) {
            forwardInputModeSwitch(source: "control-space")
            return true
        }
        if RemoteKeyboardInput.isChineseEnglishToggleHIDUsage(hidUsage) {
            forwardChineseEnglishInputModeSwitch(source: "hid-zh-en-\(hidUsage)")
            // Consume 中/英 locally. Letting iPadOS also switch caused its
            // hidden software keyboard to appear and made the iPad and Mac
            // input modes fight on the next physical key.
            return true
        }
        if RemoteKeyboardInput.isLanguageSwitchHIDUsage(hidUsage) {
            forwardInputModeSwitch(source: "hid-lang-\(hidUsage)")
            // UIKit must also receive the key so the iPad input mode changes.
            // Its notification then reconciles the Mac to the exact language.
            return false
        }
        guard let remoteEvent = remoteEvent(for: hardwareKey) else { return false }
        guard hardwareKeyRepeatTasks[hidUsage] == nil else {
            // UIKit may deliver repeat press notifications itself. SidecarBridge
            // owns the repeat cadence so each held key has one predictable
            // stream and never accelerates twice.
            return true
        }
        forwardHardwareKeyEvent(remoteEvent)
        hardwareKeyRepeatTasks[hidUsage] = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: self.hardwareKeyRepeatDelay)
            } catch {
                return
            }
            while !Task.isCancelled,
                  self.hardwareKeyRepeatTasks[hidUsage] != nil {
                self.forwardHardwareKeyEvent(remoteEvent)
                do {
                    try await Task.sleep(for: self.hardwareKeyRepeatInterval)
                } catch {
                    return
                }
            }
        }
        return true
    }

    private func handleHardwareKeyUp(_ hardwareKey: UIKey) -> Bool {
        let hidUsage = hardwareKey.keyCode.rawValue
        if RemoteKeyboardInput.isInputModeSwitchShortcut(
            hidUsage: hidUsage,
            modifiers: remoteModifiers(for: hardwareKey)
        ) {
            return true
        }
        if RemoteKeyboardInput.isChineseEnglishToggleHIDUsage(hidUsage) {
            return true
        }
        if RemoteKeyboardInput.isLanguageSwitchHIDUsage(hidUsage) {
            return false
        }
        guard let task = hardwareKeyRepeatTasks.removeValue(forKey: hidUsage) else {
            return false
        }
        task.cancel()
        return true
    }

    private func forwardHardwareKeyEvent(_ remoteEvent: RemoteInputEvent) {
        if !macOwnsInputMode {
            synchronizeRemoteInputMode()
        }
        if remoteEvent.kind == .key,
           let key = remoteEvent.key,
           remoteEvent.modifiers?.contains("control") == true,
           ["up", "down", "left", "right"].contains(key) {
            sendControlArrow(key)
        } else {
            onInput(remoteEvent)
        }
    }

    private func synchronizeRemoteInputMode(
        language announcedLanguage: String? = nil,
        force: Bool = false
    ) {
        guard let language = inputLanguageState.resolve(
                announcedLanguage: announcedLanguage,
                responderLanguage: textInputView.textInputMode?.primaryLanguage
              ) else {
            return
        }
        guard force || language != lastForwardedInputLanguage else { return }
        lastForwardedInputLanguage = language
        onInput(.inputMode(language: language))
        remoteTextLog.notice(
            "Forwarding physical keyboard input mode language=\(language, privacy: .public)"
        )
    }

    private func configureHardwareKeyboard() {
        if GCKeyboard.coalesced != nil,
           !didSuppressUnexpectedSoftwareKeyboard {
            textInputView.hasHardwareKeyboard = true
        }
        guard let keyboardInput = GCKeyboard.coalesced?.keyboardInput else {
            return
        }
        keyboardInput.keyChangedHandler = { [weak self] keyboard, _, keyCode, pressed in
            DispatchQueue.main.async {
                guard let self else { return }
                let hidUsage = Int(keyCode.rawValue)
                if pressed,
                   RemoteKeyboardInput.isChineseEnglishToggleHIDUsage(hidUsage) {
                    self.forwardChineseEnglishInputModeSwitch(
                        source: "gc-zh-en-\(hidUsage)"
                    )
                    return
                }
                if pressed,
                   RemoteKeyboardInput.isDedicatedLanguageSwitchHIDUsage(hidUsage) {
                    self.forwardInputModeSwitch(source: "hid-lang-\(hidUsage)")
                    return
                }
                if keyCode == .leftControl || keyCode == .rightControl {
                    self.gameControllerControlIsDown = pressed
                    return
                }
                let controlIsPressed = self.gameControllerControlIsDown
                    || keyboard.button(forKeyCode: .leftControl)?.isPressed == true
                    || keyboard.button(forKeyCode: .rightControl)?.isPressed == true
                guard pressed, controlIsPressed else { return }
                let key: String?
                switch keyCode {
                case .upArrow: key = "up"
                case .downArrow: key = "down"
                case .leftArrow: key = "left"
                case .rightArrow: key = "right"
                default: key = nil
                }
                if let key { self.sendControlArrow(key) }
            }
        }
        DispatchQueue.main.async { [weak self] in
            self?.synchronizeRemoteInputMode(force: true)
        }
    }

    private func forwardInputModeSwitch(source: String) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastInputModeSwitchAt >= 0.35 else { return }
        lastInputModeSwitchAt = now
        macOwnsInputMode = false
        inputLanguageState.beginInputModeSwitch()
        onInput(.cycleInputMode())
        remoteTextLog.notice(
            "Forwarding physical input-mode switch source=\(source, privacy: .public)"
        )

        // Some hardware reports the key before UITextInputMode posts its
        // notification. Re-check after UIKit has processed the responder event.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            self?.synchronizeRemoteInputMode()
        }
    }

    private func forwardChineseEnglishInputModeSwitch(source: String) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastInputModeSwitchAt >= 0.35 else { return }
        lastInputModeSwitchAt = now
        macOwnsInputMode = true
        onInput(.toggleChineseEnglishInputMode())
        remoteTextLog.notice(
            "Forwarding Mac-only 中/英 switch source=\(source, privacy: .public)"
        )
    }

    private func sendControlArrow(_ key: String) {
        let now = ProcessInfo.processInfo.systemUptime
        if let lastControlArrow,
           lastControlArrow.key == key,
           now - lastControlArrow.time < 0.08 {
            return
        }
        lastControlArrow = (key, now)
        onInput(.key(key, modifiers: ["control"]))
    }

    private func remoteEvent(for hardwareKey: UIKey) -> RemoteInputEvent? {
        let modifiers = remoteModifiers(for: hardwareKey)

        // Send the physical USB key position instead of the character produced
        // by the current iPad input method. For example, a Zhuyin layout can
        // report "ㄅ" or an empty text value for the physical 1 key; forwarding
        // that string made the Mac discard the key after correctly switching
        // input sources. HID positions let the Mac's active IME create its own
        // marked text and candidate window exactly like a local keyboard.
        let hidUsage = hardwareKey.keyCode.rawValue
        if RemoteKeyboardInput.supportsRemoteHIDUsage(hidUsage) {
            return RemoteKeyboardInput.event(
                hidUsage: hidUsage,
                modifiers: modifiers
            )
        }

        // Leave unsupported keys such as the Globe/input-source key in UIKit's
        // responder chain. iPadOS changes its input mode, and the notification
        // handler above mirrors that language change to the Mac.
        return nil
    }

    private func remoteModifiers(for hardwareKey: UIKey) -> [String] {
        var modifiers: [String] = []
        if hardwareKey.modifierFlags.contains(.command) { modifiers.append("command") }
        if hardwareKey.modifierFlags.contains(.alternate) { modifiers.append("option") }
        if hardwareKey.modifierFlags.contains(.control) { modifiers.append("control") }
        if hardwareKey.modifierFlags.contains(.shift) { modifiers.append("shift") }
        return modifiers
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

        let directTouch = DirectTouchGestureRecognizer(
            target: self,
            action: #selector(handleDirectTouch(_:))
        )
        directTouch.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        directTouch.cancelsTouchesInView = false
        directTouch.delegate = self
        addGestureRecognizer(directTouch)

        let touchDoubleClick = UITapGestureRecognizer(target: self, action: #selector(handlePrimaryDoubleClick(_:)))
        touchDoubleClick.numberOfTapsRequired = 2
        touchDoubleClick.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.stylus.rawValue)]
        addGestureRecognizer(touchDoubleClick)

        let touchPrimaryClick = UITapGestureRecognizer(target: self, action: #selector(handlePrimaryClick(_:)))
        touchPrimaryClick.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.stylus.rawValue)]
        touchPrimaryClick.require(toFail: touchDoubleClick)
        addGestureRecognizer(touchPrimaryClick)

        let continuousScroll = RemoteScrollGestureRecognizer(
            target: self,
            action: #selector(handleScroll(_:))
        )
        continuousScroll.representsContinuousScroll = true
        continuousScroll.allowedTouchTypes = []
        continuousScroll.allowedScrollTypesMask = .continuous
        continuousScroll.cancelsTouchesInView = false
        continuousScroll.delegate = self
        addGestureRecognizer(continuousScroll)

        let discreteScroll = RemoteScrollGestureRecognizer(
            target: self,
            action: #selector(handleScroll(_:))
        )
        discreteScroll.representsContinuousScroll = false
        discreteScroll.allowedTouchTypes = []
        discreteScroll.allowedScrollTypesMask = .discrete
        discreteScroll.cancelsTouchesInView = false
        discreteScroll.delegate = self
        addGestureRecognizer(discreteScroll)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.cancelsTouchesInView = false
        pinch.delegate = self
        addGestureRecognizer(pinch)

        let touchScroll = RemoteScrollGestureRecognizer(target: self, action: #selector(handleScroll(_:)))
        touchScroll.representsContinuousScroll = true
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
        touchDrag.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.stylus.rawValue)]
        touchDrag.delegate = self
        addGestureRecognizer(touchDrag)

        let directTouchHold = RemoteHoldGestureRecognizer(
            target: self,
            action: #selector(handleTouchHold(_:))
        )
        directTouchHold.consumesDirectTouch = true
        directTouchHold.minimumPressDuration = 0.22
        directTouchHold.allowableMovement = 18
        directTouchHold.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        directTouchHold.cancelsTouchesInView = false
        directTouchHold.delegate = self
        addGestureRecognizer(directTouchHold)

        let stylusHold = RemoteHoldGestureRecognizer(
            target: self,
            action: #selector(handleTouchHold(_:))
        )
        stylusHold.minimumPressDuration = 0.22
        stylusHold.allowableMovement = 18
        stylusHold.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.stylus.rawValue)]
        stylusHold.cancelsTouchesInView = false
        stylusHold.delegate = self
        addGestureRecognizer(stylusHold)
        touchPrimaryClick.require(toFail: stylusHold)
        touchDoubleClick.require(toFail: stylusHold)
    }

    @objc private func handleHover(_ recognizer: UIHoverGestureRecognizer) {
        guard !isPrimaryDragging,
              recognizer.state == .began || recognizer.state == .changed else { return }
        sendPointer(at: recognizer.location(in: self))
    }

    @objc private func handleDirectTouch(_ recognizer: DirectTouchGestureRecognizer) {
        let location = recognizer.preciseLocation
        switch recognizer.state {
        case .began:
            directTouchStartLocation = location
            directTouchLastLocation = location
            directTouchStartedAt = ProcessInfo.processInfo.systemUptime
            directTouchMovedBeyondClickSlop = false
            directTouchConsumedByHold = false
            lastPointerTime = 0
        case .changed:
            if hypot(
                location.x - directTouchStartLocation.x,
                location.y - directTouchStartLocation.y
            ) > directTouchClickSlop {
                directTouchMovedBeyondClickSlop = true
                directTouchClickTracker.reset()
            }
            guard !isPrimaryDragging else {
                directTouchLastLocation = location
                return
            }
            sendRelativePointer(from: directTouchLastLocation, to: location)
            directTouchLastLocation = location
        case .ended:
            defer {
                directTouchConsumedByHold = false
                directTouchMovedBeyondClickSlop = false
            }
            guard !directTouchConsumedByHold else { return }
            if !directTouchMovedBeyondClickSlop {
                sendDirectTouchClick(at: location)
            }
        case .cancelled, .failed:
            directTouchClickTracker.reset()
            directTouchConsumedByHold = false
            directTouchMovedBeyondClickSlop = false
        default:
            break
        }
    }

    private func sendDirectTouchClick(at location: CGPoint) {
        reclaimKeyboardFocus()
        let now = ProcessInfo.processInfo.systemUptime
        let count = directTouchClickTracker.nextCount(
            x: Double(location.x),
            y: Double(location.y),
            at: now,
            interval: pointerDoubleClickInterval,
            maximumDistance: pointerDoubleClickDistance
        )
        directTouchClickTracker.complete(
            count: count,
            x: Double(location.x),
            y: Double(location.y),
            beganAt: directTouchStartedAt,
            endedAt: now,
            interval: pointerDoubleClickInterval,
            movedBeyondClickSlop: false
        )
        onInput(.primaryDownAtCurrentPointer(clickCount: count))
        onInput(.primaryUp(clickCount: count))
    }

    @objc private func handlePointerPress(_ recognizer: PointerPressGestureRecognizer) {
        let location = recognizer.preciseLocation
        switch recognizer.state {
        case .began:
            let capturedMask = recognizer.reportedButtonMask.isEmpty
                ? recognizer.buttonMask
                : recognizer.reportedButtonMask
            guard let reportedButton = reportedButton(for: capturedMask) else { return }
            reclaimKeyboardFocus()
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
            activePointerStartLocation = location
            activePointerStartedAt = ProcessInfo.processInfo.systemUptime
            activePointerExceededClickSlop = false
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
            guard let activePointerButton,
                  let point = normalizedPoint(location) else { return }
            activePointerLastPoint = point
            if hypot(
                location.x - activePointerStartLocation.x,
                location.y - activePointerStartLocation.y
            ) > pointerClickSlop {
                activePointerExceededClickSlop = true
                resetClickHistory(for: activePointerButton)
            }
            guard activePointerButton == .primary, isPrimaryDragging else { return }
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
                completePointerPress(for: .primary, at: location)
                finishPrimaryDrag(at: point)
            } else if activePointerButton == .secondary,
                      !activePointerExceededClickSlop,
                      let point {
                completePointerPress(for: .secondary, at: location)
                if activePrimaryClickCount >= 2 {
                    onInput(.doubleClick(secondary: true, x: point.x, y: point.y))
                } else {
                    onInput(.click(secondary: true, x: point.x, y: point.y))
                }
            }
            activePointerButton = nil
            activePointerLastPoint = nil
            activePrimaryClickCount = 1
            activePointerExceededClickSlop = false
        case .cancelled, .failed:
            if let activePointerButton {
                resetClickHistory(for: activePointerButton)
            }
            if activePointerButton == .primary {
                finishPrimaryDrag(at: activePointerLastPoint)
            }
            pointerPressConsumedByCalibration = false
            activePointerButton = nil
            activePointerLastPoint = nil
            activePrimaryClickCount = 1
            activePointerExceededClickSlop = false
        default:
            break
        }
    }

    private func reportedButton(for mask: UIEvent.ButtonMask) -> RemotePointerButton? {
        let hasPrimary = mask.contains(.primary)
        let hasSecondary = mask.contains(.secondary)
        guard hasPrimary != hasSecondary else { return nil }
        return hasPrimary ? .primary : .secondary
    }

    private func nextPointerClickCount(
        for button: RemotePointerButton,
        at location: CGPoint
    ) -> Int {
        let now = ProcessInfo.processInfo.systemUptime
        let tracker = button == .primary ? primaryClickTracker : secondaryClickTracker
        return tracker.nextCount(
            x: Double(location.x),
            y: Double(location.y),
            at: now,
            interval: pointerDoubleClickInterval,
            maximumDistance: pointerDoubleClickDistance
        )
    }

    private func completePointerPress(for button: RemotePointerButton, at location: CGPoint) {
        let now = ProcessInfo.processInfo.systemUptime
        if button == .primary {
            primaryClickTracker.complete(
                count: activePrimaryClickCount,
                x: Double(location.x),
                y: Double(location.y),
                beganAt: activePointerStartedAt,
                endedAt: now,
                interval: pointerDoubleClickInterval,
                movedBeyondClickSlop: activePointerExceededClickSlop
            )
        } else {
            secondaryClickTracker.complete(
                count: activePrimaryClickCount,
                x: Double(location.x),
                y: Double(location.y),
                beganAt: activePointerStartedAt,
                endedAt: now,
                interval: pointerDoubleClickInterval,
                movedBeyondClickSlop: activePointerExceededClickSlop
            )
        }
    }

    private func resetClickHistory(for button: RemotePointerButton) {
        if button == .primary {
            primaryClickTracker.reset()
        } else {
            secondaryClickTracker.reset()
        }
    }

    @objc private func handleTouchHold(_ recognizer: UILongPressGestureRecognizer) {
        let point = recognizer.location(in: self)
        switch recognizer.state {
        case .began:
            guard !isPrimaryDragging else { return }
            reclaimKeyboardFocus()
            if (recognizer as? RemoteHoldGestureRecognizer)?.consumesDirectTouch == true {
                directTouchConsumedByHold = true
                directTouchClickTracker.reset()
            }
            activePrimaryClickCount = 1
            isPrimaryDragging = true
            lastPointerTime = 0
            directTouchHoldLastLocation = point
            onInput(.primaryDownAtCurrentPointer())
        case .changed:
            guard isPrimaryDragging else { return }
            sendRelativePointer(from: directTouchHoldLastLocation, to: point)
            directTouchHoldLastLocation = point
        case .ended, .cancelled, .failed:
            finishPrimaryDrag(at: nil)
        default:
            break
        }
    }

    @objc private func handlePrimaryDrag(_ recognizer: UIPanGestureRecognizer) {
        let point = recognizer.location(in: self)
        switch recognizer.state {
        case .began:
            guard let normalized = normalizedPoint(point) else { return }
            reclaimKeyboardFocus()
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
        hardwareKeyRepeatTasks.values.forEach { $0.cancel() }
        hardwareKeyRepeatTasks.removeAll(keepingCapacity: true)
        finishPrimaryDrag(at: nil)
        onInput(.releaseButtons())
    }

    private func sendPointer(at point: CGPoint, force: Bool = false) {
        guard let normalized = normalizedPoint(point) else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now - lastPointerTime >= pointerEmissionInterval else { return }
        lastPointerTime = now
        onInput(.pointer(x: normalized.x, y: normalized.y))
    }

    private func sendRelativePointer(from previous: CGPoint, to current: CGPoint, force: Bool = false) {
        guard let delta = normalizedDelta(from: previous, to: current) else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now - lastPointerTime >= pointerEmissionInterval else { return }
        lastPointerTime = now
        guard delta != .zero else { return }
        onInput(.pointerDelta(x: delta.x, y: delta.y))
    }

    @objc private func handlePrimaryClick(_ recognizer: UITapGestureRecognizer) {
        reclaimKeyboardFocus()
        guard let point = normalizedPoint(recognizer.location(in: self)) else { return }
        onInput(.click(x: point.x, y: point.y))
    }

    @objc private func handlePrimaryDoubleClick(_ recognizer: UITapGestureRecognizer) {
        reclaimKeyboardFocus()
        guard let point = normalizedPoint(recognizer.location(in: self)) else { return }
        onInput(.doubleClick(x: point.x, y: point.y))
    }

    @objc private func handleScroll(_ recognizer: UIPanGestureRecognizer) {
        let continuous = (recognizer as? RemoteScrollGestureRecognizer)?
            .representsContinuousScroll ?? true
        let delta = recognizer.translation(in: self)
        recognizer.setTranslation(.zero, in: self)
        let phase: RemoteScrollPhase?
        if continuous {
            switch recognizer.state {
            case .began: phase = .began
            case .changed: phase = .changed
            case .ended: phase = .ended
            case .cancelled, .failed: phase = .cancelled
            default: phase = nil
            }
        } else {
            phase = nil
        }
        guard delta != .zero || phase != nil else { return }
        onInput(.scroll(
            x: delta.x,
            y: delta.y,
            phase: phase,
            continuous: continuous
        ))
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
        if gestureRecognizer is DirectTouchGestureRecognizer ||
            otherGestureRecognizer is DirectTouchGestureRecognizer {
            return true
        }
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

    private func normalizedDelta(from previous: CGPoint, to current: CGPoint) -> CGPoint? {
        guard bounds.width > 0, bounds.height > 0, contentAspectRatio > 0 else { return nil }
        let viewAspect = bounds.width / bounds.height
        let contentSize: CGSize
        if viewAspect > contentAspectRatio {
            contentSize = CGSize(width: bounds.height * contentAspectRatio, height: bounds.height)
        } else {
            contentSize = CGSize(width: bounds.width, height: bounds.width / contentAspectRatio)
        }
        let scale = max(zoomScale, 1)
        return CGPoint(
            x: (current.x - previous.x) / max(contentSize.width * scale, 1),
            y: (current.y - previous.y) / max(contentSize.height * scale, 1)
        )
    }
}
