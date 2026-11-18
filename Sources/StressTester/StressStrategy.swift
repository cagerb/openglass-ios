import Foundation

// MARK: - Protocol + test case

public protocol StressStrategy: Sendable {
    var name: String { get }
    var description: String { get }
    var totalCases: Int? { get }
    func generate(index: Int) -> StressTestCase
}

public struct StressTestCase: Sendable {
    public let layer: String       // "raw_l2cap", "airshield_frame", "datax_message"
    public let bytes: [UInt8]
    public let description: String
}

// MARK: - Helpers

private func randomBytes(_ count: Int) -> [UInt8] {
    (0..<count).map { _ in UInt8.random(in: 0...255) }
}

// MARK: - 1. SingleByteStrategy

/// Every byte 0x00 through 0xFF, one at a time.
struct SingleByteStrategy: StressStrategy {
    let name = "Single Byte"
    let description = "Send every possible byte value (0x00-0xFF) as a 1-byte raw L2CAP packet"
    let totalCases: Int? = 256

    func generate(index: Int) -> StressTestCase {
        let byte = UInt8(clamping: index)
        return StressTestCase(
            layer: "raw_l2cap",
            bytes: [byte],
            description: String(format: "Single byte 0x%02X", byte)
        )
    }
}

// MARK: - 2. EmptyPacketStrategy

/// A zero-length packet.
struct EmptyPacketStrategy: StressStrategy {
    let name = "Empty Packet"
    let description = "Send a zero-length raw L2CAP packet"
    let totalCases: Int? = 1

    func generate(index: Int) -> StressTestCase {
        StressTestCase(
            layer: "raw_l2cap",
            bytes: [],
            description: "Empty packet (0 bytes)"
        )
    }
}

// MARK: - 3. BadFrameTypeStrategy

/// First byte 0x00 through 0xFF, each followed by 15 random bytes.
struct BadFrameTypeStrategy: StressStrategy {
    let name = "Bad Frame Type"
    let description = "Every possible first byte followed by 15 random bytes"
    let totalCases: Int? = 256

    func generate(index: Int) -> StressTestCase {
        let first = UInt8(clamping: index)
        let rest = randomBytes(15)
        return StressTestCase(
            layer: "raw_l2cap",
            bytes: [first] + rest,
            description: String(format: "Frame type 0x%02X + 15 random bytes", first)
        )
    }
}

// MARK: - 4. OversizedFrameStrategy

/// Frames from 512 bytes up to 8192 bytes in 512-byte steps, filled with random data.
struct OversizedFrameStrategy: StressStrategy {
    let name = "Oversized Frame"
    let description = "Progressively larger frames (512 to 8192 bytes) of random data"
    let totalCases: Int? = 16

    func generate(index: Int) -> StressTestCase {
        let size = (index + 1) * 512
        return StressTestCase(
            layer: "raw_l2cap",
            bytes: randomBytes(size),
            description: "Oversized frame: \(size) bytes of random data"
        )
    }
}

// MARK: - 5. BinaryPatternStrategy

/// Fixed bit patterns: all zeros, all 0xFF, alternating 0xAA, alternating 0x55,
/// walking-one (8 patterns), walking-zero (4 patterns). Total = 16 cases.
struct BinaryPatternStrategy: StressStrategy {
    let name = "Binary Pattern"
    let description = "Fixed bit patterns: all-zero, all-one, alternating, walking bits"
    let totalCases: Int? = 16

    func generate(index: Int) -> StressTestCase {
        let size = 64
        let bytes: [UInt8]
        let desc: String

        switch index {
        case 0:
            bytes = [UInt8](repeating: 0x00, count: size)
            desc = "All zeros (64 bytes)"
        case 1:
            bytes = [UInt8](repeating: 0xFF, count: size)
            desc = "All 0xFF (64 bytes)"
        case 2:
            bytes = [UInt8](repeating: 0xAA, count: size)
            desc = "Alternating 0xAA (64 bytes)"
        case 3:
            bytes = [UInt8](repeating: 0x55, count: size)
            desc = "Alternating 0x55 (64 bytes)"
        case 4...11:
            // Walking one: bit position (index - 4)
            let bit = index - 4
            let pattern = UInt8(1 << bit)
            bytes = [UInt8](repeating: pattern, count: size)
            desc = String(format: "Walking one: bit %d (0x%02X, 64 bytes)", bit, pattern)
        case 12...15:
            // Walking zero: invert bits 0-3
            let bit = index - 12
            let pattern = ~UInt8(1 << bit)
            bytes = [UInt8](repeating: pattern, count: size)
            desc = String(format: "Walking zero: bit %d (0x%02X, 64 bytes)", bit, pattern)
        default:
            bytes = [UInt8](repeating: 0xDE, count: size)
            desc = "Pattern overflow"
        }

        return StressTestCase(layer: "raw_l2cap", bytes: bytes, description: desc)
    }
}

