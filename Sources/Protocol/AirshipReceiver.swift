// svc20 Airship file receiver: download photos/videos FROM the glasses over BLE.
// Counterpart to AirshipSender (which uploads TO glasses). Uses 1024-byte BLE chunks.
//
// CRITICAL: Type 7 (drop) MUST be sent after EVERY file offer — accepted or not —
// or the glasses' Airship send queue stalls permanently.

import Foundation

final class AirshipReceiver: @unchecked Sendable {

    enum Phase: String {
        case idle             = "Idle"
        case waitingForOffer  = "Waiting for file..."
        case receiving        = "Receiving..."
        case complete         = "Transfer complete"
        case failed           = "Failed"
    }

    static let serviceAirship = 20

    private enum MsgType {
        static let fileOffer    = 1
        static let accept       = 2
        static let data         = 4
        static let checkpoint   = 5
        static let complete     = 6
        static let drop         = 7
        static let removed      = 8
    }

    struct ActiveTransfer {
        let uuid: [UInt8]
        let expectedSize: UInt64
        let namespace: String
        let basename: String
        let destinationURL: URL
        var buffer: [UInt8]
        var bytesReceived: Int
        var adler32: UInt32
        var continuation: CheckedContinuation<URL, Error>?
    }

    private(set) var phase: Phase = .idle
    private(set) var failureReason: String = ""
    private(set) var currentTransfer: ActiveTransfer?

    var log: ((String) -> Void)?

    private var pendingRequests: [String: (uuid: [UInt8], destination: URL, continuation: CheckedContinuation<URL, Error>)] = [:]
    private(set) var channelID: Int = 0
    private var firstMessage = true
    private weak var link: AirShieldLink?

    // MARK: - Public API

    var progress: Double {
        guard let t = currentTransfer, t.expectedSize > 0 else { return 0 }
        return Double(t.bytesReceived) / Double(t.expectedSize)
    }

    var bytesReceived: Int { currentTransfer?.bytesReceived ?? 0 }
    var totalBytes: Int { Int(currentTransfer?.expectedSize ?? 0) }

    func requestDownload(assetUUID: String, destinationURL: URL, link: AirShieldLink) async throws -> URL {
        let uuidBytes = Self.uuidStringToBytes(assetUUID)
        let hexKey = uuidBytes.map { String(format: "%02x", $0) }.joined()

        return try await withCheckedThrowingContinuation { continuation in
            self.link = link
            if self.channelID == 0 {
                self.channelID = link.openChannel()
                self.firstMessage = true
            }
            self.pendingRequests[hexKey] = (uuid: uuidBytes, destination: destinationURL, continuation: continuation)
            self.phase = .waitingForOffer
            self.emit("Registered download request for asset \(assetUUID)")
        }
    }

    func cancel() {
        guard let transfer = currentTransfer, let link else { return }
        sendDrop(link: link, uuid: transfer.uuid)
        let error = AirshipReceiverError.cancelled
        currentTransfer?.continuation?.resume(throwing: error)
        currentTransfer = nil
        phase = .failed
        failureReason = "Cancelled"
        emit("Transfer cancelled")

        for (_, req) in pendingRequests {
            req.continuation.resume(throwing: error)
        }
        pendingRequests.removeAll()
    }

    // MARK: - Message handler (called from bleQueue by BluetoothManager)

    func handleMessage(_ message: AirShieldMessage, link: AirShieldLink) {
        self.link = link
        let msgType = message.header.messageType

        switch msgType {
        case MsgType.fileOffer:
            handleOffer(message.payload, link: link)
        case MsgType.data:
            handleDataChunk(message.payload)
        case MsgType.checkpoint:
            handleCheckpoint(message.payload)
        case MsgType.complete:
            handleComplete(message.payload, link: link)
        case MsgType.removed:
            handleRemoved(message.payload)
        default:
            emit("Unexpected svc20 receive type \(msgType)")
        }
    }

    // MARK: - Offer handling

    private func handleOffer(_ payload: [UInt8], link: AirShieldLink) {
        let fields = ProtoWire.parse(payload)
        let uuid = fields.bytes(1)
        let size = fields.varint(2)
        let namespace = String(decoding: fields.bytes(3), as: UTF8.self)
        let basename = String(decoding: fields.bytes(4), as: UTF8.self)
        let hexKey = uuid.map { String(format: "%02x", $0) }.joined()

        emit("File offer: \(basename) (\(size) bytes) ns=\(namespace) uuid=\(hexKey.prefix(16))...")

        guard let request = pendingRequests.removeValue(forKey: hexKey) else {
            emit("Unrequested file — sending DROP to keep queue clear")
            sendDrop(link: link, uuid: uuid)
            return
        }

        currentTransfer = ActiveTransfer(
            uuid: uuid,
            expectedSize: size,
            namespace: namespace,
            basename: basename,
            destinationURL: request.destination,
            buffer: [],
            bytesReceived: 0,
            adler32: 1,
            continuation: request.continuation
        )
        currentTransfer?.buffer.reserveCapacity(Int(size))

        phase = .receiving
        emit("Accepting file: offset=0, adler32=1")
        sendAccept(link: link, offset: 0, adler32: 1)
    }

    // MARK: - Data chunks

    private func handleDataChunk(_ payload: [UInt8]) {
        guard currentTransfer != nil else {
            emit("Data chunk received with no active transfer")
            return
        }

        currentTransfer!.buffer.append(contentsOf: payload)
        currentTransfer!.bytesReceived += payload.count
        currentTransfer!.adler32 = AirshipSender.adler32Update(currentTransfer!.adler32, payload)
    }

    // MARK: - Checkpoint

