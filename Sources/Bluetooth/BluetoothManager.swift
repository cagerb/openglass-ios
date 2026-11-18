import Foundation
import CoreBluetooth
import os

/// Central manager for scanning, connecting, and communicating with
/// Meta Ray-Ban Stories glasses over BLE.
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

    /// UserDefaults key for persisting previously-seen peripheral identifiers.
    private static let knownPeripheralIDsKey = "com.openglass.knownPeripheralIDs"

    /// Callback for complete reassembled DataX messages.
    var onDataXMessage: ((Data) -> Void)?

    // MARK: - Init

    override init() {
        super.init()
        centralManager = CBCentralManager(
            delegate: self,
            queue: DispatchQueue(label: "com.openglass.ble", qos: .userInitiated),
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
        connectionState = .connecting
        connectedPeripheral = peripheral
        peripheral.delegate = self
        log("Connecting to \(peripheral.name ?? "unknown") [\(peripheral.identifier.uuidString.prefix(8))]")
        centralManager.connect(peripheral, options: [
            CBConnectPeripheralOptionNotifyOnConnectionKey: true,
            CBConnectPeripheralOptionNotifyOnDisconnectionKey: true,
        ])
    }

    func disconnect() {
        if let peripheral = connectedPeripheral {
            centralManager.cancelPeripheralConnection(peripheral)
        }
        cleanup()
    }

    /// Send a raw DataX message (will be framed and chunked automatically).
    func sendDataXMessage(type: UInt8, payload: Data) {
        guard let characteristic = dataXCharacteristic,
              let peripheral = connectedPeripheral else {
            lastError = "Not connected or DataX characteristic not found."
            return
        }

        let frames = dataXLink.frame(type: type, payload: payload, mtu: peripheral.maximumWriteValueLength(for: .withResponse))
        for frame in frames {
            peripheral.writeValue(frame, for: characteristic, type: .withResponse)
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
    private func log(_ message: String) {
        let ts = ISO8601DateFormatter.shared.string(from: Date())
        let entry = "[\(ts)] \(message)"
        debugLog.append(entry)
        if debugLog.count > 50 {
            debugLog.removeFirst(debugLog.count - 50)
        }
        logger.info("\(message)")
    }

    private func cleanup() {
        connectedPeripheral = nil
        dataXCharacteristic = nil
        batteryLevel = nil
        firmwareRevision = nil
        modelNumber = nil
        serialNumber = nil
        connectionState = .disconnected
        dataXLink.reset()
    }

    private func discoverAllServices() {
        connectedPeripheral?.discoverServices(nil)  // discover ALL services
        connectionState = .discoveringServices
        log("Discovering ALL services (nil filter)")
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
        addDiscoveredPeripheral(peripheral, source: "scan RSSI=\(RSSI)")
    }

    func centralManager(_ central: CBCentralManager,
                         didConnect peripheral: CBPeripheral) {
        log("Connected to \(peripheral.name ?? "unknown"), discovering services...")
        saveKnownPeripheralID(peripheral.identifier)
        discoverAllServices()
    }

    func centralManager(_ central: CBCentralManager,
                         didFailToConnect peripheral: CBPeripheral,
                         error: Error?) {
        let msg = error?.localizedDescription ?? "unknown"
        lastError = error?.localizedDescription ?? "Connection failed."
        log("didFailToConnect: \(msg)")
        cleanup()
    }

    func centralManager(_ central: CBCentralManager,
                         didDisconnectPeripheral peripheral: CBPeripheral,
                         error: Error?) {
        if let error {
            log("didDisconnectPeripheral: \(error.localizedDescription)")
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
        guard error == nil else {
            let msg = error!.localizedDescription
            lastError = "Service discovery failed: \(msg)"
            log("didDiscoverServices ERROR: \(msg)")
            return
        }
        let services = peripheral.services ?? []
        log("didDiscoverServices: \(services.count) services")
        for service in services {
            log("  service: \(service.uuid.uuidString)")
            switch service.uuid {
            case GATTConstants.metaServiceUUID:
                peripheral.discoverCharacteristics(
                    [GATTConstants.dataXCharacteristicUUID],
                    for: service
                )
            case GATTConstants.batteryServiceUUID:
                peripheral.discoverCharacteristics(
                    [GATTConstants.batteryLevelUUID],
                    for: service
                )
            case GATTConstants.deviceInfoServiceUUID:
                peripheral.discoverCharacteristics(
                    [GATTConstants.firmwareRevisionUUID,
                     GATTConstants.modelNumberUUID,
                     GATTConstants.serialNumberUUID],
                    for: service
                )
            default:
                peripheral.discoverCharacteristics(nil, for: service)  // discover all chars on unknown services
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                     didDiscoverCharacteristicsFor service: CBService,
                     error: Error?) {
        if let error {
            log("didDiscoverCharacteristics ERROR for \(service.uuid): \(error.localizedDescription)")
            return
        }
        let chars = service.characteristics ?? []
        log("didDiscoverCharacteristics: \(chars.count) chars for service \(service.uuid.uuidString)")
        for characteristic in chars {
            log("  char: \(characteristic.uuid.uuidString) (service \(service.uuid.uuidString))")
            switch characteristic.uuid {
            case GATTConstants.dataXCharacteristicUUID:
                dataXCharacteristic = characteristic
                peripheral.setNotifyValue(true, for: characteristic)
                connectionState = .connected
                log("DataX characteristic discovered and subscribed")

            case GATTConstants.batteryLevelUUID:
                peripheral.readValue(for: characteristic)
                peripheral.setNotifyValue(true, for: characteristic)

            case GATTConstants.firmwareRevisionUUID,
                 GATTConstants.modelNumberUUID,
                 GATTConstants.serialNumberUUID:
                peripheral.readValue(for: characteristic)

            default:
                break
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                     didUpdateValueFor characteristic: CBCharacteristic,
                     error: Error?) {
        if let error {
            log("didUpdateValue ERROR for \(characteristic.uuid): \(error.localizedDescription)")
            return
        }
        guard let value = characteristic.value else { return }
        log("didUpdateValue: \(characteristic.uuid.uuidString) (\(value.count) bytes)")

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

        case GATTConstants.dataXCharacteristicUUID:
            if let message = dataXLink.receive(data: value) {
                logger.debug("DataX message received, \(message.count) bytes")
                onDataXMessage?(message)
            }

        default:
            break
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                     didWriteValueFor characteristic: CBCharacteristic,
                     error: Error?) {
        if let error {
            logger.error("Write failed: \(error.localizedDescription)")
            lastError = "Write failed: \(error.localizedDescription)"
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                     didUpdateNotificationStateFor characteristic: CBCharacteristic,
                     error: Error?) {
        if let error {
            logger.error("Notify state error on \(characteristic.uuid): \(error.localizedDescription)")
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
