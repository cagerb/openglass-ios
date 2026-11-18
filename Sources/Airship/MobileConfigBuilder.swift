// Builds MobileConfig table ZIPs for svc19 delivery to the glasses.
// Tables are FBMobileConfigTable flatbuffers wrapped in a header/footer envelope.

import Foundation

struct MobileConfigBuilder {

    struct BoolParam {
        let configID: Int
        let paramID: Int
        let slot: Int
        let value: Bool
        let sessionless: Bool
    }

    struct Int64Param {
        let configID: Int
        let paramID: Int
        let slot: Int
        let value: Int64
        let sessionless: Bool
    }

    struct StringParam {
        let configID: Int
        let paramID: Int
        let slot: Int
        let value: String
        let sessionless: Bool
    }

    // MARK: - Known flags

    static func signatureVerificationDisabled() -> BoolParam {
        // wss_appmanager.signature_verification_enabled → false (0x00)
        // The param record encodes config_id, param_id, slot, type in a 64-bit value.
        // p0pcycle flipped byte from 0x80 (true) to 0x00 (false) in the mctable.
        BoolParam(
            configID: 0,     // placeholder — needs capture to determine exact IDs
            paramID: 0,
            slot: 0,
            value: false,
            sessionless: true
        )
    }

    // MARK: - Table building

    static func buildTable(
        schemaHash: String,
        bools: [BoolParam] = [],
        int64s: [Int64Param] = [],
        strings: [StringParam] = []
    ) -> [UInt8] {
        var fb = FlatBufferBuilder()

        // Field 0: schema hash
        fb.addString(field: 0, value: schemaHash)

        // Field 1/2: bool values / metas
        if !bools.isEmpty {
            let boolValues: [UInt8] = bools.map { $0.value ? 0x80 : 0x00 }
            let boolMetas: [Int32] = bools.map { _ in Int32(0) } // 0 = has value
            fb.addByteVector(field: 1, values: boolValues)
            fb.addInt32Vector(field: 2, values: boolMetas)
        }

        // Field 3/4: int64 values / metas
        if !int64s.isEmpty {
            let i64Values: [Int64] = int64s.map { $0.value }
            let i64Metas: [Int32] = int64s.map { _ in Int32(0) }
            fb.addInt64Vector(field: 3, values: i64Values)
            fb.addInt32Vector(field: 4, values: i64Metas)
        }

        // Field 9/10: string values / metas
        if !strings.isEmpty {
            let strValues: [String] = strings.map { $0.value }
            let strMetas: [Int32] = strings.map { _ in Int32(0) }
            fb.addStringVector(field: 9, values: strValues)
            fb.addInt32Vector(field: 10, values: strMetas)
        }

        // Field 15: magic
        fb.addInt32(field: 15, value: 123456)

        let body = fb.finish()
        return wrapTable(body)
    }

    // Envelope: 3c f1 01 08 <LE32 length = body + 10> <body> 3c f1
    private static func wrapTable(_ body: [UInt8]) -> [UInt8] {
        let header: [UInt8] = [0x3C, 0xF1, 0x01, 0x08]
        let footer: [UInt8] = [0x3C, 0xF1]
        let length = UInt32(body.count + 10)
        let lenBytes = withUnsafeBytes(of: length.littleEndian) { Array($0) }
        return header + lenBytes + body + footer
    }

    // MARK: - ZIP packaging

    static func buildConfigZIP(
        sessionID: String,
        sessionlessTable: [UInt8],
        paramsTable: [UInt8]
    ) -> (data: [UInt8], filename: String) {
        let now = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM-dd-yyyy-HH-mm-ss"
        let timestamp = formatter.string(from: now)

        // Filename must be exactly 88 characters
        let baseName = "\(timestamp)_\(sessionID)_mobileconfig_params_values.zip"
        let filename: String
        if baseName.count < 88 {
            filename = baseName + String(repeating: "_", count: 88 - baseName.count)
        } else if baseName.count > 88 {
            filename = String(baseName.prefix(88))
        } else {
            filename = baseName
        }

        let zip = MiniZip.create(entries: [
            MiniZip.Entry(path: "sessionless.data/0.mctable", data: sessionlessTable),
            MiniZip.Entry(path: "params.data/0.mctable", data: paramsTable),
        ])

        return (Array(zip), filename)
    }

    // MARK: - Params map record (64-bit)

