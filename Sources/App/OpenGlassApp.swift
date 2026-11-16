import SwiftUI
import SwiftData

@main
struct OpenGlassApp: App {
    @State private var bluetoothManager = BluetoothManager()
    @State private var glassesState = GlassesState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(bluetoothManager)
                .environment(glassesState)
        }
        .modelContainer(for: [CaptureRecord.self])
    }
}
