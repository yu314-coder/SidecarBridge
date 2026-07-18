import SwiftUI

@main
struct SidecarBridgePadApp: App {
    @StateObject private var model = PadConnectionModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            PadContentView(model: model)
                .task { model.start() }
                .onChange(of: scenePhase) { _, phase in model.scenePhaseChanged(phase) }
        }
    }
}