    static func paramsRecord(type: Int, slot: Int, sessionless: Bool, paramID: Int, configID: Int) -> UInt64 {
        var record: UInt64 = 0
        record |= UInt64(type & 0x7) << 11
        record |= UInt64(slot & 0xFFFF) << 16
        if sessionless { record |= 0x400 }
        record |= UInt64(paramID & 0xFFF) << 32
        record |= UInt64(configID & 0xFFFFF) << 44
        return record
    }
}

// MARK: - Minimal FlatBuffer builder (just enough for MobileConfigTable)

private struct FlatBufferBuilder {
    private var fields: [(field: Int, data: [UInt8])] = []

    mutating func addString(field: Int, value: String) {
        let bytes = Array(value.utf8)
        var encoded: [UInt8] = []
        encoded += withUnsafeBytes(of: UInt32(bytes.count).littleEndian) { Array($0) }
        encoded += bytes
        if bytes.count % 4 != 0 {
            encoded += [UInt8](repeating: 0, count: 4 - bytes.count % 4)
        }
        fields.append((field, encoded))
    }

    mutating func addByteVector(field: Int, values: [UInt8]) {
        var encoded: [UInt8] = []
        encoded += withUnsafeBytes(of: UInt32(values.count).littleEndian) { Array($0) }
        encoded += values
        if values.count % 4 != 0 {
            encoded += [UInt8](repeating: 0, count: 4 - values.count % 4)
        }
        fields.append((field, encoded))
    }

    mutating func addInt32Vector(field: Int, values: [Int32]) {
        var encoded: [UInt8] = []
        encoded += withUnsafeBytes(of: UInt32(values.count).littleEndian) { Array($0) }
        for v in values {
            encoded += withUnsafeBytes(of: v.littleEndian) { Array($0) }
        }
        fields.append((field, encoded))
    }

    mutating func addInt64Vector(field: Int, values: [Int64]) {
        var encoded: [UInt8] = []
        encoded += withUnsafeBytes(of: UInt32(values.count).littleEndian) { Array($0) }
        for v in values {
            encoded += withUnsafeBytes(of: v.littleEndian) { Array($0) }
        }
        fields.append((field, encoded))
    }

    mutating func addStringVector(field: Int, values: [String]) {
        var encoded: [UInt8] = []
        encoded += withUnsafeBytes(of: UInt32(values.count).littleEndian) { Array($0) }
        for s in values {
            let bytes = Array(s.utf8)
            encoded += withUnsafeBytes(of: UInt32(bytes.count).littleEndian) { Array($0) }
            encoded += bytes
            if bytes.count % 4 != 0 {
                encoded += [UInt8](repeating: 0, count: 4 - bytes.count % 4)
            }
        }
        fields.append((field, encoded))
    }

    mutating func addInt32(field: Int, value: Int32) {
        let encoded = withUnsafeBytes(of: value.littleEndian) { Array($0) }
        fields.append((field, encoded))
    }

    func finish() -> [UInt8] {
        // Simplified flatbuffer: vtable + data table
        // This is a minimal implementation — real flatbuffers are more complex
        // but the glasses' parser is lenient enough to accept this layout.
        let sorted = fields.sorted { $0.field < $1.field }

        var dataSection: [UInt8] = []
        var offsets: [(field: Int, offset: Int)] = []

        for entry in sorted {
            offsets.append((entry.field, dataSection.count))
            dataSection += entry.data
        }

        // vtable: [vtable_size, object_size, field_offsets...]
        let maxField = (sorted.last?.field ?? 0) + 1
        let vtableSize = 4 + maxField * 2
        var vtable = [UInt8](repeating: 0, count: vtableSize)
        vtable[0] = UInt8(vtableSize & 0xFF)
        vtable[1] = UInt8((vtableSize >> 8) & 0xFF)
        let objectSize = dataSection.count + 4
        vtable[2] = UInt8(objectSize & 0xFF)
        vtable[3] = UInt8((objectSize >> 8) & 0xFF)

        for (field, offset) in offsets {
            let vOffset = 4 + field * 2
            let dataOffset = offset + 4 // +4 for the soffset at start of object
            vtable[vOffset] = UInt8(dataOffset & 0xFF)
            vtable[vOffset + 1] = UInt8((dataOffset >> 8) & 0xFF)
        }

        // object: [soffset_to_vtable, data...]
        let soffset = Int32(vtable.count)
        var result = vtable
        result += withUnsafeBytes(of: soffset.littleEndian) { Array($0) }
        result += dataSection

        // root offset (points to the object)
        var final: [UInt8] = []
        let rootOffset = UInt32(vtable.count)
        final += withUnsafeBytes(of: rootOffset.littleEndian) { Array($0) }
        final += result

        return final
    }
}
