import Foundation
import NetworkExtension
import Network
import os

/// Manages the Wi-Fi connection to the glasses' SoftAP (software access point).
///
/// The glasses create a Wi-Fi network when media transfer is requested.
/// This manager joins that network using NEHotspotConfiguration and ensures
/// that URL requests are routed through the Wi-Fi interface (not cellular).
@Observable
final class SoftAPManager: @unchecked Sendable {

    private let logger = Logger(subsystem: "com.openglass.app", category: "SoftAP")

    enum APState: String, Sendable {
        case disconnected
        case joining
        case connected
        case failed
    }

    private(set) var state: APState = .disconnected
    private(set) var lastError: String?

    /// The SSID the glasses broadcast (discovered during BLE negotiation).
    private(set) var currentSSID: String?
    /// The WPA2 passphrase for the SoftAP.
    private(set) var currentPassphrase: String?

    // MARK: - Join the glasses' Wi-Fi network

    /// Join the glasses' SoftAP network.
    ///
    /// - Parameters:
    ///   - ssid: The SSID advertised by the glasses.
    ///   - passphrase: The WPA2 passphrase provided during BLE negotiation.
    func joinNetwork(ssid: String, passphrase: String) async throws {
        state = .joining
        currentSSID = ssid
        currentPassphrase = passphrase

        let configuration = NEHotspotConfiguration(
            ssid: ssid,
            passphrase: passphrase,
            isWEP: false
        )
        // Don't join if there's no internet — we know there won't be, it's a local AP
        configuration.joinOnce = true

        logger.info("Joining SoftAP: \(ssid)")

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NEHotspotConfigurationManager.shared.apply(configuration) { [weak self] error in
                guard let self else { return }
                if let error {
                    if (error as NSError).domain == NEHotspotConfigurationErrorDomain,
                       (error as NSError).code == NEHotspotConfigurationError.alreadyAssociated.rawValue {
                        // Already connected — that's fine
                        self.state = .connected
                        self.logger.info("Already connected to \(ssid)")
                        continuation.resume()
                    } else {
                        self.state = .failed
                        self.lastError = error.localizedDescription
                        self.logger.error("Failed to join \(ssid): \(error.localizedDescription)")
                        continuation.resume(throwing: error)
                    }
                } else {
                    self.state = .connected
                    self.logger.info("Connected to SoftAP: \(ssid)")
                    continuation.resume()
                }
            }
        }
    }

    // MARK: - Leave the network

    func leaveNetwork() {
        guard let ssid = currentSSID else { return }
        NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: ssid)
        state = .disconnected
        currentSSID = nil
        currentPassphrase = nil
        logger.info("Disconnected from SoftAP")
    }

    // MARK: - Create a URLSession bound to the Wi-Fi interface

    /// Create a URLSession whose connections are forced through the Wi-Fi interface.
    /// This prevents iOS from routing traffic over cellular when the SoftAP has no internet.
    func createWiFiBoundSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        // Disable cellular so iOS is forced to use Wi-Fi
        config.allowsCellularAccess = false
        // Disable constrained network restrictions
        config.allowsConstrainedNetworkAccess = true
        config.allowsExpensiveNetworkAccess = true

        return URLSession(
            configuration: config,
            delegate: SelfSignedCertDelegate(),
            delegateQueue: nil
        )
    }

    // MARK: - NWConnection for direct TCP (if needed)

    /// Create an NW connection to the glasses' webserver, bound to the Wi-Fi interface.
    func createNWConnection(port: UInt16 = 443) -> NWConnection {
        let host = NWEndpoint.Host(GATTConstants.softAPAddress)
        let nwPort = NWEndpoint.Port(rawValue: port)!

        let tlsOptions = NWProtocolTLS.Options()
        sec_protocol_options_set_verify_block(
            tlsOptions.securityProtocolOptions,
            { _, trust, completionHandler in
                // Accept the glasses' self-signed certificate
                completionHandler(true)
            },
            DispatchQueue(label: "com.openglass.tls")
        )

        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.connectionTimeout = 10

        let params = NWParameters(tls: tlsOptions, tcp: tcpOptions)
        // Restrict to Wi-Fi only
        params.requiredInterfaceType = .wifi

        return NWConnection(host: host, port: nwPort, using: params)
    }
}

// MARK: - Self-signed certificate trust for URLSession

/// URLSession delegate that trusts the glasses' self-signed HTTPS certificate.
final class SelfSignedCertDelegate: NSObject, URLSessionDelegate, Sendable {

    func urlSession(_ session: URLSession,
                     didReceive challenge: URLAuthenticationChallenge,
                     completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              challenge.protectionSpace.host == GATTConstants.softAPAddress,
              let serverTrust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        // Trust the self-signed certificate from the glasses
        let credential = URLCredential(trust: serverTrust)
        completionHandler(.useCredential, credential)
    }
}
