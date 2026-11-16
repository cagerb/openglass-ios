import SwiftUI

struct ContentView: View {
    @Environment(WearablesManager.self) private var wearables
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
