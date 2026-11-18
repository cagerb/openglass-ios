import Foundation
import SwiftUI

/// Outcome of a single packet send.
enum PacketOutcome: String, Sendable, CaseIterable {
    case normal
    case disconnect
    case channelClosed
    case timeout
    case sendFailed
}

/// One entry in the test log.
struct TestLogEntry: Identifiable, Sendable {
    let id = UUID()
    let index: Int
    let strategyName: String
    let testCase: StressTestCase
    let outcome: PacketOutcome
    let timestamp: Date
}

/// Drives the stress test: picks a strategy, sends packets, detects anomalies, auto-reconnects.
@Observable
@MainActor
final class ProtocolStressTester {

    // MARK: - State

    enum TesterState: String, Sendable {
        case idle
        case running
        case paused
        case reconnecting
        case finished
    }

    private(set) var currentState: TesterState = .idle
    private(set) var packetsSent = 0
    private(set) var anomalyCount = 0
    private(set) var currentStrategyName = ""
    private(set) var log: [TestLogEntry] = []
    private(set) var startTime: Date?
    private(set) var reconnectAttempts = 0

    var packetsPerSecond: Double = 5.0

    // MARK: - Dependencies

    private let bluetooth: BluetoothManager
    let anomalyDetector = AnomalyDetector()

    private var runTask: Task<Void, Never>?
    private var selectedStrategy: (any StressStrategy)?
    private var strategyIndex = 0

    // UserDefaults keys for resume
    private static let savedPacketsKey = "com.openglass.stress.packetsSent"
    private static let savedStrategyKey = "com.openglass.stress.strategyName"

    init(bluetooth: BluetoothManager) {
        self.bluetooth = bluetooth
        // Restore progress
        packetsSent = UserDefaults.standard.integer(forKey: Self.savedPacketsKey)
        if let saved = UserDefaults.standard.string(forKey: Self.savedStrategyKey),
           let found = StressStrategies.all.first(where: { $0.name == saved }) {
            selectedStrategy = found
            currentStrategyName = saved
            strategyIndex = packetsSent
        }
    }

    // MARK: - Control

