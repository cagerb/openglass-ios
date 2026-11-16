import Foundation
import CryptoKit
import os

/// AES-256-GCM encryption and decryption for DataX session traffic.
///
/// The glasses use AES-256-GCM with a 96-bit (12-byte) nonce and 96-bit (12-byte)
/// authentication tag (truncated from the standard 128-bit GCM tag).
///
/// Wire format for encrypted messages:
/// ```
/// [0]       = 0x02 (encrypted message type)
/// [1..12]   = 12-byte nonce
/// [13..N-12]= ciphertext
/// [N-12..N] = 12-byte authentication tag (truncated)
/// ```
actor SessionCrypto {

    private let logger = Logger(subsystem: "com.openglass.app", category: "SessionCrypto")

    /// The negotiated AES-256 session key.
    private var sessionKey: SymmetricKey?

    /// Monotonic nonce counter for outbound messages (phone → glasses).
    private var sendNonceCounter: UInt64 = 0

    /// Tag length used by the glasses (96 bits = 12 bytes, truncated from GCM's 128-bit tag).
    static let tagLength = 12

    /// Nonce length (96 bits = 12 bytes).
    static let nonceLength = 12

    // MARK: - Key management

    func setSessionKey(_ key: Data) {
        precondition(key.count == 32, "Session key must be 32 bytes (AES-256)")
        sessionKey = SymmetricKey(data: key)
        sendNonceCounter = 0
        logger.info("Session key installed (\(key.count) bytes)")
    }

    func clearSessionKey() {
        sessionKey = nil
        sendNonceCounter = 0
    }

    var hasSessionKey: Bool {
        sessionKey != nil
    }

    // MARK: - Encrypt

    /// Encrypt a plaintext payload for sending to the glasses.
    ///
    /// - Parameter plaintext: The message payload to encrypt.
    /// - Returns: The complete encrypted wire-format data (nonce + ciphertext + truncated tag).
    /// - Throws: If no session key is set or encryption fails.
    func encrypt(_ plaintext: Data) throws -> Data {
        guard let key = sessionKey else {
            throw CryptoError.noSessionKey
        }

        // Build 12-byte nonce from counter (big-endian, zero-padded on the left)
        let nonce = buildNonce(counter: sendNonceCounter)
        sendNonceCounter += 1

        let aesNonce = try AES.GCM.Nonce(data: nonce)
        let sealed = try AES.GCM.seal(plaintext, using: key, nonce: aesNonce)

        // CryptoKit produces a 16-byte tag; truncate to 12 bytes for the wire format
        let fullTag = sealed.tag
        let truncatedTag = fullTag.prefix(Self.tagLength)

        var result = Data(capacity: Self.nonceLength + sealed.ciphertext.count + Self.tagLength)
        result.append(contentsOf: nonce)
        result.append(sealed.ciphertext)
        result.append(truncatedTag)

        return result
    }

    // MARK: - Decrypt

    /// Decrypt an incoming encrypted message from the glasses.
    ///
    /// - Parameter wireData: The encrypted wire-format data (nonce + ciphertext + truncated tag).
    /// - Returns: The decrypted plaintext payload.
    /// - Throws: If no session key is set, the data is too short, or authentication fails.
    func decrypt(_ wireData: Data) throws -> Data {
        guard let key = sessionKey else {
            throw CryptoError.noSessionKey
        }

        let minLength = Self.nonceLength + Self.tagLength + 1 // at least 1 byte of ciphertext
        guard wireData.count >= minLength else {
            throw CryptoError.messageTooShort
        }

        let nonce = wireData[0..<Self.nonceLength]
        let ciphertext = wireData[Self.nonceLength..<(wireData.count - Self.tagLength)]
        let truncatedTag = wireData[(wireData.count - Self.tagLength)...]

        // GCM requires a 16-byte tag for verification; pad the truncated 12-byte tag with zeros
        var fullTag = Data(truncatedTag)
        fullTag.append(contentsOf: [UInt8](repeating: 0, count: 16 - Self.tagLength))

        let aesNonce = try AES.GCM.Nonce(data: nonce)
        let sealedBox = try AES.GCM.SealedBox(
            nonce: aesNonce,
            ciphertext: ciphertext,
            tag: fullTag
        )

        let plaintext = try AES.GCM.open(sealedBox, using: key)
        return plaintext
    }

    // MARK: - Nonce construction

    private func buildNonce(counter: UInt64) -> Data {
        var nonce = Data(count: Self.nonceLength)
        // Write counter into the last 8 bytes, big-endian
        let offset = Self.nonceLength - 8
        for i in 0..<8 {
            nonce[offset + i] = UInt8((counter >> (56 - i * 8)) & 0xFF)
        }
        return nonce
    }
}

// MARK: - Errors

enum CryptoError: Error, LocalizedError {
    case noSessionKey
    case messageTooShort
    case decryptionFailed
    case rsaDecryptionFailed
    case invalidKeyData
    case keychainError(OSStatus)
    case handshakeFailed(String)
    case identityNotFound

    var errorDescription: String? {
        switch self {
        case .noSessionKey: return "No session key established."
        case .messageTooShort: return "Encrypted message too short."
        case .decryptionFailed: return "Decryption failed (authentication tag mismatch)."
        case .rsaDecryptionFailed: return "RSA decryption failed."
        case .invalidKeyData: return "Invalid key data."
        case .keychainError(let status): return "Keychain error: \(status)"
        case .handshakeFailed(let reason): return "Handshake failed: \(reason)"
        case .identityNotFound: return "Identity not found in keychain."
        }
    }
}
