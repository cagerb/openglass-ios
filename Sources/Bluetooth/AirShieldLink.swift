import Foundation
import CryptoKit
import CommonCrypto

// AirShield + DataX: the link protocol of Ray-Ban Meta ("RB Meta ...") glasses.
//
// These glasses have no writable GATT characteristic. The FD5F service only publishes
// the PSM of an LE L2CAP channel (characteristic 05ACBE9F-...); everything else runs
// over that channel:
//
//   1. Link setup, in the clear, as bare DataX messages:
//        RequestEncryption (type 1)  P-256 public key, 16-byte challenge, parameters
//        EnableEncryption  (type 2)  P-256 public key, 32-byte seed, 16-byte IV, seq base
//      Both sides send both messages.
//   2. Keys, one set per direction, from the raw ECDH secret:
//        aes  = HKDF-SHA256(ikm: secret, salt: SHA256(challenge || seed), info: "AirShield")
//        hmac = HKDF-SHA256(ikm: secret, salt: SHA256(seed || challenge || "hmac_derive"), info: "AirShield")
//      TX uses the peer's challenge and our seed; RX uses our challenge and the peer's seed.
//   3. After that every frame is [0x40 | stream][8-byte tag][block count - 1][AES-256-CBC],
//      with tag = HMAC-SHA256(02 02 00 quirks || LE32(seq) || count || ciphertext)[0..<8].
//      The CBC IV chains from the last ciphertext block; seq goes up by one per frame.
//   4. Inside is DataX: a 4-byte header (length, channel) plus 4-byte tags naming the
//      service and message type, then a protobuf payload.
//
// Protocol facts come from public reverse-engineering work: zhuowei's SimStella and
// Starcruiser, and the Visor project's protocol notes (visor.macedonga.com/protocol).
// The key schedule here reproduces Starcruiser's published test vectors.
//
// What this file does NOT do: the svc36 trust exchange. The glasses only open their
// real services to the holder of the owner key (a P-256 key installed through Meta's
// signed ownership receipts), and OpenGlass has no such key yet.

// MARK: - Protobuf (the few wire types link setup needs)

enum ProtoWire {

    static func varint(_ value: UInt64) -> [UInt8] {
        var v = value
        var out: [UInt8] = []
        while v >= 0x80 {
            out.append(UInt8(v & 0x7F) | 0x80)
            v >>= 7
        }
        out.append(UInt8(v))
        return out
    }

    static func field(_ number: Int, varint value: UInt64) -> [UInt8] {
        varint(UInt64(number << 3)) + varint(value)
    }

    static func field(_ number: Int, bytes: [UInt8]) -> [UInt8] {
        varint(UInt64(number << 3 | 2)) + varint(UInt64(bytes.count)) + bytes
    }

    struct Fields {
        var varints: [Int: UInt64] = [:]
        var blobs: [Int: [[UInt8]]] = [:]

        func bytes(_ number: Int) -> [UInt8] { blobs[number]?.first ?? [] }
        func varint(_ number: Int) -> UInt64 { varints[number] ?? 0 }
        func has(_ number: Int) -> Bool { varints[number] != nil || blobs[number] != nil }
    }

    /// Lenient parse: stops at the first thing it cannot read and returns what it has.
    static func parse(_ data: [UInt8]) -> Fields {
        var fields = Fields()
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
            guard let key = readVarint() else { break }
            let number = Int(key >> 3)
            switch key & 0x7 {
            case 0:
                guard let value = readVarint() else { return fields }
                fields.varints[number] = value
            case 1:
                guard pos + 8 <= data.count else { return fields }
                pos += 8
            case 2:
                guard let length = readVarint(), length <= UInt64(data.count - pos) else { return fields }
                let end = pos + Int(length)
                fields.blobs[number, default: []].append(Array(data[pos..<end]))
                pos = end
            case 5:
                guard pos + 4 <= data.count else { return fields }
                pos += 4
            default:
                return fields
            }
        }
        return fields
    }
}

// MARK: - DataX header

