// svc100 peer_build_info: announce the phone to the glasses so they know
// what companion is connected. Must be sent BEFORE svc28 subscribe.

import Foundation

final class PeerBuildInfoService: @unchecked Sendable {

    static let servicePeerBuildInfo = 100

    private enum MsgType {
        static let peerAppInfo = 1   // phone → glasses, empty
        static let deviceInfo  = 3   // glasses → phone
    }

    var log: ((String) -> Void)?

    private(set) var channelID = 0
    private var firstMessage = true

    private(set) var glassesBuildFingerprint: String?
    private(set) var glassesSerial: String?
    private(set) var glassesModel: String?

    // MARK: - Announce

    func announce(link: AirShieldLink) {
        channelID = link.openChannel()
        firstMessage = true
        emit("Sending PeerAppInfo (svc100 type 1, empty)")

        link.sendMessage(
            channelID: channelID,
            serviceID: Self.servicePeerBuildInfo,
            messageType: MsgType.peerAppInfo,
            payload: []
        )
        firstMessage = false
    }

    // MARK: - Message handler

    func handleMessage(_ message: AirShieldMessage, link: AirShieldLink) {
        if message.header.hasError {
            let code = message.header.errorID
            emit("Error 0x\(String(format: "%04x", code))")
            return
        }

        switch message.header.messageType {
        case MsgType.deviceInfo:
            parseDeviceInfo(message.payload)
        default:
            emit("Unknown svc100 type \(message.header.messageType)")
        }
    }

    private func parseDeviceInfo(_ payload: [UInt8]) {
        let fields = ProtoWire.parse(payload)
        // ISO-8859-1 strings
        glassesBuildFingerprint = String(bytes: fields.bytes(1), encoding: .isoLatin1)
        glassesSerial = String(bytes: fields.bytes(2), encoding: .isoLatin1)
        glassesModel = String(bytes: fields.bytes(8), encoding: .isoLatin1)
        emit("DeviceInfo: model=\(glassesModel ?? "?") serial=\(glassesSerial ?? "?") build=\(glassesBuildFingerprint?.prefix(40) ?? "?")")
    }

    private func emit(_ message: String) {
        log?("[PeerBuildInfo] \(message)")
    }
}