// MARK: - 6. RapidFireStrategy

/// 100 single-byte packets meant to be sent in a burst with no inter-packet delay.
struct RapidFireStrategy: StressStrategy {
    let name = "Rapid Fire"
    let description = "100 single-byte packets in a burst (tests parser under load)"
    let totalCases: Int? = 100

    func generate(index: Int) -> StressTestCase {
        StressTestCase(
            layer: "raw_l2cap",
            bytes: [UInt8(index & 0xFF)],
            description: "Rapid fire packet #\(index)"
        )
    }
}

// MARK: - 7. EncryptedEmptyStrategy

/// A single empty-plaintext encrypted frame.
struct EncryptedEmptyStrategy: StressStrategy {
    let name = "Encrypted Empty"
    let description = "Send empty plaintext through the AirShield encryption layer"
    let totalCases: Int? = 1

    func generate(index: Int) -> StressTestCase {
        StressTestCase(
            layer: "airshield_frame",
            bytes: [],
            description: "Empty encrypted payload"
        )
    }
}

// MARK: - 8. MalformedDataXHeaderStrategy

/// Encrypted frames with garbage DataX headers.
struct MalformedDataXHeaderStrategy: StressStrategy {
    let name = "Malformed DataX Header"
    let description = "Encrypted frames with intentionally broken DataX headers"
    let totalCases: Int? = 10

    func generate(index: Int) -> StressTestCase {
        let bytes: [UInt8]
        let desc: String

        switch index {
        case 0:
            // Length claims 16383 (max) with only 1 byte of payload
            bytes = [0x3F, 0xFF, 0x00, 0x01, 0xAB]
            desc = "Length=16383 but only 1 payload byte"
        case 1:
            // Length is 0
            bytes = [0x00, 0x00, 0x00, 0x01]
            desc = "Length=0"
        case 2:
            // All zeros
            bytes = [0x00, 0x00, 0x00, 0x00]
            desc = "All-zero header"
        case 3:
            // All 0xFF
            bytes = [0xFF, 0xFF, 0xFF, 0xFF]
            desc = "All-0xFF header"
        case 4:
            // Tag bit set but no tags follow
            bytes = [0x80, 0x04, 0x00, 0x01]
            desc = "Tag bit set, no tag bytes"
        case 5:
            // Length claims 16383 with 100 bytes of random payload
            bytes = [0x3F, 0xFF, 0x00, 0x01] + randomBytes(100)
            desc = "Length=16383 with 100 random payload bytes"
        case 6:
            // Channel ID 0xFFFF
            bytes = [0x00, 0x04, 0xFF, 0xFF] + randomBytes(4)
            desc = "Channel 0xFFFF"
        case 7:
            // Length = 1, single garbage byte
            bytes = [0x00, 0x01, 0x00, 0x01, 0xFF]
            desc = "Length=1 with garbage payload"
        case 8:
            // Tag bit set, service tag with value 0xFFFF
            bytes = [0x80, 0x08, 0x00, 0x01, 0x01, 0x00, 0xFF, 0xFF] + randomBytes(4)
            desc = "Service tag 0xFFFF"
        case 9:
            // Multiple continuation tags that point nowhere
            bytes = [0x80, 0x10, 0x00, 0x01,
                     0x81, 0x00, 0xDE, 0xAD,
                     0x82, 0x00, 0xBE, 0xEF,
                     0x83, 0x00, 0xCA, 0xFE,
                     0x01, 0x00, 0xBA, 0xBE]
            desc = "Multiple bogus continuation tags"
        default:
            bytes = [0x00, 0x00, 0x00, 0x00]
            desc = "Malformed header overflow"
        }

        return StressTestCase(layer: "airshield_frame", bytes: bytes, description: desc)
    }
}

// MARK: - 9. ContinuationBitStrategy

/// DataX headers with the continuation bit set on every tag, creating a never-ending chain.
struct ContinuationBitStrategy: StressStrategy {
    let name = "Continuation Bit"
    let description = "DataX headers with continuation bits that never terminate (1-8 tags)"
    let totalCases: Int? = 8

