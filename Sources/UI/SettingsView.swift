import SwiftUI

struct SettingsView: View {
    @Environment(BluetoothManager.self) private var bluetooth
    @Environment(GlassesState.self) private var glasses

    @AppStorage("claudeAPIKey") private var claudeAPIKey = ""
    @AppStorage("autoDownload") private var autoDownload = false
    @AppStorage("autoExportToPhotos") private var autoExportToPhotos = false
    @AppStorage("downloadQuality") private var downloadQuality = "original"

    @State private var showIdentityImport = false
    @State private var showResetConfirmation = false
    @State private var identityImportText = ""

    private let identityStore = IdentityStore()

    var body: some View {
        NavigationStack {
            Form {
                // Identity section
                Section {
                    HStack {
                        Image(systemName: "person.badge.key")
                            .foregroundStyle(.blue)
                        Text("Identity Status")
                        Spacer()
                        Text(hasIdentity ? "Configured" : "Not Set")
                            .foregroundStyle(hasIdentity ? .green : .secondary)
                    }

                    Button {
                        showIdentityImport = true
                    } label: {
                        Label("Import Identity", systemImage: "square.and.arrow.down")
                    }

                    Button(role: .destructive) {
                        showResetConfirmation = true
                    } label: {
                        Label("Reset Identity", systemImage: "trash")
                    }
                } header: {
                    Text("Identity & Authentication")
                } footer: {
                    Text("Your identity includes the RSA key pair and bootstrap ticket needed to authenticate with your glasses. Import from an existing paired device or set up a new pairing.")
                }

                // Claude AI section
                Section {
                    SecureField("API Key", text: $claudeAPIKey)
                        .textContentType(.password)
                        .autocorrectionDisabled()
                } header: {
                    Text("Claude AI")
                } footer: {
                    Text("Optional. Add a Claude API key to enable AI-powered voice commands through your glasses.")
                }

                // Media section
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

                // Connection info section
                if bluetooth.connectionState == .connected ||
                   bluetooth.connectionState == .authenticated {
                    Section("Connected Device") {
                        if let model = bluetooth.modelNumber {
                            infoRow("Model", value: model)
                        }
                        if let serial = bluetooth.serialNumber {
                            infoRow("Serial", value: serial)
                        }
                        if let firmware = bluetooth.firmwareRevision {
                            infoRow("Firmware", value: firmware)
                        }

                        Button(role: .destructive) {
                            bluetooth.disconnect()
                        } label: {
                            Label("Disconnect", systemImage: "wifi.slash")
                        }
                    }
                }

                // About section
                Section("About") {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0")
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Build")
                        Spacer()
                        Text(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1")
                            .foregroundStyle(.secondary)
                    }

                    Link(destination: URL(string: "https://github.com/niccolofanton/open-glass")!) {
                        Label("Source Code", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                    Link(destination: URL(string: "https://github.com/niccolofanton/open-glass/issues")!) {
                        Label("Report an Issue", systemImage: "exclamationmark.bubble")
                    }
                }
            }
            .navigationTitle("Settings")
            .sheet(isPresented: $showIdentityImport) {
                identityImportSheet
            }
            .alert("Reset Identity", isPresented: $showResetConfirmation) {
                Button("Reset", role: .destructive) {
                    Task {
                        await identityStore.deleteAll()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will delete your RSA key pair and all authentication tickets. You will need to re-pair with your glasses.")
            }
        }
    }

    // MARK: - Identity import sheet

    private var identityImportSheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $identityImportText)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 200)
                } header: {
                    Text("Bootstrap Ticket")
                } footer: {
                    Text("Paste the base64-encoded bootstrap ticket from your existing paired device or from the OpenGlass web tool.")
                }
            }
            .navigationTitle("Import Identity")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        showIdentityImport = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") {
                        importIdentity()
                    }
                    .disabled(identityImportText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    // MARK: - Helpers

    private var hasIdentity: Bool {
        // Synchronous check — in production this would be cached
        // from an async check at view appear
        true // Placeholder; real check: await identityStore.hasRSAKeyPair()
    }

    private func infoRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private func importIdentity() {
        let trimmed = identityImportText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let ticketData = Data(base64Encoded: trimmed) else { return }

        Task {
            do {
                try await identityStore.saveBootstrapTicket(ticketData)
                // Also generate a new RSA key pair if we don't have one
                if await !identityStore.hasRSAKeyPair() {
                    let rsa = RSAAuth()
                    let (priv, pub) = try await rsa.generateKeyPair()
                    try await identityStore.saveRSAPrivateKey(priv)
                    let pubData = try await rsa.exportPublicKey(pub)
                    try await identityStore.saveRSAPublicKeyData(pubData)
                }
                showIdentityImport = false
            } catch {
                // Handle error
            }
        }
    }
}