    private func handleCheckpoint(_ payload: [UInt8]) {
        guard let transfer = currentTransfer else { return }
        let fields = ProtoWire.parse(payload)
        let checkOffset = Int(fields.varint(1))
        let checkAdler = UInt32(fields.varint(2))

        if transfer.bytesReceived != checkOffset {
            emit("Checkpoint offset mismatch: ours=\(transfer.bytesReceived), theirs=\(checkOffset)")
        }
        if transfer.adler32 != checkAdler {
            emit("Checkpoint adler32 mismatch: ours=\(String(format: "0x%08x", transfer.adler32)), theirs=\(String(format: "0x%08x", checkAdler))")
        } else {
            emit("Checkpoint OK at \(checkOffset) bytes")
        }
    }

    // MARK: - Complete

    private func handleComplete(_ payload: [UInt8], link: AirShieldLink) {
        guard var transfer = currentTransfer else {
            emit("Complete received with no active transfer")
            return
        }

        let fields = ProtoWire.parse(payload)
        let totalSize = Int(fields.varint(1))
        let finalAdler = UInt32(fields.varint(2))

        emit("Transfer complete: \(totalSize) bytes, adler32=\(String(format: "0x%08x", finalAdler))")

        // MUST send drop or queue stalls
        sendDrop(link: link, uuid: transfer.uuid)

        // Verify
        if transfer.bytesReceived != totalSize {
            let err = AirshipReceiverError.sizeMismatch(expected: totalSize, got: transfer.bytesReceived)
            emit("Size mismatch: expected \(totalSize), got \(transfer.bytesReceived)")
            phase = .failed
            failureReason = err.localizedDescription
            transfer.continuation?.resume(throwing: err)
            currentTransfer = nil
            return
        }

        if transfer.adler32 != finalAdler {
            let err = AirshipReceiverError.checksumMismatch
            emit("Adler32 mismatch: ours=\(String(format: "0x%08x", transfer.adler32)), theirs=\(String(format: "0x%08x", finalAdler))")
            phase = .failed
            failureReason = err.localizedDescription
            transfer.continuation?.resume(throwing: err)
            currentTransfer = nil
            return
        }

        // Save to disk
        do {
            let dir = transfer.destinationURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(transfer.buffer).write(to: transfer.destinationURL)
            emit("Saved \(totalSize) bytes to \(transfer.destinationURL.lastPathComponent)")
            phase = .complete
            transfer.continuation?.resume(returning: transfer.destinationURL)
        } catch {
            emit("Failed to save file: \(error.localizedDescription)")
            phase = .failed
            failureReason = error.localizedDescription
            transfer.continuation?.resume(throwing: error)
        }

        currentTransfer = nil
    }

    // MARK: - Removed

    private func handleRemoved(_ payload: [UInt8]) {
        emit("Glasses removed the transfer")
        if let transfer = currentTransfer {
            transfer.continuation?.resume(throwing: AirshipReceiverError.removedByGlasses)
        }
        currentTransfer = nil
        phase = .failed
        failureReason = "Glasses cancelled the transfer"
    }

    // MARK: - Send helpers

    private func sendAccept(link: AirShieldLink, offset: Int, adler32: UInt32) {
        var payload = ProtoWire.field(1, varint: UInt64(offset))
        payload += ProtoWire.field(2, varint: UInt64(adler32))

        let svcID: Int? = firstMessage ? Self.serviceAirship : nil
        link.sendMessage(
            channelID: channelID,
            serviceID: svcID,
            messageType: MsgType.accept,
            payload: payload
        )
        firstMessage = false
    }

    private func sendDrop(link: AirShieldLink, uuid: [UInt8]) {
        var payload = ProtoWire.field(1, bytes: uuid)
        payload += ProtoWire.field(2, varint: 0) // reason: done

        let svcID: Int? = firstMessage ? Self.serviceAirship : nil
        link.sendMessage(
            channelID: channelID,
            serviceID: svcID,
            messageType: MsgType.drop,
            payload: payload
        )
        firstMessage = false
        emit("Sent DROP for uuid \(uuid.prefix(8).map { String(format: "%02x", $0) }.joined())...")
    }

    // MARK: - UUID conversion

    static func uuidStringToBytes(_ uuidString: String) -> [UInt8] {
        let hex = uuidString.replacingOccurrences(of: "-", with: "")
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let nextIndex = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            if let byte = UInt8(hex[index..<nextIndex], radix: 16) {
                bytes.append(byte)
            }
            index = nextIndex
        }
        return bytes
    }

    static func bytesToUUIDString(_ bytes: [UInt8]) -> String {
        guard bytes.count == 16 else {
            return bytes.map { String(format: "%02x", $0) }.joined()
        }
        let parts = [
            bytes[0..<4], bytes[4..<6], bytes[6..<8], bytes[8..<10], bytes[10..<16]
        ]
        return parts.map { $0.map { String(format: "%02x", $0) }.joined() }.joined(separator: "-")
    }

    private func emit(_ message: String) {
        log?("[AirshipRX] \(message)")
    }
}

// MARK: - Errors

enum AirshipReceiverError: Error, LocalizedError {
    case cancelled
    case removedByGlasses
    case sizeMismatch(expected: Int, got: Int)
    case checksumMismatch
    case timeout

    var errorDescription: String? {
        switch self {
        case .cancelled: return "Transfer cancelled"
        case .removedByGlasses: return "Glasses removed the transfer"
        case .sizeMismatch(let expected, let got): return "Size mismatch: expected \(expected), got \(got)"
        case .checksumMismatch: return "Adler32 checksum mismatch"
        case .timeout: return "Transfer timed out"
        }
    }
}
