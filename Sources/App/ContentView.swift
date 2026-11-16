import SwiftUI

struct ContentView: View {
    @Environment(BluetoothManager.self) private var bluetooth
    @Environment(GlassesState.self) private var glassesState

    var body: some View {
        TabView {
            DashboardView()
                .tabItem {
                    Label("Dashboard", systemImage: "gauge.medium")
                }

            GalleryView()
                .tabItem {
                    Label("Gallery", systemImage: "photo.on.rectangle.angled")
                }

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
        }
        .tint(.blue)
    }
}
