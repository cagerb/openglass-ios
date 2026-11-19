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
    private(set) var storageFreeBytes: Int64 = 0
    private(set) var storageTotalBytes: Int64 = 0

    // Capture downloads (BLE)
    enum CaptureDownloadState: Equatable, Sendable {
        case requesting
        case done
        case failed(String)
    }
    /// Download state per capture handle; a handle with no entry has not been asked for.
    private(set) var downloadStates: [String: CaptureDownloadState] = [:]
    /// Captures saved to disk that the gallery has not yet written to SwiftData.
    private(set) var finishedDownloads: [Capture] = []
    private(set) var lastDownloadError: String?
    private var downloadAttempts: [String: Int] = [:]
    private let mediaDirectory = LocalStore().mediaDirectory

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
        bluetooth.onCaptureFileReceived = { [weak self] file in
            Task { @MainActor [weak self] in
                self?.handleReceivedFile(file)
            }
        }
        bluetooth.onCaptureTransferFailed = { [weak self] reason in
            Task { @MainActor [weak self] in
                self?.handleTransferFailed(reason)
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
        storageFreeBytes = bluetooth.deviceStorageFreeBytes
        storageTotalBytes = bluetooth.deviceStorageTotalBytes

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

    /// Ask the glasses to send one capture over BLE and track it until a file lands,
    /// the glasses stay silent, or the transfer fails.
    func requestCaptureDownload(handle: String) {
        if downloadStates[handle] == .requesting { return }
        guard isOwnerVerified else {
            downloadStates[handle] = .failed("Not connected to the glasses")
            lastDownloadError = "Not connected to the glasses"
            return
        }

        lastDownloadError = nil
        downloadStates[handle] = .requesting
        let attempt = (downloadAttempts[handle] ?? 0) + 1
        downloadAttempts[handle] = attempt

        bluetooth.requestCaptureTransfer(
            handle: handle,
            linkType: 1,
            incomingDirectory: mediaDirectory.appendingPathComponent("incoming", isDirectory: true)
        )

        // Give up if the glasses never offer the file. While bytes are flowing, keep waiting.
        Task { [weak self] in
            while true {
                try? await Task.sleep(for: .seconds(25))
                guard let self,
                      self.downloadAttempts[handle] == attempt,
                      self.downloadStates[handle] == .requesting else { return }
                if self.bluetooth.airshipReceiverPhase == .receiving { continue }
                self.failDownload(handle: handle, reason: "The glasses did not send the file")
                return
            }
        }
    }

    /// Captures saved since the last call, for the gallery to persist. Clears the list.
    func takeFinishedDownloads() -> [Capture] {
        let finished = finishedDownloads
        finishedDownloads = []
        return finished
    }

    private var pendingDownloadHandles: [String] {
        downloadStates.compactMap { $0.value == .requesting ? $0.key : nil }
    }

    private func failDownload(handle: String, reason: String) {
        downloadStates[handle] = .failed(reason)
        lastDownloadError = reason
        logger.error("Capture download failed: \(reason, privacy: .public)")
    }

    private func handleTransferFailed(_ reason: String) {
        // The receiver handles one file at a time and does not know which capture it was for,
        // so only attribute the failure when exactly one download is waiting.
        let pending = pendingDownloadHandles
        if pending.count == 1, let handle = pending.first {
            failDownload(handle: handle, reason: reason)
        } else {
            lastDownloadError = reason
        }
    }

    private func handleReceivedFile(_ file: AirshipReceiver.ReceivedFile) {
        let pending = Set(pendingDownloadHandles)
        let candidates = bluetooth.captures.filter { pending.contains($0.handle) }

        func normalized(_ uuid: String) -> String {
            uuid.replacingOccurrences(of: "-", with: "").lowercased()
        }

        // Match the file to a capture: by asset UUID, then by exact size, then "the only one waiting".
        var entry: CaptureEntry?
        var asset: AssetEntry?
        for candidate in candidates {
            if let hit = candidate.assets.first(where: { normalized($0.uuid) == file.uuidHex }) {
                entry = candidate
                asset = hit
                break
            }
        }
        if entry == nil {
            let bySize = candidates.filter { $0.assets.contains { $0.sizeBytes == UInt64(file.size) } }
            if bySize.count == 1, let only = bySize.first {
                entry = only
                asset = only.assets.first { $0.sizeBytes == UInt64(file.size) }
            }
        }
        if entry == nil, candidates.count == 1 {
            entry = candidates.first
        }

        guard let entry else {
            logger.info("Received \(file.basename, privacy: .public) but no waiting capture matches it; left in incoming/")
            return
        }

        // A capture can come with side files (IMU data, a preview frame). Only the photo or
        // video itself becomes a gallery item; the rest stay in incoming/.
        let ext = file.url.pathExtension.lowercased()
        let captureIsVideo = entry.kind == CaptureType.video.rawValue
        let isVideo: Bool
        let isPhoto: Bool
        if let asset {
            // Asset media type: 1 = MP4, 2 = JPEG, 3 = IMU, 4 = frame.
            isVideo = asset.mediaType == 1
            isPhoto = asset.mediaType == 2 && !captureIsVideo
        } else {
            isVideo = captureIsVideo && (ext == "mp4" || ext == "mov")
            isPhoto = !captureIsVideo && (ext == "jpg" || ext == "jpeg" || ext == "heic")
        }
        guard isVideo || isPhoto else {
            logger.info("Received side file \(file.basename, privacy: .public) for \(entry.handle, privacy: .public)")
            return
        }

        let type: CaptureType = isVideo ? .video : .photo
        let safeID = String(entry.handle.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" })
        // Same naming as LocalStore.fileURL(for:): <id>.jpg / <id>.mp4 in the media directory.
        let destination = mediaDirectory.appendingPathComponent("\(safeID).\(type == .video ? "mp4" : "jpg")")

        do {
            let fm = FileManager.default
            try fm.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
            if fm.fileExists(atPath: destination.path) {
                try fm.removeItem(at: destination)
            }
            try fm.moveItem(at: file.url, to: destination)
        } catch {
            failDownload(handle: entry.handle, reason: "Could not store the file: \(error.localizedDescription)")
            return
        }

        let seconds = Double(entry.timestampNanos) / 1_000_000_000
        // Only trust the glasses' timestamp if it is a plausible wall-clock time (after 2020).
        let timestamp = seconds > 1_577_836_800 ? Date(timeIntervalSince1970: seconds) : Date()
        var capture = Capture(
            id: safeID,
            type: type,
            timestamp: timestamp,
            fileSize: Int64(file.size),
            duration: nil,
            width: nil,
            height: nil
        )
        capture.isDownloaded = true
        capture.localFileURL = destination

        finishedDownloads.append(capture)
        downloadStates[entry.handle] = .done
        lastDownloadError = nil
        logger.info("Capture \(entry.handle, privacy: .public) saved as \(destination.lastPathComponent, privacy: .public)")
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

    var storageUsedBytes: Int64 { max(storageTotalBytes - storageFreeBytes, 0) }

    var storageDisplayString: String {
        guard storageTotalBytes > 0 else { return "-- / -- GB" }
        let usedGB = Double(storageUsedBytes) / 1_073_741_824
        let totalGB = Double(storageTotalBytes) / 1_073_741_824
        return String(format: "%.1f / %.1f GB", usedGB, totalGB)
    }

    var storageFraction: Double {
        storageTotalBytes > 0 ? Double(storageUsedBytes) / Double(storageTotalBytes) : 0
    }

    // Reset services on disconnect
    func resetServices() {
        servicesStarted = false
        captures = []
        batteryPercent = nil
        deviceIsCharging = false
        deviceTemperature = nil
        clockSynced = false
        storageFreeBytes = 0
        storageTotalBytes = 0
        // Anything still waiting on the glasses cannot finish on a dead link.
        for (handle, state) in downloadStates where state == .requesting {
            downloadStates[handle] = .failed("Disconnected")
        }
    }
}
