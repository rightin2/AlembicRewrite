//
//  OpenAIClient.swift
//  PromptRewriter
//
//  Implements: LLMClienting (OpenAI chat completions, SSE streaming).
//
//  Endpoint : POST https://api.openai.com/v1/chat/completions
//  Headers  : Authorization: Bearer <key>, content-type
//  Body     : stream:true, stream_options.include_usage:true; all message
//             roles (system/user/assistant) passed through in order.
//
//  Stream parse (per-line SSE):
//    "data: [DONE]"            -> end of stream
//    choices[0].delta.content  -> yielded
//    usage.{prompt,completion}_tokens (final chunk) -> token counts
//

import Foundation

public struct OpenAIClient: LLMClienting {
    public init() {}

    public func stream(
        messages: [ChatMessage],
        model: String,
        temperature: Double,
        apiKey: String,
        onUsage: @escaping @Sendable (_ inputTokens: Int, _ outputTokens: Int) -> Void
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard !apiKey.isEmpty else {
                        throw LLMError.missingAPIKey(.openai)
                    }
                    let request = try makeRequest(
                        messages: messages,
                        model: model,
                        temperature: temperature,
                        apiKey: apiKey
                    )
                    let bytes = try await LLMTransport.openStream(request)

                    var inputTokens = 0
                    var outputTokens = 0

                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard let payload = LLMTransport.dataPayload(from: line) else { continue }
                        if payload == "[DONE]" { break }
                        guard let data = payload.data(using: .utf8),
                              let chunk = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                        else { continue }

                        if let choices = chunk["choices"] as? [[String: Any]],
                           let delta = choices.first?["delta"] as? [String: Any],
                           let content = delta["content"] as? String,
                           !content.isEmpty {
                            continuation.yield(content)
                        }

                        // With include_usage the final data chunk (choices empty)
                        // carries the turn's token totals.
                        if let usage = chunk["usage"] as? [String: Any] {
                            inputTokens = usage["prompt_tokens"] as? Int ?? inputTokens
                            outputTokens = usage["completion_tokens"] as? Int ?? outputTokens
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
        apiKey: String
    ) throws -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        let turns = messages.map { ["role": $0.role.rawValue, "content": $0.content] }
        let body: [String: Any] = [
            "model": model,
            "temperature": temperature,
            "stream": true,
            "stream_options": ["include_usage": true],
            "messages": turns
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }
}

/// Shared error type for stubbed and real module code.
public enum PromptRewriterError: LocalizedError {
    case notImplemented(String)
    case missingAPIKey(Provider)
    case emptySelection
    case apiError(String)

    public var errorDescription: String? {
        switch self {
        case .notImplemented(let what): return "\(what) is not yet implemented."
        case .missingAPIKey(let p):     return "No API key configured for \(p.rawValue)."
        case .emptySelection:           return "No text selected."
        case .apiError(let msg):        return msg
        }
    }
}