/// A DataX message header: 4 fixed bytes, then optional 4-byte tags.
struct DataXHeader {
    var payloadLength = 0      // 14 bits; counts the tags too
    var channelID = 0
    var serviceID = 0
    var messageType = 0
    var errorID = 0
    var hasType = false
    var hasError = false
    var isClosed = false
    var headerLength = 4

    /// Bytes the whole message takes on the wire. Always 4 + length, never headerLength + length.
    var wireTotal: Int { 4 + payloadLength }

    static let maxPayload = 16383

    private static let tagService = 1
    private static let tagMessageType = 2
    private static let tagError = 3
    private static let tagMessageTypeClosed = 4

    static func parse(_ buf: [UInt8]) -> DataXHeader? {
        guard buf.count >= 4 else { return nil }
        var header = DataXHeader()
        header.payloadLength = (Int(buf[0] & 0x3F) << 8) | Int(buf[1])
        header.channelID = (Int(buf[2]) << 8) | Int(buf[3])

        if buf[0] & 0x80 != 0 {
            var offset = 4
            let available = min(buf.count, 4 + header.payloadLength)
            while offset + 4 <= available {
                let tagByte = buf[offset]
                let value = (Int(buf[offset + 2]) << 8) | Int(buf[offset + 3])
                switch Int(tagByte & 0x7F) {
                case tagService:
                    header.serviceID = value
                    header.hasType = true
                    if value == 0 { header.isClosed = true }
                case tagMessageType:
                    header.messageType = value
                    header.hasType = true
                case tagError:
                    header.errorID = value
                    header.hasError = true
                case tagMessageTypeClosed:
                    header.messageType = value
                    header.isClosed = true
                default:
                    break
                }
                header.headerLength += 4
                offset += 4
                if tagByte & 0x80 == 0 { break }
            }
        }
        return header
    }

    static func build(channelID: Int, dataLength: Int,
                      serviceID: Int? = nil, messageType: Int? = nil, errorID: Int? = nil) -> [UInt8] {
        var tags: [(id: Int, value: Int)] = []
        if let serviceID { tags.append((tagService, serviceID & 0xFFFF)) }
        if let messageType { tags.append((tagMessageType, messageType & 0xFFFF)) }
        if let errorID { tags.append((tagError, errorID & 0xFFFF)) }

        let payloadLength = tags.count * 4 + dataLength
        var out: [UInt8] = [
            UInt8((tags.isEmpty ? 0 : 0x80) | ((payloadLength >> 8) & 0x3F)),
            UInt8(payloadLength & 0xFF),
            UInt8((channelID >> 8) & 0xFF),
            UInt8(channelID & 0xFF),
        ]
        for (index, tag) in tags.enumerated() {
            // Continuation bit on all but the last tag; the second byte stays 0.
            let continuation = index < tags.count - 1 ? 0x80 : 0
            out.append(UInt8(continuation | (tag.id & 0x7F)))
            out.append(0)
            out.append(UInt8((tag.value >> 8) & 0xFF))
            out.append(UInt8(tag.value & 0xFF))
        }
        return out
    }
}

/// One decoded DataX message.
struct AirShieldMessage {
    let header: DataXHeader
    let payload: [UInt8]
}

// MARK: - Crypto

enum AirShieldCrypto {

    static let block = 16
    static let tagSize = 8
    /// Modified PKCS#7: each pad byte is the pad length plus 0xC0.
    static let padOffset = 0xC0
    /// EncryptionParameters bit 2: a separate HMAC key.
    static let multikeyFlag = 4
    /// QuirksMode 1 (QCS7): a different HKDF info and MAC prefix.
    static let quirksQCS7 = 1

    struct DirectionKeys {
        let aes: [UInt8]
        let hmac: [UInt8]
        let iv: [UInt8]
    }

    static func sha256(_ parts: [UInt8]...) -> [UInt8] {
        var hasher = SHA256()
        for part in parts { hasher.update(data: part) }
        return Array(hasher.finalize())
    }

