// svc20 Airship file transfer: chunked sender with adler32 integrity.
// Used by firmware OTA (namespace "ota") and MobileConfig (namespace "mobileconfig").

import Foundation

final class AirshipSender {

    enum Phase: String {
        case idle             = "Idle"
        case offering         = "Offering file..."
        case sending          = "Sending..."
        case completing       = "Verifying..."
        case succeeded        = "Transfer complete"
        case refused          = "Refused"
        case failed           = "Failed"
    }

    private static let serviceAirship = 20

    private enum MsgType {
        static let fileOffer    = 1
        static let cursor       = 2   // from receiver
        static let reset        = 3
        static let data         = 4
        static let check        = 5
        static let complete     = 6
        static let drop         = 7   // from receiver (also = success at end)
        static let removed      = 8
        static let queueEmpty   = 10
        static let stopped      = 11
    }

    private static let chunkSize = 1024
    private static let checkInterval = 32  // send a check every N chunks

    private(set) var phase: Phase = .idle
    private(set) var failureReason: String = ""
    private(set) var bytesSent: Int = 0
    private(set) var totalBytes: Int = 0
    var log: ((String) -> Void)?
    var onComplete: (() -> Void)?

    private var fileData: [UInt8] = []
    private var fileUUID: [UInt8] = []
    private var namespace: String = ""
    private var basename: String = ""
    private var channelID: Int = 0
    private var offset: Int = 0
    private var adler: UInt32 = 1
    private var chunksSinceCheck: Int = 0
    private weak var link: AirShieldLink?

    // MARK: - Start

    func start(
        link: AirShieldLink,
        data: [UInt8],
        uuid: [UInt8],
        namespace: String,
        basename: String
    ) {
        self.link = link
        self.fileData = data
        self.fileUUID = uuid
        self.namespace = namespace
        self.basename = basename
        self.totalBytes = data.count
        self.offset = 0
        self.adler = 1
        self.bytesSent = 0
        self.chunksSinceCheck = 0

        channelID = link.openChannel()
        phase = .offering
        emit("Offering file: \(basename) (\(data.count) bytes) on namespace '\(namespace)'")

        var payload = ProtoWire.field(1, bytes: uuid)
        payload += ProtoWire.field(2, varint: UInt64(data.count))
        payload += ProtoWire.field(3, bytes: Array(namespace.utf8))
        payload += ProtoWire.field(4, bytes: Array(basename.utf8))

        link.sendMessage(
            channelID: channelID,
            serviceID: Self.serviceAirship,
            messageType: MsgType.fileOffer,
            payload: payload
        )
    }

    // MARK: - Message handler

    func handleMessage(_ message: AirShieldMessage) {
        let header = message.header

        switch header.messageType {
        case MsgType.cursor:
            handleCursor(message.payload)

        case MsgType.drop:
            if phase == .completing {
                phase = .succeeded
                emit("Transfer verified and accepted by glasses")
                onComplete?()
            } else {
                phase = .refused
                emit("File refused by glasses")
            }

        default:
            emit("Unexpected svc20 type \(header.messageType)")
        }
    }

    private func handleCursor(_ payload: [UInt8]) {
        let fields = ProtoWire.parse(payload)
        let resumeOffset = Int(fields.varint(1))
        let resumeAdler = UInt32(fields.varint(2))

        if phase == .offering {
            emit("Glasses accepted, resume from offset \(resumeOffset)")
        } else if phase == .sending || phase == .completing {
            if resumeOffset < offset {
                emit("Glasses requested rewind to \(resumeOffset)")
            }
        }

        offset = min(resumeOffset, fileData.count)
        adler = recomputeAdler(upTo: offset)
        bytesSent = offset
        phase = .sending
        chunksSinceCheck = 0
        sendChunks()
    }

    // MARK: - Chunk sending

    private func sendChunks() {
        guard let link, phase == .sending else { return }

        while offset < fileData.count {
            let end = min(offset + Self.chunkSize, fileData.count)
            let chunk = Array(fileData[offset..<end])

            link.sendMessage(
                channelID: channelID,
                serviceID: nil,
                messageType: MsgType.data,
                payload: chunk
            )

            adler = Self.adler32Update(adler, chunk)
            offset = end
            bytesSent = offset
            chunksSinceCheck += 1

            if chunksSinceCheck >= Self.checkInterval {
                sendCheck()
                chunksSinceCheck = 0
            }
        }

        phase = .completing
        emit("All \(totalBytes) bytes sent, sending completion check")
        sendComplete()
    }

    private func sendCheck() {
        guard let link else { return }
        var payload = ProtoWire.field(1, varint: UInt64(offset))
        payload += ProtoWire.field(2, varint: UInt64(adler))
        link.sendMessage(
            channelID: channelID,
            serviceID: nil,
            messageType: MsgType.check,
            payload: payload
        )
    }

    private func sendComplete() {
        guard let link else { return }
        var payload = ProtoWire.field(1, varint: UInt64(fileData.count))
        let finalAdler = recomputeAdler(upTo: fileData.count)
        payload += ProtoWire.field(2, varint: UInt64(finalAdler))
        link.sendMessage(
            channelID: channelID,
            serviceID: nil,
            messageType: MsgType.complete,
            payload: payload
        )
        emit("Sent complete: size=\(fileData.count), adler32=\(String(format: "0x%08x", finalAdler))")
    }

    // MARK: - Adler32

    private func recomputeAdler(upTo end: Int) -> UInt32 {
        Self.adler32Update(1, Array(fileData[0..<end]))
    }

    static func adler32Update(_ seed: UInt32, _ data: [UInt8]) -> UInt32 {
        var a = seed & 0xFFFF
        var b = (seed >> 16) & 0xFFFF
        for byte in data {
            a = (a + UInt32(byte)) % 65521
            b = (b + a) % 65521
        }
        return (b << 16) | a
    }

    // MARK: - Helpers

    var progress: Double {
        totalBytes > 0 ? Double(bytesSent) / Double(totalBytes) : 0
    }

    func cancel() {
        guard let link, phase == .sending || phase == .offering else { return }
        var payload = ProtoWire.field(1, bytes: fileUUID)
        payload += ProtoWire.field(2, varint: 0) // reason: DROPPED
        link.sendMessage(
            channelID: channelID,
            serviceID: nil,
            messageType: MsgType.stopped,
            payload: payload
        )
        phase = .failed
        failureReason = "Cancelled"
        emit("Transfer cancelled")
    }

    private func emit(_ message: String) {
        log?("[Airship] \(message)")
    }
}
