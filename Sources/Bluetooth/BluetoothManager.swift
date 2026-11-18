import Foundation
import CoreBluetooth
import CryptoKit
import os

/// Central manager for scanning, connecting, and communicating with Meta glasses over BLE.
///
/// Two generations, told apart by what the FD5F service holds:
/// - Ray-Ban Stories (2021): a write + notify DataX characteristic, used directly.
/// - Ray-Ban Meta ("RB Meta ..."): read-only characteristics. One of them names an
///   L2CAP PSM; the AirShield + DataX link runs over that channel (`AirShieldLink`).
@Observable
final class BluetoothManager: NSObject, @unchecked Sendable {

    // MARK: - Published state

    enum ConnectionState: String, Sendable {
        case disconnected
        case scanning
        case connecting
        case discoveringServices
        case connected
        case authenticated
    }

    private(set) var connectionState: ConnectionState = .disconnected
    private(set) var discoveredPeripherals: [CBPeripheral] = []
    private(set) var batteryLevel: Int?
    private(set) var firmwareRevision: String?
    private(set) var modelNumber: String?
    private(set) var serialNumber: String?
    private(set) var lastError: String?
    private(set) var debugLog: [String] = []

    // MARK: - Internal

    private var centralManager: CBCentralManager!
    private var connectedPeripheral: CBPeripheral?
    private var dataXCharacteristic: CBCharacteristic?
    private let dataXLink = DataXLink()
    private let logger = Logger(subsystem: "com.openglass.app", category: "Bluetooth")
    private let bleQueue = DispatchQueue(label: "com.openglass.ble", qos: .userInitiated)

    // Recovery state for the "FD5F reports 0 characteristics" problem.
    // Only touched from `bleQueue` (delegate callbacks) and user-initiated connect/disconnect.

    /// Bumped on every connect / cleanup so delayed retries can tell they are stale.
    @ObservationIgnored private var connectionGeneration = 0
    /// How many times in a row the Meta service came back with no characteristics.
    @ObservationIgnored private var metaEmptyCount = 0
    /// We only force one disconnect + reconnect per user-initiated connection.
    @ObservationIgnored private var reconnectAttempted = false
    /// Set while we are deliberately dropping the link to reconnect.
    @ObservationIgnored private var pendingReconnect: CBPeripheral?
    /// True when DataX was picked by shape (write + notify) rather than by its known UUID.
    @ObservationIgnored private var dataXIsFallback = false

    // Ray-Ban Meta ("RB Meta ...") link: no GATT data channel, an L2CAP channel instead.
    // Touched on `bleQueue` only.

    /// True once FD5F turned out to hold the L2CAP PSM characteristic.
    @ObservationIgnored private var usesL2CAP = false
    /// True between openL2CAPChannel and its didOpen callback.
    @ObservationIgnored private var l2capOpening = false
    /// PSMs already tried on this connection, so a refused one is not retried forever.
    @ObservationIgnored private var triedPSMs: Set<UInt16> = []
    @ObservationIgnored private var l2capPipe: L2CAPPipe?
    @ObservationIgnored var airShield: AirShieldLink?
    @ObservationIgnored private var forger: OwnershipForger?
    @ObservationIgnored private var trustExchange: OwnerTrustExchange?

    /// Current phase of the ownership forgery attempt, mirrored for observation.
    private(set) var forgerPhase: OwnershipForger.Phase = .idle
    private(set) var forgerFailure: String = ""

    private(set) var trustPhase: OwnerTrustExchange.Phase = .idle
    private(set) var trustFailure: String = ""

    @ObservationIgnored private var firmwareManager: FirmwareManager?
    @ObservationIgnored private var mobileConfigManager: MobileConfigManager?
    @ObservationIgnored private var airshipSender: AirshipSender?

    private(set) var firmwarePhase: FirmwareManager.Phase = .idle
    private(set) var firmwareFailure: String = ""
    private(set) var firmwareProgress: Double = 0
    private(set) var mobileConfigPhase: MobileConfigManager.Phase = .idle
    private(set) var mobileConfigFailure: String = ""

    /// Set by GlassesController before connecting when an owner key is available.
    @ObservationIgnored var ownerSigningKey: P256.Signing.PrivateKey?

    /// Maximum number of entries kept in the in-app debug log.
    private static let debugLogLimit = 400

    /// UserDefaults key for persisting previously-seen peripheral identifiers.
    private static let knownPeripheralIDsKey = "com.openglass.knownPeripheralIDs"

    /// Callback for complete reassembled DataX messages.
    var onDataXMessage: ((Data) -> Void)?

    /// Whether the L2CAP channel is currently open.
    var isL2CAPConnected: Bool { l2capPipe != nil }

    /// Send raw bytes over the L2CAP pipe, bypassing AirShield encryption.
    func sendRawL2CAP(_ bytes: [UInt8]) {
        bleQueue.async { [weak self] in
            self?.l2capPipe?.write(bytes)
        }
    }

    /// Send plaintext through the AirShield encryption layer, dispatched to bleQueue.
    /// Thread-safe wrapper: AirShieldLink is not thread-safe and must be called from bleQueue.
    func sendRawEncrypted(_ plaintext: [UInt8]) {
        bleQueue.async { [weak self] in
            _ = self?.airShield?.sendRawEncrypted(plaintext)
        }
    }

    /// Whether the AirShield link is in the secure phase (tracked for observation).
    private(set) var airShieldSecure = false