    static func hmacSHA256(key: [UInt8], data: [UInt8]) -> [UInt8] {
        Array(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }

    private static func hkdf(secret: [UInt8], salt: [UInt8], info: [UInt8]) -> [UInt8] {
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: secret),
            salt: salt,
            info: info,
            outputByteCount: 32
        )
        return key.withUnsafeBytes { Array($0) }
    }

    static func deriveKeys(secret: [UInt8], challenge: [UInt8], seed: [UInt8], iv: [UInt8],
                           multikey: Bool, quirks: Int) -> DirectionKeys {
        var info = Array("AirShield".utf8)
        if quirks == quirksQCS7 {
            // "AirShield" in a 128-byte label, then LE32(32) and LE32(256).
            info += [UInt8](repeating: 0, count: 128 - info.count)
            info += [32, 0, 0, 0, 0, 1, 0, 0]
        }
        let aes = hkdf(secret: secret, salt: sha256(challenge, seed), info: info)
        guard multikey else { return DirectionKeys(aes: aes, hmac: aes, iv: iv) }
        let hmac = hkdf(secret: secret, salt: sha256(seed, challenge, Array("hmac_derive".utf8)), info: info)
        return DirectionKeys(aes: aes, hmac: hmac, iv: iv)
    }

    static func aesCBC(key: [UInt8], iv: [UInt8], data: [UInt8], encrypt: Bool) -> [UInt8]? {
        guard key.count == kCCKeySizeAES256, iv.count == block,
              !data.isEmpty, data.count % block == 0 else { return nil }
        var out = [UInt8](repeating: 0, count: data.count + block)
        var moved = 0
        let status = CCCrypt(
            CCOperation(encrypt ? kCCEncrypt : kCCDecrypt),
            CCAlgorithm(kCCAlgorithmAES),
            CCOptions(0),
            key, key.count,
            iv,
            data, data.count,
            &out, out.count,
            &moved
        )
        guard status == CCCryptorStatus(kCCSuccess) else { return nil }
        return Array(out.prefix(moved))
    }

    /// An aligned input still gets a whole block, so there is always a pad.
    static func pad(_ data: [UInt8]) -> [UInt8] {
        let padLength = block - (data.count % block)
        return data + [UInt8](repeating: UInt8(padLength + padOffset), count: padLength)
    }

    /// Removes the pad `pad` adds; data that does not end in one comes back whole.
    static func stripPad(_ data: [UInt8]) -> [UInt8] {
        guard let last = data.last else { return data }
        let padLength = Int(last) - padOffset
        guard padLength >= 1, padLength <= block, padLength <= data.count else { return data }
        guard data.suffix(padLength).allSatisfy({ $0 == last }) else { return data }
        return Array(data.dropLast(padLength))
    }

    static func le32(_ value: UInt32) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF)]
    }
}

/// One direction's cipher over AirShield DATA frame bodies (the bytes after the 0x40 byte).
struct AirShieldFrameCipher {

    enum Failure: Error {
        case tooShort
        case lengthMismatch
        case badTag
        case cipher
    }

    private let aesKey: [UInt8]
    private let hmacKey: [UInt8]
    private var iv: [UInt8]
    private var seq: UInt32
    private let macPrefix: [UInt8]

    init(keys: AirShieldCrypto.DirectionKeys, seq: UInt32, quirks: Int) {
        aesKey = keys.aes
        hmacKey = keys.hmac
        iv = keys.iv
        self.seq = seq
        macPrefix = [0x02, 0x02, 0x00, UInt8(quirks & 0xFF)]
    }

    private func tag(blockCount: UInt8, ciphertext: [UInt8]) -> [UInt8] {
        let input = macPrefix + AirShieldCrypto.le32(seq) + [blockCount] + ciphertext
        return Array(AirShieldCrypto.hmacSHA256(key: hmacKey, data: input).prefix(AirShieldCrypto.tagSize))
    }

