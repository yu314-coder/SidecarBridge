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

        MenuBarExtra {
            Text("SidecarBridge")
                .font(.headline)
            Label(model.menuBarStatusText, systemImage: model.menuBarStatusIcon)
                .font(.caption)
            if model.hasPadPeer, let latency = model.connectionLatencyMS {
                Text("Encrypted link • \(latency) ms")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Divider()

            Button(model.isStreaming ? "Stop In-App Display" : "Start In-App Display") {
                if model.isStreaming {
                    model.stopFallback()
                } else {
                    model.startFallback()
                }
            }
            .keyboardShortcut("s", modifiers: [.command, .option])

            Button("Send Files…") { model.chooseFileToSend() }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(!model.hasPadPeer)
            Button("Open Transfers Folder") { model.openTransferFolder() }
                .keyboardShortcut("f", modifiers: [.command, .option])

            Menu("Input shortcuts") {
                #if SIDECARBRIDGE_APP_STORE_SAFE
                Text("Available in the direct companion build")
                #else
                Button("Control–↑") { model.testControlShortcut("up") }
                Button("Control–↓") { model.testControlShortcut("down") }
                Button("Control–←") { model.testControlShortcut("left") }
                Button("Control–→") { model.testControlShortcut("right") }
                Divider()
                Button("Option–click") { model.testModifierClick(["option"]) }
                Button("Shift–click") { model.testModifierClick(["shift"]) }
                Button("Option–Shift–click") { model.testModifierClick(["option", "shift"]) }
                #endif
            }

            Divider()

            Button("Open SidecarBridge") {
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
            .keyboardShortcut("o", modifiers: [.command])
            Button("Open Displays Settings") { model.openDisplaysSettings() }
            Button("Copy Diagnostic Report") { model.copyDiagnosticReport() }
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q", modifiers: [.command])
        } label: {
            Label("SidecarBridge", systemImage: model.menuBarStatusIcon)
        }
        .menuBarExtraStyle(.menu)
    }
}
