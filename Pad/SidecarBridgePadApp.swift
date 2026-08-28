import SwiftUI
import UIKit

@main
struct SidecarBridgePadApp: App {
    @StateObject private var model = PadConnectionModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            PadContentView(model: model)
                .task { model.start() }
                // ScenePhase normally delivers this transition, but the
                // will-resign-active notification arrives earlier on iPadOS.
                // Starting the PiP handoff at that point gives the system a
                // chance to preserve the encrypted session before the app is
                // suspended behind another app.
                .onReceive(
                    NotificationCenter.default.publisher(
                        for: UIApplication.willResignActiveNotification
                    )
                ) { _ in
                    model.appWillResignActive()
                }
                .onReceive(
                    NotificationCenter.default.publisher(
                        for: UIApplication.didEnterBackgroundNotification
                    )
                ) { _ in
                    model.appDidEnterBackground()
                }
                .onChange(of: scenePhase) { _, phase in model.scenePhaseChanged(phase) }
        }
    }
}
