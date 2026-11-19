// svc36 trust exchange: prove we hold the owner key so the glasses unlock their services.

import Foundation
import CryptoKit
@preconcurrency import Security

final class OwnerTrustExchange {

    enum Phase: String {
        case idle                 = "Idle"
        case proving              = "Proving ownership..."
        case waitingForGlassesPush = "Waiting for glasses..."
        case succeeded            = "OWNER VERIFIED"
        case failed               = "Failed"
    }

    struct HandshakeParams {
        let glassesChallenge: [UInt8]    // 16 bytes
        let glassesPubkey: [UInt8]       // 64 bytes
        let ourSeed: [UInt8]             // 32 bytes
        let ourPubkey: [UInt8]           // 64 bytes
    }

    private enum MsgType {
        static let trustProof = 0x1000   // phone → glasses, also success status
        static let glassesPush = 0x1001  // glasses → phone
    }

    private enum StatusCode {
        static let success = 0x1000
    }

    private static let endLinkSetupChannel = 0x8001

    private static let p256Order: [UInt8] = [
        0xFF, 0xFF, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0x00,
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0xBC, 0xE6, 0xFA, 0xAD, 0xA7, 0x17, 0x9E, 0x84,
        0xF3, 0xB9, 0xCA, 0xC2, 0xFC, 0x63, 0x25, 0x51,
    ]

    private static let p256HalfOrder: [UInt8] = [
        0x7F, 0xFF, 0xFF, 0xFF, 0x80, 0x00, 0x00, 0x00,
        0x7F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0xDE, 0x73, 0x7D, 0x56, 0xD3, 0x8B, 0xCF, 0x42,
        0x79, 0xDC, 0xE5, 0x61, 0x7E, 0x31, 0x92, 0xA8,
    ]

    private(set) var phase: Phase = .idle
    private(set) var failureReason: String = ""
    var log: ((String) -> Void)?

    private var channelID = 0
    private var phoneToGlassesVerified = false
    private var glassesToPhoneVerified = false

    // MARK: - Start

    func start(link: AirShieldLink, params: HandshakeParams, ownerKey: P256.Signing.PrivateKey) {
        let binding = computeBinding(params)
        emit("=== TRUST EXCHANGE STARTING ===")
        emit("Channel binding digest: \(hex(binding))")
        guard let der = sign(binding: binding, ownerKey: ownerKey) else {
            fail("could not sign the channel binding"); return
        }
        guard let rs = normalize(der: der) else {
            fail("could not normalize the signature"); return
        }
        let ownerKeyHash = AirShieldCrypto.sha256(Array(ownerKey.publicKey.rawRepresentation))
        var payload = ProtoWire.field(1, bytes: ownerKeyHash)
        payload += ProtoWire.field(2, bytes: rs)
        payload += ProtoWire.field(3, varint: 2)

        channelID = link.openChannel()
        phase = .proving
        emit("Owner key hash: \(hex(ownerKeyHash))")
        emit("Sending TRUST_PROOF (0x1000) on channel \(String(format: "0x%04x", channelID))")
        link.sendMessage(
            channelID: channelID,
            serviceID: AirShieldLink.serviceIdentity,
            messageType: MsgType.trustProof,
            payload: payload
        )
    }

    // MARK: - Message handler

    func handleMessage(_ message: AirShieldMessage, link: AirShieldLink) {
        let header = message.header

        if header.hasError {
            if header.errorID == StatusCode.success {
                emit("Glasses accepted our proof (status 0x1000) — phone→glasses verified")
                phoneToGlassesVerified = true
                checkCompletion(link: link)
            } else {
                let code = String(format: "0x%04x", header.errorID)
                switch header.errorID {
                case 0x1010: emit("→ KEY_NOT_FOUND: glasses do not know this owner key")
                case 0x1044: emit("→ INVALID_SIGNATURE: the binding signature did not verify")
                default:     emit("→ Trust rejected, error \(code)")
                }
                failureReason = "Error \(code)"
                phase = .failed
                emit("=== TRUST EXCHANGE FAILED ===")
            }
            return
        }

        switch header.messageType {
        case MsgType.glassesPush, MsgType.trustProof:
            let mirror = header.channelID ^ 0x8000
            emit("Glasses pushed their proof (type \(String(format: "0x%04x", header.messageType))) on ch 0x\(String(format: "%04x", header.channelID))")
            link.sendStatus(channelID: mirror, statusCode: StatusCode.success)
            emit("Replied status 0x1000 on mirror 0x\(String(format: "%04x", mirror)) — glasses→phone verified")
            glassesToPhoneVerified = true
            checkCompletion(link: link)
        default:
            emit("Unexpected svc36 type \(String(format: "0x%04x", header.messageType))")
        }
    }

    private func checkCompletion(link: AirShieldLink) {
        guard phase != .failed, phase != .succeeded else { return }
        if phoneToGlassesVerified && glassesToPhoneVerified {
            phase = .succeeded
            emit("✅ BOTH DIRECTIONS VERIFIED")
            sendEndLinkSetup(link)
            emit("=== OWNER VERIFIED — services unlocked ===")
        } else if phoneToGlassesVerified {
            phase = .waitingForGlassesPush
        }
    }