    func generate(index: Int) -> StressTestCase {
        let tagCount = index + 1
        // All tags have continuation bit set (0x80 | tag_id), including the last one
        var bytes: [UInt8] = []
        let payloadLength = tagCount * 4
        bytes.append(0x80 | UInt8((payloadLength >> 8) & 0x3F))
        bytes.append(UInt8(payloadLength & 0xFF))
        bytes.append(0x00)  // channel high
        bytes.append(0x01)  // channel low

        for i in 0..<tagCount {
            // Every tag has continuation bit set, even the last
            let tagID = UInt8((i + 1) & 0x7F)
            bytes.append(0x80 | tagID)  // continuation bit always set
            bytes.append(0x00)
            bytes.append(UInt8.random(in: 0...255))
            bytes.append(UInt8.random(in: 0...255))
        }

        return StressTestCase(
            layer: "airshield_frame",
            bytes: bytes,
            description: "Never-ending header chain with \(tagCount) tag(s)"
        )
    }
}

// MARK: - 10. ServiceSweepStrategy

/// Iterate service IDs 0-255 with message type 0x0001 and empty payload.
struct ServiceSweepStrategy: StressStrategy {
    let name = "Service Sweep"
    let description = "Probe all service IDs 0-255 with type 0x0001"
    let totalCases: Int? = 256

    func generate(index: Int) -> StressTestCase {
        let serviceID = index & 0xFF
        let header = DataXHeader.build(
            channelID: 0x8002,
            dataLength: 0,
            serviceID: serviceID,
            messageType: 0x0001
        )
        return StressTestCase(
            layer: "datax_message",
            bytes: header,
            description: String(format: "Service %d (0x%02X) type 0x0001", serviceID, serviceID)
        )
    }
}

// MARK: - 11. KnownServiceTypeStrategy

/// Known services (5, 30, 36, 79) with message types 0x0000 through 0x00FF.
struct KnownServiceTypeStrategy: StressStrategy {
    let name = "Known Service Types"
    let description = "Known services (5, 30, 36, 79) x all message types 0x0000-0x00FF"
    let totalCases: Int? = 1024  // 4 * 256

    private static let services = [5, 30, 36, 79]

    func generate(index: Int) -> StressTestCase {
        let serviceIndex = index / 256
        let msgType = index % 256
        let serviceID = Self.services[serviceIndex % Self.services.count]
        let header = DataXHeader.build(
            channelID: 0x8002,
            dataLength: 0,
            serviceID: serviceID,
            messageType: msgType
        )
        return StressTestCase(
            layer: "datax_message",
            bytes: header,
            description: String(format: "Service %d type 0x%04X", serviceID, msgType)
        )
    }
}

// MARK: - 12. LargePayloadStrategy

/// Service 36 type 0x3000 with payloads of 1KB, 2KB, 4KB, 8KB, 16KB of random data.
struct LargePayloadStrategy: StressStrategy {
    let name = "Large Payload"
    let description = "Service 36 type 0x3000 with 1KB to 16KB random payloads"
    let totalCases: Int? = 5

    private static let sizes = [1024, 2048, 4096, 8192, 16384]

    func generate(index: Int) -> StressTestCase {
        let size = Self.sizes[index % Self.sizes.count]
        // DataX max payload is 16383 bytes, so cap at that
        let actualSize = min(size, DataXHeader.maxPayload - 8)
        let payload = randomBytes(actualSize)
        let header = DataXHeader.build(
            channelID: 0x8002,
            dataLength: payload.count,
            serviceID: 36,
            messageType: 0x3000
        )
        return StressTestCase(
            layer: "datax_message",
            bytes: header + payload,
            description: "Large payload: \(size) bytes to svc36/0x3000"
        )
    }
}

// MARK: - 13. RepeatedIdentityStrategy

/// 50 rapid svc36/0x3000 identity requests.
struct RepeatedIdentityStrategy: StressStrategy {
    let name = "Repeated Identity"
    let description = "50 rapid identity requests (svc36/0x3000) to test replay handling"
    let totalCases: Int? = 50

    func generate(index: Int) -> StressTestCase {
        let header = DataXHeader.build(
            channelID: 0x8002,
            dataLength: 0,
            serviceID: 36,
            messageType: 0x3000
        )
        return StressTestCase(
            layer: "datax_message",
            bytes: header,
            description: "Identity request #\(index + 1)"
        )
    }
}

// MARK: - 14. SizeProbeStrategy

