import Foundation
import Security
import os

/// RSA-OAEP SHA-256 operations for the initial authentication handshake.
///
/// During PhaseB, the glasses encrypt session data with the phone's RSA public key.
/// The phone decrypts it with its private key to obtain the session AES key.
actor RSAAuth {

    private let logger = Logger(subsystem: "com.openglass.app", category: "RSAAuth")

    /// RSA key size in bits.
    static let keySize = 2048

    // MARK: - Key generation

    /// Generate a new RSA-2048 key pair and return (privateKey, publicKey).
    func generateKeyPair() throws -> (SecKey, SecKey) {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: Self.keySize,
            kSecAttrIsPermanent as String: false,
        ]

        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            let err = error?.takeRetainedValue()
            logger.error("RSA key generation failed: \(err?.localizedDescription ?? "unknown")")
            throw CryptoError.invalidKeyData
        }

        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            throw CryptoError.invalidKeyData
        }

        logger.info("Generated RSA-\(Self.keySize) key pair")
        return (privateKey, publicKey)
    }

    // MARK: - Export public key

    /// Export an RSA public key as DER-encoded PKCS#1 data (for sending to the glasses).
    func exportPublicKey(_ publicKey: SecKey) throws -> Data {
        var error: Unmanaged<CFError>?
        guard let data = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            throw CryptoError.invalidKeyData
        }
        return data
    }

    // MARK: - Decrypt with RSA-OAEP SHA-256

    /// Decrypt data that was encrypted with our RSA public key using OAEP SHA-256.
    ///
    /// - Parameters:
    ///   - ciphertext: The RSA-encrypted blob from the glasses.
    ///   - privateKey: Our RSA private key.
    /// - Returns: The decrypted plaintext (typically the AES-256 session key material).
    func decrypt(ciphertext: Data, privateKey: SecKey) throws -> Data {
        let algorithm = SecKeyAlgorithm.rsaEncryptionOAEPSHA256

        guard SecKeyIsAlgorithmSupported(privateKey, .decrypt, algorithm) else {
            logger.error("RSA-OAEP-SHA256 not supported on this key")
            throw CryptoError.rsaDecryptionFailed
        }

        var error: Unmanaged<CFError>?
        guard let plaintext = SecKeyCreateDecryptedData(
            privateKey,
            algorithm,
            ciphertext as CFData,
            &error
        ) as Data? else {
            let err = error?.takeRetainedValue()
            logger.error("RSA decryption failed: \(err?.localizedDescription ?? "unknown")")
            throw CryptoError.rsaDecryptionFailed
        }

        logger.debug("RSA decrypted \(ciphertext.count) bytes -> \(plaintext.count) bytes plaintext")
        return plaintext
    }

    // MARK: - Encrypt with RSA-OAEP SHA-256

    /// Encrypt data with an RSA public key using OAEP SHA-256.
    /// Used during FinishChallenge to send the challenge response.
    func encrypt(plaintext: Data, publicKey: SecKey) throws -> Data {
        let algorithm = SecKeyAlgorithm.rsaEncryptionOAEPSHA256

        guard SecKeyIsAlgorithmSupported(publicKey, .encrypt, algorithm) else {
            throw CryptoError.rsaDecryptionFailed
        }

        var error: Unmanaged<CFError>?
        guard let ciphertext = SecKeyCreateEncryptedData(
            publicKey,
            algorithm,
            plaintext as CFData,
            &error
        ) as Data? else {
            let err = error?.takeRetainedValue()
            logger.error("RSA encryption failed: \(err?.localizedDescription ?? "unknown")")
            throw CryptoError.rsaDecryptionFailed
        }

        return ciphertext
    }

    // MARK: - Import private key from DER

    /// Import an RSA private key from DER-encoded PKCS#1 data.
    func importPrivateKey(from derData: Data) throws -> SecKey {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits as String: Self.keySize,
        ]

        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(derData as CFData, attributes as CFDictionary, &error) else {
            throw CryptoError.invalidKeyData
        }
        return key
    }
}
