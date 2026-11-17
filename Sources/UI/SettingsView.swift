import SwiftUI

struct SettingsView: View {
    @Environment(GlassesController.self) private var controller
    @Environment(GlassesState.self) private var glasses

    @AppStorage("claudeAPIKey") private var claudeAPIKey = ""
    @AppStorage("autoDownload") private var autoDownload = false
    @AppStorage("autoExportToPhotos") private var autoExportToPhotos = false
    @AppStorage("downloadQuality") private var downloadQuality = "original"

    @State private var showDeleteIdentityConfirmation = false
    @State private var showExtractionGuide = false
    @State private var showImportSheet = false
    @State private var importKeyHex = ""
    @State private var importTicketHex = ""
    @State private var importError: String?

    var body: some View {
        NavigationStack {
            Form {
                identitySection
                claudeSection
                mediaSection

                if controller.isConnected {
                    connectionSection
                }

                aboutSection
            }
            .navigationTitle("Settings")
            .alert("Delete Identity", isPresented: $showDeleteIdentityConfirmation) {
                Button("Delete", role: .destructive) {
                    Task { await controller.deleteIdentity() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will remove the RSA key pair and bootstrap ticket from the keychain. You'll need to extract them again from the Meta AI app.")
            }
            .sheet(isPresented: $showExtractionGuide) {
                extractionGuideSheet
            }
            .sheet(isPresented: $showImportSheet) {
                importIdentitySheet
            }
        }
    }

    // MARK: - Identity

    private var identitySection: some View {
        Section {
            HStack {
                Image(systemName: controller.hasIdentity ? "key.fill" : "key.slash")
                    .foregroundStyle(controller.hasIdentity ? .green : .orange)
                Text("Pairing Identity")
                Spacer()
                Text(controller.hasIdentity ? "Imported" : "Missing")
                    .foregroundStyle(controller.hasIdentity ? .green : .orange)
            }

            if controller.hasIdentity {
                Button(role: .destructive) {
                    showDeleteIdentityConfirmation = true
                } label: {
                    Label("Delete Identity", systemImage: "trash")
                }
            } else {
                Button {
                    showImportSheet = true
                } label: {
                    Label("Import Identity", systemImage: "square.and.arrow.down")
                }

                Button {
                    showExtractionGuide = true
                } label: {
                    Label("How to Extract Identity", systemImage: "questionmark.circle")
                }
            }
        } header: {
            Text("Glasses Identity")
        } footer: {
            Text("The RSA key and bootstrap ticket are extracted once from the Meta AI app during initial pairing, then stored locally. After extraction, the Meta AI app can be deleted.")
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
        Section("Connection") {
            HStack {
                Text("Status")
                Spacer()
                Text(controller.state.rawValue.capitalized)
                    .foregroundStyle(.secondary)
            }

            Button(role: .destructive) {
                controller.disconnect()
            } label: {
                Label("Disconnect", systemImage: "wifi.slash")
            }
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        Section("About") {
            HStack {
                Text("Version")
                Spacer()
                Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.3.0")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text("Build")
                Spacer()
                Text(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "3")
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

    // MARK: - Import identity sheet

    private var importIdentitySheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("RSA Private Key (hex)", text: $importKeyHex, axis: .vertical)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(4...8)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)

                    TextField("Bootstrap Ticket (hex)", text: $importTicketHex, axis: .vertical)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(2...4)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("Paste Extracted Data")
                } footer: {
                    Text("Paste the hex-encoded RSA private key and bootstrap ticket from the Frida extraction script.")
                }

                if let error = importError {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }

                Section {
                    Button("Import") {
                        Task { await performImport() }
                    }
                    .disabled(importKeyHex.isEmpty || importTicketHex.isEmpty)
                }
            }
            .navigationTitle("Import Identity")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        showImportSheet = false
                    }
                }
            }
        }
    }

    private func performImport() async {
        importError = nil
        guard let keyData = Data(hexString: importKeyHex.trimmingCharacters(in: .whitespacesAndNewlines)),
              let ticketData = Data(hexString: importTicketHex.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            importError = "Invalid hex format. Paste the raw hex output from the extraction script."
            return
        }
        do {
            try await controller.importIdentity(rsaKeyData: keyData, bootstrapTicket: ticketData)
            showImportSheet = false
        } catch {
            importError = error.localizedDescription
        }
    }

    // MARK: - Extraction guide sheet

    private var extractionGuideSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("One-Time Key Extraction")
                        .font(.title2)
                        .fontWeight(.bold)

                    Text("OpenGlass needs your glasses' RSA private key and bootstrap ticket to authenticate independently. These are extracted once from the Meta AI app, then the app can be deleted forever.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    guideStep(1, title: "Install the Meta AI app", detail: "Pair your glasses normally through the Meta AI app if you haven't already.")

                    guideStep(2, title: "Get the decrypted IPA", detail: "Use a tool like bagbak, frida-ios-dump, or CrackerXI+ to get a FairPlay-decrypted copy of the Meta AI .ipa file.")

                    guideStep(3, title: "Inject Frida gadget", detail: "Unzip the IPA, copy FridaGadget.dylib into the Frameworks folder, add a load command with insert_dylib or optool, then re-sign with your dev certificate.")

                    guideStep(4, title: "Sideload the patched IPA", detail: "Install via AltStore or Sideloadly. Open the patched Meta AI app — Frida will start listening.")

                    guideStep(5, title: "Run the extraction script", detail: "Connect from your Mac:\n\nfrida -U \"Meta AI\" -l extract_keys.js\n\nThe script hooks SecItemAdd to intercept the RSA private key and bootstrap ticket during the next pairing handshake.")

                    guideStep(6, title: "Trigger a re-pair", detail: "In the patched Meta AI app, unpair and re-pair your glasses. The Frida script will print the hex-encoded key and ticket to your terminal.")

                    guideStep(7, title: "Import into OpenGlass", detail: "Copy the hex values and paste them into Settings > Import Identity in OpenGlass. Done — delete the Meta AI app.")

                    Text("The extraction script (extract_keys.js) is included in the OpenGlass GitHub repo under tools/.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                }
                .padding()
            }
            .navigationTitle("Extraction Guide")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        showExtractionGuide = false
                    }
                }
            }
        }
    }

    private func guideStep(_ number: Int, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.caption)
                .fontWeight(.bold)
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(.blue, in: Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Hex decoding

extension Data {
    init?(hexString: String) {
        let cleaned = hexString.replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\n", with: "")
        guard cleaned.count.isMultiple(of: 2) else { return nil }

        var data = Data(capacity: cleaned.count / 2)
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let nextIndex = cleaned.index(index, offsetBy: 2)
            guard let byte = UInt8(cleaned[index..<nextIndex], radix: 16) else { return nil }
            data.append(byte)
            index = nextIndex
        }
        self = data
    }
}
