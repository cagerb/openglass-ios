import SwiftUI

struct ConnectionButton: View {
    @Environment(GlassesController.self) private var controller

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
        switch controller.state {
        case .disconnected, .error:
            Circle()
                .fill(.secondary)
                .frame(width: 8, height: 8)

        case .scanning, .connecting, .authenticating:
            ProgressView()
                .controlSize(.mini)

        case .connected:
            Circle()
                .fill(.blue)
                .frame(width: 8, height: 8)

        case .authenticated:
            Circle()
                .fill(.green)
                .frame(width: 8, height: 8)
        }
    }

    // MARK: - Computed

    private var statusLabel: String {
        switch controller.state {
        case .disconnected: return "Scan"
        case .scanning: return "Scanning"
        case .connecting: return "Connecting"
        case .connected: return "Connected"
        case .authenticating: return "Auth..."
        case .authenticated: return "Secure"
        case .error: return "Error"
        }
    }

    private var statusTint: Color {
        switch controller.state {
        case .disconnected, .error: return .secondary
        case .scanning, .connecting, .authenticating: return .orange
        case .connected: return .blue
        case .authenticated: return .green
        }
    }

    // MARK: - Action

    private func handleTap() {
        switch controller.state {
        case .disconnected, .error:
            controller.startScan()
        case .scanning:
            controller.stopScan()
        case .connected:
            if controller.hasIdentity {
                Task { await controller.authenticate() }
            }
        case .authenticated, .authenticating:
            controller.disconnect()
        case .connecting:
            break
        }
    }
}
