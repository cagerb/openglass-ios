// svc22 clock sync: send the phone's current time to the glasses so capture
// timestamps are accurate.

import Foundation

final class ClockSyncService: @unchecked Sendable {

    static let serviceClockSync = 22

    enum Phase: String {
        case idle    = "Idle"
        case syncing = "Syncing clock..."
        case synced  = "Clock synced"
        case failed  = "Failed"
    }

    private enum MsgType {
        static let syncRequest  = 1
        static let syncResponse = 2
    }

    private(set) var phase: Phase = .idle
    private(set) var failureReason: String = ""
    private(set) var lastSyncTime: Date?

    var log: ((String) -> Void)?

    private(set) var channelID = 0
    private var firstMessage = true

    // MARK: - Sync

    func sync(link: AirShieldLink) {
        channelID = link.openChannel()
        firstMessage = true
        phase = .syncing

        let now = Date()
        let seconds = UInt64(now.timeIntervalSince1970)
        let nanos = UInt64((now.timeIntervalSince1970 - Double(seconds)) * 1_000_000_000)

        // Field 1: nested timestamp {field1: seconds, field2: nanos}
        var tsInner = ProtoWire.field(1, varint: seconds)
        tsInner += ProtoWire.field(2, varint: nanos)
        var payload = ProtoWire.field(1, bytes: tsInner)

        // Field 2: timezone ID
        let tz = TimeZone.current.identifier
        payload += ProtoWire.field(2, bytes: Array(tz.utf8))

        // Field 3: 16-byte request UUID
        let reqUUID = UUID()
        let u = reqUUID.uuid
        let uuidBytes: [UInt8] = [u.0, u.1, u.2, u.3, u.4, u.5, u.6, u.7,
                                   u.8, u.9, u.10, u.11, u.12, u.13, u.14, u.15]
        payload += ProtoWire.field(3, bytes: uuidBytes)

        emit("Sending DeviceInfoRequest: \(seconds)s tz=\(tz)")

        link.sendMessage(
            channelID: channelID,
            serviceID: Self.serviceClockSync,
            messageType: MsgType.syncRequest,
            payload: payload
        )
        firstMessage = false
    }

    // MARK: - Message handler

    func handleMessage(_ message: AirShieldMessage, link: AirShieldLink) {
        let msgType = message.header.messageType

        switch msgType {
        case MsgType.syncResponse:
            phase = .synced
            lastSyncTime = Date()
            emit("Clock sync acknowledged by glasses")

        default:
            emit("Unknown svc22 message type \(msgType)")
        }
    }

    // MARK: - Helpers

    func reset() {
        phase = .idle
        failureReason = ""
        lastSyncTime = nil
    }

    private func emit(_ message: String) {
        log?("[ClockSync] \(message)")
    }
}
