//
//  LLMClient.swift
//  AlembicRewrite
//
//  Shared LLMClienting factory, typed error, and streaming helpers. The two
//  concrete backends live in AnthropicClient.swift and OpenAIClient.swift.
//

import Foundation

/// Returns the streaming client for a given provider.
public enum LLMClientFactory {
    public static func client(for provider: Provider) -> LLMClienting {
        switch provider {
        case .anthropic: return AnthropicClient()
        case .openai:    return OpenAIClient()
        }
    }
}

/// Typed errors surfaced by the LLM backends. HTTP failures carry the status
/// code and (best-effort) response body so the panel can show a useful message.
public enum LLMError: LocalizedError, Sendable {
    /// Non-2xx HTTP response from the provider.
    case httpError(status: Int, body: String)
    /// The response was not an HTTPURLResponse, or was otherwise unusable.
    case invalidResponse
    /// The API key handed to the backend was empty.
    case missingAPIKey(Provider)
    /// The provider accepted the request but reported it is temporarily
    /// overloaded (Anthropic overloaded_error / HTTP 529). Transient; retry.
    case providerOverloaded(Provider)
    /// The provider reported an error inside an otherwise-successful stream.
    case streamError(message: String)

    public var errorDescription: String? {
        switch self {
        case .httpError(let status, let body):
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = LLMError.extractMessage(from: trimmed) ?? trimmed
            if detail.isEmpty {
                return "The provider returned HTTP \(status)."
            }
            return "HTTP \(status): \(detail)"
        case .invalidResponse:
            return "The provider returned an unexpected response."
        case .missingAPIKey(let provider):
            return "No API key configured for \(provider.rawValue)."
        case .providerOverloaded(let provider):
            return "\(provider.rawValue.capitalized) is briefly overloaded. Wait a few seconds and press Retry."
        case .streamError(let message):
            return message
        }
    }

    /// Both providers wrap errors as `{"error":{"message":"..."}}`. Pull the
    /// human-readable message out when present.
    private static func extractMessage(from body: String) -> String? {
        guard
            let data = body.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let error = object["error"] as? [String: Any],
            let message = error["message"] as? String
        else { return nil }
        return message
    }
}

// MARK: - Shared streaming transport

enum LLMTransport {
    /// The shared session for streaming LLM calls. A per-client default session
    /// is fine for v1's low volume; kept here so both backends share config.
    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 300
        config.waitsForConnectivity = true
        return URLSession(configuration: config)
    }()

    /// Fire the request and, on a 2xx response, hand back the byte stream ready
    /// for line-by-line SSE parsing. On a non-2xx response, drain the body and
    /// throw `LLMError.httpError`.
    static func openStream(_ request: URLRequest) async throws -> URLSession.AsyncBytes {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LLMError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            // 529 is Anthropic's dedicated overloaded status; 503 is the
            // generic equivalent. Both are transient and worth a retry.
            if http.statusCode == 529 || http.statusCode == 503 {
                throw LLMError.providerOverloaded(
                    request.url?.host?.contains("anthropic") == true ? .anthropic : .openai)
            }
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
            }
            let body = String(data: data, encoding: .utf8) ?? ""
            throw LLMError.httpError(status: http.statusCode, body: body)
        }
        return bytes
    }

    /// Strip the leading `data:` (or `data: `) marker from an SSE line, or
    /// return `nil` if the line is not a data line.
    static func dataPayload(from line: String) -> String? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst("data:".count)
        return payload.hasPrefix(" ") ? String(payload.dropFirst()) : String(payload)
    }
}