    /// Whether the AirShield link is in the secure phase.
    var isAirShieldSecure: Bool { airShieldSecure }

    /// Whether the glasses use the L2CAP + AirShield path (gen 2+) instead of GATT DataX (gen 1).
    var isL2CAPMode: Bool { usesL2CAP }

    /// Start the trust exchange right now (called after importing the owner key when AirShield is already secure).
    func startTrustExchange() {
        bleQueue.async { [weak self] in
            guard let self, let link = self.airShield, link.phase == .secure else {
                self?.log("Cannot start trust exchange: AirShield link is not secure")
                return
            }
            guard self.trustExchange == nil || self.trustPhase == .idle || self.trustPhase == .failed else {
                self.log("Trust exchange already in progress (\(self.trustPhase.rawValue))")
                return
            }
            guard let key = self.ownerSigningKey else {
                self.log("Cannot start trust exchange: no owner key loaded")
                return
            }
            guard let peer = link.peerRequest else {
                self.log("No peer handshake params yet — requesting identity first")
                link.requestIdentity()
                return
            }
            let params = OwnerTrustExchange.HandshakeParams(
                glassesChallenge: peer.challenge,
                glassesPubkey: peer.publicKey,
                ourSeed: link.mySeed,
                ourPubkey: Array(link.privateKey.publicKey.rawRepresentation)
            )
            let exchange = OwnerTrustExchange()
            exchange.log = { [weak self] msg in self?.log(msg) }
            self.trustExchange = exchange
            self.trustPhase = .proving
            exchange.start(link: link, params: params, ownerKey: key)
        }
    }

    /// Start the ownership forgery attempt on the current AirShield link.
    func startOwnershipForgery() {
        bleQueue.async { [weak self] in
            guard let self, let link = self.airShield, link.phase == .secure else {
                self?.log("Cannot start forgery: AirShield link is not secure")
                return
            }
            let f = OwnershipForger()
            f.log = { [weak self] message in self?.log(message) }
            self.forger = f
            self.forgerPhase = .waitingForIdentity
            f.start(link: link)
        }
    }

    /// Push a firmware ZIP to the glasses via svc29 + svc20 Airship.
    func startFirmwareUpdate(firmwareZIP: [UInt8], name: String = "firmware", version: String = "0") {
        bleQueue.async { [weak self] in
            guard let self, let link = self.airShield, link.phase == .secure else {
                self?.log("Cannot start firmware update: AirShield link is not secure")
                return
            }
            let fm = FirmwareManager()
            fm.log = { [weak self] message in self?.log(message) }
            self.firmwareManager = fm
            self.firmwarePhase = .startingSession
            fm.startUpdate(link: link, firmwareZIP: firmwareZIP, name: name, version: version)
        }
    }

    /// Push MobileConfig tables to the glasses via svc19 + svc20 Airship.
    func pushMobileConfig(sessionlessTable: [UInt8], paramsTable: [UInt8]) {
        bleQueue.async { [weak self] in
            guard let self, let link = self.airShield, link.phase == .secure else {
                self?.log("Cannot push MobileConfig: AirShield link is not secure")
                return
            }
            let mc = MobileConfigManager()
            mc.log = { [weak self] message in self?.log(message) }
            self.mobileConfigManager = mc
            self.mobileConfigPhase = .delivering
            mc.pushConfig(link: link, sessionlessTable: sessionlessTable, paramsTable: paramsTable)
        }
    }

    // MARK: - Init

    override init() {
        super.init()
        centralManager = CBCentralManager(
            delegate: self,
            queue: bleQueue,
            options: [CBCentralManagerOptionRestoreIdentifierKey: "com.openglass.central"]
        )
    }

    // MARK: - Public API

    func startScanning() {
        guard centralManager.state == .poweredOn else {
            lastError = "Bluetooth is not powered on."
            log("Scan aborted — Bluetooth not powered on")
            return
        }
        discoveredPeripherals.removeAll()
        connectionState = .scanning

        // Scan with nil services so we see ALL nearby BLE devices.
        // After factory reset + iOS-level pairing the glasses may stop
        // advertising the FD5F service UUID, making a filtered scan miss them.
        // Name filtering in didDiscover still limits results to "RB*" devices.
        centralManager.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
        log("Scan started (unfiltered, name-matched)")

        // Pick up glasses already connected at the iOS system level (they
        // stop advertising once paired, so scanForPeripherals won't find them).
        let alreadyConnected = centralManager.retrieveConnectedPeripherals(
            withServices: [GATTConstants.metaServiceUUID]
        )
        log("retrieveConnectedPeripherals: \(alreadyConnected.count) found")
        for peripheral in alreadyConnected {
            addDiscoveredPeripheral(peripheral, source: "system-connected")
        }

        // Re-discover previously-seen glasses by their saved identifiers.
        // retrievePeripherals(withIdentifiers:) works even when the device
        // is neither advertising nor system-connected — iOS returns a
        // CBPeripheral handle if it has ever bonded with that identifier.
        let knownIDs = Self.loadKnownPeripheralIDs()
        if !knownIDs.isEmpty {
            let knownPeripherals = centralManager.retrievePeripherals(withIdentifiers: knownIDs)
            log("retrievePeripherals(withIdentifiers:): \(knownPeripherals.count) of \(knownIDs.count) known IDs found")
            for peripheral in knownPeripherals {
                addDiscoveredPeripheral(peripheral, source: "known-identifier")
            }
        }
    }

    func stopScanning() {
        centralManager.stopScan()
        if connectionState == .scanning {
            connectionState = .disconnected
        }
    }

