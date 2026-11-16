import SwiftUI

struct DashboardView: View {
    @Environment(WearablesManager.self) private var wearables
    @Environment(GlassesState.self) private var glasses

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    connectionCard

                    if wearables.isConnected {
                        cameraCard
                        batteryCard
                        storageCard
                        capturesCard
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
                    .symbolEffect(
                        .pulse,
                        isActive: wearables.connectionState == .connecting ||
                                  wearables.connectionState == .registering
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

            switch wearables.connectionState {
            case .unregistered, .error:
                Button {
                    wearables.register()
                } label: {
                    Text("Register with Glasses")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

            case .registered:
                Button {
                    wearables.startSession()
                } label: {
                    Text("Connect to Glasses")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

            default:
                EmptyView()
            }

            if let error = wearables.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Camera card

    private var cameraCard: some View {
        VStack(spacing: 12) {
            if wearables.isStreaming, let frame = wearables.latestFrame {
                Image(uiImage: frame)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                HStack(spacing: 16) {
                    Button {
                        _ = wearables.capturePhoto()
                    } label: {
                        Label("Capture", systemImage: "camera.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    Button {
                        wearables.stopCamera()
                    } label: {
                        Label("Stop", systemImage: "stop.circle")
                    }
                    .buttonStyle(.bordered)
                }
            } else if wearables.connectionState == .connected {
                VStack(spacing: 8) {
                    Image(systemName: "camera.viewfinder")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text("Camera Ready")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(height: 200)

                Button {
                    Task { await wearables.startCamera() }
                } label: {
                    Label("Start Camera", systemImage: "video")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }

            if !wearables.capturedPhotos.isEmpty {
                HStack {
                    Text("\(wearables.capturedPhotos.count) photos captured")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
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
                Text("On Device")
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

    // MARK: - Computed

    private var connectionIcon: String {
        switch wearables.connectionState {
        case .unregistered, .error: return "eyeglasses"
        case .registering: return "person.badge.key"
        case .registered: return "eyeglasses"
        case .connecting, .disconnecting: return "ellipsis.circle"
        case .connected: return "eyeglasses"
        case .streaming: return "video.circle.fill"
        }
    }

    private var connectionColor: Color {
        switch wearables.connectionState {
        case .unregistered, .error: return .secondary
        case .registering, .connecting, .disconnecting: return .orange
        case .registered: return .blue
        case .connected: return .green
        case .streaming: return .green
        }
    }

    private var connectionLabel: String {
        switch wearables.connectionState {
        case .unregistered: return "Not Registered"
        case .registering: return "Registering..."
        case .registered: return "Ready"
        case .connecting: return "Connecting..."
        case .connected: return "Connected"
        case .streaming: return "Streaming"
        case .disconnecting: return "Disconnecting..."
        case .error: return "Error"
        }
    }

    private var connectionSubtitle: String {
        switch wearables.connectionState {
        case .unregistered: return "Register to connect to your glasses"
        case .registering: return "Complete setup in the Meta AI app"
        case .registered: return "Tap Connect to start a session"
        case .connecting: return "Establishing session..."
        case .connected: return "Session active"
        case .streaming: return "Live camera feed"
        case .disconnecting: return "Ending session..."
        case .error: return wearables.lastError ?? "Something went wrong"
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
