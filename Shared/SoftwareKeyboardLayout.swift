import Foundation

/// Local-only diagnostic sink. Never sends input or reads the clipboard.
struct KeyboardDiagnosticState {
    private(set) var text = ""
    private(set) var events: [String] = []
    private(set) var keyCount = 0

    mutating func record(_ key: String, modifiers: Set<String> = []) {
        keyCount += 1
        events.insert((modifiers.sorted() + [key]).joined(separator: " + "), at: 0)
        events = Array(events.prefix(20))
        guard modifiers.isDisjoint(with: ["command", "control", "option"]) else { return }
        switch key {
        case "delete": if !text.isEmpty { text.removeLast() }
        case "space": text += " "
        case "return": text += "\n"
        case "tab": text += "\t"
        default:
            if key.count == 1 {
                text += SoftwareKeyboardLayout.title(for: key, shift: modifiers.contains("shift"))
            }
        }
        text = String(text.suffix(5_000))
    }
}

enum SoftwareKeyboardLayout {
    static func panelSize(in available: CGSize) -> CGSize {
        CGSize(width: max(0, available.width - 24),
               height: min(available.width < 600 ? 336 : 400, max(0, available.height * 0.5)))
    }
    static let letters = ["1234567890", "qwertyuiop", "asdfghjkl", "zxcvbnm"]
    static let punctuation = ["1234567890", "-=[]\\;'/", ",.`"]
    static let shifted: [String: String] = [
        "1": "!", "2": "@", "3": "#", "4": "$", "5": "%", "6": "^",
        "7": "&", "8": "*", "9": "(", "0": ")", "-": "_", "=": "+",
        "[": "{", "]": "}", "\\": "|", ";": ":", "'": "\"", "/": "?",
        ",": "<", ".": ">", "`": "~"
    ]

    static func title(for key: String, shift: Bool) -> String {
        shift ? (shifted[key] ?? key.uppercased()) : key
    }

    static func usesSystemInputView(customKeyboardVisible: Bool, hardwareKeyboard: Bool) -> Bool {
        !customKeyboardVisible && hardwareKeyboard
    }
}
