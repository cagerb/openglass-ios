// Keychain-backed storage for the P-256 owner key and serial imported from a G-Link identity file.
import CryptoKit
import Foundation
@preconcurrency import Security
import os

actor OwnerKeyStore {

    private let logger = Logger(subsystem: "com.openglass.app", category: "OwnerKeyStore")

    private static let service = "com.openglass.owner"
    private static let privateKeyAccount = "ownerPrivateKey"
    private static let serialAccount = "ownerSerial"
    private static let keyLength = 96
    private static let scalarLength = 32
    private static let serialLengthOffset = 100
    private static let serialOffset = 104

    func importFromGLink(_ data: Data) throws {
        let bytes = [UInt8](data)
        guard bytes.count >= 8, Self.readLE32(bytes, at: 0) == Self.keyLength,
              bytes.count >= Self.serialOffset else {
            throw CryptoError.invalidKeyData
        }
        let serialLength = Self.readLE32(bytes, at: Self.serialLengthOffset)
        guard serialLength > 0, serialLength <= bytes.count - Self.serialOffset,
              let serial = String(bytes: bytes[Self.serialOffset..<Self.serialOffset + serialLength], encoding: .utf8)
        else {
            throw CryptoError.invalidKeyData
        }

        let privateKey: P256.Signing.PrivateKey
        do {
            privateKey = try P256.Signing.PrivateKey(rawRepresentation: Data(bytes[4..<4 + Self.scalarLength]))
        } catch {
            throw CryptoError.invalidKeyData
        }

        try saveData(privateKey.rawRepresentation, account: Self.privateKeyAccount)
        try saveData(Data(serial.utf8), account: Self.serialAccount)
        logger.info("Owner key imported for serial \(serial, privacy: .private)")
    }

    func loadSigningKey() throws -> P256.Signing.PrivateKey {
        let data = try loadData(account: Self.privateKeyAccount)
        guard let key = try? P256.Signing.PrivateKey(rawRepresentation: data) else {
            throw CryptoError.invalidKeyData
        }
        return key
    }

    func loadSerial() throws -> String {
        let data = try loadData(account: Self.serialAccount)
        guard let serial = String(data: data, encoding: .utf8) else {
            throw CryptoError.invalidKeyData
        }
        return serial
    }

    func hasOwnerKey() -> Bool {
        return hasData(account: Self.privateKeyAccount)
    }

    func generateNewKey(serial: String) throws -> P256.Signing.PrivateKey {
        let key = P256.Signing.PrivateKey()
        try saveData(key.rawRepresentation, account: Self.privateKeyAccount)
        try saveData(Data(serial.utf8), account: Self.serialAccount)
        logger.info("Generated new owner key for serial \(serial, privacy: .private)")
        return key
    }

    func deleteOwnerKey() {
        deleteData(account: Self.privateKeyAccount)
        deleteData(account: Self.serialAccount)
        logger.info("Owner key deleted from keychain")
    }

    private static func readLE32(_ bytes: [UInt8], at offset: Int) -> Int {
        return Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
            | Int(bytes[offset + 2]) << 16 | Int(bytes[offset + 3]) << 24
    }

    private func saveData(_ data: Data, account: String) throws {
        deleteData(account: account)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            logger.error("Keychain save failed for \(account): \(status)")
            throw CryptoError.keychainError(status)
        }
    }

    private func loadData(account: String) throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            throw CryptoError.identityNotFound
        }
        return data
    }

    private func hasData(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    private func deleteData(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
