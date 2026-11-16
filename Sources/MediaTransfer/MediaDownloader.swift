import Foundation
import os

/// Downloads photos and videos from the glasses over the SoftAP Wi-Fi connection.
///
/// The glasses run an HTTPS webserver at `https://192.168.1.1/stella-webserver/`
/// that serves captured media via the asset endpoint.
actor MediaDownloader {

    private let logger = Logger(subsystem: "com.openglass.app", category: "MediaDownloader")

    private let softAPManager: SoftAPManager
    private var session: URLSession?

    /// Maximum number of concurrent downloads.
    private let maxConcurrent = 3
    /// Retry count for failed downloads.
    private let maxRetries = 3

    // MARK: - Download state

    struct DownloadProgress: Sendable {
        let assetId: String
        let bytesReceived: Int64
        let totalBytes: Int64
        var fraction: Double {
            totalBytes > 0 ? Double(bytesReceived) / Double(totalBytes) : 0
        }
    }

    private(set) var activeDownloads: [String: DownloadProgress] = [:]

    init(softAPManager: SoftAPManager) {
        self.softAPManager = softAPManager
    }

    // MARK: - Asset list

    /// Fetch the list of captures (photos/videos) stored on the glasses.
    ///
    /// - Returns: JSON data from the asset manifest endpoint.
    func fetchAssetManifest() async throws -> Data {
        let session = getSession()
        let url = URL(string: "\(GATTConstants.webserverBaseURL)/manifest")!

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15

        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw MediaError.invalidResponse
        }
        guard http.statusCode == 200 else {
            throw MediaError.httpError(http.statusCode)
        }

        logger.info("Fetched asset manifest: \(data.count) bytes")
        return data
    }

    // MARK: - Download a single asset

    /// Download a photo or video from the glasses.
    ///
    /// - Parameters:
    ///   - assetId: The unique asset identifier from the manifest.
    ///   - destinationURL: The local file URL to save to.
    /// - Returns: The local file URL where the asset was saved.
    @discardableResult
    func downloadAsset(assetId: String, to destinationURL: URL) async throws -> URL {
        let session = getSession()
        let urlString = "\(GATTConstants.webserverBaseURL)\(GATTConstants.assetEndpoint)?id=\(assetId)"
        guard let url = URL(string: urlString) else {
            throw MediaError.invalidURL(urlString)
        }

        var lastError: Error?

        for attempt in 1...maxRetries {
            do {
                logger.info("Downloading asset \(assetId), attempt \(attempt)")

                var request = URLRequest(url: url)
                request.httpMethod = "GET"
                request.timeoutInterval = 120

                let (tempURL, response) = try await session.download(for: request)

                guard let http = response as? HTTPURLResponse else {
                    throw MediaError.invalidResponse
                }
                guard http.statusCode == 200 else {
                    throw MediaError.httpError(http.statusCode)
                }

                // Move from temp to destination
                let fm = FileManager.default
                if fm.fileExists(atPath: destinationURL.path) {
                    try fm.removeItem(at: destinationURL)
                }
                try fm.moveItem(at: tempURL, to: destinationURL)

                // Update progress
                let fileSize = try fm.attributesOfItem(atPath: destinationURL.path)[.size] as? Int64 ?? 0
                activeDownloads[assetId] = DownloadProgress(
                    assetId: assetId,
                    bytesReceived: fileSize,
                    totalBytes: fileSize
                )

                logger.info("Downloaded asset \(assetId): \(fileSize) bytes")
                activeDownloads.removeValue(forKey: assetId)
                return destinationURL

            } catch {
                lastError = error
                logger.warning("Download attempt \(attempt) failed: \(error.localizedDescription)")
                if attempt < maxRetries {
                    // Brief delay before retry
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        }

        activeDownloads.removeValue(forKey: assetId)
        throw lastError ?? MediaError.downloadFailed
    }

    // MARK: - Download a thumbnail

    /// Download a thumbnail image for an asset.
    func downloadThumbnail(assetId: String, to destinationURL: URL) async throws -> URL {
        let session = getSession()
        let urlString = "\(GATTConstants.webserverBaseURL)\(GATTConstants.assetEndpoint)?id=\(assetId)&thumbnail=true"
        guard let url = URL(string: urlString) else {
            throw MediaError.invalidURL(urlString)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15

        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse,
              http.statusCode == 200 else {
            throw MediaError.invalidResponse
        }

        try data.write(to: destinationURL)
        logger.debug("Downloaded thumbnail for \(assetId): \(data.count) bytes")
        return destinationURL
    }

    // MARK: - Batch download

    /// Download multiple assets concurrently, respecting the concurrency limit.
    func downloadBatch(assets: [(id: String, destination: URL)],
                       progress: @Sendable @escaping (Int, Int) -> Void) async throws {
        let total = assets.count
        var completed = 0

        try await withThrowingTaskGroup(of: Void.self) { group in
            var index = 0

            // Seed the group with up to maxConcurrent tasks
            for _ in 0..<min(maxConcurrent, total) {
                let asset = assets[index]
                index += 1
                group.addTask {
                    try await self.downloadAsset(assetId: asset.id, to: asset.destination)
                }
            }

            // As each finishes, start the next
            for try await _ in group {
                completed += 1
                progress(completed, total)

                if index < total {
                    let asset = assets[index]
                    index += 1
                    group.addTask {
                        try await self.downloadAsset(assetId: asset.id, to: asset.destination)
                    }
                }
            }
        }
    }

    // MARK: - Private

    private func getSession() -> URLSession {
        if let session { return session }
        let newSession = softAPManager.createWiFiBoundSession()
        session = newSession
        return newSession
    }
}

// MARK: - Errors

enum MediaError: Error, LocalizedError {
    case invalidURL(String)
    case invalidResponse
    case httpError(Int)
    case downloadFailed
    case manifestParseFailed

    var errorDescription: String? {
        switch self {
        case .invalidURL(let url): return "Invalid URL: \(url)"
        case .invalidResponse: return "Invalid server response."
        case .httpError(let code): return "HTTP error \(code)."
        case .downloadFailed: return "Download failed after all retries."
        case .manifestParseFailed: return "Failed to parse asset manifest."
        }
    }
}
