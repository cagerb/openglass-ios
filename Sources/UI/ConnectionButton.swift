import SwiftUI

struct ConnectionButton: View {
    @Environment(WearablesManager.self) private var wearables

    var body: some View {
        Button {
            handleTap()
        } label: {
            HStack(spacing: 6) {
                connectionIndicator
                Text(statusLabel)
                    .font(.caption)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(statusTint)
    }

    // MARK: - Indicator

    @ViewBuilder
    private var connectionIndicator: some View {
        switch wearables.connectionState {
        case .unregistered, .error:
            Circle()
                .fill(.secondary)
                .frame(width: 8, height: 8)

        case .registering, .connecting, .disconnecting:
            ProgressView()
                .controlSize(.mini)

        case .registered:
            Circle()
                .fill(.blue)
                .frame(width: 8, height: 8)

        case .connected:
            Circle()
                .fill(.green)
                .frame(width: 8, height: 8)

        case .streaming:
            Image(systemName: "video.circle.fill")
                .font(.caption2)
                .foregroundStyle(.green)
        }
    }

    // MARK: - Computed

    private var statusLabel: String {
        switch wearables.connectionState {
        case .unregistered: return "Register"
        case .registering: return "Registering"
        case .registered: return "Connect"
        case .connecting: return "Connecting"
        case .connected: return "Connected"
        case .streaming: return "Live"
        case .disconnecting: return "Ending"
        case .error: return "Error"
        }
    }

    private var statusTint: Color {
        switch wearables.connectionState {
        case .unregistered, .error: return .secondary
        case .registering, .connecting, .disconnecting: return .orange
        case .registered: return .blue
        case .connected, .streaming: return .green
        }
    }

    // MARK: - Action

    private func handleTap() {
        switch wearables.connectionState {
        case .unregistered, .error:
            wearables.register()
        case .registered:
            wearables.startSession()
        case .connected, .streaming:
            wearables.stopSession()
        case .registering, .connecting, .disconnecting:
            break
        }
    }
}
