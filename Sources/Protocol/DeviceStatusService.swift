// svc28 device status: battery level, charging state, temperature.
//
// CRITICAL TRAP: The response is wrapped in HNDeviceState { field 1: stateCommon }.
// Reading the outer message directly for battery returns 0%. You MUST parse the inner
// sub-message at field 1 to get the real values.

import Foundation

final class DeviceStatusService: @unchecked Sendable {

    enum Phase: String {
        case idle       = "Idle"
        case requesting = "Requesting status..."
        case received   = "Status received"
        case failed     = "Failed"
    }

    static let serviceDeviceStatus = 28

    private enum MsgType {
        static let subscribe      = 1000  // CompanionDeviceInit
        static let subscribeAck   = 1001
        static let deviceState    = 2005  // full snapshot
        static let stateUpdate    = 2006  // delta update
    }

    private(set) var phase: Phase = .idle
    private(set) var failureReason: String = ""

    private(set) var batteryPercent: Int?
    private(set) var isCharging: Bool = false
    private(set) var temperatureCelsius: Double?
    private(set) var deviceState: UInt32 = 0
    private(set) var storageFreeBytes: Int64 = 0
    private(set) var storageTotalBytes: Int64 = 0

    var log: ((String) -> Void)?

    private(set) var channelID: Int = 0
    private var firstMessage = true

    // MARK: - Subscribe

    func subscribe(link: AirShieldLink) {
        if channelID == 0 {
            channelID = link.openChannel()
            firstMessage = true
        }

        phase = .requesting

        // CompanionDeviceInit: field 1 = packed varint [1], field 2 = interaction key
        let interactionKey = UUID().uuidString
        var payload = ProtoWire.field(1, bytes: ProtoWire.varint(1))
        payload += ProtoWire.field(2, bytes: Array(interactionKey.utf8))

        emit("Subscribing to device state (svc28 type 1000, key=\(interactionKey.prefix(8))...)")

        link.sendMessage(
            channelID: channelID,
            serviceID: firstMessage ? Self.serviceDeviceStatus : nil,
            messageType: MsgType.subscribe,
            payload: payload
        )
        firstMessage = false
    }

    // MARK: - Message handler

    func handleMessage(_ message: AirShieldMessage, link: AirShieldLink) {
        let msgType = message.header.messageType

        switch msgType {
        case MsgType.subscribeAck:
            emit("Subscribe acknowledged")
        case MsgType.deviceState:
            parseFullSnapshot(message.payload)
        case MsgType.stateUpdate, 2007...2043:
            emit("svc28 delta type \(msgType) (\(message.payload.count) bytes)")
        default:
            emit("svc28 type \(msgType) (\(message.payload.count) bytes)")
        }
    }

    // MARK: - Parse full HNDeviceState snapshot (type 2005 only)

    private func parseFullSnapshot(_ payload: [UInt8]) {
        let outer = ProtoWire.parse(payload)

        let stateCommonBytes = outer.bytes(1)
        guard !stateCommonBytes.isEmpty else {
            emit("No stateCommon in full snapshot — skipping (\(payload.count) bytes)")
            return
        }

        let inner = ProtoWire.parse(stateCommonBytes)

        let charging = inner.varint(2)
        let battery = Int(inner.varint(3))
        let tempRaw = inner.varint(4)
        let voltage = UInt32(inner.varint(5))

        batteryPercent = battery
        isCharging = charging != 0
        if tempRaw > 0 {
            temperatureCelsius = Double(tempRaw) / 1000.0
        }
        deviceState = voltage

        // Storage: outer field 2 contains device info with storage sub-message at field 4
        let deviceInfoBytes = outer.bytes(2)
        if !deviceInfoBytes.isEmpty {
            let devInfo = ProtoWire.parse(deviceInfoBytes)
            let storageBytes = devInfo.bytes(3)
            if !storageBytes.isEmpty {
                let storage = ProtoWire.parse(storageBytes)
                let freeMB = Int64(storage.varint(1))
                let totalMB = Int64(storage.varint(2))
                if totalMB > 0 {
                    storageFreeBytes = freeMB * 1_048_576
                    storageTotalBytes = totalMB * 1_048_576
                    emit("Storage: \(freeMB)MB free / \(totalMB)MB total")
                }
            }
        }

        phase = .received
        emit("Battery: \(battery)%, charging: \(isCharging), temp: \(temperatureCelsius.map { String(format: "%.1f°C", $0) } ?? "unknown"), voltage: \(voltage)mV")
    }

    // MARK: - Convenience

    var batteryDisplayString: String {
        guard let pct = batteryPercent else { return "--%" }
        let chargingIndicator = isCharging ? " ⚡" : ""
        return "\(pct)%\(chargingIndicator)"
    }

    var temperatureDisplayString: String {
        guard let temp = temperatureCelsius else { return "--°C" }
        return String(format: "%.1f°C", temp)
    }

    func reset() {
        phase = .idle
        failureReason = ""
        batteryPercent = nil
        isCharging = false
        temperatureCelsius = nil
        deviceState = 0
        storageFreeBytes = 0
        storageTotalBytes = 0
        channelID = 0
        firstMessage = true
    }

    private func emit(_ message: String) {
        log?("[DeviceStatus] \(message)")
    }
}