    private func sendEndLinkSetup(_ link: AirShieldLink) {
        let streamUUID = Self.uuidV4Bytes()
        let linkUUID = Self.uuidV4Bytes()

        var payload = ProtoWire.field(1, varint: 1)        // MAIN
        payload += ProtoWire.field(2, bytes: streamUUID)    // stream UUID (RFC 4122 v4)
        payload += ProtoWire.field(3, bytes: linkUUID)      // link UUID (RFC 4122 v4)

        emit("Sending EndLinkSetup on 0x8001: MAIN, stream=\(hex(streamUUID)) link=\(hex(linkUUID))")
        link.sendMessage(
            channelID: Self.endLinkSetupChannel,
            serviceID: nil,
            messageType: 0x1000,
            payload: payload
        )
    }

    private static func uuidV4Bytes() -> [UInt8] {
        let uuid = UUID()
        let u = uuid.uuid
        return [u.0, u.1, u.2, u.3, u.4, u.5, u.6, u.7,
                u.8, u.9, u.10, u.11, u.12, u.13, u.14, u.15]
    }

    // MARK: - Crypto

    private func computeBinding(_ params: HandshakeParams) -> [UInt8] {
        let inner1 = AirShieldCrypto.sha256(params.glassesChallenge, params.glassesPubkey)
        let inner2 = AirShieldCrypto.sha256(params.ourSeed, params.ourPubkey)
        return AirShieldCrypto.sha256(inner1, inner2)
    }

    // Sign the 32-byte binding WITHOUT re-hashing: SecKey's DigestX962 variant takes a
    // pre-hashed digest. CryptoKit's signature(for:) would SHA-256 it again, which is wrong.
    private func sign(binding: [UInt8], ownerKey: P256.Signing.PrivateKey) -> [UInt8]? {
        let x963Private = ownerKey.x963Representation   // 0x04 || X(32) || Y(32) || D(32)
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits as String: 256,
        ]
        var error: Unmanaged<CFError>?
        guard let secKey = SecKeyCreateWithData(Data(x963Private) as CFData, attributes as CFDictionary, &error) else {
            emit("SecKeyCreateWithData failed: \(describe(error))")
            return nil
        }
        guard let der = SecKeyCreateSignature(secKey, .ecdsaSignatureDigestX962SHA256, Data(binding) as CFData, &error) else {
            emit("SecKeyCreateSignature failed: \(describe(error))")
            return nil
        }
        return Array(der as Data)
    }

    // DER: 0x30 len 0x02 rlen r 0x02 slen s → normalized 64-byte r || s, low-S.
    private func normalize(der: [UInt8]) -> [UInt8]? {
        var i = 0
        guard der.count > 2, der[i] == 0x30 else { return nil }
        i += 2                                   // SEQUENCE tag + total length (P-256 fits in one byte)
        guard i < der.count, der[i] == 0x02 else { return nil }
        i += 1
        guard i < der.count else { return nil }
        let rLen = Int(der[i]); i += 1
        guard i + rLen <= der.count else { return nil }
        let r = Array(der[i..<i + rLen]); i += rLen
        guard i < der.count, der[i] == 0x02 else { return nil }
        i += 1
        guard i < der.count else { return nil }
        let sLen = Int(der[i]); i += 1
        guard i + sLen <= der.count else { return nil }
        let s = Array(der[i..<i + sLen])
        let r32 = to32(r)
        var s32 = to32(s)
        if compareBE(s32, Self.p256HalfOrder) > 0 {
            s32 = subBE(Self.p256Order, s32)       // low-S: s = n - s
        }
        return r32 + s32
    }

    private func to32(_ bytes: [UInt8]) -> [UInt8] {
        var b = bytes
        while b.count > 32, b.first == 0 { b.removeFirst() }   // strip DER sign-bit zero
        while b.count < 32 { b.insert(0, at: 0) }
        return b
    }

    private func compareBE(_ a: [UInt8], _ b: [UInt8]) -> Int {
        for (x, y) in zip(a, b) where x != y { return x < y ? -1 : 1 }
        return 0
    }

    private func subBE(_ a: [UInt8], _ b: [UInt8]) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: 32)
        var borrow = 0
        for idx in stride(from: 31, through: 0, by: -1) {
            let diff = Int(a[idx]) - Int(b[idx]) - borrow
            if diff < 0 { result[idx] = UInt8(diff + 256); borrow = 1 }
            else { result[idx] = UInt8(diff); borrow = 0 }
        }
        return result
    }

    // MARK: - Helpers

    private func fail(_ reason: String) {
        failureReason = reason
        phase = .failed
        emit("FAILED: \(reason)")
    }

    private func describe(_ error: Unmanaged<CFError>?) -> String {
        guard let error else { return "unknown error" }
        return CFErrorCopyDescription(error.takeRetainedValue()) as String? ?? "unknown error"
    }

    private func emit(_ message: String) {
        log?("[Trust] \(message)")
    }

    private func hex(_ bytes: [UInt8], limit: Int = 32) -> String {
        let shown = bytes.prefix(limit).map { String(format: "%02x", $0) }.joined()
        return bytes.count > limit ? "\(shown)...(\(bytes.count)B)" : shown
    }
}
