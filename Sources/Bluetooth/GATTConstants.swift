import CoreBluetooth

/// Known GATT UUIDs for Meta glasses: the 2021 Ray-Ban Stories (GATT DataX) and
/// Ray-Ban Meta (L2CAP PSM characteristic).
enum GATTConstants {

    // MARK: - Primary service

    /// The proprietary Meta/Facebook service advertised by the glasses.
    /// 16-bit UUID 0xFD5F registered to Facebook, Inc.
    nonisolated(unsafe) static let metaServiceUUID = CBUUID(string: "FD5F")

    // MARK: - DataX characteristic (Ray-Ban Stories, 2021)

    /// The main DataX characteristic used for all command/response traffic.
    /// Full 128-bit UUID. Only the 2021 Ray-Ban Stories have it.
    nonisolated(unsafe) static let dataXCharacteristicUUID = CBUUID(string: "24154476-0E45-11AB-6441-E8BE42459478")

    // MARK: - L2CAP PSM characteristic (Ray-Ban Meta, "RB Meta ...")

    /// Ray-Ban Meta glasses have no writable characteristic at all. FD5F only tells
    /// the phone which LE L2CAP PSM to open; the AirShield + DataX link runs over that
    /// channel (see `AirShieldLink`). The value is a list of little-endian 16-bit
    /// words, e.g. `00 00 80 00` = PSM 0x80.
    nonisolated(unsafe) static let psmCharacteristicUUID = CBUUID(string: "05ACBE9F-6F61-4CA9-80BF-C8BBB52991C0")

    /// The glasses' usual PSM (128). Burbank Audio and the Neural Band use 129.
    static let defaultL2CAPPSM: UInt16 = 0x80

    /// The PSM out of the characteristic's value: the first word in the LE dynamic
    /// range 0x80...0xFF, else the first in 0x01...0x7F.
    static func parsePSM(_ value: Data) -> UInt16? {
        let bytes = [UInt8](value)
        var words: [UInt16] = []
        var index = 0
        while index + 1 < bytes.count {
            words.append(UInt16(bytes[index]) | (UInt16(bytes[index + 1]) << 8))
            index += 2
        }
        return words.first(where: { (0x80...0xFF).contains($0) })
            ?? words.first(where: { (0x01...0x7F).contains($0) })
    }

    /// Two more read-only FD5F characteristics on Ray-Ban Meta. Their meaning is not
    /// documented anywhere public; they are only logged.
    nonisolated(unsafe) static let metaUnknownCharacteristicA = CBUUID(string: "C53673DD-69E0-4A65-B530-6FFB330BFF85")
    nonisolated(unsafe) static let metaUnknownCharacteristicB = CBUUID(string: "F9FBF15D-6CC8-400A-B70A-AA7DCDCAEDD8")

    // MARK: - Standard Battery Service (0x180F)

    nonisolated(unsafe) static let batteryServiceUUID = CBUUID(string: "180F")
    /// Battery Level characteristic — returns a single byte 0–100.
    nonisolated(unsafe) static let batteryLevelUUID = CBUUID(string: "2A19")

    // MARK: - Standard Device Information Service (0x180A)

    nonisolated(unsafe) static let deviceInfoServiceUUID = CBUUID(string: "180A")
    nonisolated(unsafe) static let manufacturerNameUUID = CBUUID(string: "2A29")
    nonisolated(unsafe) static let modelNumberUUID = CBUUID(string: "2A24")
    nonisolated(unsafe) static let serialNumberUUID = CBUUID(string: "2A25")
    nonisolated(unsafe) static let hardwareRevisionUUID = CBUUID(string: "2A27")
    nonisolated(unsafe) static let firmwareRevisionUUID = CBUUID(string: "2A26")
    nonisolated(unsafe) static let softwareRevisionUUID = CBUUID(string: "2A28")
    nonisolated(unsafe) static let systemIDUUID = CBUUID(string: "2A23")

    // MARK: - Device name matching

    /// The glasses advertise with a local name containing this prefix.
    static let deviceNamePrefix = "RB"

    // MARK: - Auth message types (PhaseB handshake)

    /// StartSession request (phone → glasses)
    static let authStartSessionRequest: UInt8 = 0x00
    /// StartSession response (glasses → phone)
    static let authStartSessionResponse: UInt8 = 0x01

    /// Identity request (phone → glasses)
    static let authIdentityRequest: UInt8 = 0x09
    /// Identity response (glasses → phone)
    static let authIdentityResponse: UInt8 = 0x0A

    /// StartChallenge request (phone → glasses)
    static let authStartChallengeRequest: UInt8 = 0x0D
    /// StartChallenge response (glasses → phone)
    static let authStartChallengeResponse: UInt8 = 0x0E

    /// FinishChallenge request (phone → glasses)
    static let authFinishChallengeRequest: UInt8 = 0x05
    /// FinishChallenge response (glasses → phone)
    static let authFinishChallengeResponse: UInt8 = 0x06

    /// Encrypted message wrapper type
    static let encryptedMessageType: UInt8 = 0x02

    // MARK: - DataX framing

    /// Maximum payload per BLE write (after 3-byte header).
    /// MTU is typically 512 on modern iOS but we use a conservative default.
    static let defaultMTU: Int = 512
    /// DataX header size: 3 bytes (type + length big-endian uint16).
    static let headerSize: Int = 3

    // MARK: - Media / SoftAP

    /// The IP address the glasses expose when acting as a Wi-Fi access point.
    static let softAPAddress = "192.168.1.1"
    /// Base URL for the glasses' HTTPS webserver.
    static let webserverBaseURL = "https://192.168.1.1/stella-webserver"
    /// Asset download endpoint. Append `?id=<assetId>`.
    static let assetEndpoint = "/asset"

    /// Photo capture type ID in the asset manifest.
    static let captureTypePhoto: UInt16 = 3073
    /// Video capture type ID in the asset manifest.
    static let captureTypeVideo: UInt16 = 3074
}
