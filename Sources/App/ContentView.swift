import SwiftUI

struct ContentView: View {
    @Environment(GlassesController.self) private var controller
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

            StressTesterView()
                .tabItem {
                    Label("Tester", systemImage: "bolt.shield")
                }

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
        }
        .tint(.blue)
    }
}
