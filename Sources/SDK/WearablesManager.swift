import Foundation
import SwiftUI
import os
import MWDATCore
import MWDATCamera

@Observable
@MainActor
final class WearablesManager {

    enum ConnectionState: String, Sendable {
        case unregistered
        case registering
        case registered
        case connecting
        case connected
        case streaming
        case disconnecting
        case error
    }

    // MARK: - State

    private(set) var connectionState: ConnectionState = .unregistered
    private(set) var lastError: String?
    private(set) var latestFrame: UIImage?
    private(set) var capturedPhotos: [Data] = []
    private(set) var isCameraPermissionGranted = false

    // MARK: - Private

    private var deviceSession: DeviceSession?
    private var camera: Camera?
    private var tokenBag = ListenerTokenBag()
    private let logger = Logger(subsystem: "com.openglass.app", category: "Wearables")

    // MARK: - SDK Initialization

    func configure() {
        do {
            try Wearables.configure()
            logger.info("Wearables SDK configured")
            observeRegistration()
        } catch {
            connectionState = .error
            lastError = error.localizedDescription
            logger.error("SDK configure failed: \(error)")
        }
    }

    // MARK: - Registration

    private func observeRegistration() {
        Task {
            for await state in Wearables.shared.registrationStateStream() {
                switch state {
                case .registered:
                    connectionState = .registered
                case .unregistered:
                    connectionState = .unregistered
                case .registering:
                    connectionState = .registering
                default:
                    break
                }
            }
        }
    }

    func register() {
        connectionState = .registering
        Wearables.shared.startRegistration()
    }

    func unregister() {
        stopSession()
        Wearables.shared.startUnregistration()
        connectionState = .unregistered
    }

    // MARK: - Callback URL

    func handleURL(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.queryItems?.contains(where: { $0.name == "metaWearablesAction" }) == true else {
            return false
        }
        do {
            try Wearables.shared.handleUrl(url)
            return true
        } catch {
            logger.error("URL handling failed: \(error)")
            return false
        }
    }

    // MARK: - Session

    func startSession() {
        guard connectionState == .registered else { return }
        connectionState = .connecting

        Task {
            do {
                let selector = AutoDeviceSelector()
                deviceSession = try Wearables.shared.createSession(deviceSelector: selector)
                observeSession()
                try await deviceSession?.start()
            } catch {
                connectionState = .error
                lastError = error.localizedDescription
                logger.error("Session start failed: \(error)")
            }
        }
    }

    func stopSession() {
        guard deviceSession != nil else { return }
        connectionState = .disconnecting
        Task {
            camera?.stop()
            camera = nil
            try? await deviceSession?.stop()
            deviceSession = nil
            latestFrame = nil
            tokenBag = ListenerTokenBag()
            connectionState = .registered
        }
    }

    private func observeSession() {
        guard let session = deviceSession else { return }
        Task {
            for await state in session.statePublisher.values {
                await MainActor.run {
                    switch state {
                    case .started:
                        self.connectionState = .connected
                    case .stopped:
                        self.connectionState = .registered
                        self.deviceSession = nil
                        self.camera = nil
                    default:
                        break
                    }
                }
            }
        }
    }

    // MARK: - Camera

    func startCamera(resolution: StreamConfiguration.Resolution = .medium, frameRate: Int = 15) async {
        guard let session = deviceSession, connectionState == .connected else { return }

        do {
            let status = try await session.checkPermissionStatus(.camera)
            if status != .granted {
                try await session.requestPermission(.camera)
            }
            isCameraPermissionGranted = true

            let config = StreamConfiguration(
                resolution: resolution,
                frameRate: frameRate,
                codec: .raw
            )
            camera = try await session.addCamera(config: config)
            guard let camera else { return }

            observeStream(camera)
            try await camera.stream.start()
            connectionState = .streaming
        } catch {
            lastError = error.localizedDescription
            logger.error("Camera start failed: \(error)")
        }
    }

    func stopCamera() {
        camera?.stop()
        camera = nil
        latestFrame = nil
        if deviceSession != nil {
            connectionState = .connected
        }
    }

    func capturePhoto() -> Bool {
        guard let camera else { return false }
        return camera.stream.capturePhoto(format: .jpeg)
    }

    private func observeStream(_ camera: Camera) {
        Task {
            for await frame in camera.stream.videoFramePublisher.values {
                await MainActor.run {
                    self.latestFrame = frame.makeUIImage()
                }
            }
        }

        Task {
            for await photo in camera.stream.photoDataPublisher.values {
                await MainActor.run {
                    self.capturedPhotos.insert(photo.data, at: 0)
                }
            }
        }

        Task {
            for await error in camera.stream.errorPublisher.values {
                await MainActor.run {
                    self.lastError = error.localizedDescription
                }
                logger.error("Stream error: \(error)")
            }
        }
    }

    // MARK: - Convenience

    var isConnected: Bool {
        connectionState == .connected || connectionState == .streaming
    }

    var isStreaming: Bool {
        connectionState == .streaming
    }

    func clearError() {
        lastError = nil
        if connectionState == .error {
            connectionState = .unregistered
            observeRegistration()
        }
    }
}
