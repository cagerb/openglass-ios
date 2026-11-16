import SwiftUI

struct SettingsView: View {
    @Environment(WearablesManager.self) private var wearables
    @Environment(GlassesState.self) private var glasses

    @AppStorage("claudeAPIKey") private var claudeAPIKey = ""
    @AppStorage("autoDownload") private var autoDownload = false
    @AppStorage("autoExportToPhotos") private var autoExportToPhotos = false
    @AppStorage("downloadQuality") private var downloadQuality = "original"

    @State private var showUnregisterConfirmation = false

    var body: some View {
        NavigationStack {
            Form {
                registrationSection
                claudeSection
                mediaSection

                if wearables.isConnected {
                    connectionSection
                }

                aboutSection
            }
            .navigationTitle("Settings")
            .alert("Unregister", isPresented: $showUnregisterConfirmation) {
                Button("Unregister", role: .destructive) {
                    wearables.unregister()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will disconnect from your glasses and remove the registration. You'll need to register again through the Meta AI app.")
            }
        }
    }

    // MARK: - Registration

    private var registrationSection: some View {
        Section {
            HStack {
                Image(systemName: registrationIcon)
                    .foregroundStyle(registrationColor)
                Text("Registration")
                Spacer()
                Text(registrationStatus)
                    .foregroundStyle(registrationColor)
            }

            switch wearables.connectionState {
            case .unregistered, .error:
                Button {
                    wearables.register()
                } label: {
                    Label("Register with Glasses", systemImage: "link")
                }

            case .registering:
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text("Complete setup in the Meta AI app...")
                        .foregroundStyle(.secondary)
                }

            default:
                Button(role: .destructive) {
                    showUnregisterConfirmation = true
                } label: {
                    Label("Unregister", systemImage: "link.badge.plus")
                }
            }
        } header: {
            Text("Glasses Connection")
        } footer: {
            Text("Registration links OpenGlass to your glasses through the Meta AI app. This is a one-time setup. Developer Mode must be enabled in the Meta AI app settings.")
        }
    }

    // MARK: - Claude AI

    private var claudeSection: some View {
        Section {
            SecureField("API Key", text: $claudeAPIKey)
                .textContentType(.password)
                .autocorrectionDisabled()
        } header: {
            Text("Claude AI")
        } footer: {
            Text("Optional. Add a Claude API key to enable AI-powered voice commands through your glasses.")
        }
    }

    // MARK: - Media

    private var mediaSection: some View {
        Section {
            Toggle("Auto-Download New Captures", isOn: $autoDownload)
            Toggle("Auto-Export to Photos", isOn: $autoExportToPhotos)

            Picker("Download Quality", selection: $downloadQuality) {
                Text("Original").tag("original")
                Text("High (compressed)").tag("high")
                Text("Medium").tag("medium")
            }
        } header: {
            Text("Media")
        }
    }

    // MARK: - Connected device

    private var connectionSection: some View {
        Section("Session") {
            HStack {
                Text("Status")
                Spacer()
                Text(wearables.connectionState.rawValue.capitalized)
                    .foregroundStyle(.secondary)
            }

            if wearables.isCameraPermissionGranted {
                HStack {
                    Text("Camera Permission")
                    Spacer()
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }

            Button(role: .destructive) {
                wearables.stopSession()
            } label: {
                Label("End Session", systemImage: "wifi.slash")
            }
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        Section("About") {
            HStack {
                Text("Version")
                Spacer()
                Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.2.0")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text("Build")
                Spacer()
                Text(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "2")
                    .foregroundStyle(.secondary)
            }

            Link(destination: URL(string: "https://github.com/cagerb/openglass-ios")!) {
                Label("Source Code", systemImage: "chevron.left.forwardslash.chevron.right")
            }
            Link(destination: URL(string: "https://github.com/cagerb/openglass-ios/issues")!) {
                Label("Report an Issue", systemImage: "exclamationmark.bubble")
            }
        }
    }

    // MARK: - Helpers

    private var registrationIcon: String {
        switch wearables.connectionState {
        case .unregistered, .error: return "person.badge.key"
        case .registering: return "arrow.triangle.2.circlepath"
        default: return "checkmark.seal.fill"
        }
    }

    private var registrationColor: Color {
        switch wearables.connectionState {
        case .unregistered, .error: return .secondary
        case .registering: return .orange
        default: return .green
        }
    }

    private var registrationStatus: String {
        switch wearables.connectionState {
        case .unregistered, .error: return "Not Registered"
        case .registering: return "Registering..."
        default: return "Registered"
        }
    }
}
