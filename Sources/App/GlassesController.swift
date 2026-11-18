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
    private(set) var changeOwnerPhase: ChangeOwnerExchange.Phase = .idle
    private(set) var changeOwnerFailure: String = ""

    // Protocol service state
    private(set) var captureListPhase: CaptureListService.Phase = .idle
    private(set) var captures: [CaptureEntry] = []
    private(set) var batteryPercent: Int?
    private(set) var deviceIsCharging: Bool = false
    private(set) var deviceTemperature: Double?
    private(set) var clockSynced: Bool = false
    private(set) var assistantPhase: AssistantService.Phase = .idle
    private(set) var airshipReceiverPhase: AirshipReceiver.Phase = .idle
    private(set) var airshipReceiverProgress: Double = 0
    private(set) var servicesStarted: Bool = false

    // MARK: - Dependencies

    let bluetooth = BluetoothManager()
    private let sessionCrypto = SessionCrypto()
    private let authHandshake: AuthHandshake
    private let identityStore = IdentityStore()
    private let ownerKeyStore = OwnerKeyStore()
    let metaAuth = MetaAuth()
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

    // MARK: - Change owner (claim ownership via Meta)

    private static let defaultHWToken = "HW|1312539125771114|98588f106d5d542adbf590619ca071fe"
    private static let defaultARToken = "AR|306760944872162|a919421a55a8ea18080ab2f10f57f1be"

    /// The Meta hardware graph app token (VISOR_META_HW_TOKEN).
    var hwAppToken: String {
        get {
            let stored = UserDefaults.standard.string(forKey: "com.openglass.hwAppToken") ?? ""
            return stored.isEmpty ? Self.defaultHWToken : stored
        }
        set { UserDefaults.standard.set(newValue, forKey: "com.openglass.hwAppToken") }
    }

    /// The Meta AR graph app token (VISOR_META_AR_TOKEN).
    var arAppToken: String {
        get {
            let stored = UserDefaults.standard.string(forKey: "com.openglass.arAppToken") ?? ""
            return stored.isEmpty ? Self.defaultARToken : stored
        }
        set { UserDefaults.standard.set(newValue, forKey: "com.openglass.arAppToken") }
    }

    func claimOwnership(authCode: String) async throws {
        guard bluetooth.isAirShieldSecure else {
            throw ChangeOwnerError.noLink
        }
        guard !hwAppToken.isEmpty else {
            throw MetaAuthError.serverError("HW app token not set. Extract VISOR_META_HW_TOKEN from Visor or the Meta AI APK.")
        }
        guard !arAppToken.isEmpty else {
            throw MetaAuthError.serverError("AR app token not set. Extract VISOR_META_AR_TOKEN from Visor or the Meta AI APK.")
        }

        let serial = bluetooth.serialNumber ?? "unknown"
        let tokens = try await metaAuth.exchangeCodeForTokens(code: authCode, arAppToken: arAppToken, hwAppToken: hwAppToken)
        let key = try await ownerKeyStore.generateNewKey(serial: serial)
        let pubkey64 = Array(key.publicKey.rawRepresentation)

        bluetooth.ownerSigningKey = key
        hasOwnerKey = true
        ownerSerial = serial
        bluetooth.startChangeOwner(ownerPubkey64: pubkey64, tokens: tokens, metaAuth: metaAuth)
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
        changeOwnerPhase = bluetooth.changeOwnerPhase
        changeOwnerFailure = bluetooth.changeOwnerFailure

        if changeOwnerPhase == .succeeded && trustPhase == .idle {
            bluetooth.startTrustExchange()
        }

        if trustPhase == .succeeded && !servicesStarted {
            servicesStarted = true
            bluetooth.startServicesAfterTrust()
            bluetooth.enumerateCaptures()
        }

        captureListPhase = bluetooth.captureListPhase
        captures = bluetooth.captures
        batteryPercent = bluetooth.deviceBatteryPercent
        deviceIsCharging = bluetooth.deviceIsCharging
        deviceTemperature = bluetooth.deviceTemperature
        clockSynced = bluetooth.clockSyncPhase == .synced
        assistantPhase = bluetooth.assistantPhase
        airshipReceiverPhase = bluetooth.airshipReceiverPhase
        airshipReceiverProgress = bluetooth.airshipReceiverProgress

        firmwarePhase = bluetooth.firmwarePhase
        firmwareFailure = bluetooth.firmwareFailure
        firmwareProgress = bluetooth.firmwareProgress
        mobileConfigPhase = bluetooth.mobileConfigPhase
        mobileConfigFailure = bluetooth.mobileConfigFailure

        switch bluetooth.connectionState {
        case .disconnected:
            if state == .connecting || state == .connected || state == .authenticating || state == .authenticated {
                state = .disconnected
                resetServices()
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

    // MARK: - Gallery / Captures

    func refreshCaptures() {
        bluetooth.enumerateCaptures()
    }

    func requestCaptureDownload(handle: String) {
        bluetooth.requestCaptureTransfer(handle: handle, linkType: 1)
    }

    func downloadAsset(uuid: String, to destination: URL) async throws -> URL {
        try await bluetooth.downloadAsset(uuid: uuid, to: destination)
    }

    func deleteCapture(handle: String) {
        bluetooth.deleteCapture(handle: handle)
    }

    // MARK: - Device Status

    func refreshDeviceStatus() {
        bluetooth.refreshDeviceStatus()
    }

    // MARK: - Assistant

    func sendAssistantResponse(text: String) {
        bluetooth.sendAssistantResponse(text: text)
    }

    var onAssistantRequest: ((AssistantService.AssistantRequest) -> Void)? {
        get { nil }
        set { }
    }

    // MARK: - Convenience

    var isConnected: Bool {
        state == .connected || state == .authenticated || state == .authenticating
    }

    var isOwnerVerified: Bool {
        trustPhase == .succeeded
    }

    func clearError() {
        lastError = nil
        if state == .error {
            state = .disconnected
        }
    }

    // Reset services on disconnect
    func resetServices() {
        servicesStarted = false
        captures = []
        batteryPercent = nil
        deviceIsCharging = false
        deviceTemperature = nil
        clockSynced = false
    }
}
