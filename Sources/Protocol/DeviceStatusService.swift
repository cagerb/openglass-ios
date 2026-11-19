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
    /// Raw stateCommon field 2, kept for diagnostics (see parseFullSnapshot).
    private(set) var chargingFieldRaw: UInt64 = 0
    private(set) var temperatureCelsius: Double?
    private(set) var deviceState: UInt32 = 0
    private(set) var storageFreeBytes: Int64 = 0
    private(set) var storageTotalBytes: Int64 = 0

    var log: ((String) -> Void)?

    private(set) var channelID: Int = 0
    private var firstMessage = true
    private var dumpedSnapshot = false

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
            emit("svc28 delta type \(msgType) (\(message.payload.count) bytes): \(Self.summarize(message.payload))")
        default:
            emit("svc28 type \(msgType) (\(message.payload.count) bytes): \(Self.summarize(message.payload))")
        }
    }

    // MARK: - Parse full HNDeviceState snapshot (type 2005 only)

    private func parseFullSnapshot(_ payload: [UInt8]) {
        let outer = ProtoWire.parse(payload)

        // One-time structure dump so storage (and anything else) can be located from the log.
        if !dumpedSnapshot {
            dumpedSnapshot = true
            dumpStructure(payload)
        }

        let stateCommonBytes = outer.bytes(1)
        guard !stateCommonBytes.isEmpty else {
            emit("No stateCommon in full snapshot — skipping (\(payload.count) bytes)")
            return
        }

        let inner = ProtoWire.parse(stateCommonBytes)

        let charging = inner.varint(2)
        let batteryRaw = inner.varint(3)
        let tempRaw = inner.varint(4)
        let voltage = UInt32(truncatingIfNeeded: inner.varint(5))

        if batteryRaw >= 1 && batteryRaw <= 100 {
            batteryPercent = Int(batteryRaw)
        }
        // Field 2 is the Android BatteryManager status enum, not a bool:
        // 1 unknown, 2 charging, 3 discharging, 4 not charging, 5 full.
        // The raw value is logged below so it can be checked on and off the charger.
        chargingFieldRaw = charging
        isCharging = charging == 2
        if tempRaw > 0 && tempRaw < 200_000 {
            temperatureCelsius = Double(tempRaw) / 1000.0
        }
        deviceState = voltage

        emit("stateCommon: charging_field=\(charging), battery=\(batteryRaw), temp_raw=\(tempRaw), f5=\(voltage), all=[\(Self.summarize(stateCommonBytes))]")

        parseStorage(inner: inner, outer: outer, payloadCount: payload.count)

        phase = .received
        emit("Battery: \(batteryRaw)%, charging: \(isCharging) (raw \(charging)), temp: \(temperatureCelsius.map { String(format: "%.1f°C", $0) } ?? "unknown"), voltage: \(voltage)mV")
    }

    // MARK: - Storage (location unconfirmed — try each candidate path)

    private func parseStorage(inner: ProtoWire.Fields, outer: ProtoWire.Fields, payloadCount: Int) {
        // storage_details is field 21 of DeviceState (the stateCommon sub-message):
        // field 1 = MB free, field 2 = MB total (per the Visor protocol notes).
        // The outer-message paths are kept only as a fallback.
        var candidates: [(label: String, bytes: [UInt8])] = []
        candidates.append((label: "stateCommon.21", bytes: inner.bytes(21)))

        let field21 = outer.bytes(21)
        candidates.append((label: "outer.21", bytes: field21))
        let nested21 = ProtoWire.parse(field21)
        for sub in 1...4 {
            candidates.append((label: "outer.21 > \(sub)", bytes: nested21.bytes(sub)))
        }

        var tried: [String] = []
        for candidate in candidates where !candidate.bytes.isEmpty {
            let fields = ProtoWire.parse(candidate.bytes)
            let first = fields.varint(1)
            let second = fields.varint(2)
            tried.append("\(candidate.label): f1=\(first) f2=\(second)")

            // Expect free <= total. The unit is guessed from the size of the total.
            guard second > 0, first <= second else { continue }
            let unit: UInt64
            let unitName: String
            if second >= 1_000 && second < 1_000_000 {
                unit = 1_048_576
                unitName = "MB"
            } else if second >= 1_000_000 && second < 1_000_000_000 {
                unit = 1_024
                unitName = "KB"
            } else if second >= 1_000_000_000 && second < 1_000_000_000_000 {
                unit = 1
                unitName = "bytes"
            } else {
                continue
            }
            storageFreeBytes = Int64(clamping: first * unit)
            storageTotalBytes = Int64(clamping: second * unit)
            emit("Storage found at \(candidate.label): free=\(first) total=\(second) (\(unitName))")
            return
        }

        if tried.isEmpty {
            emit("Storage not found: nothing at stateCommon.21 or outer.21 (\(payloadCount) byte payload) — see the 2005 dump")
        } else {
            emit("Storage not found; candidates did not look like free/total: \(tried.joined(separator: "; "))")
        }
    }

    // MARK: - Structure dump (protocol analysis)

    /// Logs every top-level field of the snapshot, one level of nesting, and a hex prefix.
    /// Kept to a few dozen lines: the in-app debug log only holds 400 entries.
    private func dumpStructure(_ payload: [UInt8]) {
        let top = Self.scan(payload).fields
        emit("2005 dump: \(payload.count) bytes, \(top.count) top-level fields: \(Self.summarize(payload))")

        var lines = 0
        for item in top {
            guard case .blob(let bytes) = item.value, bytes.count >= 2 else { continue }
            guard lines < 30 else {
                emit("2005 dump: (more nested fields not shown)")
                break
            }
            emit("2005 f\(item.number) [\(bytes.count)B]: \(Self.summarize(bytes))")
            lines += 1
        }

        let hexLimit = min(payload.count, 192)
        var offset = 0
        while offset < hexLimit {
            let end = min(offset + 64, hexLimit)
            emit("2005 hex @\(offset): \(Self.hex(payload[offset..<end]))")
            offset = end
        }
    }

    private enum WireValue {
        case varint(UInt64)
        case fixed64(UInt64)
        case fixed32(UInt32)
        case blob([UInt8])
    }

    private struct WireField {
        let number: Int
        let value: WireValue
    }

    /// Ordered protobuf walk that keeps every field (ProtoWire.parse drops fixed-width ones
    /// and repeated varints). `clean` is false if it stopped before the end.
    private static func scan(_ data: [UInt8]) -> (fields: [WireField], clean: Bool) {
        var out: [WireField] = []
        var pos = 0

        func readVarint() -> UInt64? {
            var result: UInt64 = 0
            var shift: UInt64 = 0
            while pos < data.count, shift < 64 {
                let byte = data[pos]
                pos += 1
                result |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return result }
                shift += 7
            }
            return nil
        }

        while pos < data.count {
            guard let key = readVarint() else { return (out, false) }
            let number = Int(truncatingIfNeeded: key >> 3)
            guard number > 0, number < 100_000 else { return (out, false) }
            switch key & 0x7 {
            case 0:
                guard let value = readVarint() else { return (out, false) }
                out.append(WireField(number: number, value: .varint(value)))
            case 1:
                guard pos + 8 <= data.count else { return (out, false) }
                var value: UInt64 = 0
                for i in 0..<8 { value |= UInt64(data[pos + i]) << UInt64(i * 8) }
                pos += 8
                out.append(WireField(number: number, value: .fixed64(value)))
            case 2:
                guard let length = readVarint(), length <= UInt64(data.count - pos) else { return (out, false) }
                let end = pos + Int(length)
                out.append(WireField(number: number, value: .blob(Array(data[pos..<end]))))
                pos = end
            case 5:
                guard pos + 4 <= data.count else { return (out, false) }
                var value: UInt32 = 0
                for i in 0..<4 { value |= UInt32(data[pos + i]) << UInt32(i * 8) }
                pos += 4
                out.append(WireField(number: number, value: .fixed32(value)))
            default:
                return (out, false)
            }
        }
        return (out, true)
    }

    /// One-line summary of a message, e.g. `1=L57 2=v1 3=v79 7="text" 9=x00ff`
    /// (v varint, q fixed64, d fixed32, L length of a nested blob, x short raw bytes).
    private static func summarize(_ data: [UInt8]) -> String {
        let result = scan(data)
        var parts: [String] = []
        for item in result.fields.prefix(40) {
            switch item.value {
            case .varint(let v):
                parts.append("\(item.number)=v\(v)")
            case .fixed64(let v):
                parts.append("\(item.number)=q\(v)")
            case .fixed32(let v):
                parts.append("\(item.number)=d\(v)")
            case .blob(let bytes):
                if !bytes.isEmpty, bytes.count <= 24, bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) {
                    let text = String(decoding: bytes, as: UTF8.self)
                    parts.append("\(item.number)=\"\(text)\"")
                } else if bytes.count <= 8 {
                    parts.append("\(item.number)=x\(hex(bytes[...]))")
                } else {
                    parts.append("\(item.number)=L\(bytes.count)")
                }
            }
        }
        if result.fields.count > 40 { parts.append("+\(result.fields.count - 40) more") }
        if !result.clean { parts.append("(not clean protobuf)") }
        return parts.joined(separator: " ")
    }

    private static func hex(_ bytes: ArraySlice<UInt8>) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
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
        chargingFieldRaw = 0
        dumpedSnapshot = false
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