    mutating func seal(_ plaintext: [UInt8]) throws -> [UInt8] {
        guard let ciphertext = AirShieldCrypto.aesCBC(
            key: aesKey, iv: iv, data: AirShieldCrypto.pad(plaintext), encrypt: true
        ) else { throw Failure.cipher }
        let blocks = ciphertext.count / AirShieldCrypto.block - 1
        guard blocks >= 0, blocks <= 0xFF else { throw Failure.lengthMismatch }
        let frame = tag(blockCount: UInt8(blocks), ciphertext: ciphertext) + [UInt8(blocks)] + ciphertext
        iv = Array(ciphertext.suffix(AirShieldCrypto.block))
        seq &+= 1
        return frame
    }

    /// Verifies and decrypts one frame body. The pad is left on.
    mutating func unseal(_ body: [UInt8]) throws -> [UInt8] {
        let headSize = AirShieldCrypto.tagSize + 1
        guard body.count >= headSize + AirShieldCrypto.block else { throw Failure.tooShort }
        let theirTag = Array(body[0..<AirShieldCrypto.tagSize])
        let blockCount = body[AirShieldCrypto.tagSize]
        let ciphertext = Array(body[headSize...])
        guard ciphertext.count == (Int(blockCount) + 1) * AirShieldCrypto.block else { throw Failure.lengthMismatch }
        guard theirTag == tag(blockCount: blockCount, ciphertext: ciphertext) else { throw Failure.badTag }
        guard let plaintext = AirShieldCrypto.aesCBC(key: aesKey, iv: iv, data: ciphertext, encrypt: false) else {
            throw Failure.cipher
        }
        iv = Array(ciphertext.suffix(AirShieldCrypto.block))
        seq &+= 1
        return plaintext
    }
}

// MARK: - The link

/// AirShield handshake + encrypted DataX over a byte pipe (the L2CAP channel).
///
/// Not thread-safe: feed it and call it from one queue. It does no I/O of its own;
/// outgoing bytes leave through `send`, incoming bytes arrive through `feed`.
final class AirShieldLink: @unchecked Sendable {

    enum Phase: String {
        case idle
        case handshaking
        case secure
        case failed
    }

    // DataX ids.
    static let serviceLinkSetup = 5
    static let serviceIdentity = 36
    static let typeRequestEncryption = 1
    static let typeEnableEncryption = 2
    static let typeIdentityRequest = 0x3000
    static let typeIdentityResponse = 0x3001
    /// RequestEncryption rides the secure variant of channel 1; EnableEncryption plain channel 1.
    static let linkSetupChannel = 0x8001
    static let enableChannel = 0x0001
    /// What both of our link setup messages announce.
    static let ourParameters = 31
    static let ourAirshieldVersion = 16

    private static let frameData: UInt8 = 0x40
    private static let frameCommand: UInt8 = 0x80
    private static let frameTypeMask: UInt8 = 0xC0
    private static let streamMask: UInt8 = 0x3F
    /// The most plaintext one frame holds: 256 blocks less at least one pad byte.
    private static let framePlaintextLimit = 256 * 16 - 1
    private static let inboundLimit = 1 << 20

    var send: (([UInt8]) -> Void)?
    var log: ((String) -> Void)?
    /// Called once, when both directions' ciphers are installed.
    var onSecure: (() -> Void)?
    var onMessage: ((AirShieldMessage) -> Void)?
    var onFailure: ((String) -> Void)?

    private(set) var phase: Phase = .idle

    let privateKey = P256.KeyAgreement.PrivateKey()
    let myChallenge = AirShieldLink.randomBytes(16)
    let mySeed = AirShieldLink.randomBytes(32)
    private let myIV = AirShieldLink.randomBytes(16)
    private let mySeq = UInt32.random(in: 0...UInt32.max)

    struct PeerRequest {
        let publicKey: [UInt8]
        let challenge: [UInt8]
        let supportedParameters: Int
        let quirks: Int
        let airshieldVersion: Int
        let keyHints: Int
    }

    struct PeerEnable {
        let publicKey: [UInt8]
        let seed: [UInt8]
        let iv: [UInt8]
        let base: UInt32
        let parameters: Int
        let quirks: Int
    }

