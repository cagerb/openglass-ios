import CryptoKit
import Foundation
import CoreBluetooth
@preconcurrency import Security
import SwiftUI
import os

@Observable
@MainActor
final class GlassesController {

    enum State: String, Sendable {
        case disconnected
        case scanning
        case connecting
        case connected
        case authenticating
        case authenticated
        case error
    }

    // MARK: - Published state

    private(set) var state: State = .disconnected
    private(set) var discoveredPeripherals: [CBPeripheral] = []
    private(set) var lastError: String?
    private(set) var hasIdentity = false
    private(set) var hasOwnerKey = false
    private(set) var ownerSerial: String = ""
    private(set) var trustPhase: OwnerTrustExchange.Phase = .idle
    private(set) var trustFailure: String = ""
    private(set) var firmwarePhase: FirmwareManager.Phase = .idle
    private(set) var firmwareFailure: String = ""
    private(set) var firmwareProgress: Double = 0
    private(set) var mobileConfigPhase: MobileConfigManager.Phase = .idle
    private(set) var mobileConfigFailure: String = ""

    // MARK: - Dependencies

    let bluetooth = BluetoothManager()
    private let sessionCrypto = SessionCrypto()
    private let authHandshake: AuthHandshake
    private let identityStore = IdentityStore()
    private let ownerKeyStore = OwnerKeyStore()
    private let logger = Logger(subsystem: "com.openglass.app", category: "GlassesController")

    // MARK: - Init

    init() {
        authHandshake = AuthHandshake(bluetooth: bluetooth, sessionCrypto: sessionCrypto)
        bluetooth.onDataXMessage = { [weak self] data in
            Task { @MainActor [weak self] in
                await self?.handleDataXMessage(data)
            }
        }
    }

    // MARK: - Identity check

    func checkIdentity() async {
        let hasKey = await identityStore.hasRSAKeyPair()
        let hasTicket = await identityStore.hasBootstrapTicket()
        hasIdentity = hasKey && hasTicket
    }

    // MARK: - Scanning

    func startScan() {
        lastError = nil
        state = .scanning
        bluetooth.startScanning()
        observeBluetooth()
    }

    func stopScan() {
        bluetooth.stopScanning()
        state = .disconnected
    }

    // MARK: - Connection

    func connect(to peripheral: CBPeripheral) {
        state = .connecting
        bluetooth.connect(to: peripheral)
    }

    func disconnect() {
        bluetooth.disconnect()
        state = .disconnected
    }

    // MARK: - Authentication

    func authenticate() async {
        guard state == .connected else { return }
        state = .authenticating

        do {
            try await authHandshake.performHandshake()
            state = .authenticated
            logger.info("Authentication successful")
        } catch {
            state = .error
            lastError = error.localizedDescription
            logger.error("Authentication failed: \(error)")
        }
    }

    // MARK: - Identity import

    func importIdentity(rsaKeyData: Data, bootstrapTicket: Data) async throws {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits as String: 2048,
        ]
        var importError: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(rsaKeyData as CFData, attributes as CFDictionary, &importError) else {
            throw CryptoError.invalidKeyData
        }
        try await identityStore.saveRSAPrivateKey(key)
        guard let pubKey = SecKeyCopyPublicKey(key) else {
            throw CryptoError.invalidKeyData
        }
        var pubError: Unmanaged<CFError>?
        guard let pubData = SecKeyCopyExternalRepresentation(pubKey, &pubError) as Data? else {
            throw CryptoError.invalidKeyData
        }
        try await identityStore.saveRSAPublicKeyData(pubData)
        try await identityStore.saveBootstrapTicket(bootstrapTicket)
        hasIdentity = true
        logger.info("Identity imported successfully")
    }

    func deleteIdentity() async {
        await identityStore.deleteAll()
        hasIdentity = false
        if state == .authenticated {
            disconnect()
        }
    }

    // MARK: - Owner key (P-256 from G-Link)

    func loadOwnerKey() async {
        hasOwnerKey = await ownerKeyStore.hasOwnerKey()
        if hasOwnerKey {
            do {
                let key = try await ownerKeyStore.loadSigningKey()
                bluetooth.ownerSigningKey = key
                ownerSerial = (try? await ownerKeyStore.loadSerial()) ?? ""
                logger.info("Owner key loaded for serial \(self.ownerSerial, privacy: .private)")
            } catch {
                logger.error("Failed to load owner key: \(error)")
                hasOwnerKey = false
            }
        }
    }

    func importOwnerKey(from data: Data) async throws {
        try await ownerKeyStore.importFromGLink(data)
        await loadOwnerKey()
        if bluetooth.isAirShieldSecure {
            bluetooth.startTrustExchange()
        }
    }

    func deleteOwnerKey() async {
        await ownerKeyStore.deleteOwnerKey()
        bluetooth.ownerSigningKey = nil
        hasOwnerKey = false
        ownerSerial = ""
        trustPhase = .idle
        trustFailure = ""
    }

    // MARK: - Firmware + MobileConfig

    func startFirmwareUpdate(from data: Data) {
        bluetooth.startFirmwareUpdate(firmwareZIP: Array(data))
    }

    func disableSignatureVerification() {
        let sessionlessTable = MobileConfigBuilder.buildTable(
            schemaHash: "unknown",
            bools: [MobileConfigBuilder.signatureVerificationDisabled()]
        )
        let paramsTable = MobileConfigBuilder.buildTable(
            schemaHash: "unknown",
            bools: []
        )
        bluetooth.pushMobileConfig(
            sessionlessTable: sessionlessTable,
            paramsTable: paramsTable
        )
    }

    // MARK: - Bluetooth observation

    private func observeBluetooth() {
        Task.detached { [weak self] in
            while true {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self else { return }
                await MainActor.run {
                    self.syncBluetoothState()
                }
            }
        }
    }

    private func syncBluetoothState() {
        discoveredPeripherals = bluetooth.discoveredPeripherals

        if let error = bluetooth.lastError, lastError == nil {
            lastError = error
        }

        trustPhase = bluetooth.trustPhase
        trustFailure = bluetooth.trustFailure
        firmwarePhase = bluetooth.firmwarePhase
        firmwareFailure = bluetooth.firmwareFailure
        firmwareProgress = bluetooth.firmwareProgress
        mobileConfigPhase = bluetooth.mobileConfigPhase
        mobileConfigFailure = bluetooth.mobileConfigFailure

        switch bluetooth.connectionState {
        case .disconnected:
            if state == .connecting || state == .connected || state == .authenticating || state == .authenticated {
                state = .disconnected
            }
        case .scanning:
            break
        case .connecting, .discoveringServices:
            if state != .connecting {
                state = .connecting
            }
        case .connected:
            if state == .connecting || state == .authenticating || state == .error {
                state = .connected
                lastError = nil
            }
        case .authenticated:
            break
        }
    }

    // MARK: - DataX message routing

    private func handleDataXMessage(_ data: Data) async {
        if state == .authenticating {
            await authHandshake.handleIncomingMessage(data)
        }
    }

    // MARK: - Convenience

    var isConnected: Bool {
        state == .connected || state == .authenticated || state == .authenticating
    }

    func clearError() {
        lastError = nil
        if state == .error {
            state = .disconnected
        }
    }
}
