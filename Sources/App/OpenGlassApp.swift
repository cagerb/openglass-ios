import SwiftUI
import SwiftData

@main
struct OpenGlassApp: App {
    @State private var controller = GlassesController()
    @State private var glassesState = GlassesState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(controller)
                .environment(glassesState)
                .task {
                    await controller.checkIdentity()
                }
        }
        .modelContainer(for: [CaptureRecord.self])
    }
}