    private(set) var peerRequest: PeerRequest?
    private(set) var peerEnable: PeerEnable?
    private var txCipher: AirShieldFrameCipher?
    private var rxCipher: AirShieldFrameCipher?

    private var inbound: [UInt8] = []
    /// DATA frames that arrived before the handshake finished.
    private var earlyFrames: [[UInt8]] = []
    /// The DataX stream after the last whole message.
    private var carry: [UInt8] = []
    private var lastTypeByChannel: [Int: Int] = [:]
    /// 0x8001 is link setup, so our own channels start at 2.
    private var nextChannel = 2

    // MARK: Start

    /// Send our two link setup messages. The glasses answer with their own pair.
    func start() {
        guard phase == .idle else { return }
        phase = .handshaking
        let publicKey = Array(privateKey.publicKey.rawRepresentation)   // 64 bytes, x || y

        var request = ProtoWire.field(1, bytes: publicKey)
        request += ProtoWire.field(2, bytes: myChallenge)
        request += ProtoWire.field(3, varint: 0)                         // curve: P-256
        request += ProtoWire.field(4, varint: UInt64(Self.ourParameters))
        request += ProtoWire.field(7, varint: UInt64(Self.ourAirshieldVersion))
        let requestSDU = DataXHeader.build(
            channelID: Self.linkSetupChannel, dataLength: request.count,
            serviceID: Self.serviceLinkSetup, messageType: Self.typeRequestEncryption
        ) + request
        log?("AirShield TX RequestEncryption (\(requestSDU.count) bytes) \(Self.hex(requestSDU))")
        send?(requestSDU)

        var enable = ProtoWire.field(1, bytes: publicKey)
        enable += ProtoWire.field(2, bytes: mySeed)
        enable += ProtoWire.field(3, bytes: myIV)
        enable += ProtoWire.field(4, varint: UInt64(mySeq))
        enable += ProtoWire.field(5, varint: UInt64(Self.ourParameters))
        // Only the first message of the exchange carries the service tag.
        let enableSDU = DataXHeader.build(
            channelID: Self.enableChannel, dataLength: enable.count,
            messageType: Self.typeEnableEncryption
        ) + enable
        log?("AirShield TX EnableEncryption (\(enableSDU.count) bytes) \(Self.hex(enableSDU))")
        send?(enableSDU)
    }

    // MARK: Receive

    /// Hand over bytes read from the pipe, in order. Cuts them into SDUs and handles each.
    func feed(_ bytes: [UInt8]) {
        guard phase == .handshaking || phase == .secure else { return }
        inbound += bytes
        guard inbound.count <= Self.inboundLimit else {
            fail("inbound buffer overran; the framing is out of step")
            return
        }
        while phase == .handshaking || phase == .secure {
            // Re-read the phase every time: the cut rule changes once the handshake is done.
            guard let total = Self.sduLength(inbound, secure: phase == .secure),
                  inbound.count >= total else { break }
            let sdu = Array(inbound[0..<total])
            inbound.removeFirst(total)
            if phase == .secure {
                handleSecure(sdu)
            } else {
                handleSetup(sdu)
            }
        }
    }

    /// The total length of the SDU starting at `head`, or nil if `head` is too short to say.
    ///
    /// Bit 7 is a bare DataX message until the handshake is done and a COMMAND frame after it.
    static func sduLength(_ head: [UInt8], secure: Bool) -> Int? {
        guard head.count >= 2 else { return nil }
        let first = head[0]
        if first & 0x80 != 0 {
            if !secure { return 4 + ((Int(first & 0x3F) << 8) | Int(head[1])) }
            if head[1] & 0x80 == 0 { return 2 }                       // short COMMAND
            guard head.count >= 5 else { return nil }
            return 5 + ((Int(head[2]) << 8) | Int(head[3]))            // long COMMAND
        }
        if first & frameTypeMask == 0 { return 3 + Int(head[1]) }      // sub-stream PLAINTEXT
        guard head.count >= 10 else { return nil }
        return 10 + AirShieldCrypto.block * (Int(head[9]) + 1)         // DATA
    }

