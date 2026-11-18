// Meta OAuth login and hardware-API pairing backend for the change-owner protocol.

import AuthenticationServices
import CryptoKit
import Foundation
import os

actor MetaAuth {

    private let logger = Logger(subsystem: "com.openglass.app", category: "MetaAuth")

    // The OAuth login opens a Meta accounts page and returns an auth code, which we exchange
    // for an FRLA (first-party resource-limited access token), then for an AR access token.
    // The AR token goes to the hardware Graph for pair_request / pair.
    //
    // APP_ID and REDIRECT_URI come from the Meta AI companion app's OAuth configuration.
    // The hardware token (HW_APP_TOKEN) is the app-level token that identifies the caller to
    // graph.facebook-hardware.com. It is NOT a user secret — but it is not published either.
    // The user can extract it from an Android APK or Visor's local.properties.

    private static let oauthAppID = "934401142814369"
    private static let redirectURI = "https://accounts.meta.com/native/oidc/redirect/metaai"
    private static let authorizeURL = "https://accounts.meta.com/oidc/"
    private static let exchangeURL = "https://api.accounts.meta.com/native/oidc/token-exchange/"
    private static let arLoginURL = "https://ar.graph.meta.com/login"
    private static let hwGraphBase = "https://graph.facebook-hardware.com"
    private static let pairProtocolVersion = "4"

    struct Tokens {
        let arToken: String
        let hwAppToken: String
    }

    struct Receipt {
        let signature: Data
        let bodyJSON: Data

        func encode() -> [UInt8] {
            ProtoWire.field(1, bytes: Array(signature)) + ProtoWire.field(2, bytes: Array(bodyJSON))
        }

        static func decode(_ data: [UInt8]) -> Receipt {
            let fields = ProtoWire.parse(data)
            return Receipt(signature: Data(fields.bytes(1)), bodyJSON: Data(fields.bytes(2)))
        }
    }

    struct DeviceIdentity {
        let certDER: Data
        let serial: String
        let secondaryCert: Data
    }

    // MARK: - OAuth login

    func loginURL() -> URL {
        var components = URLComponents(string: Self.authorizeURL)!
        components.queryItems = [
            URLQueryItem(name: "app_id", value: Self.oauthAppID),
            URLQueryItem(name: "scope", value: "openid"),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "state", value: randomState()),
        ]
        return components.url!
    }

    func exchangeCodeForTokens(code: String, hwAppToken: String) async throws -> Tokens {
        let frla = try await exchangeCodeForFRLA(code: code)
        let arToken = try await exchangeFRLAForAR(frla: frla)
        return Tokens(arToken: arToken, hwAppToken: hwAppToken)
    }

    private func exchangeCodeForFRLA(code: String) async throws -> String {
        let body = formEncode([
            "mt_app_id": Self.oauthAppID,
            "oidc_auth_code": code,
            "redirect_uri": Self.redirectURI,
        ])
        let json = try await post(url: Self.exchangeURL, body: body)
        guard let token = json["access_token"] as? String, !token.isEmpty else {
            throw MetaAuthError.tokenExchangeFailed("no access_token in response")
        }
        return token
    }

    private func exchangeFRLAForAR(frla: String) async throws -> String {
        let body = formEncode([
            "access_token": frla,
            "format": "json",
        ])
        let json = try await post(url: Self.arLoginURL, body: body)
        guard let token = json["access_token"] as? String, !token.isEmpty else {
            throw MetaAuthError.tokenExchangeFailed("no AR access_token in response")
        }
        return token
    }

    // MARK: - Hardware Graph: pair_request → pair

    func pairRequest(
        tokens: Tokens,
        certDER: Data,
        serial: String,
        deviceNonce: Data,
        appPubkey: Data,
        secondaryCert: Data
    ) async throws -> Receipt {
        let additionalData = jsonString([
            "device_nonce": deviceNonce.base64EncodedString(),
            "app_pubkey": appPubkey.base64EncodedString(),
            "secondary_cert": secondaryCert.base64EncodedString(),
        ])
        let fields: [(String, String)] = [
            ("access_token", tokens.hwAppToken),
            ("user_access_token", tokens.arToken),
            ("user_token_universe", "ar"),
            ("pair_protocol_version", Self.pairProtocolVersion),
            ("device_cert", certDER.base64EncodedString()),
            ("serial_number", serial),
            ("additional_data", additionalData),
        ]
        let json = try await post(url: "\(Self.hwGraphBase)/pair_request", body: formEncode(fields))
        return try parseReceipt(json, receiptKey: "pending_ownership_receipt")
    }

    func pair(tokens: Tokens, devicePendingReceipt: Receipt) async throws -> Receipt {
        let fields: [(String, String)] = [
            ("access_token", tokens.hwAppToken),
            ("user_access_token", tokens.arToken),
            ("user_token_universe", "ar"),
            ("pair_protocol_version", Self.pairProtocolVersion),
            ("device_pending_ownership_receipt", String(data: devicePendingReceipt.bodyJSON, encoding: .utf8) ?? ""),
            ("device_pending_ownership_receipt_signature", devicePendingReceipt.signature.base64EncodedString()),
        ]
        let json = try await post(url: "\(Self.hwGraphBase)/pair", body: formEncode(fields))
        return try parseReceipt(json, receiptKey: "final_ownership_receipt")
    }

    // MARK: - Helpers

    private func post(url: String, body: Data, headers: [String: String] = [:]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MetaAuthError.serverError("HTTP \(status), not JSON")
        }
        if let error = json["error"] as? [String: Any], let message = error["message"] as? String {
            throw MetaAuthError.serverError(message)
        }
        if status >= 400 {
            throw MetaAuthError.serverError("HTTP \(status)")
        }
        return json
    }

    private func parseReceipt(_ json: [String: Any], receiptKey: String) throws -> Receipt {
        guard let sigB64 = json["receipt_signature"] as? String else {
            throw MetaAuthError.serverError("no receipt_signature in response")
        }
        guard let signature = Data(base64Encoded: sigB64, options: .ignoreUnknownCharacters) else {
            throw MetaAuthError.serverError("invalid receipt_signature base64")
        }
        let bodyJSON: Data
        if let str = json[receiptKey] as? String {
            bodyJSON = Data(str.utf8)
        } else if let obj = json[receiptKey] {
            bodyJSON = try JSONSerialization.data(withJSONObject: obj)
        } else {
            throw MetaAuthError.serverError("no \(receiptKey) in response")
        }
        return Receipt(signature: signature, bodyJSON: bodyJSON)
    }

    private func formEncode(_ fields: [(String, String)]) -> Data {
        let encoded = fields.map { key, value in
            "\(urlEncode(key))=\(urlEncode(value))"
        }.joined(separator: "&")
        return Data(encoded.utf8)
    }

    private func formEncode(_ dict: [String: String]) -> Data {
        formEncode(dict.sorted(by: { $0.key < $1.key }).map { ($0.key, $0.value) })
    }

    private func urlEncode(_ string: String) -> String {
        string.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? string
    }

    private func jsonString(_ dict: [String: String]) -> String {
        let pairs = dict.sorted(by: { $0.key < $1.key }).map { key, value in
            "\"\(key)\": \"\(value)\""
        }
        return "{\(pairs.joined(separator: ", "))}"
    }

    private func randomState() -> String {
        Data((0..<16).map { _ in UInt8.random(in: 0...255) })
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

enum MetaAuthError: LocalizedError {
    case tokenExchangeFailed(String)
    case serverError(String)
    case wrongOwner

    var errorDescription: String? {
        switch self {
        case .tokenExchangeFailed(let msg): return "Token exchange failed: \(msg)"
        case .serverError(let msg): return "Meta API error: \(msg)"
        case .wrongOwner: return "These glasses belong to another Meta account"
        }
    }
}

private extension CharacterSet {
    static let urlQueryValueAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&=+")
        return set
    }()
}
