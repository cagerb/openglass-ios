import Foundation
import Security
import os

/// Keychain-backed storage for the phone's RSA identity, bootstrap ticket,
/// and session ticket used to authenticate with the glasses.
///
/// Keys are stored in the iOS Keychain under the `com.openglass` access group
/// so they persist across app launches but not across app reinstalls
/// (unless backed up to iCloud Keychain, which we do not enable).
actor IdentityStore {

    private let logger = Logger(subsystem: "com.openglass.app", category: "IdentityStore")

    // MARK: - Keychain service/account tags

    private static let service = "com.openglass.identity"
    private static let rsaPrivateKeyTag = "com.openglass.rsa.private"
    private static let rsaPublicKeyTag = "com.openglass.rsa.public"
    private static let bootstrapTicketAccount = "bootstrapTicket"
    private static let sessionTicketAccount = "sessionTicket"
    private static let deviceIdentifierAccount = "deviceIdentifier"

    // MARK: - RSA Key Pair

    /// Save an RSA private key to the Keychain.
    func saveRSAPrivateKey(_ key: SecKey) throws {
        // Export to DER
        var error: Unmanaged<CFError>?
        guard let keyData = SecKeyCopyExternalRepresentation(key, &error) as Data? else {
            throw CryptoError.invalidKeyData
        }

        try saveData(keyData, account: Self.rsaPrivateKeyTag)
        logger.info("RSA private key saved to keychain")
    }

    /// Load the RSA private key from the Keychain.
    func loadRSAPrivateKey() throws -> SecKey {
        let keyData = try loadData(account: Self.rsaPrivateKeyTag)

        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits as String: RSAAuth.keySize,
        ]

        var importError: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(keyData as CFData, attributes as CFDictionary, &importError) else {
            throw CryptoError.invalidKeyData
        }

        return key
    }

    /// Save the RSA public key DER data.
    func saveRSAPublicKeyData(_ data: Data) throws {
        try saveData(data, account: Self.rsaPublicKeyTag)
        logger.info("RSA public key data saved")
    }

    /// Load the RSA public key DER data.
    func loadRSAPublicKeyData() throws -> Data {
        return try loadData(account: Self.rsaPublicKeyTag)
    }

    /// Check whether an RSA key pair exists.
    func hasRSAKeyPair() -> Bool {
        return hasData(account: Self.rsaPrivateKeyTag)
    }

    // MARK: - Bootstrap Ticket

    /// The bootstrap ticket is obtained during initial pairing setup
    /// (imported from the user or extracted from an existing paired device).
    func saveBootstrapTicket(_ ticket: Data) throws {
        try saveData(ticket, account: Self.bootstrapTicketAccount)
        logger.info("Bootstrap ticket saved (\(ticket.count) bytes)")
    }

    func loadBootstrapTicket() throws -> Data {
        return try loadData(account: Self.bootstrapTicketAccount)
    }

    func hasBootstrapTicket() -> Bool {
        return hasData(account: Self.bootstrapTicketAccount)
    }

    // MARK: - Session Ticket

    /// The session ticket is received after a successful FinishChallenge and
    /// can be reused for reconnection without a full handshake.
    func saveSessionTicket(_ ticket: Data) throws {
        try saveData(ticket, account: Self.sessionTicketAccount)
        logger.info("Session ticket saved (\(ticket.count) bytes)")
    }

    func loadSessionTicket() throws -> Data {
        return try loadData(account: Self.sessionTicketAccount)
    }

    func hasSessionTicket() -> Bool {
        return hasData(account: Self.sessionTicketAccount)
    }

    // MARK: - Device Identifier

    /// A unique identifier for the paired glasses (e.g., their BLE peripheral UUID).
    func saveDeviceIdentifier(_ identifier: String) throws {
        guard let data = identifier.data(using: .utf8) else {
            throw CryptoError.invalidKeyData
        }
        try saveData(data, account: Self.deviceIdentifierAccount)
    }

    func loadDeviceIdentifier() throws -> String {
        let data = try loadData(account: Self.deviceIdentifierAccount)
        guard let str = String(data: data, encoding: .utf8) else {
            throw CryptoError.invalidKeyData
        }
        return str
    }

    // MARK: - Delete all

    /// Remove all OpenGlass identity data from the Keychain.
    func deleteAll() {
        let accounts = [
            Self.rsaPrivateKeyTag,
            Self.rsaPublicKeyTag,
            Self.bootstrapTicketAccount,
            Self.sessionTicketAccount,
            Self.deviceIdentifierAccount,
        ]
        for account in accounts {
            deleteData(account: account)
        }
        logger.info("All identity data deleted from keychain")
    }

    // MARK: - Generic Keychain helpers

    private func saveData(_ data: Data, account: String) throws {
        // Delete existing first
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
