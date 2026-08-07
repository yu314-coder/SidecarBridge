import Foundation

enum ShutdownProtectionDecision: Equatable {
    case hold
    case finishTermination
    case cancelTermination
}

struct ShutdownProtectionPolicy {
    static let maximumHoldDuration: TimeInterval = 105

    static func shouldEngage(
        isSystemTermination: Bool,
        isEnabled: Bool,
        hasRemoteSession: Bool,
        blockingApplicationCount: Int
    ) -> Bool {
        isSystemTermination
            && isEnabled
            && hasRemoteSession
            && blockingApplicationCount > 0
    }

    static func decisionWhileEngaged(
        hasRemoteSession: Bool,
        blockingApplicationCount: Int,
        elapsed: TimeInterval
    ) -> ShutdownProtectionDecision {
        if blockingApplicationCount == 0 {
            return .finishTermination
        }
        if !hasRemoteSession || elapsed >= maximumHoldDuration {
            return .cancelTermination
        }
        return .hold
    }
}
