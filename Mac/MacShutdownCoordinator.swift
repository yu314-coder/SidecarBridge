import AppKit
import Foundation

@MainActor
final class MacShutdownCoordinator {
    static let shared = MacShutdownCoordinator()

    private weak var model: MacConnectionModel?
    private var receivedSystemTerminationNotice = false
    private var isHoldingTermination = false
    private var holdStartedAt: Date?
    private var pollTimer: Timer?
    private var workspaceObserver: NSObjectProtocol?
    private var systemNoticeGeneration = UUID()

    private init() {}

    func startObserving() {
        guard workspaceObserver == nil else { return }
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willPowerOffNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let generation = UUID()
                self.systemNoticeGeneration = generation
                self.receivedSystemTerminationNotice = true
                try? await Task.sleep(for: .seconds(120))
                guard self.systemNoticeGeneration == generation,
                      !self.isHoldingTermination else {
                    return
                }
                self.receivedSystemTerminationNotice = false
            }
        }
    }

    func attach(_ model: MacConnectionModel) {
        self.model = model
        startObserving()
    }

    func applicationShouldTerminate(_ application: NSApplication) -> NSApplication.TerminateReply {
        let blockers = blockingApplicationNames()
        guard ShutdownProtectionPolicy.shouldEngage(
            isSystemTermination: receivedSystemTerminationNotice,
            isEnabled: model?.shutdownProtectionEnabled == true,
            hasRemoteSession: model?.hasPadPeer == true,
            blockingApplicationCount: blockers.count
        ) else {
            model?.prepareForTermination()
            return .terminateNow
        }

        guard !isHoldingTermination else { return .terminateLater }
        isHoldingTermination = true
        holdStartedAt = Date()
        model?.updateShutdownProtection(active: true, blockingApplications: blockers)

        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self, weak application] _ in
            guard let application else { return }
            Task { @MainActor in
                self?.evaluatePendingTermination(application)
            }
        }
        pollTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        return .terminateLater
    }

    func applicationWillTerminate() {
        pollTimer?.invalidate()
        pollTimer = nil
        model?.prepareForTermination()
    }

    private func evaluatePendingTermination(_ application: NSApplication) {
        guard isHoldingTermination, let holdStartedAt else { return }
        let blockers = blockingApplicationNames()
        let decision = ShutdownProtectionPolicy.decisionWhileEngaged(
            hasRemoteSession: model?.hasPadPeer == true,
            blockingApplicationCount: blockers.count,
            elapsed: Date().timeIntervalSince(holdStartedAt)
        )

        switch decision {
        case .hold:
            model?.updateShutdownProtection(active: true, blockingApplications: blockers)
        case .finishTermination:
            finishHolding()
            model?.prepareForTermination()
            application.reply(toApplicationShouldTerminate: true)
        case .cancelTermination:
            let reason: String
            if model?.hasPadPeer != true {
                reason = "Shutdown was stopped because the remote-control connection was lost."
            } else {
                reason = "Shutdown was stopped because another app still needs attention."
            }
            finishHolding()
            receivedSystemTerminationNotice = false
            model?.cancelShutdownProtection(reason: reason)
            application.reply(toApplicationShouldTerminate: false)
        }
    }

    private func finishHolding() {
        pollTimer?.invalidate()
        pollTimer = nil
        holdStartedAt = nil
        isHoldingTermination = false
    }

    private func blockingApplicationNames() -> [String] {
        let ownProcessIdentifier = ProcessInfo.processInfo.processIdentifier
        let excludedBundleIdentifiers: Set<String> = [
            "com.apple.finder",
            "com.apple.loginwindow"
        ]

        return Array(Set(
            NSWorkspace.shared.runningApplications.compactMap { application in
                guard application.processIdentifier != ownProcessIdentifier,
                      !application.isTerminated,
                      application.activationPolicy == .regular,
                      !excludedBundleIdentifiers.contains(application.bundleIdentifier ?? "")
                else {
                    return nil
                }
                return application.localizedName
                    ?? application.bundleIdentifier
                    ?? "Another app"
            }
        )).sorted()
    }
}