    func start(strategy: any StressStrategy) {
        guard currentState == .idle || currentState == .paused || currentState == .finished else { return }
        selectedStrategy = strategy
        currentStrategyName = strategy.name
        if currentState != .paused || currentStrategyName != strategy.name {
            packetsSent = 0
            strategyIndex = 0
            log.removeAll()
            Task { await anomalyDetector.reset() }
            anomalyCount = 0
        }
        startTime = startTime ?? Date()
        currentState = .running
        saveProgress()
        runTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    func pause() {
        guard currentState == .running else { return }
        currentState = .paused
        runTask?.cancel()
        runTask = nil
        saveProgress()
    }

    func stop() {
        currentState = .idle
        runTask?.cancel()
        runTask = nil
        startTime = nil
        saveProgress()
    }

    func resume() {
        guard currentState == .paused, let strategy = selectedStrategy else { return }
        start(strategy: strategy)
    }

    // MARK: - Run loop

    private func runLoop() async {
        guard let strategy = selectedStrategy else { return }
        let total = strategy.totalCases ?? Int.max

        while currentState == .running, strategyIndex < total {
            if Task.isCancelled { break }

            let testCase = strategy.generate(index: strategyIndex)

            // Send the packet
            let sent = sendPacket(testCase)

            // Wait based on rate
            let delay = 1.0 / packetsPerSecond
            if testCase.layer != "raw_l2cap" || !(strategy is RapidFireStrategy) {
                try? await Task.sleep(for: .milliseconds(Int(delay * 1000)))
            }

            if Task.isCancelled { break }

            // Check for anomalies
            let outcome = await checkOutcome(sent: sent, packetIndex: strategyIndex)

            let entry = TestLogEntry(
                index: strategyIndex,
                strategyName: strategy.name,
                testCase: testCase,
                outcome: outcome,
                timestamp: Date()
            )
            log.append(entry)
            if log.count > 2000 { log.removeFirst(log.count - 2000) }

            packetsSent += 1
            strategyIndex += 1
            saveProgress()

            // Handle anomaly: attempt reconnect
            if outcome == .disconnect || outcome == .channelClosed {
                anomalyCount += 1
                if currentState == .running {
                    let reconnected = await attemptReconnect(afterPacket: strategyIndex)
                    if !reconnected {
                        // Glasses did not come back — record it and stop
                        break
                    }
                    // Resume from the packet that caused the crash
                }
            }
        }

        if currentState == .running {
            currentState = .finished
        }
    }

    // MARK: - Packet dispatch

    /// Send a test case through the appropriate layer. Returns true if the send call succeeded.
    private func sendPacket(_ testCase: StressTestCase) -> Bool {
        switch testCase.layer {
        case "raw_l2cap":
            bluetooth.sendRawL2CAP(testCase.bytes)
            return true

        case "airshield_frame":
            guard bluetooth.isAirShieldSecure else { return false }
            // Dispatches to bleQueue where AirShieldLink is safe to call
            bluetooth.sendRawEncrypted(testCase.bytes)
            return true

        case "datax_message":
            guard bluetooth.isAirShieldSecure else { return false }
            // Dispatches to bleQueue where AirShieldLink is safe to call
            bluetooth.sendRawEncrypted(testCase.bytes)
            return true

        default:
            return false
        }
    }

    // MARK: - Anomaly detection

    /// Check the connection state after sending a packet.
    private func checkOutcome(sent: Bool, packetIndex: Int) async -> PacketOutcome {
        guard sent else { return .sendFailed }

        // Brief pause to let any disconnect propagate
        try? await Task.sleep(for: .milliseconds(100))

        let connState = bluetooth.connectionState
        let l2capUp = bluetooth.isL2CAPConnected

        if connState == .disconnected {
            await anomalyDetector.record(
                .bleDisconnect(afterPacket: packetIndex, timestamp: Date())
            )
            return .disconnect
        }

        if !l2capUp && bluetooth.airShield != nil {
            // L2CAP closed but BLE still up
            await anomalyDetector.record(
                .l2capClosed(afterPacket: packetIndex, timestamp: Date())
            )
            return .channelClosed
        }

        return .normal
    }

    // MARK: - Auto-reconnect

    /// Wait for the glasses to come back after a detected crash. Returns true if reconnected.
    private func attemptReconnect(afterPacket: Int) async -> Bool {
        currentState = .reconnecting
        reconnectAttempts += 1

        // Wait 2 seconds for the glasses to reboot
        try? await Task.sleep(for: .seconds(2))

        // Start scanning
        bluetooth.startScanning()

        // Wait up to 30 seconds for them to reappear
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if Task.isCancelled { return false }
            try? await Task.sleep(for: .milliseconds(500))

            if !bluetooth.discoveredPeripherals.isEmpty {
                // Found the glasses, try to connect
                if let peripheral = bluetooth.discoveredPeripherals.first {
                    bluetooth.connect(to: peripheral)
                    // Wait up to 15 seconds for the full connection + AirShield handshake
                    let connectDeadline = Date().addingTimeInterval(15)
                    while Date() < connectDeadline {
                        try? await Task.sleep(for: .milliseconds(500))
                        if bluetooth.connectionState == .connected
                            || bluetooth.connectionState == .authenticated {
                            // Check if AirShield is up for encrypted strategies
                            let needsEncryption = !(selectedStrategy is SingleByteStrategy
                                || selectedStrategy is EmptyPacketStrategy
                                || selectedStrategy is BadFrameTypeStrategy
                                || selectedStrategy is OversizedFrameStrategy
                                || selectedStrategy is BinaryPatternStrategy
                                || selectedStrategy is RapidFireStrategy)
                            if !needsEncryption || bluetooth.isAirShieldSecure {
                                currentState = .running
                                return true
                            }
                        }
                    }
                }
            }
        }

        // 30 seconds passed, glasses never came back — HIGH VALUE finding
        await anomalyDetector.record(
            .glassesMissing(afterPacket: afterPacket, missingForSeconds: 30, timestamp: Date())
        )
        anomalyCount += 1
        currentState = .paused
        return false
    }

    // MARK: - Persistence

    private func saveProgress() {
        UserDefaults.standard.set(packetsSent, forKey: Self.savedPacketsKey)
        UserDefaults.standard.set(currentStrategyName, forKey: Self.savedStrategyKey)
    }

    // MARK: - Export

    func exportAnomaliesJSON() async -> String {
        await anomalyDetector.exportJSONString()
    }

    var elapsedTime: TimeInterval {
        guard let start = startTime else { return 0 }
        return Date().timeIntervalSince(start)
    }

    var elapsedString: String {
        let elapsed = elapsedTime
        let minutes = Int(elapsed) / 60
        let seconds = Int(elapsed) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