    func connect(to peripheral: CBPeripheral) {
        stopScanning()
        metaEmptyCount = 0
        reconnectAttempted = false
        pendingReconnect = nil
        startConnection(to: peripheral)
    }

    func disconnect() {
        let peripheral = connectedPeripheral
        // cleanup() first so the disconnect callback is not mistaken for a planned reconnect.
        cleanup()
        if let peripheral {
            centralManager.cancelPeripheralConnection(peripheral)
        }
    }

    /// Send a raw DataX message (will be framed and chunked automatically).
    func sendDataXMessage(type: UInt8, payload: Data) {
        guard let characteristic = dataXCharacteristic,
              let peripheral = connectedPeripheral else {
            if usesL2CAP {
                lastError = "These glasses use the L2CAP + AirShield link. The Stories gen 1 handshake does not apply to them."
                log("Gen 1 DataX send refused: these glasses have no GATT DataX characteristic")
            } else {
                lastError = "Not connected or DataX characteristic not found."
            }
            return
        }

        // Prefer write-with-response; fall back if the characteristic only allows write-without-response.
        let writeType: CBCharacteristicWriteType =
            characteristic.properties.contains(.write) ? .withResponse : .withoutResponse
        let frames = dataXLink.frame(type: type, payload: payload, mtu: peripheral.maximumWriteValueLength(for: writeType))
        let typeHex = String(format: "%02x", type)
        log("DataX TX type=0x\(typeHex) payload=\(payload.count) bytes in \(frames.count) write(s)")
        for frame in frames {
            peripheral.writeValue(frame, for: characteristic, type: writeType)
        }
    }

    // MARK: - Private

    /// De-duplicate and append a peripheral to the discovered list.
    private func addDiscoveredPeripheral(_ peripheral: CBPeripheral, source: String) {
        if !discoveredPeripherals.contains(where: { $0.identifier == peripheral.identifier }) {
            discoveredPeripherals.append(peripheral)
            logger.info("Found peripheral (\(source)): \(peripheral.name ?? "unknown")")
        }
    }

    /// Persist a peripheral identifier so we can retrieve it in future scans.
    private func saveKnownPeripheralID(_ id: UUID) {
        var ids = Self.loadKnownPeripheralIDs()
        guard !ids.contains(id) else { return }
        ids.append(id)
        let strings = ids.map { $0.uuidString }
        UserDefaults.standard.set(strings, forKey: Self.knownPeripheralIDsKey)
    }

    /// Load all previously-seen peripheral identifiers.
    private static func loadKnownPeripheralIDs() -> [UUID] {
        guard let strings = UserDefaults.standard.stringArray(forKey: knownPeripheralIDsKey) else {
            return []
        }
        return strings.compactMap { UUID(uuidString: $0) }
    }