/// Narrow the oversized-frame crash zone: 2048 to 2560 bytes in 1-byte increments.
struct SizeProbeStrategy: StressStrategy {
    let name = "Size Probe 2K-2.5K"
    let description = "Probe 2048-2560 bytes in 1-byte steps to find exact crash threshold"
    let totalCases: Int? = 513  // 2048...2560 inclusive

    func generate(index: Int) -> StressTestCase {
        let size = 2048 + index
        return StressTestCase(
            layer: "raw_l2cap",
            bytes: randomBytes(size),
            description: "Size probe: \(size) bytes"
        )
    }
}

// MARK: - 15. CrashConfirmStrategy

/// Send the crashing size (2560 bytes) 20 times to test consistency.
struct CrashConfirmStrategy: StressStrategy {
    let name = "Crash Confirm 2560"
    let description = "Send 2560 bytes 20 times to confirm reproducibility"
    let totalCases: Int? = 20

    func generate(index: Int) -> StressTestCase {
        StressTestCase(
            layer: "raw_l2cap",
            bytes: randomBytes(2560),
            description: "Crash confirm: 2560 bytes (attempt \(index + 1)/20)"
        )
    }
}

// MARK: - 16. ContentProbeStrategy

/// At the crashing size (2560 bytes), vary content to see if it's size-only or content-dependent.
struct ContentProbeStrategy: StressStrategy {
    let name = "Content Probe 2560"
    let description = "2560 bytes with different fill patterns to isolate size vs content"
    let totalCases: Int? = 10

    func generate(index: Int) -> StressTestCase {
        let size = 2560
        let bytes: [UInt8]
        let desc: String

        switch index {
        case 0:
            bytes = [UInt8](repeating: 0x00, count: size)
            desc = "2560 bytes: all zeros"
        case 1:
            bytes = [UInt8](repeating: 0xFF, count: size)
            desc = "2560 bytes: all 0xFF"
        case 2:
            bytes = [UInt8](repeating: 0xAA, count: size)
            desc = "2560 bytes: all 0xAA"
        case 3:
            // Valid DATA frame header (0x40) followed by fill
            bytes = [0x40] + [UInt8](repeating: 0x00, count: size - 1)
            desc = "2560 bytes: 0x40 header + zeros"
        case 4:
            // Valid control frame header (0x80) followed by fill
            bytes = [0x80] + [UInt8](repeating: 0x00, count: size - 1)
            desc = "2560 bytes: 0x80 header + zeros"
        case 5:
            // Sequential bytes 0x00-0xFF repeating
            bytes = (0..<size).map { UInt8($0 & 0xFF) }
            desc = "2560 bytes: sequential pattern"
        case 6:
            bytes = randomBytes(size)
            desc = "2560 bytes: random #1"
        case 7:
            bytes = randomBytes(size)
            desc = "2560 bytes: random #2"
        case 8:
            bytes = randomBytes(size)
            desc = "2560 bytes: random #3"
        case 9:
            bytes = randomBytes(size)
            desc = "2560 bytes: random #4"
        default:
            bytes = randomBytes(size)
            desc = "2560 bytes: random overflow"
        }

        return StressTestCase(layer: "raw_l2cap", bytes: bytes, description: desc)
    }
}

// MARK: - 17. SecondCrashProbeStrategy

/// Narrow the second crash zone: 6144 to 6656 bytes in 32-byte increments.
struct SecondCrashProbeStrategy: StressStrategy {
    let name = "Size Probe 6K-6.5K"
    let description = "Probe 6144-6656 bytes in 32-byte steps for the second crash zone"
    let totalCases: Int? = 17  // (6656 - 6144) / 32 + 1

    func generate(index: Int) -> StressTestCase {
        let size = 6144 + (index * 32)
        return StressTestCase(
            layer: "raw_l2cap",
            bytes: randomBytes(size),
            description: "Size probe: \(size) bytes"
        )
    }
}

// MARK: - All strategies

enum StressStrategies {
    static let all: [any StressStrategy] = [
        SingleByteStrategy(),
        EmptyPacketStrategy(),
        BadFrameTypeStrategy(),
        OversizedFrameStrategy(),
        BinaryPatternStrategy(),
        RapidFireStrategy(),
        EncryptedEmptyStrategy(),
        MalformedDataXHeaderStrategy(),
        ContinuationBitStrategy(),
        ServiceSweepStrategy(),
        KnownServiceTypeStrategy(),
        LargePayloadStrategy(),
        RepeatedIdentityStrategy(),
        SizeProbeStrategy(),
        CrashConfirmStrategy(),
        ContentProbeStrategy(),
        SecondCrashProbeStrategy(),
    ]
}