    private func handleSetup(_ sdu: [UInt8]) {
        guard let first = sdu.first else { return }
        if first & Self.frameTypeMask == Self.frameData {
            earlyFrames.append(sdu)
            log?("AirShield RX early DATA frame (\(sdu.count) bytes), held until the handshake is done")
            return
        }
        guard first & 0x80 != 0, let header = DataXHeader.parse(sdu), header.headerLength <= sdu.count else {
            log?("AirShield RX unexpected setup frame (\(sdu.count) bytes) \(Self.hex(sdu))")
            return
        }
        let payload = Array(sdu[header.headerLength...])
        if header.hasError {
            let code = String(format: "0x%04x", header.errorID)
            log?("AirShield RX setup ERROR \(code) on channel \(Self.hex16(header.channelID))")
            return
        }

        switch header.messageType {
        case Self.typeRequestEncryption:
            let fields = ProtoWire.parse(payload)
            let request = PeerRequest(
                publicKey: fields.bytes(1),
                challenge: fields.bytes(2),
                supportedParameters: Int(truncatingIfNeeded: fields.varint(4)),
                quirks: Int(truncatingIfNeeded: fields.varint(6)),
                airshieldVersion: Int(truncatingIfNeeded: fields.varint(7)),
                keyHints: fields.blobs[5]?.count ?? 0
            )
            peerRequest = request
            log?("AirShield RX RequestEncryption: key=\(request.publicKey.count)B challenge=\(request.challenge.count)B "
                + "params=\(request.supportedParameters) quirks=\(request.quirks) "
                + "version=\(request.airshieldVersion) keyHints=\(request.keyHints)")

        case Self.typeEnableEncryption:
            let fields = ProtoWire.parse(payload)
            let enable = PeerEnable(
                publicKey: fields.bytes(1),
                seed: fields.bytes(2),
                iv: fields.bytes(3),
                base: UInt32(truncatingIfNeeded: fields.varint(4)),
                // Left out, the glasses mean 31.
                parameters: fields.has(5) ? Int(truncatingIfNeeded: fields.varint(5)) : Self.ourParameters,
                quirks: Int(truncatingIfNeeded: fields.varint(6))
            )
            peerEnable = enable
            log?("AirShield RX EnableEncryption: key=\(enable.publicKey.count)B seed=\(enable.seed.count)B "
                + "iv=\(enable.iv.count)B base=\(enable.base) params=\(enable.parameters) quirks=\(enable.quirks)")

        default:
            let type = String(format: "0x%04x", header.messageType)
            log?("AirShield RX setup message type \(type) (\(sdu.count) bytes) \(Self.hex(sdu))")
        }

        if peerRequest != nil && peerEnable != nil {
            finishHandshake()
        }
    }

    private func finishHandshake() {
        guard let request = peerRequest, let enable = peerEnable else { return }
        guard enable.publicKey.count == 64, request.challenge.count == 16,
              enable.seed.count == 32, enable.iv.count == 16 else {
            fail("the glasses' link setup fields have unexpected sizes")
            return
        }

        let secret: [UInt8]
        do {
            let peerKey = try P256.KeyAgreement.PublicKey(rawRepresentation: Data(enable.publicKey))
            let shared = try privateKey.sharedSecretFromKeyAgreement(with: peerKey)
            secret = shared.withUnsafeBytes { Array($0) }
        } catch {
            fail("ECDH with the glasses' key failed: \(error.localizedDescription)")
            return
        }

        // What both ends support is what the link uses.
        let multikey = (Self.ourParameters & request.supportedParameters & enable.parameters
            & AirShieldCrypto.multikeyFlag) != 0
        // Each peer message's quirks pick its direction's HKDF info and MAC prefix.
        let rxKeys = AirShieldCrypto.deriveKeys(
            secret: secret, challenge: myChallenge, seed: enable.seed, iv: enable.iv,
            multikey: multikey, quirks: enable.quirks
        )
        let txKeys = AirShieldCrypto.deriveKeys(
            secret: secret, challenge: request.challenge, seed: mySeed, iv: myIV,
            multikey: multikey, quirks: request.quirks
        )
        rxCipher = AirShieldFrameCipher(keys: rxKeys, seq: enable.base, quirks: enable.quirks)
        txCipher = AirShieldFrameCipher(keys: txKeys, seq: mySeq, quirks: request.quirks)
        phase = .secure
        log?("AirShield handshake done: link encrypted (multikey=\(multikey), \(earlyFrames.count) early frame(s))")

        let held = earlyFrames
        earlyFrames = []
        for frame in held where phase == .secure {
            handleSecure(frame)
        }
        if phase == .secure {
            onSecure?()
        }
    }

