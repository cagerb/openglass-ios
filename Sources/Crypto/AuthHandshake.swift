import Foundation
@preconcurrency import Security
import CryptoKit
import os

/// Implements the PhaseB authentication handshake with Meta Ray-Ban Stories.
///
/// The handshake consists of four message exchanges over the DataX channel:
///
/// 1. **StartSession** (0x00 → 0x01): Phone sends protocol version and capabilities.
///    Glasses respond with their version and a session nonce.
///
/// 2. **Identity** (0x09 → 0x0A): Phone sends its RSA public key and bootstrap ticket.
///    Glasses respond with an RSA-encrypted blob containing the AES-256 session key.
///
/// 3. **StartChallenge** (0x0D → 0x0E): Phone sends a random challenge.
///    Glasses respond with a challenge encrypted under the new session key.
///
/// 4. **FinishChallenge** (0x05 → 0x06): Phone sends the decrypted challenge proof.
///    Glasses respond with a session ticket for future reconnections.
actor AuthHandshake {

    private let logger = Logger(subsystem: "com.openglass.app", category: "AuthHandshake")

    // MARK: - Dependencies

    private let bluetooth: BluetoothManager
    private let rsaAuth = RSAAuth()
    private let identityStore = IdentityStore()
    private let sessionCrypto: SessionCrypto

    // MARK: - Handshake state

    private var rsaPrivateKey: SecKey?
    private var rsaPublicKey: SecKey?
    private var sessionNonce: Data?
    private var pendingContinuation: CheckedContinuation<Data, Error>?

    enum Phase: Sendable {
        case idle
        case awaitingStartSessionResponse
        case awaitingIdentityResponse
        case awaitingStartChallengeResponse
        case awaitingFinishChallengeResponse
        case completed
        case failed(Error)
    }

    private(set) var phase: Phase = .idle

    // MARK: - Init

    init(bluetooth: BluetoothManager, sessionCrypto: SessionCrypto) {
        self.bluetooth = bluetooth
        self.sessionCrypto = sessionCrypto
    }

    // MARK: - Start handshake

    /// Run the full 4-step PhaseB handshake.
    func performHandshake() async throws {
        phase = .idle
        logger.info("Starting PhaseB authentication handshake")

        // Ensure we have an RSA key pair
        if await identityStore.hasRSAKeyPair() {
            rsaPrivateKey = try await identityStore.loadRSAPrivateKey()
            rsaPublicKey = SecKeyCopyPublicKey(rsaPrivateKey!)
        } else {
            let (priv, pub) = try await rsaAuth.generateKeyPair()
            rsaPrivateKey = priv
            rsaPublicKey = pub
            try await identityStore.saveRSAPrivateKey(priv)
            let pubData = try await rsaAuth.exportPublicKey(pub)
            try await identityStore.saveRSAPublicKeyData(pubData)
            logger.info("Generated and saved new RSA key pair")
        }

        // Step 1: StartSession
        let startSessionResponse = try await sendStartSession()
        try parseStartSessionResponse(startSessionResponse)

        // Step 2: Identity
        let identityResponse = try await sendIdentity()
        let sessionKeyData = try await parseIdentityResponse(identityResponse)
        await sessionCrypto.setSessionKey(sessionKeyData)

        // Step 3: StartChallenge
        let startChallengeResponse = try await sendStartChallenge()
        let challengeProof = try await parseStartChallengeResponse(startChallengeResponse)

        // Step 4: FinishChallenge
        let finishResponse = try await sendFinishChallenge(proof: challengeProof)
        try await parseFinishChallengeResponse(finishResponse)

        phase = .completed
        logger.info("PhaseB handshake completed successfully")
    }

    // MARK: - Step 1: StartSession

    private func sendStartSession() async throws -> Data {
        phase = .awaitingStartSessionResponse

        // Build StartSession request payload
        var payload = Data()
        // Protocol version (2 bytes, big-endian): version 1
        payload.append(0x00)
        payload.append(0x01)
        // Capabilities flags (2 bytes): DataX v1, media transfer, voice
        payload.append(0x00)
        payload.append(0x07)

        bluetooth.sendDataXMessage(type: GATTConstants.authStartSessionRequest, payload: payload)
        logger.debug("Sent StartSession request")

        return try await waitForResponse()
    }

    private func parseStartSessionResponse(_ data: Data) throws {
        guard data.count >= 4 else {
            throw CryptoError.handshakeFailed("StartSession response too short")
        }
        // Extract session nonce (bytes after version/capabilities)
        if data.count > 4 {
            sessionNonce = data[4...]
            logger.debug("Session nonce: \(self.sessionNonce!.count) bytes")
        }
    }

    // MARK: - Step 2: Identity

    private func sendIdentity() async throws -> Data {
        phase = .awaitingIdentityResponse

        guard let pubKey = rsaPublicKey else {
            throw CryptoError.identityNotFound
        }

        let pubKeyData = try await rsaAuth.exportPublicKey(pubKey)

        var payload = Data()
        // Public key length (2 bytes, big-endian)
        payload.append(UInt8((pubKeyData.count >> 8) & 0xFF))
        payload.append(UInt8(pubKeyData.count & 0xFF))
        // Public key DER data
        payload.append(pubKeyData)

        // Bootstrap ticket (if we have one)
        if await identityStore.hasBootstrapTicket() {
            let ticket = try await identityStore.loadBootstrapTicket()
            // Ticket length (2 bytes, big-endian)
            payload.append(UInt8((ticket.count >> 8) & 0xFF))
            payload.append(UInt8(ticket.count & 0xFF))
            payload.append(ticket)
        } else {
            // No ticket — send zero length
            payload.append(0x00)
            payload.append(0x00)
        }

        bluetooth.sendDataXMessage(type: GATTConstants.authIdentityRequest, payload: payload)
        logger.debug("Sent Identity request with \(pubKeyData.count)-byte public key")

        return try await waitForResponse()
    }

    private func parseIdentityResponse(_ data: Data) async throws -> Data {
        // The response contains an RSA-encrypted blob with the AES-256 session key
        guard data.count >= 2 else {
            throw CryptoError.handshakeFailed("Identity response too short")
        }

        let encBlobLength = (Int(data[0]) << 8) | Int(data[1])
        guard data.count >= 2 + encBlobLength else {
            throw CryptoError.handshakeFailed("Identity response truncated")
        }

        let encryptedBlob = data[2..<(2 + encBlobLength)]

        guard let privateKey = rsaPrivateKey else {
            throw CryptoError.identityNotFound
        }

        let sessionKeyMaterial = try await rsaAuth.decrypt(
            ciphertext: Data(encryptedBlob),
            privateKey: privateKey
        )

        // The first 32 bytes are the AES-256 session key
        guard sessionKeyMaterial.count >= 32 else {
            throw CryptoError.handshakeFailed("Session key material too short (\(sessionKeyMaterial.count) bytes)")
        }

        logger.info("Extracted \(sessionKeyMaterial.count)-byte session key material")
        return Data(sessionKeyMaterial.prefix(32))
    }

    // MARK: - Step 3: StartChallenge

    private func sendStartChallenge() async throws -> Data {
        phase = .awaitingStartChallengeResponse

        // Generate a 32-byte random challenge
        var challenge = Data(count: 32)
        challenge.withUnsafeMutableBytes { ptr in
            _ = SecRandomCopyBytes(kSecRandomDefault, 32, ptr.baseAddress!)
        }

        var payload = Data()
        payload.append(UInt8((challenge.count >> 8) & 0xFF))
        payload.append(UInt8(challenge.count & 0xFF))
        payload.append(challenge)

        bluetooth.sendDataXMessage(type: GATTConstants.authStartChallengeRequest, payload: payload)
        logger.debug("Sent StartChallenge with 32-byte challenge")

        return try await waitForResponse()
    }

    private func parseStartChallengeResponse(_ data: Data) async throws -> Data {
        // The response contains an encrypted challenge that we must decrypt
        // to prove we have the session key
        let decrypted = try await sessionCrypto.decrypt(data)
        logger.debug("Decrypted challenge response: \(decrypted.count) bytes")
        return decrypted
    }

    // MARK: - Step 4: FinishChallenge

    private func sendFinishChallenge(proof: Data) async throws -> Data {
        phase = .awaitingFinishChallengeResponse

        // Encrypt the proof with the session key
        let encryptedProof = try await sessionCrypto.encrypt(proof)

        bluetooth.sendDataXMessage(type: GATTConstants.authFinishChallengeRequest, payload: encryptedProof)
        logger.debug("Sent FinishChallenge with encrypted proof")

        return try await waitForResponse()
    }

    private func parseFinishChallengeResponse(_ data: Data) async throws {
        guard data.count >= 2 else {
            throw CryptoError.handshakeFailed("FinishChallenge response too short")
        }

        // Status byte
        let status = data[0]
        guard status == 0x00 else {
            throw CryptoError.handshakeFailed("FinishChallenge rejected with status \(String(format: "0x%02X", status))")
        }

        // Extract session ticket for future reconnections
        if data.count > 2 {
            let ticketLength = (Int(data[1]) << 8) | Int(data[2])
            if data.count >= 3 + ticketLength, ticketLength > 0 {
                let ticket = Data(data[3..<(3 + ticketLength)])
                try await identityStore.saveSessionTicket(ticket)
                logger.info("Session ticket saved (\(ticketLength) bytes)")
            }
        }
    }

    // MARK: - Response waiting

    /// Wait for the next DataX message from the glasses.
    private func waitForResponse() async throws -> Data {
        return try await withCheckedThrowingContinuation { continuation in
            self.pendingContinuation = continuation
        }
    }

    /// Called by the Bluetooth layer when a DataX message arrives during handshake.
    func handleIncomingMessage(_ data: Data) {
        guard let continuation = pendingContinuation else {
            logger.warning("Received message with no pending continuation")
            return
        }
        pendingContinuation = nil
        continuation.resume(returning: data)
    }

    /// Called on error or disconnect during handshake.
    func handleError(_ error: Error) {
        phase = .failed(error)
        if let continuation = pendingContinuation {
            pendingContinuation = nil
            continuation.resume(throwing: error)
        }
    }
}
