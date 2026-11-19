// svc18 capture list: enumerate photos and videos stored on the glasses,
// request BLE/Wi-Fi transfers, and delete captures.

import Foundation

// MARK: - Data types

struct CaptureEntry: Sendable {
    let handle: String
    let kind: Int // 3073 = photo, 3074 = video
    let timestampNanos: UInt64
    let isLandscape: Bool
    let assets: [AssetEntry]
}

struct AssetEntry: Sendable {
    let uuid: String
    let typeCode: UInt32
    let sizeBytes: UInt64
    var isDelivered: Bool { typeCode & 0x100000 != 0 }
    var mediaType: Int { Int(typeCode & 0xFF) } // 1=MP4, 2=JPEG, 3=IMU, 4=frame
}

// MARK: - FlatBuffer reader

struct FlatBufferReader {

    let buffer: [UInt8]

    struct Table {
        let buffer: [UInt8]
        let pos: Int       // absolute position of the table in the buffer
        let vtable: Int    // absolute position of the vtable

        private var vtableSize: Int {
            Int(readUInt16(buffer, vtable))
        }

        func fieldOffset(slot: Int) -> Int {
            let vtableEntryOffset = slot
            guard vtableEntryOffset < vtableSize else { return 0 }
            return Int(readUInt16(buffer, vtable + vtableEntryOffset))
        }

        func uint16(slot: Int) -> UInt16? {
            let off = fieldOffset(slot: slot)
            guard off != 0 else { return nil }
            return readUInt16(buffer, pos + off)
        }

        func uint32(slot: Int) -> UInt32? {
            let off = fieldOffset(slot: slot)
            guard off != 0, pos + off + 4 <= buffer.count else { return nil }
            return readUInt32(buffer, pos + off)
        }

        func uint64(slot: Int) -> UInt64? {
            let off = fieldOffset(slot: slot)
            guard off != 0, pos + off + 8 <= buffer.count else { return nil }
            return readUInt64(buffer, pos + off)
        }

        func bool(slot: Int) -> Bool? {
            let off = fieldOffset(slot: slot)
            guard off != 0, pos + off < buffer.count else { return nil }
            return buffer[pos + off] != 0
        }

        func string(slot: Int) -> String? {
            let off = fieldOffset(slot: slot)
            guard off != 0 else { return nil }
            let strOffset = pos + off
            guard strOffset + 4 <= buffer.count else { return nil }
            let rel = Int(readUInt32(buffer, strOffset))
            let strStart = strOffset + rel
            guard strStart + 4 <= buffer.count else { return nil }
            let len = Int(readUInt32(buffer, strStart))
            guard strStart + 4 + len <= buffer.count else { return nil }
            return String(bytes: buffer[(strStart + 4)..<(strStart + 4 + len)], encoding: .utf8)
        }

        func subTable(slot: Int) -> Table? {
            let off = fieldOffset(slot: slot)
            guard off != 0 else { return nil }
            let tableOffset = pos + off
            guard tableOffset + 4 <= buffer.count else { return nil }
            let rel = Int(readUInt32(buffer, tableOffset))
            let tablePos = tableOffset + rel
            return makeTable(buffer, at: tablePos)
        }

        func vectorCount(slot: Int) -> Int {
            let off = fieldOffset(slot: slot)
            guard off != 0 else { return 0 }
            let vecOffset = pos + off
            guard vecOffset + 4 <= buffer.count else { return 0 }
            let rel = Int(readUInt32(buffer, vecOffset))
            let vecStart = vecOffset + rel
            guard vecStart + 4 <= buffer.count else { return 0 }
            return Int(readUInt32(buffer, vecStart))
        }

        func vectorElement(slot: Int, index: Int) -> Table? {
            let off = fieldOffset(slot: slot)
            guard off != 0 else { return nil }
            let vecOffset = pos + off
            guard vecOffset + 4 <= buffer.count else { return nil }
            let rel = Int(readUInt32(buffer, vecOffset))
            let vecStart = vecOffset + rel
            guard vecStart + 4 <= buffer.count else { return nil }
            let elemOffset = vecStart + 4 + index * 4
            guard elemOffset + 4 <= buffer.count else { return nil }
            let elemRel = Int(readUInt32(buffer, elemOffset))
            let elemPos = elemOffset + elemRel
            return makeTable(buffer, at: elemPos)
        }
    }

