import Foundation
import os

/// Implements the DataX framing protocol for Meta glasses BLE communication.
///
/// Wire format per frame:
/// ```
/// [0]    = type byte (message type OR continuation marker)
/// [1..2] = payload length (big-endian UInt16)
/// [3..]  = payload bytes
/// ```
///
/// Messages larger than (MTU - 3) are chunked into multiple frames:
/// - First frame: type = actual message type, length = total payload length
/// - Continuation frames: type = 0xFF, length = chunk payload length
///
/// Reassembly: accumulate payload bytes until total received == declared length.
final class DataXLink: @unchecked Sendable {

    private let logger = Logger(subsystem: "com.openglass.app", category: "DataXLink")

    /// Continuation marker byte — not a real message type.
    static let continuationType: UInt8 = 0xFF

    // MARK: - Reassembly state

    private var pendingType: UInt8?
    private var pendingTotalLength: Int = 0
    private var pendingBuffer = Data()
    private let lock = NSLock()

    // MARK: - Framing (outbound)

    /// Frame a message into one or more BLE write chunks.
    ///
    /// - Parameters:
    ///   - type: The DataX message type byte.
    ///   - payload: The full message payload.
    ///   - mtu: The negotiated BLE MTU (maximum write size including header).
    /// - Returns: An array of `Data` values, each ready to write to the characteristic.
    func frame(type: UInt8, payload: Data, mtu: Int) -> [Data] {
        let maxChunk = max(mtu - GATTConstants.headerSize, 20) // floor at BLE minimum
        var frames: [Data] = []

        if payload.count <= maxChunk {
            // Single frame
            var frame = Data(capacity: GATTConstants.headerSize + payload.count)
            frame.append(type)
            frame.append(UInt8((payload.count >> 8) & 0xFF))
            frame.append(UInt8(payload.count & 0xFF))
            frame.append(payload)
            frames.append(frame)
        } else {
            // Multi-frame: first frame carries the message type and total length
            let firstChunkSize = maxChunk
            var first = Data(capacity: GATTConstants.headerSize + firstChunkSize)
            first.append(type)
            first.append(UInt8((payload.count >> 8) & 0xFF))
            first.append(UInt8(payload.count & 0xFF))
            first.append(payload[0..<firstChunkSize])
            frames.append(first)

            // Continuation frames
            var offset = firstChunkSize
            while offset < payload.count {
                let remaining = payload.count - offset
                let chunkSize = min(remaining, maxChunk)
                var cont = Data(capacity: GATTConstants.headerSize + chunkSize)
                cont.append(Self.continuationType)
                cont.append(UInt8((chunkSize >> 8) & 0xFF))
                cont.append(UInt8(chunkSize & 0xFF))
                cont.append(payload[offset..<(offset + chunkSize)])
                frames.append(cont)
                offset += chunkSize
            }
        }

        logger.debug("Framed type=\(String(format: "0x%02X", type)), \(payload.count) bytes into \(frames.count) frame(s)")
        return frames
    }

    // MARK: - Reassembly (inbound)

    /// Feed a received BLE notification into the reassembler.
    ///
    /// - Parameter data: Raw bytes from the characteristic notification.
    /// - Returns: The complete reassembled payload when the message is fully received,
    ///            or `nil` if more chunks are expected.
    func receive(data: Data) -> Data? {
        guard data.count >= GATTConstants.headerSize else {
            logger.warning("Received runt frame (\(data.count) bytes), ignoring")
            return nil
        }

        lock.lock()
        defer { lock.unlock() }

        let typeByte = data[0]
        let declaredLength = (Int(data[1]) << 8) | Int(data[2])
        let chunkPayload = data.dropFirst(GATTConstants.headerSize)

        if typeByte != Self.continuationType {
            // Start of a new message
            pendingType = typeByte
            pendingTotalLength = declaredLength
            pendingBuffer = Data(chunkPayload)
        } else {
            // Continuation of an in-progress message
            guard pendingType != nil else {
                logger.warning("Received continuation frame with no pending message, ignoring")
                return nil
            }
            pendingBuffer.append(contentsOf: chunkPayload)
        }

        // Check if we have the complete message
        if pendingBuffer.count >= pendingTotalLength {
            let complete = pendingBuffer.prefix(pendingTotalLength)
            let messageType = pendingType!
            logger.debug("Reassembled message type=\(String(format: "0x%02X", messageType)), \(complete.count) bytes")
            resetLocked()
            return Data(complete)
        }

        return nil
    }

    /// Reset the reassembly state (e.g., on disconnect).
    func reset() {
        lock.lock()
        resetLocked()
        lock.unlock()
    }

    private func resetLocked() {
        pendingType = nil
        pendingTotalLength = 0
        pendingBuffer = Data()
    }
}
