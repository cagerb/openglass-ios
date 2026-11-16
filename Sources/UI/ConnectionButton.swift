import SwiftUI

/// A toolbar button that reflects the current Bluetooth connection state
/// and provides scan/connect/disconnect actions.
struct ConnectionButton: View {
    @Environment(BluetoothManager.self) private var bluetooth

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

    // MARK: - Indicator dot / icon

    @ViewBuilder
    private var connectionIndicator: some View {
        switch bluetooth.connectionState {
        case .disconnected:
            Circle()
                .fill(.secondary)
                .frame(width: 8, height: 8)

        case .scanning:
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.caption2)
                .symbolEffect(.variableColor.iterative)

        case .connecting, .discoveringServices:
            ProgressView()
                .controlSize(.mini)

        case .connected:
            Circle()
                .fill(.green)
                .frame(width: 8, height: 8)

        case .authenticated:
            Image(systemName: "checkmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(.green)
        }
    }

    // MARK: - Computed

    private var statusLabel: String {
        switch bluetooth.connectionState {
        case .disconnected: return "Connect"
        case .scanning: return "Scanning"
        case .connecting, .discoveringServices: return "Connecting"
        case .connected: return "Connected"
        case .authenticated: return "Ready"
        }
    }

    private var statusTint: Color {
        switch bluetooth.connectionState {
        case .disconnected: return .secondary
        case .scanning: return .orange
        case .connecting, .discoveringServices: return .orange
        case .connected, .authenticated: return .green
        }
    }

    // MARK: - Action

    private func handleTap() {
        switch bluetooth.connectionState {
        case .disconnected:
            bluetooth.startScanning()
        case .scanning:
            bluetooth.stopScanning()
        case .connected, .authenticated:
            bluetooth.disconnect()
        case .connecting, .discoveringServices:
            // Already in progress, do nothing
            break
        }
    }
}
