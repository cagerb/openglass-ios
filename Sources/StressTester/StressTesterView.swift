import SwiftUI
import UIKit

struct StressTesterView: View {
    @Environment(GlassesController.self) private var controller
    @State private var tester: ProtocolStressTester?
    @State private var selectedStrategyIndex = 0
    @State private var exportMessage: String?

    private let strategies = StressStrategies.all
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    strategyPicker
                    controlButtons
                    speedSlider
                    statsCard
                    anomalyLog
                }
                .padding()
            }
            .navigationTitle("Stress Tester")
            .onAppear {
                if tester == nil {
                    tester = ProtocolStressTester(bluetooth: controller.bluetooth)
                }
            }
            .onReceive(timer) { _ in
                // Force a view update for the elapsed time counter
            }
        }
    }

    // MARK: - Strategy picker

    private var strategyPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Strategy")
                .font(.headline)

            Picker("Strategy", selection: $selectedStrategyIndex) {
                ForEach(Array(strategies.enumerated()), id: \.offset) { index, strategy in
                    Text(strategy.name).tag(index)
                }
            }
            .pickerStyle(.menu)

            if selectedStrategyIndex < strategies.count {
                let strategy = strategies[selectedStrategyIndex]
                Text(strategy.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let total = strategy.totalCases {
                    Text("\(total) test cases")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Control buttons

    private var controlButtons: some View {
        HStack(spacing: 12) {
            if let tester {
                switch tester.currentState {
                case .idle, .finished:
                    Button {
                        let strategy = strategies[selectedStrategyIndex]
                        tester.start(strategy: strategy)
                    } label: {
                        Label("Start", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .disabled(!controller.isConnected)

                case .running:
                    Button {
                        tester.pause()
                    } label: {
                        Label("Pause", systemImage: "pause.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)

                    Button {
                        tester.stop()
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)

                case .paused:
                    Button {
                        tester.resume()
                    } label: {
                        Label("Resume", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .disabled(!controller.isConnected)

                    Button {
                        tester.stop()
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)

                case .reconnecting:
                    HStack {
                        ProgressView()
                        Text("Reconnecting...")
                            .foregroundStyle(.orange)
                    }
                    .frame(maxWidth: .infinity)
                }
            } else {
                Text("Initializing...")
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Speed slider

    private var speedSlider: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Speed")
                    .font(.headline)
                Spacer()
                if let tester {
                    Text("\(Int(tester.packetsPerSecond)) pkt/s")
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }

            if let tester {
                @Bindable var t = tester
                Slider(value: $t.packetsPerSecond, in: 1...10, step: 1) {
                    Text("Packets per second")
                }
            }
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Stats card

    private var statsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "chart.bar.fill")
                    .foregroundStyle(.blue)
                Text("Stats")
                    .font(.headline)
                Spacer()
                if let tester {
                    statusBadge(tester.currentState)
                }
            }

            if let tester {
                LazyVGrid(columns: [
                    GridItem(.flexible()),
                    GridItem(.flexible()),
                ], spacing: 12) {
                    statCell("Packets Sent", value: "\(tester.packetsSent)")
                    statCell("Anomalies", value: "\(tester.anomalyCount)",
                             color: tester.anomalyCount > 0 ? .red : .green)
                    statCell("Strategy", value: tester.currentStrategyName.isEmpty
                             ? "None" : tester.currentStrategyName)
                    statCell("Time", value: tester.elapsedString)
                    statCell("Reconnects", value: "\(tester.reconnectAttempts)",
                             color: tester.reconnectAttempts > 0 ? .orange : .primary)
                    statCell("Rate", value: "\(Int(tester.packetsPerSecond)) pkt/s")
                }

                // Export button
                HStack {
                    Spacer()
                    Button {
                        Task {
                            let json = await tester.exportAnomaliesJSON()
                            UIPasteboard.general.string = json
                            exportMessage = "Copied \(tester.anomalyCount) anomalies to clipboard"
                            Task {
                                try? await Task.sleep(for: .seconds(3))
                                exportMessage = nil
                            }
                        }
                    } label: {
                        Label("Export Anomalies", systemImage: "square.and.arrow.up")
                            .font(.subheadline)
                    }
                    .buttonStyle(.bordered)
                    .disabled(tester.anomalyCount == 0)
                }

                if let msg = exportMessage {
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(.green)
                        .transition(.opacity)
                }
            }
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private func statCell(_ label: String, value: String, color: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private func statusBadge(_ state: ProtocolStressTester.TesterState) -> some View {
        let (text, color): (String, Color) = {
            switch state {
            case .idle: return ("Idle", .secondary)
            case .running: return ("Running", .green)
            case .paused: return ("Paused", .orange)
            case .reconnecting: return ("Reconnecting", .purple)
            case .finished: return ("Done", .blue)
            }
        }()
        return Text(text)
            .font(.caption)
            .fontWeight(.medium)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(color.opacity(0.2), in: Capsule())
            .foregroundStyle(color)
    }

    // MARK: - Anomaly log

    private var anomalyLog: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Test Log")
                    .font(.headline)
                Spacer()
                if let tester {
                    Text("\(tester.log.count) entries")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }

            if let tester {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        if tester.log.isEmpty {
                            Text("No test results yet. Start a strategy to begin.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 8)
                        } else {
                            // Show most recent first
                            ForEach(tester.log.suffix(200).reversed()) { entry in
                                logRow(entry)
                            }
                        }
                    }
                    .padding(8)
                }
                .frame(maxHeight: 350)
            }
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private func logRow(_ entry: TestLogEntry) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(outcomeColor(entry.outcome))
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 1) {
                HStack {
                    Text("#\(entry.index)")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text(entry.testCase.description)
                        .font(.caption2)
                        .lineLimit(1)
                }

                HStack {
                    Text(outcomeLabel(entry.outcome))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(outcomeColor(entry.outcome))

                    Spacer()

                    Text(hexPreview(entry.testCase.bytes))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)

                    Text(timeString(entry.timestamp))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func outcomeColor(_ outcome: PacketOutcome) -> Color {
        switch outcome {
        case .normal: return .green
        case .disconnect: return .red
        case .channelClosed: return .orange
        case .timeout: return .orange
        case .sendFailed: return .purple
        }
    }

    private func outcomeLabel(_ outcome: PacketOutcome) -> String {
        switch outcome {
        case .normal: return "OK"
        case .disconnect: return "DISCONNECT"
        case .channelClosed: return "CHAN CLOSED"
        case .timeout: return "TIMEOUT"
        case .sendFailed: return "SEND FAIL"
        }
    }

    private func hexPreview(_ bytes: [UInt8]) -> String {
        let shown = bytes.prefix(8).map { String(format: "%02x", $0) }.joined(separator: " ")
        if bytes.count > 8 {
            return shown + "..."
        }
        return shown
    }

    private func timeString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}
