import SwiftUI

final class MacAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MacShutdownCoordinator.shared.startObserving()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MacShutdownCoordinator.shared.applicationShouldTerminate(sender)
    }

    func applicationWillTerminate(_ notification: Notification) {
        MacShutdownCoordinator.shared.applicationWillTerminate()
    }
}

@main
struct SidecarBridgeMacApp: App {
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var appDelegate
    @StateObject private var model = MacConnectionModel()

    var body: some Scene {
        WindowGroup {
            MacContentView(model: model)
                .frame(minWidth: 760, minHeight: 680)
                .task {
                    MacShutdownCoordinator.shared.attach(model)
                    model.start()
                    if ProcessInfo.processInfo.arguments.contains("--test-control-up") {
                        try? await Task.sleep(for: .seconds(1))
                        model.testControlShortcut("up")
                    }
                }
        }
        .windowResizability(.contentMinSize)

        MenuBarExtra("SidecarBridge", systemImage: "ipad.and.arrow.forward") {
            Button("Use In-App Display") { model.startFallback() }
            #if SIDECARBRIDGE_APP_STORE_SAFE
            Button("Open Display Settings") { model.openDisplaysSettings() }
            #else
            Button("Open System Sidecar") { model.trySidecarNow() }
            #endif
            Divider()
            Text(model.status)
            Button("Open SidecarBridge") {
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
    }
}
