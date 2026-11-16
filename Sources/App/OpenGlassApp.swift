import SwiftUI
import SwiftData

@main
struct OpenGlassApp: App {
    @State private var wearables = WearablesManager()
    @State private var glassesState = GlassesState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(wearables)
                .environment(glassesState)
                .onOpenURL { url in
                    _ = wearables.handleURL(url)
                }
                .task {
                    wearables.configure()
                }
        }
        .modelContainer(for: [CaptureRecord.self])
    }
}
