import Foundation
import SwiftData
import Photos
import os

/// Manages local file storage for downloaded captures and exports to the Photos library.
actor LocalStore {

    private let logger = Logger(subsystem: "com.openglass.app", category: "LocalStore")

    /// Root directory for all downloaded media.
    let mediaDirectory: URL
    /// Subdirectory for thumbnails.
    let thumbnailDirectory: URL

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        mediaDirectory = docs.appendingPathComponent("OpenGlass", isDirectory: true)
        thumbnailDirectory = mediaDirectory.appendingPathComponent("thumbnails", isDirectory: true)

        // Ensure directories exist
        let fm = FileManager.default
        try? fm.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
        try? fm.createDirectory(at: thumbnailDirectory, withIntermediateDirectories: true)
    }

    // MARK: - File paths

    /// Return the local file URL for a capture's full-resolution file.
    func fileURL(for capture: Capture) -> URL {
        let ext = capture.type == .video ? "mp4" : "jpg"
        return mediaDirectory.appendingPathComponent("\(capture.id).\(ext)")
    }

    /// Return the local file URL for a capture's thumbnail.
    func thumbnailURL(for capture: Capture) -> URL {
        return thumbnailDirectory.appendingPathComponent("\(capture.id)_thumb.jpg")
    }

    // MARK: - File existence

    func isDownloaded(_ capture: Capture) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(for: capture).path)
    }

    func hasThumbnail(_ capture: Capture) -> Bool {
        FileManager.default.fileExists(atPath: thumbnailURL(for: capture).path)
    }

    // MARK: - Delete

    func deleteCapture(_ capture: Capture) throws {
        let fm = FileManager.default
        let file = fileURL(for: capture)
        let thumb = thumbnailURL(for: capture)

        if fm.fileExists(atPath: file.path) {
            try fm.removeItem(at: file)
            logger.info("Deleted file: \(file.lastPathComponent)")
        }
        if fm.fileExists(atPath: thumb.path) {
            try fm.removeItem(at: thumb)
        }
    }

    func deleteAllMedia() throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: mediaDirectory.path) {
            try fm.removeItem(at: mediaDirectory)
            try fm.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
            try fm.createDirectory(at: thumbnailDirectory, withIntermediateDirectories: true)
            logger.info("Deleted all local media")
        }
    }

    // MARK: - Storage stats

    struct StorageStats: Sendable {
        let fileCount: Int
        let totalBytes: Int64
    }

    func getStorageStats() -> StorageStats {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: mediaDirectory,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return StorageStats(fileCount: 0, totalBytes: 0)
        }

        var count = 0
        var totalBytes: Int64 = 0

        while let url = enumerator.nextObject() as? URL {
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            count += 1
            totalBytes += Int64(values.fileSize ?? 0)
        }

        return StorageStats(fileCount: count, totalBytes: totalBytes)
    }

    // MARK: - Export to Photos

    /// Export a downloaded capture to the system Photos library.
    ///
    /// - Parameter capture: The capture to export (must be downloaded).
    /// - Throws: If the file doesn't exist or Photos access is denied.
    func exportToPhotos(_ capture: Capture) async throws {
        let fileURL = fileURL(for: capture)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw StorageError.fileNotFound(fileURL.path)
        }

        // Request Photos access
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw StorageError.photosAccessDenied
        }

        try await PHPhotoLibrary.shared().performChanges {
            if capture.type == .video {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: fileURL)
            } else {
                PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: fileURL)
            }
        }

        logger.info("Exported \(capture.type.displayName) \(capture.id) to Photos")
    }

    /// Export all downloaded captures to Photos.
    func exportAllToPhotos(captures: [Capture], progress: @Sendable @escaping (Int, Int) -> Void) async throws {
        let downloadedCaptures = captures.filter { isDownloaded($0) && !$0.isExportedToPhotos }
        let total = downloadedCaptures.count
        var completed = 0

        for capture in downloadedCaptures {
            try await exportToPhotos(capture)
            completed += 1
            progress(completed, total)
        }
    }
}

// MARK: - Errors

enum StorageError: Error, LocalizedError {
    case fileNotFound(String)
    case photosAccessDenied
    case exportFailed

    var errorDescription: String? {
        switch self {
        case .fileNotFound(let path): return "File not found: \(path)"
        case .photosAccessDenied: return "Photos library access denied."
        case .exportFailed: return "Failed to export to Photos."
        }
    }
}