    /// Append a timestamped entry to the in-app debug log and also log via os.Logger.
    /// The array itself is only mutated on the main queue, where SwiftUI reads it.
    private func log(_ message: String) {
        let ts = ISO8601DateFormatter.shared.string(from: Date())
        let entry = "[\(ts)] \(message)"
        logger.info("\(message)")
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.debugLog.append(entry)
            if self.debugLog.count > Self.debugLogLimit {
                self.debugLog.removeFirst(self.debugLog.count - Self.debugLogLimit)
            }
        }
    }

    private func cleanup() {
        connectionGeneration += 1
        metaEmptyCount = 0
        reconnectAttempted = false
        pendingReconnect = nil
        dataXIsFallback = false
        tearDownL2CAP()
        usesL2CAP = false
        connectedPeripheral = nil
        dataXCharacteristic = nil
        batteryLevel = nil
        firmwareRevision = nil
        modelNumber = nil
        serialNumber = nil
        connectionState = .disconnected
        dataXLink.reset()
    }

    private func startConnection(to peripheral: CBPeripheral) {
        connectionGeneration += 1
        connectionState = .connecting
        connectedPeripheral = peripheral
        peripheral.delegate = self
        log("Connecting to \(peripheral.name ?? "unknown") [\(peripheral.identifier.uuidString.prefix(8))]")
        centralManager.connect(peripheral, options: [
            CBConnectPeripheralOptionNotifyOnConnectionKey: true,
            CBConnectPeripheralOptionNotifyOnDisconnectionKey: true,
        ])
    }

    private func discoverAllServices() {
        connectedPeripheral?.discoverServices(nil)  // discover ALL services
        connectionState = .discoveringServices
        log("Discovering ALL services (nil filter)")
    }

    // MARK: - L2CAP + AirShield (Ray-Ban Meta)

    private func tearDownL2CAP() {
        l2capPipe?.close()
        l2capPipe = nil
        airShield = nil
        airShieldSecure = false
        forger = nil
        forgerPhase = .idle
        forgerFailure = ""
        trustExchange = nil
        trustPhase = .idle
        trustFailure = ""
        firmwareManager = nil
        firmwarePhase = .idle
        firmwareFailure = ""
        firmwareProgress = 0
        mobileConfigManager = nil
        mobileConfigPhase = .idle
        mobileConfigFailure = ""
        airshipSender = nil
        l2capOpening = false
        triedPSMs.removeAll()
    }

    /// The PSM characteristic's value arrived (by read or by notify): open the channel it names.
    private func handlePSMValue(_ value: Data, on peripheral: CBPeripheral) {
        let parsed = GATTConstants.parsePSM(value)
        if let parsed {
            log("L2CAP PSM characteristic: \(Self.hex(value)) -> PSM \(parsed) (0x\(String(parsed, radix: 16)))")
        } else {
            log("L2CAP PSM characteristic: \(Self.hex(value)) holds no usable PSM, falling back to \(GATTConstants.defaultL2CAPPSM)")
        }
        openL2CAP(psm: parsed ?? GATTConstants.defaultL2CAPPSM, on: peripheral)
    }

    private func openL2CAP(psm: UInt16, on peripheral: CBPeripheral) {
        guard l2capPipe == nil, !l2capOpening else { return }
        guard !triedPSMs.contains(psm) else {
            log("L2CAP PSM \(psm) was already tried on this connection, not retrying")
            return
        }
        guard peripheral.state == .connected else { return }
        triedPSMs.insert(psm)
        l2capOpening = true
        log("Opening L2CAP channel on PSM \(psm)...")
        peripheral.openL2CAPChannel(CBL2CAPPSM(psm))
    }

    /// The L2CAP channel is open: wrap its streams and start the AirShield handshake.
    private func startAirShield(on channel: CBL2CAPChannel) {
        guard let pipe = L2CAPPipe(channel: channel) else {
            log("L2CAP channel opened without streams, cannot use it")
            lastError = "The glasses opened a data channel with no streams."
            return
        }
        let generation = connectionGeneration
        let link = AirShieldLink()

        // Stream callbacks arrive on the main thread; everything else lives on bleQueue.
        pipe.onBytes = { [weak self] bytes in
            self?.bleQueue.async { [weak self] in
                guard let self, self.connectionGeneration == generation else { return }
                self.log("L2CAP RX \(bytes.count) bytes: \(Self.hex(Data(bytes), limit: 48))")
                self.airShield?.feed(bytes)
            }
        }
        pipe.onEvent = { [weak self] event in
            self?.bleQueue.async { [weak self] in
                guard let self, self.connectionGeneration == generation else { return }
                self.log(event)
            }
        }
        pipe.onClosed = { [weak self] reason in
            self?.bleQueue.async { [weak self] in
                guard let self, self.connectionGeneration == generation else { return }
                self.log(reason)
                self.l2capPipe = nil
                self.airShield = nil
                self.airShieldSecure = false
                self.forger = nil
                self.forgerPhase = .idle
                self.forgerFailure = ""
                self.trustExchange = nil
                self.trustPhase = .idle
                self.trustFailure = ""
                self.firmwareManager = nil
                self.firmwarePhase = .idle
                self.firmwareFailure = ""
                self.firmwareProgress = 0
                self.mobileConfigManager = nil
                self.mobileConfigPhase = .idle
                self.mobileConfigFailure = ""
                self.airshipSender = nil
                if self.connectionState == .connected || self.connectionState == .authenticated {
                    self.connectionState = .discoveringServices
                }
                self.lastError = "The glasses closed the data channel. See the debug log."
            }
        }

        link.log = { [weak self] message in self?.log(message) }
        link.send = { [weak self] bytes in
            guard let self else { return }
            self.log("L2CAP TX \(bytes.count) bytes")
            self.l2capPipe?.write(bytes)
        }
        link.onSecure = { [weak self] in
            guard let self else { return }
            self.connectionState = .connected
            self.airShieldSecure = true
            self.log("AirShield link is up. Asking the glasses for their identity (svc36 0x3000)...")
            self.airShield?.requestIdentity()
            if self.ownerSigningKey != nil {
                self.log("Owner key loaded — will start trust exchange after identity response")
            } else {
                self.log("No owner key — services will stay locked")
            }
        }
        link.onMessage = { [weak self] message in
            guard let self else { return }
            let isSvc36 = message.header.serviceID == AirShieldLink.serviceIdentity || message.header.serviceID == 0

            if let trust = self.trustExchange, trust.phase == .proving || trust.phase == .waitingForGlassesPush {
                if isSvc36 {
                    trust.handleMessage(message, link: link)
                    self.trustPhase = trust.phase
                    self.trustFailure = trust.failureReason
                }
                return
            }

            if isSvc36 && message.header.messageType == AirShieldLink.typeIdentityResponse && !message.header.hasError {
                if let key = self.ownerSigningKey, let peer = link.peerRequest {
                    let params = OwnerTrustExchange.HandshakeParams(
                        glassesChallenge: peer.challenge,
                        glassesPubkey: peer.publicKey,
                        ourSeed: link.mySeed,
                        ourPubkey: Array(link.privateKey.publicKey.rawRepresentation)
                    )
                    let exchange = OwnerTrustExchange()
                    exchange.log = { [weak self] msg in self?.log(msg) }
                    self.trustExchange = exchange
                    self.trustPhase = .proving
                    exchange.start(link: link, params: params, ownerKey: key)
                    return
                }
            }

            if let forger = self.forger, forger.phase != .idle && forger.phase != .failed && forger.phase != .succeeded {
                if isSvc36 {
                    forger.handleMessage(message, link: link)
                    self.forgerPhase = forger.phase
                    self.forgerFailure = forger.failureReason
                }
            }

            let svcID = message.header.serviceID

            // svc29: firmware session messages
            if svcID == FirmwareManager.serviceFirmware || (svcID == 0 && self.firmwareManager != nil) {
                if let fm = self.firmwareManager, fm.phase != .idle && fm.phase != .failed && fm.phase != .succeeded {
                    fm.handleMessage(message, link: link)
                    self.firmwarePhase = fm.phase
                    self.firmwareFailure = fm.failureReason
                    self.firmwareProgress = fm.transferProgress
                }
            }

            // svc20: airship file transfer messages (routed to active sender)
            if svcID == 20 || (svcID == 0 && (self.firmwareManager != nil || self.mobileConfigManager != nil)) {
                self.firmwareManager?.handleAirshipMessage(message)
                self.mobileConfigManager?.handleAirshipMessage(message)
                if let fm = self.firmwareManager {
                    self.firmwarePhase = fm.phase
                    self.firmwareProgress = fm.transferProgress
                }
                if let mc = self.mobileConfigManager {
                    self.mobileConfigPhase = mc.phase
                    self.mobileConfigFailure = mc.failureReason
                }
            }

            // svc19: MobileConfig sync messages
            if svcID == MobileConfigManager.serviceMobileConfig {
                if let mc = self.mobileConfigManager {
                    mc.handleMessage(message, link: link)
                    self.mobileConfigPhase = mc.phase
                    self.mobileConfigFailure = mc.failureReason
                }
            }
        }
        link.onFailure = { [weak self] reason in
            self?.lastError = "Encrypted link to the glasses failed: \(reason)"
        }

        l2capPipe = pipe
        airShield = link
        pipe.open()
        link.start()
    }

    // MARK: - DataX characteristic selection

    /// Pick the DataX characteristic out of everything the Meta service exposes.
    ///
    /// The known Stories gen 1 UUID wins. If it is absent we fall back to the first
    /// write + notify characteristic on the service, which is what the DataX channel
    /// looks like on the wire, and say so loudly in the log.
    private func selectDataXCharacteristic(from chars: [CBCharacteristic], on peripheral: CBPeripheral) {
        let chosen: CBCharacteristic
        if let exact = chars.first(where: { $0.uuid == GATTConstants.dataXCharacteristicUUID }) {
            chosen = exact
            dataXIsFallback = false
            log("DataX characteristic found by UUID")
        } else if let candidate = chars.first(where: { Self.isWriteAndNotify($0) }) {
            chosen = candidate
            dataXIsFallback = true
            log("DataX UUID \(GATTConstants.dataXCharacteristicUUID.uuidString) is NOT on FD5F")
            log("FALLBACK: using first write+notify char \(candidate.uuid.uuidString) as DataX (unverified)")
        } else {
            log("FD5F has \(chars.count) chars but none is write+notify, so no DataX candidate")
            lastError = "Glasses service found, but no usable DataX characteristic. See the debug log."
            return
        }

        dataXCharacteristic = chosen
        if chosen.properties.contains(.notify) || chosen.properties.contains(.indicate) {
            // .connected is set once the subscription is confirmed (didUpdateNotificationState).
            // If the CCCD needs an encrypted link, this write is what makes iOS pair.
            log("Subscribing to DataX \(chosen.uuid.uuidString)...")
            peripheral.setNotifyValue(true, for: chosen)
        } else {
            log("DataX has no notify/indicate property, marking connected without subscribing")
            connectionState = .connected
        }
    }

    private func isDataX(_ characteristic: CBCharacteristic) -> Bool {
        guard let dataX = dataXCharacteristic else { return false }
        return characteristic === dataX
            || (characteristic.uuid == dataX.uuid && characteristic.service?.uuid == dataX.service?.uuid)
    }

    // MARK: - Empty Meta service recovery

    /// Called whenever FD5F comes back with no characteristics (or is missing altogether).
    ///
    /// Ladder: re-discover the characteristics after a pause, then re-discover every
    /// service, then drop the link once and reconnect so iOS re-reads the GATT table
    /// (CoreBluetooth answers repeat discoveries from its per-connection cache, so only
    /// a new connection is guaranteed to go back over the air). After that, give up and
    /// explain, but keep the link up so a Service Changed indication can still rescue us.
    private func handleMetaServiceEmpty(_ what: String) {
        metaEmptyCount += 1
        let generation = connectionGeneration
        log("\(what) (empty result #\(metaEmptyCount)\(reconnectAttempted ? ", after reconnect" : ""))")

        if !reconnectAttempted {
            switch metaEmptyCount {
            case 1:
                log("Retry 1: re-discovering FD5F characteristics in 1.5 s")
                scheduleMetaCharacteristicRediscovery(after: 1.5, generation: generation)
            case 2:
                log("Retry 2: re-discovering ALL services in 2 s")
                bleQueue.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                    guard let self, self.connectionGeneration == generation,
                          let peripheral = self.connectedPeripheral,
                          peripheral.state == .connected else { return }
                    self.log("Re-discovering ALL services now")
                    peripheral.discoverServices(nil)
                }
            default:
                reconnectForFreshGATT()
            }
        } else if metaEmptyCount == 1 {
            log("Retry after reconnect: re-discovering FD5F characteristics in 2 s")
            scheduleMetaCharacteristicRediscovery(after: 2.0, generation: generation)
        } else {
            reportMetaServiceStillEmpty()
        }
    }

    private func scheduleMetaCharacteristicRediscovery(after delay: TimeInterval, generation: Int) {
        bleQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.connectionGeneration == generation,
                  let peripheral = self.connectedPeripheral,
                  peripheral.state == .connected else { return }
            if let service = peripheral.services?.first(where: { $0.uuid == GATTConstants.metaServiceUUID }) {
                self.log("Re-discovering FD5F characteristics now (nil filter)")
                peripheral.discoverCharacteristics(nil, for: service)
            } else {
                self.log("FD5F not in the service list, re-discovering ALL services instead")
                peripheral.discoverServices(nil)
            }
        }
    }

    /// Drop the BLE link once and connect again so the GATT table is read fresh.
    private func reconnectForFreshGATT() {
        guard let peripheral = connectedPeripheral else { return }
        reconnectAttempted = true
        metaEmptyCount = 0
        pendingReconnect = peripheral
        dataXCharacteristic = nil
        dataXLink.reset()
        connectionState = .connecting
        log("Retry 3: disconnecting and reconnecting to force a fresh GATT read")
        centralManager.cancelPeripheralConnection(peripheral)
    }

    private func reportMetaServiceStillEmpty() {
        log("GAVE UP: FD5F still has no characteristics after retries + reconnect")
        log("Discovery was UNFILTERED, so this is not a wrong-UUID problem:")
        log("the glasses (or the iOS GATT cache) list nothing under FD5F on this link.")
        log("Try 1: Settings > Bluetooth OFF then ON (flushes the iOS GATT cache), reconnect")
        log("Try 2: Forget the glasses in Settings > Bluetooth, pairing mode again, connect from OpenGlass FIRST")
        log("Try 3: open the glasses in nRF Connect and compare what it lists under FD5F")
        log("Link left open: still listening for Service Changed (didModifyServices)")
        lastError = "Connected, but the glasses list no characteristics on their Meta service (FD5F). See the debug log for what to try."
    }

    // MARK: - Log formatting helpers

    private static func isWriteAndNotify(_ characteristic: CBCharacteristic) -> Bool {
        let p = characteristic.properties
        let writable = p.contains(.write) || p.contains(.writeWithoutResponse)
        let notifiable = p.contains(.notify) || p.contains(.indicate)
        return writable && notifiable
    }

    private static func describe(properties: CBCharacteristicProperties) -> String {
        var names: [String] = []
        if properties.contains(.broadcast) { names.append("broadcast") }
        if properties.contains(.read) { names.append("read") }
        if properties.contains(.writeWithoutResponse) { names.append("writeNoRsp") }
        if properties.contains(.write) { names.append("write") }
        if properties.contains(.notify) { names.append("notify") }
        if properties.contains(.indicate) { names.append("indicate") }
        if properties.contains(.authenticatedSignedWrites) { names.append("signedWrite") }
        if properties.contains(.extendedProperties) { names.append("extended") }
        if properties.contains(.notifyEncryptionRequired) { names.append("notifyEncRequired") }
        if properties.contains(.indicateEncryptionRequired) { names.append("indicateEncRequired") }
        return "[" + names.joined(separator: ",") + "] raw=0x" + String(properties.rawValue, radix: 16)
    }

    /// Error text plus domain/code, with a note when the error is the kind that starts BLE pairing.
    private static func describe(error: Error) -> String {
        let ns = error as NSError
        var text = "\(ns.localizedDescription) [\(ns.domain) \(ns.code)]"
        if ns.domain == CBATTErrorDomain {
            switch ns.code {
            case CBATTError.Code.insufficientAuthentication.rawValue,
                 CBATTError.Code.insufficientEncryption.rawValue,
                 CBATTError.Code.insufficientAuthorization.rawValue,
                 CBATTError.Code.insufficientEncryptionKeySize.rawValue:
                text += " <- link security required: iOS should offer to pair; accept, then reconnect"
            default:
                break
            }
        }
        return text
    }

    private static func hex(_ data: Data, limit: Int = 40) -> String {
        let shown = data.prefix(limit).map { String(format: "%02x", $0) }.joined()
        return data.count > limit ? shown + "...(+\(data.count - limit))" : shown
    }

    /// One-line summary of an advertisement, for working out what state the glasses are in.
    private static func describe(advertisement: [String: Any]) -> String {
        var parts: [String] = []
        if let uuids = advertisement[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID], !uuids.isEmpty {
            parts.append("svc=" + uuids.map { $0.uuidString }.joined(separator: ","))
        }
        if let serviceData = advertisement[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] {
            for (uuid, data) in serviceData {
                parts.append("svcData[\(uuid.uuidString)]=\(hex(data))")
            }
        }
        if let manufacturer = advertisement[CBAdvertisementDataManufacturerDataKey] as? Data {
            parts.append("mfg=\(hex(manufacturer))")
        }
        if let connectable = advertisement[CBAdvertisementDataIsConnectable] as? NSNumber {
            parts.append("connectable=\(connectable.boolValue)")
        }
        return parts.isEmpty ? "(no adv fields)" : parts.joined(separator: " ")
    }
}