    func rootTable() -> Table? {
        guard buffer.count >= 4 else { return nil }
        let rootOffset = Int(readUInt32(buffer, 0))
        return makeTable(buffer, at: rootOffset)
    }
}

private func readUInt16(_ buf: [UInt8], _ pos: Int) -> UInt16 {
    guard pos + 2 <= buf.count else { return 0 }
    return UInt16(buf[pos]) | (UInt16(buf[pos + 1]) << 8)
}

private func readUInt32(_ buf: [UInt8], _ pos: Int) -> UInt32 {
    guard pos + 4 <= buf.count else { return 0 }
    return UInt32(buf[pos])
        | (UInt32(buf[pos + 1]) << 8)
        | (UInt32(buf[pos + 2]) << 16)
        | (UInt32(buf[pos + 3]) << 24)
}

private func readUInt64(_ buf: [UInt8], _ pos: Int) -> UInt64 {
    guard pos + 8 <= buf.count else { return 0 }
    var v: UInt64 = 0
    for i in 0..<8 { v |= UInt64(buf[pos + i]) << (i * 8) }
    return v
}

private func readInt32(_ buf: [UInt8], _ pos: Int) -> Int32 {
    Int32(bitPattern: readUInt32(buf, pos))
}

private func makeTable(_ buf: [UInt8], at pos: Int) -> FlatBufferReader.Table? {
    guard pos + 4 <= buf.count else { return nil }
    let soffset = readInt32(buf, pos)
    let vtable = pos - Int(soffset)
    guard vtable >= 0, vtable + 4 <= buf.count else { return nil }
    return FlatBufferReader.Table(buffer: buf, pos: pos, vtable: vtable)
}

// MARK: - CaptureListService

final class CaptureListService: @unchecked Sendable {

    static let serviceCaptureList = 18

    enum Phase: String {
        case idle          = "Idle"
        case enumerating   = "Fetching capture list..."
        case ready         = "Capture list ready"
        case failed        = "Failed"
    }

    private enum MsgType {
        static let enumerate     = 1
        static let listDone      = 2
        static let delete        = 3
        static let deleted       = 4
        static let notDeleted    = 5
        static let captureEntry  = 6
        static let retry         = 0x80
        static let requeue       = 0x86
    }

    private(set) var phase: Phase = .idle
    private(set) var failureReason: String = ""
    private(set) var captures: [CaptureEntry] = []

    var isEnumerating: Bool { phase == .enumerating }

    var log: ((String) -> Void)?
    var onListComplete: (() -> Void)?
    var onDeleteResult: ((String, Bool) -> Void)?

    private(set) var channelID = 0
    private var firstMessage = true
    private weak var link: AirShieldLink?

    // MARK: - Enumerate

    func start(link: AirShieldLink) {
        self.link = link
        captures = []
        if channelID == 0 {
            channelID = link.openChannel()
            firstMessage = true
        }
        phase = .enumerating
        emit("Enumerating captures (svc18 type 1, ch=0x\(String(format: "%04x", channelID)), reuse=\(!firstMessage))")

        link.sendMessage(
            channelID: channelID,
            serviceID: firstMessage ? Self.serviceCaptureList : nil,
            messageType: MsgType.enumerate,
            payload: []
        )
        firstMessage = false
    }

    // MARK: - Transfer request

    @discardableResult
    func requestTransfer(handle: String, linkType: Int = 7) -> Bool {
        guard let link, channelID != 0 else {
            emit("Cannot request transfer: no link / capture channel not open")
            return false
        }
        let text = "\(handle):\(linkType)"
        let payload = Array(text.utf8)
        emit("Requesting transfer for \(handle) with link type \(linkType) (svc18 type 0x86 on ch=0x\(String(format: "%04x", channelID)))")

        let sent = link.sendMessage(
            channelID: channelID,
            serviceID: firstMessage ? Self.serviceCaptureList : nil,
            messageType: MsgType.requeue,
            payload: payload
        )
        firstMessage = false
        if !sent { emit("Transfer request could not be sent") }
        return sent
    }

