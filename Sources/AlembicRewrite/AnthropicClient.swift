//
//  AnthropicClient.swift
//  AlembicRewrite
//
//  Implements: LLMClienting (Anthropic Messages API, SSE streaming).
//
//  Endpoint : POST https://api.anthropic.com/v1/messages
//  Headers  : x-api-key, anthropic-version: 2023-06-01, content-type
//  Body     : stream:true; system extracted from ChatMessage system turns;
//             user/assistant turns passed through in order.
//
//  Stream parse (per-line SSE, keyed off the JSON "type" field):
//    message_start        -> usage.input_tokens
//    content_block_delta  -> delta.text (text_delta) yielded
//    message_delta        -> usage.output_tokens
//    error                -> throws LLMError
//

import Foundation

public struct AnthropicClient: LLMClienting {
    public init() {}

    public func stream(
        messages: [ChatMessage],
        model: String,
        temperature: Double,
        maxTokens: Int,
        apiKey: String,
        onUsage: @escaping @Sendable (_ inputTokens: Int, _ outputTokens: Int) -> Void
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard !apiKey.isEmpty else {
                        throw LLMError.missingAPIKey(.anthropic)
                    }
                    let request = try makeRequest(
                        messages: messages,
                        model: model,
                        temperature: temperature,
                        maxTokens: maxTokens,
                        apiKey: apiKey
                    )
                    let bytes = try await LLMTransport.openStream(request)

                    var inputTokens = 0
                    var outputTokens = 0

                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard let payload = LLMTransport.dataPayload(from: line),
                              let data = payload.data(using: .utf8),
                              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let type = event["type"] as? String
                        else { continue }

                        switch type {
                        case "message_start":
                            if let message = event["message"] as? [String: Any],
                               let usage = message["usage"] as? [String: Any] {
                                inputTokens = usage["input_tokens"] as? Int ?? inputTokens
                                outputTokens = usage["output_tokens"] as? Int ?? outputTokens
                            }
                        case "content_block_delta":
                            if let delta = event["delta"] as? [String: Any],
                               delta["type"] as? String == "text_delta",
                               let text = delta["text"] as? String {
                                continuation.yield(text)
                            }
                        case "message_delta":
                            if let usage = event["usage"] as? [String: Any],
                               let output = usage["output_tokens"] as? Int {
                                outputTokens = output
                            }
                        case "error":
                            let message = (event["error"] as? [String: Any])?["message"] as? String ?? "Anthropic stream error"
                            throw LLMError.httpError(status: 200, body: message)
                        default:
                            continue
                        }
                    }

                    onUsage(inputTokens, outputTokens)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func makeRequest(
        messages: [ChatMessage],
        model: String,
        temperature: Double,
        maxTokens: Int,
        apiKey: String
    ) throws -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        // Anthropic takes system prompts out-of-band; the messages array holds
        // only user/assistant turns.
        let system = messages
            .filter { $0.role == .system }
            .map(\.content)
            .joined(separator: "\n\n")
        let turns = messages
            .filter { $0.role != .system }
            .map { ["role": $0.role.rawValue, "content": $0.content] }

        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "temperature": temperature,
            "stream": true,
            "messages": turns
        ]
        if !system.isEmpty {
            body["system"] = system
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }
}
