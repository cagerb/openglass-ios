import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct DashboardView: View {
    @Environment(GlassesController.self) private var controller
    @Environment(GlassesState.self) private var glasses
    @State private var showingOwnerKeyPicker = false
    @State private var ownerKeyError: String?
    @State private var showingFirmwarePicker = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    connectionCard

                    if !controller.hasIdentity && controller.state == .connected && !controller.bluetooth.isL2CAPMode {
                        identityWarning
                    }

                    if controller.state == .scanning && !controller.discoveredPeripherals.isEmpty {
                        discoveredDevicesCard
                    }

                    if controller.isConnected {
                        deviceInfoCard

                        if controller.bluetooth.isAirShieldSecure {
                            ownershipCard

                            if controller.trustPhase == .succeeded {
                                firmwareCard
                                mobileConfigCard
                            }

                            forgeryCard
                        }

                        batteryCard
                        storageCard
                    }

                    debugLogCard
                }
                .padding()
            }
            .navigationTitle("OpenGlass")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    ConnectionButton()
                }
            }
            .fileImporter(
                isPresented: $showingOwnerKeyPicker,
                allowedContentTypes: [.data],
                allowsMultipleSelection: false
            ) { result in
                Task {
                    do {
                        guard let url = try result.get().first else { return }
                        guard url.startAccessingSecurityScopedResource() else {
                            ownerKeyError = "Cannot access file"
                            return
                        }
                        defer { url.stopAccessingSecurityScopedResource() }
                        let data = try Data(contentsOf: url)
                        try await controller.importOwnerKey(from: data)
                        ownerKeyError = nil
                    } catch {
                        ownerKeyError = error.localizedDescription
                    }
                }
            }
            .fileImporter(
                isPresented: $showingFirmwarePicker,
                allowedContentTypes: [.data, .archive],
                allowsMultipleSelection: false
            ) { result in
                Task {
                    do {
                        guard let url = try result.get().first else { return }
                        guard url.startAccessingSecurityScopedResource() else { return }
                        defer { url.stopAccessingSecurityScopedResource() }
                        let data = try Data(contentsOf: url)
                        controller.startFirmwareUpdate(from: data)
                    } catch {
                        // File access error — firmware manager logs internally
                    }
                }
            }
        }
    }

    // MARK: - Connection card

    private var connectionCard: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: connectionIcon)
                    .font(.title2)
                    .foregroundStyle(connectionColor)
                    .symbolEffect(
                        .pulse,
                        isActive: controller.state == .scanning ||
                                  controller.state == .connecting ||
                                  controller.state == .authenticating
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(connectionLabel)
                        .font(.headline)
                    Text(connectionSubtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }

            switch controller.state {
            case .disconnected:
                Button {
                    controller.startScan()
                } label: {
                    Text("Scan for Glasses")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

            case .scanning:
                Button {
                    controller.stopScan()
                } label: {
                    Text("Stop Scanning")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

            case .connected:
                if controller.bluetooth.isAirShieldSecure {
                    Label("AirShield Secure", systemImage: "checkmark.shield.fill")
                        .font(.subheadline)
                        .foregroundStyle(.green)
                } else if controller.bluetooth.isL2CAPMode {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Setting up AirShield...")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Button {
                        Task { await controller.authenticate() }
                    } label: {
                        Text(controller.hasIdentity ? "Authenticate" : "Pair as New Device")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }

            default:
                EmptyView()
            }

            if let error = controller.lastError {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                .padding(.top, 4)

                Button("Dismiss") {
                    controller.clearError()
                }
                .font(.caption)
            }
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Identity warning

    private var identityWarning: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: "key.radiowaves.forward")
                    .foregroundStyle(.blue)
                Text("Fresh Pairing Mode")
                    .font(.headline)
            }

            Text("No existing identity found. Tapping 'Pair as New Device' will generate a fresh RSA key pair and attempt to pair with the glasses.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .background(.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Discovered devices

    private var discoveredDevicesCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Nearby Glasses")
                .font(.headline)
                .padding(.horizontal, 4)

            ForEach(controller.discoveredPeripherals, id: \.identifier) { peripheral in
                Button {
                    controller.connect(to: peripheral)
                } label: {
                    HStack {
                        Image(systemName: "eyeglasses")
                            .foregroundStyle(.blue)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(peripheral.name ?? "Unknown Device")
                                .font(.subheadline)
                                .fontWeight(.medium)
                            Text(peripheral.identifier.uuidString.prefix(8) + "...")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(12)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Device info card

    private var deviceInfoCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "info.circle")
                    .foregroundStyle(.blue)
                Text("Device")
                    .font(.headline)
                Spacer()
                if controller.state == .authenticated {
                    Label("Authenticated", systemImage: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }

            if let model = controller.bluetooth.modelNumber {
                infoRow("Model", value: model)
            }
            if let firmware = controller.bluetooth.firmwareRevision {
                infoRow("Firmware", value: firmware)
            }
            if let serial = controller.bluetooth.serialNumber {
                infoRow("Serial", value: serial)
            }
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private func infoRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.subheadline)
                .monospacedDigit()
        }
    }

    // MARK: - Battery card

    private var batteryCard: some View {
        HStack(spacing: 16) {
            Image(systemName: batteryIcon)
                .font(.system(size: 32))
                .foregroundStyle(batteryColor)

            VStack(alignment: .leading, spacing: 2) {
                Text("Battery")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let pct = controller.bluetooth.batteryLevel {
                    Text("\(pct)%")
                        .font(.title)
                        .fontWeight(.semibold)
                        .monospacedDigit()
                } else {
                    Text("--")
                        .font(.title)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Storage card

    private var storageCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "internaldrive")
                    .foregroundStyle(.blue)
                Text("Storage")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(glasses.storageDisplayString)
                    .font(.subheadline)
                    .monospacedDigit()
            }

            ProgressView(value: glasses.storageFraction)
                .tint(glasses.storageFraction > 0.9 ? .red : .blue)
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Ownership card

    private var ownershipCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "person.badge.key.fill")
                    .foregroundStyle(.green)
                Text("Owner Trust")
                    .font(.headline)
                Spacer()
                Text(controller.trustPhase.rawValue)
                    .font(.caption)
                    .foregroundStyle(trustPhaseColor)
            }

            if controller.hasOwnerKey {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Owner key loaded")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        if !controller.ownerSerial.isEmpty {
                            Text("Serial: \(controller.ownerSerial)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }

                switch controller.trustPhase {
                case .idle:
                    Text("Trust exchange starts automatically on next secure connection.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                case .succeeded:
                    HStack {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                            .font(.title2)
                        Text("OWNER VERIFIED — services unlocked")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundStyle(.green)
                    }

                case .failed:
                    HStack {
                        Image(systemName: "xmark.octagon.fill")
                            .foregroundStyle(.red)
                            .font(.title2)
                        VStack(alignment: .leading) {
                            Text("Trust exchange failed")
                                .font(.subheadline)
                                .fontWeight(.semibold)
                            if !controller.trustFailure.isEmpty {
                                Text(controller.trustFailure)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                default:
                    HStack(spacing: 8) {
                        ProgressView()
                        Text(controller.trustPhase.rawValue)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                Button(role: .destructive) {
                    Task { await controller.deleteOwnerKey() }
                } label: {
                    Label("Remove Owner Key", systemImage: "trash")
                        .font(.caption)
                }
            } else {
                Text("Import the owner key extracted from G-Link Direct to prove ownership and unlock all services.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button {
                    showingOwnerKeyPicker = true
                } label: {
                    Label("Import Owner Key", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
            }

            if let error = ownerKeyError {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private var trustPhaseColor: Color {
        switch controller.trustPhase {
        case .idle: return .secondary
        case .succeeded: return .green
        case .failed: return .red
        default: return .orange
        }
    }

    // MARK: - Firmware card

    private var firmwareCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "arrow.down.app.fill")
                    .foregroundStyle(.blue)
                Text("Firmware")
                    .font(.headline)
                Spacer()
                Text(controller.firmwarePhase.rawValue)
                    .font(.caption)
                    .foregroundStyle(firmwarePhaseColor)
            }

            switch controller.firmwarePhase {
            case .idle:
                Text("Push a firmware ZIP to the glasses over Airship. Use Meta's signed package for stock updates, or a custom image after disabling signature verification.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button {
                    showingFirmwarePicker = true
                } label: {
                    Label("Select Firmware ZIP", systemImage: "doc.zipper")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

            case .transferring:
                VStack(spacing: 8) {
                    ProgressView(value: controller.firmwareProgress)
                        .tint(.blue)
                    Text("\(Int(controller.firmwareProgress * 100))% transferred")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

            case .succeeded:
                HStack {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                        .font(.title2)
                    Text("Firmware installed")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(.green)
                }

            case .failed:
                HStack {
                    Image(systemName: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                    VStack(alignment: .leading) {
                        Text("Firmware update failed")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                        if !controller.firmwareFailure.isEmpty {
                            Text(controller.firmwareFailure)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

            default:
                HStack(spacing: 8) {
                    ProgressView()
                    Text(controller.firmwarePhase.rawValue)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private var firmwarePhaseColor: Color {
        switch controller.firmwarePhase {
        case .idle: return .secondary
        case .succeeded: return .green
        case .failed: return .red
        default: return .blue
        }
    }

    // MARK: - MobileConfig card

    private var mobileConfigCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "gearshape.2.fill")
                    .foregroundStyle(.orange)
                Text("MobileConfig")
                    .font(.headline)
                Spacer()
                Text(controller.mobileConfigPhase.rawValue)
                    .font(.caption)
                    .foregroundStyle(mobileConfigPhaseColor)
            }

            Text("Control the glasses' feature flags. Disabling signature verification allows sideloading unsigned apps — the path to shell access and custom firmware.")
                .font(.caption)
                .foregroundStyle(.secondary)

            switch controller.mobileConfigPhase {
            case .idle:
                Button {
                    controller.disableSignatureVerification()
                } label: {
                    Label("Disable Signature Verification", systemImage: "lock.open.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)

            case .succeeded:
                HStack {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                        .font(.title2)
                    Text("Config delivered to glasses")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(.green)
                }

            case .failed:
                HStack {
                    Image(systemName: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                    VStack(alignment: .leading) {
                        Text("Config delivery failed")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                        if !controller.mobileConfigFailure.isEmpty {
                            Text(controller.mobileConfigFailure)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

            default:
                HStack(spacing: 8) {
                    ProgressView()
                    Text(controller.mobileConfigPhase.rawValue)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private var mobileConfigPhaseColor: Color {
        switch controller.mobileConfigPhase {
        case .idle: return .secondary
        case .succeeded: return .green
        case .failed: return .red
        default: return .orange
        }
    }

    // MARK: - Forgery card

    private var forgeryCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "key.horizontal")
                    .foregroundStyle(.purple)
                Text("Ownership Forgery")
                    .font(.headline)
                Spacer()
                Text(controller.bluetooth.forgerPhase.rawValue)
                    .font(.caption)
                    .foregroundStyle(forgeryPhaseColor)
            }

            Text("Test whether the glasses verify Meta's receipt signatures. If they don't, we can claim ownership with our own key.")
                .font(.caption)
                .foregroundStyle(.secondary)

            switch controller.bluetooth.forgerPhase {
            case .idle:
                Button {
                    controller.bluetooth.startOwnershipForgery()
                } label: {
                    Label("Attempt Ownership Forgery", systemImage: "lock.open.rotation")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.purple)

            case .succeeded:
                HStack {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                        .font(.title2)
                    Text("Glasses accepted our forged receipt!")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(.green)
                }

            case .failed:
                HStack {
                    Image(systemName: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                        .font(.title2)
                    VStack(alignment: .leading) {
                        Text("Forgery rejected")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                        if !controller.bluetooth.forgerFailure.isEmpty {
                            Text(controller.bluetooth.forgerFailure)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

            default:
                HStack(spacing: 8) {
                    ProgressView()
                    Text(controller.bluetooth.forgerPhase.rawValue)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private var forgeryPhaseColor: Color {
        switch controller.bluetooth.forgerPhase {
        case .idle: return .secondary
        case .succeeded: return .green
        case .failed: return .red
        default: return .purple
        }
    }

    // MARK: - Debug log

    @State private var debugLogExpanded = true

    private var debugLogCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            DisclosureGroup(isExpanded: $debugLogExpanded) {
                Button {
                    UIPasteboard.general.string = controller.bluetooth.debugLog.joined(separator: "\n")
                } label: {
                    Label("Copy log", systemImage: "doc.on.doc")
                        .font(.subheadline)
                }
                .buttonStyle(.bordered)
                .disabled(controller.bluetooth.debugLog.isEmpty)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.top, 8)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if controller.bluetooth.debugLog.isEmpty {
                            Text("No log entries yet.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 8)
                        } else {
                            ForEach(Array(controller.bluetooth.debugLog.enumerated()), id: \.offset) { _, entry in
                                Text(entry)
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.primary)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .padding(8)
                }
                .frame(maxHeight: 300)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "ladybug")
                        .foregroundStyle(.orange)
                    Text("Debug Log")
                        .font(.headline)
                    Spacer()
                    Text("\(controller.bluetooth.debugLog.count)")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Computed

    private var connectionIcon: String {
        switch controller.state {
        case .disconnected, .error: return "eyeglasses"
        case .scanning: return "antenna.radiowaves.left.and.right"
        case .connecting: return "ellipsis.circle"
        case .connected: return "eyeglasses"
        case .authenticating: return "lock.rotation"
        case .authenticated: return "checkmark.shield.fill"
        }
    }

    private var connectionColor: Color {
        switch controller.state {
        case .disconnected, .error: return .secondary
        case .scanning, .connecting, .authenticating: return .orange
        case .connected: return .blue
        case .authenticated: return .green
        }
    }

    private var connectionLabel: String {
        switch controller.state {
        case .disconnected: return "Disconnected"
        case .scanning: return "Scanning..."
        case .connecting: return "Connecting..."
        case .connected: return "Connected"
        case .authenticating: return "Authenticating..."
        case .authenticated: return "Authenticated"
        case .error: return "Error"
        }
    }

    private var connectionSubtitle: String {
        switch controller.state {
        case .disconnected: return "Scan to find your glasses"
        case .scanning: return "Looking for Ray-Ban glasses nearby"
        case .connecting: return "Establishing BLE connection"
        case .connected where controller.bluetooth.isAirShieldSecure: return "Encrypted link established"
        case .connected where controller.hasIdentity: return "Ready to authenticate"
        case .connected: return "Ready to pair as new device"
        case .authenticating: return "Running PhaseB handshake"
        case .authenticated: return "Full access to glasses"
        case .error: return controller.lastError ?? "Something went wrong"
        }
    }

    private var batteryIcon: String {
        guard let pct = controller.bluetooth.batteryLevel else { return "battery.0percent" }
        switch pct {
        case 76...100: return "battery.100percent"
        case 51...75: return "battery.75percent"
        case 26...50: return "battery.50percent"
        case 1...25: return "battery.25percent"
        default: return "battery.0percent"
        }
    }

    private var batteryColor: Color {
        guard let pct = controller.bluetooth.batteryLevel else { return .secondary }
        switch pct {
        case 51...100: return .green
        case 21...50: return .orange
        default: return .red
        }
    }
}
