import SwiftUI

struct DashboardView: View {
    @Environment(GlassesController.self) private var controller
    @Environment(GlassesState.self) private var glasses

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    connectionCard

                    if !controller.hasIdentity && controller.state == .connected {
                        identityWarning
                    }

                    if controller.state == .scanning && !controller.discoveredPeripherals.isEmpty {
                        discoveredDevicesCard
                    }

                    if controller.isConnected {
                        deviceInfoCard
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
                Button {
                    Task { await controller.authenticate() }
                } label: {
                    Text(controller.hasIdentity ? "Authenticate" : "Pair as New Device")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

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

    // MARK: - Debug log

    @State private var debugLogExpanded = true

    private var debugLogCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            DisclosureGroup(isExpanded: $debugLogExpanded) {
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
