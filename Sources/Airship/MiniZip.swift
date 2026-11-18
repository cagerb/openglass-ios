// Minimal ZIP archive builder — just enough to create uncompressed ZIPs
// for MobileConfig delivery (two mctable files in a ZIP).

import Foundation

enum MiniZip {

    struct Entry {
        let path: String
        let data: [UInt8]
    }

    static func create(entries: [Entry]) -> Data {
        var archive = Data()
        var centralDirectory = Data()
        var offsets: [Int] = []

        for entry in entries {
            offsets.append(archive.count)
            let pathBytes = Array(entry.path.utf8)
            let crc = crc32(entry.data)

            // Local file header
            archive.append(contentsOf: localFileHeader(
                pathBytes: pathBytes,
                crc: crc,
                size: UInt32(entry.data.count)
            ))
            archive.append(contentsOf: pathBytes)
            archive.append(contentsOf: entry.data)

            // Central directory entry
            centralDirectory.append(contentsOf: centralDirEntry(
                pathBytes: pathBytes,
                crc: crc,
                size: UInt32(entry.data.count),
                localOffset: UInt32(offsets.last!)
            ))
            centralDirectory.append(contentsOf: pathBytes)
        }

        let cdOffset = archive.count
        archive.append(centralDirectory)

        // End of central directory
        archive.append(contentsOf: endOfCentralDir(
            entryCount: UInt16(entries.count),
            cdSize: UInt32(centralDirectory.count),
            cdOffset: UInt32(cdOffset)
        ))

        return archive
    }

    private static func localFileHeader(pathBytes: [UInt8], crc: UInt32, size: UInt32) -> [UInt8] {
        var h = [UInt8]()
        h += [0x50, 0x4B, 0x03, 0x04] // signature
        h += le16(20)                   // version needed
        h += le16(0)                    // flags
        h += le16(0)                    // compression (store)
        h += le16(0)                    // mod time
        h += le16(0)                    // mod date
        h += le32(crc)                  // crc-32
        h += le32(size)                 // compressed size
        h += le32(size)                 // uncompressed size
        h += le16(UInt16(pathBytes.count)) // filename length
        h += le16(0)                    // extra length
        return h
    }

    private static func centralDirEntry(pathBytes: [UInt8], crc: UInt32, size: UInt32, localOffset: UInt32) -> [UInt8] {
        var h = [UInt8]()
        h += [0x50, 0x4B, 0x01, 0x02] // signature
        h += le16(20)                   // version made by
        h += le16(20)                   // version needed
        h += le16(0)                    // flags
        h += le16(0)                    // compression
        h += le16(0)                    // mod time
        h += le16(0)                    // mod date
        h += le32(crc)
        h += le32(size)
        h += le32(size)
        h += le16(UInt16(pathBytes.count))
        h += le16(0)                    // extra length
        h += le16(0)                    // comment length
        h += le16(0)                    // disk number
        h += le16(0)                    // internal attributes
        h += le32(0)                    // external attributes
        h += le32(localOffset)
        return h
    }

    private static func endOfCentralDir(entryCount: UInt16, cdSize: UInt32, cdOffset: UInt32) -> [UInt8] {
        var h = [UInt8]()
        h += [0x50, 0x4B, 0x05, 0x06] // signature
        h += le16(0)                    // disk number
        h += le16(0)                    // CD start disk
        h += le16(entryCount)           // entries on this disk
        h += le16(entryCount)           // total entries
        h += le32(cdSize)
        h += le32(cdOffset)
        h += le16(0)                    // comment length
        return h
    }

    // MARK: - CRC-32

    private static let crcTable: [UInt32] = {
        (0..<256).map { i -> UInt32 in
            var c = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1
            }
            return c
        }
    }()

    static func crc32(_ data: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            let index = Int((crc ^ UInt32(byte)) & 0xFF)
            crc = crcTable[index] ^ (crc >> 8)
        }
        return crc ^ 0xFFFFFFFF
    }

    // MARK: - Little-endian helpers

    private static func le16(_ v: UInt16) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8(v >> 8)]
    }

    private static func le32(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)]
    }
}