    // MARK: - Delete

    func deleteCapture(handle: String) {
        guard let link else {
            emit("Cannot delete: no link")
            return
        }
        let payload = Array(handle.utf8)
        emit("Deleting capture \(handle)")

        link.sendMessage(
            channelID: channelID,
            serviceID: nil,
            messageType: MsgType.delete,
            payload: payload
        )
    }

    // MARK: - Retry

    func retryCapture(handle: String) {
        guard let link else {
            emit("Cannot retry: no link")
            return
        }
        let payload = Array(handle.utf8)
        emit("Retrying capture \(handle)")

        link.sendMessage(
            channelID: channelID,
            serviceID: nil,
            messageType: MsgType.retry,
            payload: payload
        )
    }

    // MARK: - Message handler

    func handleMessage(_ message: AirShieldMessage, link: AirShieldLink) {
        let msgType = message.header.messageType

        switch msgType {
        case MsgType.captureEntry:
            if let entry = parseCaptureEntry(message.payload) {
                captures.append(entry)
                emit("Capture: \(entry.handle) (\(entry.kind == 3073 ? "photo" : "video"), \(entry.assets.count) assets)")
            } else {
                emit("Failed to parse capture entry (\(message.payload.count) bytes)")
            }

        case MsgType.listDone:
            phase = .ready
            emit("Capture list complete: \(captures.count) captures")
            onListComplete?()

        case MsgType.deleted:
            let handle = String(bytes: message.payload, encoding: .utf8) ?? "?"
            emit("Capture deleted: \(handle)")
            onDeleteResult?(handle, true)

        case MsgType.notDeleted:
            let handle = String(bytes: message.payload, encoding: .utf8) ?? "?"
            emit("Capture NOT deleted: \(handle)")
            onDeleteResult?(handle, false)

        default:
            let hex = message.payload.prefix(48).map { String(format: "%02x", $0) }.joined()
            let status = message.header.hasError ? " status=0x\(String(format: "%04x", message.header.errorID))" : ""
            emit("Unknown svc18 message type \(msgType)\(status) (\(message.payload.count) bytes): \(hex)")
        }
    }

    // MARK: - FlatBuffer parsing

    private func parseCaptureEntry(_ payload: [UInt8]) -> CaptureEntry? {
        let reader = FlatBufferReader(buffer: payload)
        guard let root = reader.rootTable() else { return nil }

        // Root slot 4 → info sub-table (NOT the handle directly)
        guard let info = root.subTable(slot: 4) else { return nil }

        let handle = info.string(slot: 4) ?? ""
        guard !handle.isEmpty else { return nil }

        let kind = Int(info.uint32(slot: 8) ?? 0)

        // Meta table is at info slot 12
        var timestampNanos: UInt64 = 0
        var isLandscape = false
        if let meta = info.subTable(slot: 12) {
            timestampNanos = meta.uint64(slot: 4) ?? 0
            isLandscape = meta.bool(slot: 34) ?? false
        }

        // Asset vector is at info slot 10
        let assetCount = info.vectorCount(slot: 10)
        var assets: [AssetEntry] = []
        for i in 0..<assetCount {
            if let assetTable = info.vectorElement(slot: 10, index: i) {
                let uuid = assetTable.string(slot: 4) ?? ""
                guard !uuid.isEmpty else { continue }
                let typeCode = assetTable.uint32(slot: 6) ?? 0
                let sizeBytes = assetTable.uint64(slot: 12) ?? 0
                assets.append(AssetEntry(uuid: uuid, typeCode: typeCode, sizeBytes: sizeBytes))
            }
        }

        return CaptureEntry(
            handle: handle,
            kind: kind,
            timestampNanos: timestampNanos,
            isLandscape: isLandscape,
            assets: assets
        )
    }

    // MARK: - Helpers

    func reset() {
        phase = .idle
        captures = []
        failureReason = ""
    }

    private func emit(_ message: String) {
        log?("[CaptureList] \(message)")
    }
}
