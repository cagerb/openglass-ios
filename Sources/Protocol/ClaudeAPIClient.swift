// Minimal Claude API client for the assistant service.
// Posts to the Messages API and returns the text response.

import Foundation
import os

actor ClaudeAPIClient {

    private static let endpoint = "https://api.anthropic.com/v1/messages"
    private static let apiVersion = "2023-06-01"
    private static let defaultModel = "claude-sonnet-4-20250514"
    private static let defaultMaxTokens = 1024

    private let logger = Logger(subsystem: "com.openglass.app", category: "ClaudeAPI")

    private let model: String
    private let maxTokens: Int

    static var apiKey: String {
        get {
            UserDefaults.standard.string(forKey: "com.openglass.claudeAPIKey") ?? ""
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "com.openglass.claudeAPIKey")
        }
    }

    var hasAPIKey: Bool {
        !Self.apiKey.isEmpty
    }

    init(model: String = defaultModel, maxTokens: Int = defaultMaxTokens) {
        self.model = model
        self.maxTokens = maxTokens
    }

    // MARK: - Public

    struct Message: Codable, Sendable {
        let role: String
        let content: String
    }

    func chat(messages: [Message], systemPrompt: String? = nil) async throws -> String {
        let key = Self.apiKey
        guard !key.isEmpty else {
            throw ClaudeAPIError.noAPIKey
        }

        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "messages": messages.map { ["role": $0.role, "content": $0.content] },
        ]
        if let system = systemPrompt {
            body["system"] = system
        }

        let jsonData = try JSONSerialization.data(withJSONObject: body)

        var request = URLRequest(url: URL(string: Self.endpoint)!)
        request.httpMethod = "POST"
        request.httpBody = jsonData
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 60

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw ClaudeAPIError.invalidResponse
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeAPIError.decodingFailed("response is not JSON")
        }

        if http.statusCode == 401 {
            throw ClaudeAPIError.invalidAPIKey
        }

        if let error = json["error"] as? [String: Any], let message = error["message"] as? String {
            throw ClaudeAPIError.apiError(http.statusCode, message)
        }

        guard http.statusCode == 200 else {
            throw ClaudeAPIError.apiError(http.statusCode, "HTTP \(http.statusCode)")
        }

        guard let content = json["content"] as? [[String: Any]],
              let first = content.first,
              let text = first["text"] as? String else {
            throw ClaudeAPIError.decodingFailed("no content[0].text in response")
        }

        logger.info("Claude response: \(text.prefix(80))...")
        return text
    }
}

// MARK: - Errors

enum ClaudeAPIError: Error, LocalizedError {
    case noAPIKey
    case invalidAPIKey
    case invalidResponse
    case decodingFailed(String)
    case apiError(Int, String)

    var errorDescription: String? {
        switch self {
        case .noAPIKey:
            return "No Claude API key set. Add one in Settings."
        case .invalidAPIKey:
            return "Invalid Claude API key."
        case .invalidResponse:
            return "Invalid response from Claude API."
        case .decodingFailed(let detail):
            return "Failed to decode Claude response: \(detail)"
        case .apiError(let code, let message):
            return "Claude API error (\(code)): \(message)"
        }
    }
}
