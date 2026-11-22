import SwiftUI

@main
struct ZydroTrackSyncApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                // Fase (c): se sincroniza al abrir, al volver a primer plano y, mientras está
                // abierta, cuando vence el siguiente reintento. La fase (d) añade
                // HKObserverQuery + BGTaskScheduler para hacerlo con la app cerrada.
                .onChange(of: scenePhase, initial: true) { _, phase in
                    model.setActive(phase == .active)
                }
        }
    }
}
