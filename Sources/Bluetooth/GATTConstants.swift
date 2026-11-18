import CoreBluetooth

/// All known GATT UUIDs for Meta Ray-Ban Stories gen 1.
enum GATTConstants {

    // MARK: - Primary service

    /// The proprietary Meta/Facebook service advertised by the glasses.
    /// 16-bit UUID 0xFD5F registered to Facebook, Inc.
    nonisolated(unsafe) static let metaServiceUUID = CBUUID(string: "FD5F")

    // MARK: - DataX characteristic

    /// The main DataX characteristic used for all command/response traffic.
    /// Full 128-bit UUID.
    nonisolated(unsafe) static let dataXCharacteristicUUID = CBUUID(string: "24154476-0E45-11AB-6441-E8BE42459478")

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
    static let deviceNamePrefix = "RB Stories"

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
