// svc20 Airship file receiver: download photos/videos FROM the glasses over BLE.
// Counterpart to AirshipSender (which uploads TO glasses). Uses 1024-byte BLE chunks.
//
// Flow (mirror of AirshipSender): the glasses open a channel and send a file offer
// (type 1). We answer with a cursor/accept (type 2), they stream data (type 4) with
// periodic checks (type 5), then complete (type 6). We answer the complete with a
// drop (type 7), which the sender side treats as "received OK".
//
// While a receiver exists it accepts EVERY file the glasses offer and saves it. It never
// drops a file it has not safely written to disk: a drop tells the glasses the file was
// delivered, and they may then free the capture.
//
// UNVERIFIED on real glasses: which channel the replies belong on. Every other
// glasses-initiated exchange in this app (svc4, svc30, svc79) is answered on the mirror
// channel (id ^ 0x8000), so that is what this does.

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

    /// A file that was received, verified, and written to disk.
    struct ReceivedFile: Sendable {
        let uuidHex: String
        let size: Int
        let namespace: String
        let basename: String
        let url: URL
    }

    private struct ActiveTransfer {
        let uuid: [UInt8]
        let uuidHex: String
        let expectedSize: UInt64
        let namespace: String
        let basename: String
        let destinationURL: URL
        var buffer: [UInt8]
        var bytesReceived: Int
        var adler32: UInt32
        var chunks: Int
    }

    private(set) var phase: Phase = .idle
    private(set) var failureReason: String = ""

    var log: ((String) -> Void)?
    /// Called (on the BLE queue) once a file is verified and saved.
    var onFileSaved: ((ReceivedFile) -> Void)?
    /// Called (on the BLE queue) when a transfer that had started could not be finished.
    var onTransferFailed: ((String) -> Void)?

    /// Channel the glasses are sending the current file on (0 = none seen yet).
    private(set) var incomingChannelID: Int = 0

    private let destinationDirectory: URL
    private var currentTransfer: ActiveTransfer?
    private var replyChannelID: Int = 0
    private var replyNeedsServiceTag = false
    private var ownChannelID: Int = 0
    private var ownChannelTagged = false

    init(destinationDirectory: URL) {
        self.destinationDirectory = destinationDirectory
    }

    // MARK: - Public API

    var progress: Double {
        guard let t = currentTransfer, t.expectedSize > 0 else { return 0 }
        return min(Double(t.bytesReceived) / Double(t.expectedSize), 1)
    }

    var bytesReceived: Int { currentTransfer?.bytesReceived ?? 0 }
    var totalBytes: Int { Int(clamping: currentTransfer?.expectedSize ?? 0) }

    /// Note that a download was asked for, so the UI can show "waiting".
    func expectFile() {
        if phase != .receiving {
            phase = .waitingForOffer
            failureReason = ""
        }
    }

    /// True when `message` is a bulk data chunk for the file being received
    /// (used to keep thousands of chunks out of the debug log).
    func isDataChunk(_ message: AirShieldMessage) -> Bool {
        currentTransfer != nil
            && incomingChannelID != 0
            && message.header.channelID == incomingChannelID
            && message.header.messageType == MsgType.data
            && !message.header.hasError
    }

    // MARK: - Message handler (called from bleQueue by BluetoothManager)

    func handleMessage(_ message: AirShieldMessage, link: AirShieldLink) {
        let header = message.header

        if header.hasError {
            emit("svc20 status 0x\(String(format: "%04x", header.errorID)) on ch=0x\(String(format: "%04x", header.channelID))")
            return
        }

        switch header.messageType {
        case MsgType.fileOffer:
            handleOffer(message, link: link)
        case MsgType.data:
            handleDataChunk(message.payload)
        case MsgType.checkpoint:
            handleCheckpoint(message.payload)
        case MsgType.complete:
            handleComplete(message.payload, link: link)
        case MsgType.removed:
            handleRemoved()
        default:
            emit("Unhandled svc20 type \(header.messageType) on ch=0x\(String(format: "%04x", header.channelID)) (\(message.payload.count) bytes): \(Self.hex(message.payload.prefix(48)))")
        }
    }

    // MARK: - Offer handling

    private func handleOffer(_ message: AirShieldMessage, link: AirShieldLink) {
        let payload = message.payload
        let fields = ProtoWire.parse(payload)
        let uuid = fields.bytes(1)
        let size = fields.varint(2)
        let namespace = String(decoding: fields.bytes(3), as: UTF8.self)
        let basename = String(decoding: fields.bytes(4), as: UTF8.self)
        let uuidHex = Self.hex(uuid[...])
        let ch = message.header.channelID

        emit("File offer on ch=0x\(String(format: "%04x", ch)): \"\(basename)\" (\(size) bytes) ns=\"\(namespace)\" uuid=\(uuidHex)")
        emit("Offer raw (\(payload.count) bytes): \(Self.hex(payload.prefix(64)))")

        guard !uuid.isEmpty, size > 0, size <= 2_000_000_000 else {
            emit("Offer does not parse as uuid + size — not accepting, not dropping")
            return
        }

        if let stale = currentTransfer {
            emit("New offer while \"\(stale.basename)\" was still in flight (\(stale.bytesReceived)/\(stale.expectedSize)) — abandoning it")
            onTransferFailed?("Interrupted by another file")
            currentTransfer = nil
        }

        // Reply where the glasses expect it: the mirror of the channel they opened.
        incomingChannelID = ch
        if ch & 0x8000 != 0 {
            replyChannelID = ch ^ 0x8000
            replyNeedsServiceTag = false
        } else {
            if ownChannelID == 0 {
                ownChannelID = link.openChannel()
                ownChannelTagged = false
            }
            replyChannelID = ownChannelID
            replyNeedsServiceTag = !ownChannelTagged
        }

        let fileName = Self.safeFileName(basename: basename, uuidHex: uuidHex)
        var transfer = ActiveTransfer(
            uuid: uuid,
            uuidHex: uuidHex,
            expectedSize: size,
            namespace: namespace,
            basename: basename,
            destinationURL: destinationDirectory.appendingPathComponent(fileName),
            buffer: [],
            bytesReceived: 0,
            adler32: 1,
            chunks: 0
        )
        transfer.buffer.reserveCapacity(Int(min(size, 32_000_000)))
        currentTransfer = transfer

        phase = .receiving
        failureReason = ""
        emit("Accepting file on ch=0x\(String(format: "%04x", replyChannelID)): offset=0, adler32=1")
        sendAccept(link: link, offset: 0, adler32: 1)
    }

    // MARK: - Data chunks

    private func handleDataChunk(_ payload: [UInt8]) {
        guard var transfer = currentTransfer else {
            emit("Data chunk (\(payload.count) bytes) received with no active transfer")
            return
        }
        currentTransfer = nil // avoid a copy-on-write of the buffer
        transfer.buffer.append(contentsOf: payload)
        transfer.bytesReceived += payload.count
        transfer.adler32 = AirshipSender.adler32Update(transfer.adler32, payload)
        transfer.chunks += 1
        if transfer.chunks == 1 || transfer.chunks % 128 == 0 {
            emit("Receiving \"\(transfer.basename)\": \(transfer.bytesReceived)/\(transfer.expectedSize) bytes (\(transfer.chunks) chunks)")
        }
        currentTransfer = transfer
    }

    // MARK: - Checkpoint

    private func handleCheckpoint(_ payload: [UInt8]) {
        guard let transfer = currentTransfer else { return }
        let fields = ProtoWire.parse(payload)
        let checkOffset = Int(clamping: fields.varint(1))
        let checkAdler = UInt32(truncatingIfNeeded: fields.varint(2))

        if transfer.bytesReceived != checkOffset {
            emit("Checkpoint offset mismatch: ours=\(transfer.bytesReceived), theirs=\(checkOffset)")
        } else if transfer.adler32 != checkAdler {
            emit("Checkpoint adler32 mismatch at \(checkOffset): ours=\(String(format: "0x%08x", transfer.adler32)), theirs=\(String(format: "0x%08x", checkAdler))")
        }
    }

    // MARK: - Complete

    private func handleComplete(_ payload: [UInt8], link: AirShieldLink) {
        guard let transfer = currentTransfer else {
            emit("Complete received with no active transfer")
            return
        }
        currentTransfer = nil

        let fields = ProtoWire.parse(payload)
        let totalSize = Int(clamping: fields.varint(1))
        let finalAdler = UInt32(truncatingIfNeeded: fields.varint(2))

        emit("Glasses say complete: \(totalSize) bytes, adler32=\(String(format: "0x%08x", finalAdler)); we have \(transfer.bytesReceived) bytes, adler32=\(String(format: "0x%08x", transfer.adler32))")

        // Verify BEFORE acknowledging. No drop is sent for a bad transfer: a drop reads as
        // "delivered" on the glasses, and the capture must stay there to be fetched again.
        if transfer.bytesReceived != totalSize {
            fail("Size mismatch: expected \(totalSize), got \(transfer.bytesReceived)")
            return
        }
        if transfer.adler32 != finalAdler {
            fail("Checksum mismatch")
            return
        }

        do {
            try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
            try Data(transfer.buffer).write(to: transfer.destinationURL, options: .atomic)
        } catch {
            fail("Could not save file: \(error.localizedDescription)")
            return
        }

        emit("Saved \(totalSize) bytes to \(transfer.destinationURL.lastPathComponent)")
        sendDrop(link: link, uuid: transfer.uuid)
        phase = .complete
        onFileSaved?(ReceivedFile(
            uuidHex: transfer.uuidHex,
            size: totalSize,
            namespace: transfer.namespace,
            basename: transfer.basename,
            url: transfer.destinationURL
        ))
    }

    // MARK: - Removed

    private func handleRemoved() {
        emit("Glasses removed the transfer")
        if currentTransfer != nil {
            currentTransfer = nil
            fail("Glasses cancelled the transfer")
        }
    }

    private func fail(_ reason: String) {
        phase = .failed
        failureReason = reason
        emit("FAILED: \(reason)")
        onTransferFailed?(reason)
    }

    // MARK: - Send helpers

    private func sendAccept(link: AirShieldLink, offset: Int, adler32: UInt32) {
        var payload = ProtoWire.field(1, varint: UInt64(offset))
        payload += ProtoWire.field(2, varint: UInt64(adler32))
        send(link: link, type: MsgType.accept, payload: payload)
    }

    private func sendDrop(link: AirShieldLink, uuid: [UInt8]) {
        var payload = ProtoWire.field(1, bytes: uuid)
        payload += ProtoWire.field(2, varint: 0) // reason: done
        send(link: link, type: MsgType.drop, payload: payload)
        emit("Sent DROP (received OK) for uuid \(Self.hex(uuid.prefix(8)))...")
    }

    private func send(link: AirShieldLink, type: Int, payload: [UInt8]) {
        let sent = link.sendMessage(
            channelID: replyChannelID,
            serviceID: replyNeedsServiceTag ? Self.serviceAirship : nil,
            messageType: type,
            payload: payload
        )
        if replyNeedsServiceTag {
            replyNeedsServiceTag = false
            ownChannelTagged = true
        }
        if !sent {
            emit("svc20 type \(type) could not be sent")
        }
    }

    // MARK: - Helpers

    private static func safeFileName(basename: String, uuidHex: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        let lastComponent = basename.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map { String($0) } ?? ""
        var cleaned = String(lastComponent.map { allowed.contains($0) ? $0 : "_" })
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        let prefix = String(uuidHex.prefix(12))
        if cleaned.isEmpty { return prefix.isEmpty ? "file.bin" : "\(prefix).bin" }
        return "\(prefix)_\(cleaned)"
    }

    static func hex(_ bytes: ArraySlice<UInt8>) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    private func emit(_ message: String) {
        log?("[AirshipRX] \(message)")
    }
}