// MARK: - CBCentralManagerDelegate

extension BluetoothManager: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let stateName: String
        switch central.state {
        case .unknown: stateName = "unknown"
        case .resetting: stateName = "resetting"
        case .unsupported: stateName = "unsupported"
        case .unauthorized: stateName = "unauthorized"
        case .poweredOff: stateName = "poweredOff"
        case .poweredOn: stateName = "poweredOn"
        @unknown default: stateName = "rawValue(\(central.state.rawValue))"
        }
        log("centralManagerDidUpdateState: \(stateName)")
        if central.state != .poweredOn {
            cleanup()
        }
    }

    func centralManager(_ central: CBCentralManager,
                         willRestoreState dict: [String: Any]) {
        if let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
           let first = peripherals.first {
            connectedPeripheral = first
            first.delegate = self
            connectionState = .connected
        }
    }

    func centralManager(_ central: CBCentralManager,
                         didDiscover peripheral: CBPeripheral,
                         advertisementData: [String: Any],
                         rssi RSSI: NSNumber) {
        let name = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? ""
        // With unfiltered scanning we see every nearby BLE device.
        // Only accept devices whose name starts with the glasses prefix.
        guard !name.isEmpty, name.hasPrefix(GATTConstants.deviceNamePrefix) else { return }
        log("didDiscover: \(name) RSSI=\(RSSI)")
        log("  adv: \(Self.describe(advertisement: advertisementData))")
        addDiscoveredPeripheral(peripheral, source: "scan RSSI=\(RSSI)")
    }

    func centralManager(_ central: CBCentralManager,
                         didConnect peripheral: CBPeripheral) {
        log("Connected to \(peripheral.name ?? "unknown"), discovering services...")
        let withRsp = peripheral.maximumWriteValueLength(for: .withResponse)
        let withoutRsp = peripheral.maximumWriteValueLength(for: .withoutResponse)
        log("  max write: \(withRsp) with rsp / \(withoutRsp) without rsp")
        saveKnownPeripheralID(peripheral.identifier)
        discoverAllServices()
    }

    func centralManager(_ central: CBCentralManager,
                         didFailToConnect peripheral: CBPeripheral,
                         error: Error?) {
        let msg = error.map { Self.describe(error: $0) } ?? "unknown"
        lastError = error?.localizedDescription ?? "Connection failed."
        log("didFailToConnect: \(msg)")
        cleanup()
    }

    func centralManager(_ central: CBCentralManager,
                         didDisconnectPeripheral peripheral: CBPeripheral,
                         error: Error?) {
        if let pending = pendingReconnect, pending.identifier == peripheral.identifier {
            // Planned drop: connect again so iOS re-reads the GATT table.
            pendingReconnect = nil
            connectionGeneration += 1
            let generation = connectionGeneration
            log("didDisconnectPeripheral: planned drop done, reconnecting in 1 s")
            bleQueue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self, self.connectionGeneration == generation,
                      let target = self.connectedPeripheral else { return }
                self.startConnection(to: target)
            }
            return
        }
        if let error {
            log("didDisconnectPeripheral: \(Self.describe(error: error))")
            lastError = "Disconnected: \(error.localizedDescription)"
        } else {
            log("didDisconnectPeripheral: clean disconnect")
        }
        cleanup()
    }
}

