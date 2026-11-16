import Foundation
import SwiftData

/// The type of media captured by the glasses.
enum CaptureType: Int, Codable, Sendable {
    /// Photo capture (type code 3073 / 0x0C01).
    case photo = 3073
    /// Video capture (type code 3074 / 0x0C02).
    case video = 3074

    var displayName: String {
        switch self {
        case .photo: return "Photo"
        case .video: return "Video"
        }
    }

    var systemImage: String {
        switch self {
        case .photo: return "photo"
        case .video: return "video"
        }
    }
}

/// Metadata for a single photo or video captured by the glasses.
/// This is used for display in the gallery and for download tracking.
struct Capture: Identifiable, Codable, Sendable {
    /// The asset ID used for downloading from the glasses' webserver.
    let id: String
    /// Photo (3073) or video (3074).
    let type: CaptureType
    /// When the capture was taken (epoch seconds from the glasses' clock).
    let timestamp: Date
    /// File size in bytes, if known from the manifest.
    let fileSize: Int64?
    /// Duration in seconds (videos only).
    let duration: Double?
    /// Width in pixels, if reported.
    let width: Int?
    /// Height in pixels, if reported.
    let height: Int?

    /// Whether the full-resolution file has been downloaded locally.
    var isDownloaded: Bool = false
    /// Whether the thumbnail has been downloaded.
    var hasThumbnail: Bool = false
    /// Local file URL for the downloaded full-resolution file.
    var localFileURL: URL?
    /// Local file URL for the downloaded thumbnail.
    var thumbnailURL: URL?
    /// Whether this capture has been exported to the Photos library.
    var isExportedToPhotos: Bool = false
}

/// SwiftData model for persisting capture records across app launches.
@Model
final class CaptureRecord {
    @Attribute(.unique) var assetId: String
    var captureType: Int
    var timestamp: Date
    var fileSize: Int64
    var duration: Double?
    var width: Int?
    var height: Int?
    var isDownloaded: Bool
    var localFileName: String?
    var thumbnailFileName: String?
    var isExportedToPhotos: Bool

    init(from capture: Capture) {
        self.assetId = capture.id
        self.captureType = capture.type.rawValue
        self.timestamp = capture.timestamp
        self.fileSize = capture.fileSize ?? 0
        self.duration = capture.duration
        self.width = capture.width
        self.height = capture.height
        self.isDownloaded = capture.isDownloaded
        self.localFileName = capture.localFileURL?.lastPathComponent
        self.thumbnailFileName = capture.thumbnailURL?.lastPathComponent
        self.isExportedToPhotos = capture.isExportedToPhotos
    }

    func toCapture(baseDirectory: URL) -> Capture {
        var capture = Capture(
            id: assetId,
            type: CaptureType(rawValue: captureType) ?? .photo,
            timestamp: timestamp,
            fileSize: fileSize,
            duration: duration,
            width: width,
            height: height
        )
        capture.isDownloaded = isDownloaded
        capture.isExportedToPhotos = isExportedToPhotos
        if let fileName = localFileName {
            capture.localFileURL = baseDirectory.appendingPathComponent(fileName)
        }
        if let thumbName = thumbnailFileName {
            capture.thumbnailURL = baseDirectory.appendingPathComponent("thumbnails").appendingPathComponent(thumbName)
        }
        return capture
    }
}
