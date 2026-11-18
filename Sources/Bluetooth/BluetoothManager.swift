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

    // MARK: - Internal

    private var centralManager: CBCentralManager!
    private var connectedPeripheral: CBPeripheral?
    private var dataXCharacteristic: CBCharacteristic?
    private let dataXLink = DataXLink()
    private let logger = Logger(subsystem: "com.openglass.app", category: "Bluetooth")

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
            return
        }
        discoveredPeripherals.removeAll()
        connectionState = .scanning
        centralManager.scanForPeripherals(
            withServices: [GATTConstants.metaServiceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
        logger.info("Started scanning for glasses (service FD5F)")

        // Pick up glasses already connected at the iOS system level (they
        // stop advertising once paired, so scanForPeripherals won't find them).
        let alreadyConnected = centralManager.retrieveConnectedPeripherals(
            withServices: [GATTConstants.metaServiceUUID]
        )
        for peripheral in alreadyConnected {
            if !discoveredPeripherals.contains(where: { $0.identifier == peripheral.identifier }) {
                discoveredPeripherals.append(peripheral)
                logger.info("Found system-connected peripheral: \(peripheral.name ?? "unknown")")
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
        centralManager.connect(peripheral, options: [
            CBConnectPeripheralOptionNotifyOnConnectionKey: true,
            CBConnectPeripheralOptionNotifyOnDisconnectionKey: true,
        ])
        logger.info("Connecting to \(peripheral.name ?? "unknown")")
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
        connectedPeripheral?.discoverServices([
            GATTConstants.metaServiceUUID,
            GATTConstants.batteryServiceUUID,
            GATTConstants.deviceInfoServiceUUID,
        ])
        connectionState = .discoveringServices
    }
}

// MARK: - CBCentralManagerDelegate

extension BluetoothManager: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        logger.info("Central state: \(String(describing: central.state.rawValue))")
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
        guard name.isEmpty || name.hasPrefix(GATTConstants.deviceNamePrefix) else { return }
        if !discoveredPeripherals.contains(where: { $0.identifier == peripheral.identifier }) {
            discoveredPeripherals.append(peripheral)
            logger.info("Discovered: \(name) RSSI=\(RSSI)")
        }
    }

    func centralManager(_ central: CBCentralManager,
                         didConnect peripheral: CBPeripheral) {
        logger.info("Connected to \(peripheral.name ?? "unknown")")
        discoverAllServices()
    }

    func centralManager(_ central: CBCentralManager,
                         didFailToConnect peripheral: CBPeripheral,
                         error: Error?) {
        lastError = error?.localizedDescription ?? "Connection failed."
        logger.error("Failed to connect: \(error?.localizedDescription ?? "unknown")")
        cleanup()
    }

    func centralManager(_ central: CBCentralManager,
                         didDisconnectPeripheral peripheral: CBPeripheral,
                         error: Error?) {
        logger.info("Disconnected from \(peripheral.name ?? "unknown")")
        if let error {
            lastError = "Disconnected: \(error.localizedDescription)"
        }
        cleanup()
    }
}

// MARK: - CBPeripheralDelegate

extension BluetoothManager: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral,
                     didDiscoverServices error: Error?) {
        guard error == nil else {
            lastError = "Service discovery failed: \(error!.localizedDescription)"
            return
        }
        for service in peripheral.services ?? [] {
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
                break
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                     didDiscoverCharacteristicsFor service: CBService,
                     error: Error?) {
        guard error == nil else { return }
        for characteristic in service.characteristics ?? [] {
            switch characteristic.uuid {
            case GATTConstants.dataXCharacteristicUUID:
                dataXCharacteristic = characteristic
                peripheral.setNotifyValue(true, for: characteristic)
                connectionState = .connected
                logger.info("DataX characteristic discovered and subscribed")

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
        guard error == nil, let value = characteristic.value else { return }

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
