import Foundation

struct RemoteInputLanguageState {
    private(set) var observedLanguage: String?
    private var isWaitingForSwitchAnnouncement = false

    mutating func beginInputModeSwitch() {
        isWaitingForSwitchAnnouncement = true
    }

    mutating func resolve(
        announcedLanguage: String?,
        responderLanguage: String?
    ) -> String? {
        if let announcedLanguage {
            let normalized = RemoteKeyboardInput.normalizedLanguage(announcedLanguage)
            if !normalized.isEmpty {
                isWaitingForSwitchAnnouncement = false
                observedLanguage = normalized
                return normalized
            }
        }

        if isWaitingForSwitchAnnouncement {
            guard let responderLanguage else { return nil }
            let normalized = RemoteKeyboardInput.normalizedLanguage(responderLanguage)
            guard !normalized.isEmpty,
                  normalized != observedLanguage else { return nil }
            isWaitingForSwitchAnnouncement = false
            observedLanguage = normalized
            return normalized
        }

        // A hidden UIKit text responder can briefly continue reporting the
        // previous language after the hardware Globe key changes input mode.
        // Preserve the authoritative notification until another notification
        // announces a new language instead of reverting on the next key press.
        if let observedLanguage {
            return observedLanguage
        }

        guard let responderLanguage else { return nil }
        let normalized = RemoteKeyboardInput.normalizedLanguage(responderLanguage)
        guard !normalized.isEmpty else { return nil }
        observedLanguage = normalized
        return normalized
    }
}
