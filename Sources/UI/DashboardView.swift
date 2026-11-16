import SwiftUI

struct DashboardView: View {
    @Environment(BluetoothManager.self) private var bluetooth
    @Environment(GlassesState.self) private var glasses

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // Connection card
                    connectionCard

                    if bluetooth.connectionState == .connected ||
                       bluetooth.connectionState == .authenticated {
                        // Battery card
                        batteryCard

                        // Storage card
                        storageCard

                        // Captures card
                        capturesCard

                        // Device info card
                        deviceInfoCard
                    }
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
                    .symbolEffect(.pulse, isActive: bluetooth.connectionState == .scanning || bluetooth.connectionState == .connecting)

                VStack(alignment: .leading, spacing: 2) {
                    Text(bluetooth.connectionState.rawValue.capitalized)
                        .font(.headline)
                    if let name = bluetooth.modelNumber {
                        Text(name)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()
            }

            if bluetooth.connectionState == .disconnected {
                Button {
                    bluetooth.startScanning()
                } label: {
                    Text("Scan for Glasses")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }

            // Show discovered peripherals
            if bluetooth.connectionState == .scanning,
               !bluetooth.discoveredPeripherals.isEmpty {
                ForEach(bluetooth.discoveredPeripherals, id: \.identifier) { peripheral in
                    Button {
                        bluetooth.connect(to: peripheral)
                    } label: {
                        HStack {
                            Image(systemName: "eyeglasses")
                            Text(peripheral.name ?? "Unknown Device")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }

            if let error = bluetooth.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
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
                Text(glasses.batteryDisplayString)
                    .font(.title)
                    .fontWeight(.semibold)
                    .monospacedDigit()
            }

            Spacer()

            if glasses.isCharging {
                Label("Charging", systemImage: "bolt.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
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

    // MARK: - Captures card

    private var capturesCard: some View {
        HStack(spacing: 24) {
            VStack(spacing: 4) {
                Text("\(glasses.captureCount)")
                    .font(.title2)
                    .fontWeight(.semibold)
                    .monospacedDigit()
                Text("Total")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()
                .frame(height: 40)

            VStack(spacing: 4) {
                HStack(spacing: 4) {
                    Image(systemName: "photo")
                    Text("\(glasses.photoCount)")
                        .monospacedDigit()
                }
                .font(.subheadline)
                Text("Photos")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 4) {
                HStack(spacing: 4) {
                    Image(systemName: "video")
                    Text("\(glasses.videoCount)")
                        .monospacedDigit()
                }
                .font(.subheadline)
                Text("Videos")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Device info card

    private var deviceInfoCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Device Info")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if let model = glasses.modelNumber {
                infoRow("Model", value: model)
            }
            if let serial = glasses.serialNumber {
                infoRow("Serial", value: serial)
            }
            if let firmware = glasses.firmwareVersion {
                infoRow("Firmware", value: firmware)
            }
            if let temp = glasses.temperatureCelsius {
                infoRow("Temperature", value: String(format: "%.0f°C", temp))
            }
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private func infoRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .monospacedDigit()
        }
        .font(.subheadline)
    }

    // MARK: - Computed properties

    private var connectionIcon: String {
        switch bluetooth.connectionState {
        case .disconnected: return "eyeglasses"
        case .scanning: return "antenna.radiowaves.left.and.right"
        case .connecting, .discoveringServices: return "ellipsis.circle"
        case .connected: return "eyeglasses"
        case .authenticated: return "checkmark.circle.fill"
        }
    }

    private var connectionColor: Color {
        switch bluetooth.connectionState {
        case .disconnected: return .secondary
        case .scanning, .connecting, .discoveringServices: return .orange
        case .connected, .authenticated: return .green
        }
    }

    private var batteryIcon: String {
        guard let pct = glasses.batteryPercent else { return "battery.0percent" }
        switch pct {
        case 76...100: return "battery.100percent"
        case 51...75: return "battery.75percent"
        case 26...50: return "battery.50percent"
        case 1...25: return "battery.25percent"
        default: return "battery.0percent"
        }
    }

    private var batteryColor: Color {
        guard let pct = glasses.batteryPercent else { return .secondary }
        switch pct {
        case 51...100: return .green
        case 21...50: return .orange
        default: return .red
        }
    }
}
