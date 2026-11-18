// svc19 MobileConfig: push feature flag tables to the glasses.
// The sync flow is glasses-initiated (they send REQUEST_MC_UPDATE),
// but we can also push proactively after trust is established.

import Foundation

final class MobileConfigManager {

    enum Phase: String {
        case idle               = "Idle"
        case waitingForRequest  = "Waiting for glasses..."
        case syncing            = "Syncing config..."
        case delivering         = "Delivering tables..."
        case succeeded          = "Config delivered"
        case failed             = "Failed"
    }

    static let serviceMobileConfig = 19

    private enum MsgType {
        static let syncRequest       = 1   // phone → glasses
        static let status            = 2   // glasses → phone
        static let requestMCUpdate   = 3   // glasses → phone
    }

    private(set) var phase: Phase = .idle
    private(set) var failureReason: String = ""
    var log: ((String) -> Void)?
    var onDeliveryNeeded: ((_ sessionID: String) -> Void)?

    private var channelID: Int = 0
    private var sessionID: String = ""
    private weak var link: AirShieldLink?
    private var airshipSender: AirshipSender?

    // MARK: - Start listening

    func startListening(link: AirShieldLink) {
        self.link = link
        phase = .waitingForRequest
        emit("Listening for MobileConfig sync requests")
    }

    // MARK: - Push config proactively

    func pushConfig(
        link: AirShieldLink,
        sessionlessTable: [UInt8],
        paramsTable: [UInt8]
    ) {
        self.link = link
        sessionID = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        channelID = link.openChannel()

        emit("Proactive config push, session \(sessionID)")

        // Send SyncRequest (type 1) to initiate
        var payload = ProtoWire.field(1, bytes: Array(sessionID.utf8))
        payload += ProtoWire.field(2, varint: 1) // format = 1
        link.sendMessage(
            channelID: channelID,
            serviceID: Self.serviceMobileConfig,
            messageType: MsgType.syncRequest,
            payload: payload
        )

        phase = .delivering
        deliverTables(link: link, sessionlessTable: sessionlessTable, paramsTable: paramsTable)
    }

    // MARK: - Message handler

    func handleMessage(_ message: AirShieldMessage, link: AirShieldLink) {
        let header = message.header

        switch header.messageType {
        case MsgType.requestMCUpdate:
            emit("Glasses requested MobileConfig update")
            self.link = link
            sessionID = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
            channelID = header.channelID

            // Reply with SyncRequest
            var payload = ProtoWire.field(1, bytes: Array(sessionID.utf8))
            payload += ProtoWire.field(2, varint: 1)
            link.sendMessage(
                channelID: channelID,
                serviceID: nil,
                messageType: MsgType.syncRequest,
                payload: payload
            )
            phase = .syncing
            onDeliveryNeeded?(sessionID)

        case MsgType.status:
            let fields = ProtoWire.parse(message.payload)
            let statusCode = fields.varint(1)
            if statusCode == 0 {
                phase = .succeeded
                emit("Glasses accepted MobileConfig tables")
            } else {
                phase = .failed
                failureReason = "Status \(statusCode)"
                emit("MobileConfig rejected, status \(statusCode)")
            }

        default:
            emit("Unexpected svc19 type \(header.messageType)")
        }
    }

    // MARK: - Deliver tables via Airship

    func deliverTables(
        link: AirShieldLink,
        sessionlessTable: [UInt8],
        paramsTable: [UInt8]
    ) {
        let (zipData, filename) = MobileConfigBuilder.buildConfigZIP(
            sessionID: sessionID,
            sessionlessTable: sessionlessTable,
            paramsTable: paramsTable
        )

        emit("Sending config ZIP: \(filename) (\(zipData.count) bytes)")

        let sender = AirshipSender()
        sender.log = log
        sender.onComplete = { [weak self] in
            self?.emit("Config ZIP delivered, waiting for status")
        }
        self.airshipSender = sender

        let id = UUID()
        let uuid = withUnsafeBytes(of: id.uuid) { Array($0) }
        sender.start(
            link: link,
            data: zipData,
            uuid: uuid,
            namespace: "mobileconfig",
            basename: filename
        )
    }

    func handleAirshipMessage(_ message: AirShieldMessage) {
        airshipSender?.handleMessage(message)
    }

    // MARK: - Helpers

    private func emit(_ message: String) {
        log?("[MobileConfig] \(message)")
    }
}
