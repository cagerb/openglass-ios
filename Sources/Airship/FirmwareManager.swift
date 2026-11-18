// svc29 Firmware: manages OTA update sessions and delivers firmware via Airship.
// Flow: type 2000 (start session) → type 1 (install) → wait type 4 (ready) →
//       Airship "ota" send → wait type 7 (installed) → type 8 (feature change) → wait type 9

import Foundation

final class FirmwareManager {

    enum Phase: String {
        case idle               = "Idle"
        case startingSession    = "Starting session..."
        case installing         = "Sending install..."
        case waitingReady       = "Waiting for ready..."
        case transferring       = "Transferring firmware..."
        case waitingInstalled   = "Installing on glasses..."
        case enabling           = "Enabling..."
        case succeeded          = "Firmware updated"
        case failed             = "Failed"
    }

    static let serviceFirmware = 29

    private enum MsgType {
        static let otaUpdateInstall = 1
        static let ready            = 4
        static let installed        = 7
        static let featureChange    = 8
        static let featureRunning   = 9
        static let startSession     = 2000
    }

    private(set) var phase: Phase = .idle
    private(set) var failureReason: String = ""
    private(set) var transferProgress: Double = 0
    var log: ((String) -> Void)?

    private var channelID: Int = 0
    private var requestUUID: [UInt8] = []
    private var firmwareData: [UInt8] = []
    private var firmwareName: String = ""
    private var firmwareVersion: String = ""
    private weak var link: AirShieldLink?
    private var airshipSender: AirshipSender?

    // MARK: - Start firmware update

    func startUpdate(
        link: AirShieldLink,
        firmwareZIP: [UInt8],
        name: String = "firmware",
        version: String = "0"
    ) {
        self.link = link
        self.firmwareData = firmwareZIP
        self.firmwareName = name
        self.firmwareVersion = version
        self.requestUUID = Array(UUID().uuid).prefix(16).map { $0 }

        channelID = link.openChannel()
        phase = .startingSession
        emit("Starting firmware session (\(firmwareZIP.count) bytes)")

        // Type 2000: start update session
        let payload = ProtoWire.field(1, bytes: Array("ota".utf8))
        link.sendMessage(
            channelID: channelID,
            serviceID: Self.serviceFirmware,
            messageType: MsgType.startSession,
            payload: payload
        )
    }

    // MARK: - Message handler

    func handleMessage(_ message: AirShieldMessage, link: AirShieldLink) {
        let header = message.header

        if header.hasError {
            if header.errorID == 12 {
                emit("Session already started (error 12), continuing")
                sendInstall(link: link)
            } else {
                fail("Firmware error \(String(format: "0x%04x", header.errorID))")
            }
            return
        }

        switch header.messageType {
        case MsgType.startSession:
            emit("Session started")
            sendInstall(link: link)

        case MsgType.ready:
            emit("Glasses ready for firmware file")
            phase = .transferring
            startTransfer(link: link)

        case MsgType.installed:
            emit("Firmware installed on glasses")
            phase = .enabling
            sendFeatureChange(link: link)

        case MsgType.featureRunning:
            phase = .succeeded
            emit("Firmware update complete — feature running")

        default:
            emit("Unexpected svc29 type \(header.messageType)")
        }
    }

    // MARK: - Protocol steps

    private func sendInstall(link: AirShieldLink) {
        phase = .installing
        // Type 1: OtaUpdateInstall
        var payload = ProtoWire.field(1, bytes: Array(firmwareName.utf8))
        payload += ProtoWire.field(2, bytes: Array(firmwareVersion.utf8))
        payload += ProtoWire.field(3, bytes: requestUUID) // artifactId / request UUID
        payload += ProtoWire.field(4, varint: 1) // resource-only flag
        link.sendMessage(
            channelID: channelID,
            serviceID: nil,
            messageType: MsgType.otaUpdateInstall,
            payload: payload
        )
        phase = .waitingReady
        emit("Sent install request, waiting for ready")
    }

    private func startTransfer(link: AirShieldLink) {
        let sender = AirshipSender()
        sender.log = log
        sender.onComplete = { [weak self] in
            guard let self else { return }
            self.phase = .waitingInstalled
            self.emit("Firmware transfer complete, waiting for install confirmation")
        }
        self.airshipSender = sender

        sender.start(
            link: link,
            data: firmwareData,
            uuid: requestUUID,
            namespace: "ota",
            basename: "\(firmwareName).zip"
        )
    }

    private func sendFeatureChange(link: AirShieldLink) {
        // Type 8: FEATURE_CHANGE — enable the installed feature
        var payload = ProtoWire.field(1, varint: 1) // app 1
        payload += ProtoWire.field(2, bytes: Array(firmwareName.utf8))
        payload += ProtoWire.field(3, varint: 1) // ENABLE
        link.sendMessage(
            channelID: channelID,
            serviceID: nil,
            messageType: MsgType.featureChange,
            payload: payload
        )
        emit("Sent feature change (enable), waiting for confirmation")
    }

    func handleAirshipMessage(_ message: AirShieldMessage) {
        airshipSender?.handleMessage(message)
        transferProgress = airshipSender?.progress ?? 0
    }

    // MARK: - Helpers

    func cancel() {
        airshipSender?.cancel()
        phase = .failed
        failureReason = "Cancelled"
    }

    private func fail(_ reason: String) {
        failureReason = reason
        phase = .failed
        emit("FAILED: \(reason)")
    }

    private func emit(_ message: String) {
        log?("[Firmware] \(message)")
    }
}