    private func handleSecure(_ sdu: [UInt8]) {
        guard let first = sdu.first else { return }
        let type = first & Self.frameTypeMask
        let stream = Int(first & Self.streamMask)

        if stream != 0 {
            log?("AirShield RX frame for relay sub-stream \(stream) (\(sdu.count) bytes), ignored")
            return
        }
        if type == Self.frameCommand {
            let code = sdu.count > 1 ? String(format: "0x%02x", sdu[1]) : "none"
            log?("AirShield RX COMMAND code=\(code) (\(sdu.count) bytes)")
            return
        }
        guard type == Self.frameData else {
            log?("AirShield RX unknown frame (\(sdu.count) bytes) \(Self.hex(sdu))")
            return
        }
        guard var cipher = rxCipher else { return }

        let plaintext: [UInt8]
        do {
            plaintext = try cipher.unseal(Array(sdu.dropFirst()))
        } catch {
            // CBC chaining and the seq make a bad frame unrecoverable.
            fail("could not open an encrypted frame (\(error)); the keys or the framing are wrong")
            return
        }
        rxCipher = cipher

        let stream2 = carry + AirShieldCrypto.stripPad(plaintext)
        var pos = 0
        var messages: [AirShieldMessage] = []
        while stream2.count - pos >= 4 {
            guard let fixed = DataXHeader.parse(Array(stream2[pos..<(pos + 4)])) else { break }
            let total = fixed.wireTotal
            guard stream2.count - pos >= total else { break }
            let whole = Array(stream2[pos..<(pos + total)])
            if var header = DataXHeader.parse(whole), header.headerLength <= total {
                // A message without a type tag takes the channel's last type.
                if header.hasType || header.messageType != 0 {
                    lastTypeByChannel[header.channelID] = header.messageType
                } else if !header.hasError, let cached = lastTypeByChannel[header.channelID] {
                    header.messageType = cached
                }
                messages.append(AirShieldMessage(header: header, payload: Array(whole[header.headerLength...])))
            }
            pos += total
        }
        carry = Array(stream2[pos...])

        for message in messages {
            describe(message)
            onMessage?(message)
        }
    }

    private func describe(_ message: AirShieldMessage) {
        let header = message.header
        var line = "DataX RX ch=\(Self.hex16(header.channelID)) svc=\(header.serviceID) "
            + "type=\(Self.hex16(header.messageType)) payload=\(message.payload.count)B"
        if header.hasError { line += " status=\(Self.hex16(header.errorID))" }
        if header.isClosed { line += " (closed)" }
        if !message.payload.isEmpty { line += " \(Self.hex(message.payload))" }
        log?(line)

        if header.messageType == Self.typeIdentityResponse {
            let fields = ProtoWire.parse(message.payload)
            let serial = String(decoding: fields.bytes(2), as: UTF8.self)
            log?("Glasses identity: serial=\"\(serial)\" certificate=\(fields.bytes(1).count) bytes (DER)")
        }
    }

    // MARK: Send

    /// A new channel id of ours, with the originator bit set.
    func openChannel() -> Int {
        let channel = 0x8000 | nextChannel
        nextChannel += 1
        return channel
    }

    /// Bump the next channel past any channels used during setup to avoid collisions.
    func skipChannels(to minimum: Int) {
        if nextChannel < minimum { nextChannel = minimum }
    }

