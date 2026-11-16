import Foundation

/// Observable model representing the current state of the connected glasses.
@Observable
final class GlassesState: @unchecked Sendable {

    // MARK: - Connection

    enum ConnectionStatus: String, Sendable, CaseIterable {
        case disconnected = "Disconnected"
        case scanning = "Scanning..."
        case connecting = "Connecting..."
        case connected = "Connected"
        case authenticated = "Authenticated"
    }

    var connectionStatus: ConnectionStatus = .disconnected

    // MARK: - Battery

    /// Battery percentage (0–100), or nil if not yet read.
    var batteryPercent: Int?

    /// Whether the glasses are currently charging.
    var isCharging: Bool = false

    var batteryDisplayString: String {
        guard let pct = batteryPercent else { return "--%" }
        return "\(pct)%"
    }

    // MARK: - Storage

    /// Used storage in bytes.
    var storageUsed: Int64 = 0
    /// Total storage in bytes.
    var storageTotal: Int64 = 0

    var storageUsedGB: Double {
        Double(storageUsed) / 1_073_741_824
    }

    var storageTotalGB: Double {
        Double(storageTotal) / 1_073_741_824
    }

    var storageDisplayString: String {
        String(format: "%.1f / %.1f GB", storageUsedGB, storageTotalGB)
    }

    var storageFraction: Double {
        storageTotal > 0 ? Double(storageUsed) / Double(storageTotal) : 0
    }

    // MARK: - Temperature

    /// Device temperature in Celsius, if reported.
    var temperatureCelsius: Double?

    var temperatureDisplayString: String {
        guard let temp = temperatureCelsius else { return "--°C" }
        return String(format: "%.0f°C", temp)
    }

    var isOverheating: Bool {
        guard let temp = temperatureCelsius else { return false }
        return temp > 45.0
    }

    // MARK: - Firmware

    var firmwareVersion: String?
    var modelNumber: String?
    var serialNumber: String?
    var hardwareRevision: String?

    // MARK: - Captures

    /// Number of captures (photos + videos) on the device.
    var captureCount: Int = 0
    var photoCount: Int = 0
    var videoCount: Int = 0

    // MARK: - SoftAP

    var softAPSSID: String?
    var isSoftAPConnected: Bool = false

    // MARK: - Reset

    func reset() {
        connectionStatus = .disconnected
        batteryPercent = nil
        isCharging = false
        storageUsed = 0
        storageTotal = 0
        temperatureCelsius = nil
        firmwareVersion = nil
        modelNumber = nil
        serialNumber = nil
        hardwareRevision = nil
        captureCount = 0
        photoCount = 0
        videoCount = 0
        softAPSSID = nil
        isSoftAPConnected = false
    }
}