// MARK: - CBPeripheralDelegate

extension BluetoothManager: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral,
                     didDiscoverServices error: Error?) {
        if let error {
            lastError = "Service discovery failed: \(error.localizedDescription)"
            log("didDiscoverServices ERROR: \(Self.describe(error: error))")
            return
        }
        let services = peripheral.services ?? []
        log("didDiscoverServices: \(services.count) services")
        for service in services {
            log("  service: \(service.uuid.uuidString) primary=\(service.isPrimary)")
            // Always discover with a nil filter. A UUID filter makes CoreBluetooth hide
            // every characteristic that does not match, so "0 chars" from a filtered call
            // cannot tell "nothing there" apart from "something there under another UUID".
            peripheral.discoverCharacteristics(nil, for: service)
        }
        if !services.contains(where: { $0.uuid == GATTConstants.metaServiceUUID }) {
            handleMetaServiceEmpty("Meta service FD5F is not in the service list")
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                     didDiscoverCharacteristicsFor service: CBService,
                     error: Error?) {
        if let error {
            log("didDiscoverCharacteristics ERROR for \(service.uuid.uuidString): \(Self.describe(error: error))")
            return
        }
        let chars = service.characteristics ?? []
        let isMetaService = service.uuid == GATTConstants.metaServiceUUID
        log("didDiscoverCharacteristics: \(chars.count) chars for service \(service.uuid.uuidString) (unfiltered)")
        for characteristic in chars {
            log("  char: \(characteristic.uuid.uuidString) \(Self.describe(properties: characteristic.properties))")
        }

        if isMetaService {
            if chars.isEmpty {
                handleMetaServiceEmpty("FD5F returned 0 characteristics")
                return
            }
            metaEmptyCount = 0
            if chars.contains(where: { $0.uuid == GATTConstants.psmCharacteristicUUID }) {
                // Ray-Ban Meta: FD5F has no data characteristic, only the PSM of an L2CAP
                // channel. Reading it (below) is what opens the channel.
                if !usesL2CAP {
                    usesL2CAP = true
                    log("FD5F holds the L2CAP PSM characteristic: Ray-Ban Meta link (L2CAP + AirShield), no GATT DataX")
                }
            } else {
                let current = dataXCharacteristic
                if current == nil || !chars.contains(where: { $0 === current }) {
                    selectDataXCharacteristic(from: chars, on: peripheral)
                }
            }
        }

        for characteristic in chars {
            if isMetaService {
                // Map the whole proprietary service: descriptors, readable values, and
                // every notify source. Any of these that needs an encrypted link is also
                // what makes iOS start pairing, since CoreBluetooth has no explicit bond call.
                peripheral.discoverDescriptors(for: characteristic)
                let canNotify = characteristic.properties.contains(.notify)
                    || characteristic.properties.contains(.indicate)
                if canNotify && !isDataX(characteristic) {
                    peripheral.setNotifyValue(true, for: characteristic)
                }
            }
            if characteristic.properties.contains(.read) {
                peripheral.readValue(for: characteristic)
            }
            if characteristic.uuid == GATTConstants.batteryLevelUUID {
                peripheral.setNotifyValue(true, for: characteristic)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                     didDiscoverDescriptorsFor characteristic: CBCharacteristic,
                     error: Error?) {
        if let error {
            log("didDiscoverDescriptors ERROR for \(characteristic.uuid.uuidString): \(Self.describe(error: error))")
            return
        }
        let descriptors = (characteristic.descriptors ?? []).map { $0.uuid.uuidString }
        let list = descriptors.isEmpty ? "none" : descriptors.joined(separator: ",")
        log("  descriptors for \(characteristic.uuid.uuidString): \(list)")
    }

    func peripheral(_ peripheral: CBPeripheral,
                     didModifyServices invalidatedServices: [CBService]) {
        // The glasses changed their GATT table (Service Changed). This is how a service
        // that was empty before pairing / unlock would announce its characteristics.
        let names = invalidatedServices.map { $0.uuid.uuidString }.joined(separator: ",")
        log("didModifyServices: invalidated [\(names)], re-discovering ALL services")
        if let dataX = dataXCharacteristic,
           invalidatedServices.contains(where: { $0.uuid == dataX.service?.uuid }) {
            dataXCharacteristic = nil
            dataXLink.reset()
            if connectionState == .connected || connectionState == .authenticated {
                connectionState = .discoveringServices
            }
        }
        metaEmptyCount = 0
        peripheral.discoverServices(nil)
    }

    func peripheral(_ peripheral: CBPeripheral,
                     didOpen channel: CBL2CAPChannel?,
                     error: Error?) {
        l2capOpening = false
        if let error {
            log("L2CAP open FAILED: \(Self.describe(error: error))")
            // The characteristic can name a PSM the glasses refuse; the usual one is worth one try.
            if !triedPSMs.contains(GATTConstants.defaultL2CAPPSM) {
                log("Retrying on the usual PSM \(GATTConstants.defaultL2CAPPSM)")
                openL2CAP(psm: GATTConstants.defaultL2CAPPSM, on: peripheral)
            } else {
                lastError = "Could not open the glasses' data channel: \(error.localizedDescription)"
            }
            return
        }
        guard let channel else {
            log("L2CAP open returned neither a channel nor an error")
            return
        }
        guard l2capPipe == nil else {
            log("L2CAP channel opened twice (PSM \(channel.psm)), ignoring the second")
            return
        }
        log("L2CAP channel open on PSM \(channel.psm), starting the AirShield handshake")
        startAirShield(on: channel)
    }

    func peripheralDidUpdateName(_ peripheral: CBPeripheral) {
        log("peripheralDidUpdateName: \(peripheral.name ?? "nil")")
    }

    func peripheral(_ peripheral: CBPeripheral,
                     didUpdateValueFor characteristic: CBCharacteristic,
                     error: Error?) {
        if let error {
            log("didUpdateValue ERROR for \(characteristic.uuid.uuidString): \(Self.describe(error: error))")
            return
        }
        guard let value = characteristic.value else { return }

        if isDataX(characteristic) {
            log("DataX RX \(value.count) bytes: \(Self.hex(value, limit: 16))")
            if let message = dataXLink.receive(data: value) {
                logger.debug("DataX message received, \(message.count) bytes")
                onDataXMessage?(message)
            }
            return
        }

        log("didUpdateValue: \(characteristic.uuid.uuidString) (\(value.count) bytes) \(Self.hex(value))")

        if characteristic.uuid == GATTConstants.psmCharacteristicUUID
            && characteristic.service?.uuid == GATTConstants.metaServiceUUID {
            handlePSMValue(value, on: peripheral)
            return
        }

        switch characteristic.uuid {
        case GATTConstants.batteryLevelUUID:
            if let byte = value.first {
                batteryLevel = Int(byte)
                logger.debug("Battery: \(byte)%")
            }

        case GATTConstants.firmwareRevisionUUID:
            firmwareRevision = String(data: value, encoding: .utf8)

        case GATTConstants.modelNumberUUID:
            modelNumber = String(data: value, encoding: .utf8)

        case GATTConstants.serialNumberUUID:
            serialNumber = String(data: value, encoding: .utf8)

        default:
            break
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                     didWriteValueFor characteristic: CBCharacteristic,
                     error: Error?) {
        if let error {
            log("Write FAILED on \(characteristic.uuid.uuidString): \(Self.describe(error: error))")
            lastError = "Write failed: \(error.localizedDescription)"
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                     didUpdateNotificationStateFor characteristic: CBCharacteristic,
                     error: Error?) {
        let forDataX = isDataX(characteristic)
        let tag = forDataX ? " (DataX)" : ""
        if let error {
            log("Subscribe FAILED on \(characteristic.uuid.uuidString)\(tag): \(Self.describe(error: error))")
            if forDataX {
                lastError = "Could not subscribe to the glasses' data channel: \(error.localizedDescription)"
            }
            return
        }
        log("Notify \(characteristic.isNotifying ? "ON" : "OFF") for \(characteristic.uuid.uuidString)\(tag)")
        if forDataX && characteristic.isNotifying
            && (connectionState == .discoveringServices || connectionState == .connecting) {
            connectionState = .connected
            log("DataX ready\(dataXIsFallback ? " (FALLBACK characteristic, unverified)" : ""), link is up")
        }
    }
}

// MARK: - ISO8601 formatter (reused for debug timestamps)

private extension ISO8601DateFormatter {
    nonisolated(unsafe) static let shared: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withTime, .withColonSeparatorInTime]
        return f
    }()
}