    /// Send one DataX message, encrypted. Name the service on a channel's first message only.
    @discardableResult
    func sendMessage(channelID: Int, serviceID: Int?, messageType: Int?, payload: [UInt8]) -> Bool {
        guard phase == .secure, var cipher = txCipher else {
            log?("DataX TX refused: the link is not encrypted yet")
            return false
        }
        guard payload.count + 8 <= DataXHeader.maxPayload else {
            log?("DataX TX refused: \(payload.count) bytes is too long for one message")
            return false
        }
        let message = DataXHeader.build(
            channelID: channelID, dataLength: payload.count,
            serviceID: serviceID, messageType: messageType
        ) + payload

        // A message longer than one frame runs on into the next frames.
        var frames: [[UInt8]] = []
        var at = 0
        repeat {
            let end = min(message.count, at + Self.framePlaintextLimit)
            do {
                let sealed = try cipher.seal(Array(message[at..<end]))
                frames.append([Self.frameData] + sealed)
            } catch {
                fail("could not seal a frame (\(error))")
                return false
            }
            at = end
        } while at < message.count
        txCipher = cipher

        let service = serviceID.map { String($0) } ?? "-"
        let type = messageType.map { Self.hex16($0) } ?? "-"
        log?("DataX TX ch=\(Self.hex16(channelID)) svc=\(service) type=\(type) "
            + "payload=\(payload.count)B in \(frames.count) frame(s)")
        for frame in frames { send?(frame) }
        return true
    }

    /// Send raw plaintext through the AirShield encryption layer, bypassing DataX framing.
    /// Returns false if the link is not yet secure.
    func sendRawEncrypted(_ plaintext: [UInt8]) -> Bool {
        guard phase == .secure, var cipher = txCipher else { return false }
        do {
            let sealed = try cipher.seal(plaintext)
            let frame = [Self.frameData] + sealed
            send?(frame)
            txCipher = cipher
            return true
        } catch {
            log?("Raw encrypted send failed: \(error)")
            return false
        }
    }

    /// Send a status frame (error tag) on a channel.
    @discardableResult
    func sendStatus(channelID: Int, statusCode: Int) -> Bool {
        guard phase == .secure, var cipher = txCipher else {
            log?("DataX TX status refused: the link is not encrypted yet")
            return false
        }
        let message = DataXHeader.build(
            channelID: channelID, dataLength: 0, errorID: statusCode
        )
        var frames: [[UInt8]] = []
        do {
            let sealed = try cipher.seal(message)
            frames.append([Self.frameData] + sealed)
        } catch {
            fail("could not seal a status frame (\(error))")
            return false
        }
        txCipher = cipher
        log?("DataX TX status=\(Self.hex16(statusCode)) ch=\(Self.hex16(channelID))")
        for frame in frames { send?(frame) }
        return true
    }

    /// Ask the glasses who they are (svc36 IDENTITY_REQUEST). They answer with their
    /// device certificate and serial before any trust exists, so it proves the cipher works.
    func requestIdentity() {
        sendMessage(
            channelID: openChannel(),
            serviceID: Self.serviceIdentity,
            messageType: Self.typeIdentityRequest,
            payload: []
        )
    }

    // MARK: Helpers

    private func fail(_ reason: String) {
        guard phase != .failed else { return }
        phase = .failed
        log?("AirShield FAILED: \(reason)")
        onFailure?(reason)
    }

    private static func randomBytes(_ count: Int) -> [UInt8] {
        var generator = SystemRandomNumberGenerator()
        return (0..<count).map { _ in UInt8.random(in: 0...255, using: &generator) }
    }

    private static func hex(_ bytes: [UInt8], limit: Int = 48) -> String {
        let shown = bytes.prefix(limit).map { String(format: "%02x", $0) }.joined()
        return bytes.count > limit ? shown + "...(+\(bytes.count - limit))" : shown
    }

    private static func hex16(_ value: Int) -> String {
        String(format: "0x%04x", value)
    }
}
