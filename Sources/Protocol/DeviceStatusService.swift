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

    var log: ((String) -> Void)?

    private(set) var channelID: Int = 0
    private var firstMessage = true

    // MARK: - Request

    func requestStatus(link: AirShieldLink) {
        if channelID == 0 {
            channelID = link.openChannel()
            firstMessage = true
        }

        phase = .requesting

        // CompanionDeviceInit: field 1 = varint 1, field 2 = interaction key
        let interactionKey = UUID().uuidString
        var payload = ProtoWire.field(1, varint: 1)
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
        case MsgType.deviceState, MsgType.stateUpdate:
            parseStatusResponse(message.payload)
        case 2007...2043:
            parseStatusResponse(message.payload)
        default:
            emit("svc28 type \(msgType) (\(message.payload.count) bytes)")
        }
    }

    // MARK: - Parse HNDeviceState wrapper

    private func parseStatusResponse(_ payload: [UInt8]) {
        // Outer message: HNDeviceState
        let outer = ProtoWire.parse(payload)

        // Field 1 contains the stateCommon sub-message (length-delimited bytes)
        let stateCommonBytes = outer.bytes(1)
        guard !stateCommonBytes.isEmpty else {
            emit("No stateCommon in HNDeviceState — raw payload \(payload.count) bytes")
            // Try parsing the outer directly as a fallback
            parseFlatStatus(outer)
            return
        }

        // Parse the inner stateCommon
        let inner = ProtoWire.parse(stateCommonBytes)

        let battery = Int(inner.varint(1))
        let charging = inner.varint(2)
        let tempRaw = inner.varint(3)
        let state = UInt32(inner.varint(5))

        batteryPercent = battery
        isCharging = charging != 0
        if tempRaw > 0 {
            temperatureCelsius = Double(tempRaw) / 10.0
        }
        deviceState = state

        phase = .received
        emit("Battery: \(battery)%, charging: \(isCharging), temp: \(temperatureCelsius.map { String(format: "%.1f°C", $0) } ?? "unknown"), state: \(state)")
    }

    private func parseFlatStatus(_ fields: ProtoWire.Fields) {
        let battery = Int(fields.varint(1))
        if battery > 0 && battery <= 100 {
            batteryPercent = battery
            isCharging = fields.varint(2) != 0
            let tempRaw = fields.varint(3)
            if tempRaw > 0 {
                temperatureCelsius = Double(tempRaw) / 10.0
            }
            deviceState = UInt32(fields.varint(5))
            phase = .received
            emit("(flat parse) Battery: \(battery)%, charging: \(isCharging)")
        } else {
            phase = .failed
            failureReason = "Could not parse device status"
            emit("Failed to parse status response (\(fields.varints.count) varints, \(fields.blobs.count) blobs)")
        }
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
        channelID = 0
        firstMessage = true
    }

    private func emit(_ message: String) {
        log?("[DeviceStatus] \(message)")
    }
}
