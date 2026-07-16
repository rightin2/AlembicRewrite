//
//  PriceTable.swift
//  PromptRewriter
//
//  Per-model USD price data (input/output per 1M tokens) consumed by CostMeter,
//  plus the shared on-disk storage location helper used by StyleStore,
//  HistoryStore and CostMeter (all JSON-file-backed — see the storage decision
//  in Protocols.swift).
//

import Foundation

/// USD price per one million tokens for a given model.
public struct ModelPrice: Codable, Hashable, Sendable {
    public var inputPerMTok: Double
    public var outputPerMTok: Double

    public init(inputPerMTok: Double, outputPerMTok: Double) {
        self.inputPerMTok = inputPerMTok
        self.outputPerMTok = outputPerMTok
    }
}

public enum PriceTable {
    /// Looked-up price for a model string, or `nil` if unknown (cost meter
    /// treats unknown models as zero-cost and may surface a warning).
    public static func price(for model: String) -> ModelPrice? {
        prices[model]
    }

    /// Static rate table, USD per 1M tokens (input / output).
    static let prices: [String: ModelPrice] = [
        // Anthropic
        "claude-haiku-4-5":  ModelPrice(inputPerMTok: 1.00,  outputPerMTok: 5.00),
        "claude-sonnet-4-6": ModelPrice(inputPerMTok: 3.00,  outputPerMTok: 15.00),
        "claude-opus-4-8":   ModelPrice(inputPerMTok: 5.00,  outputPerMTok: 25.00),
        // OpenAI
        "gpt-4o":            ModelPrice(inputPerMTok: 2.50,  outputPerMTok: 10.00),
        "gpt-4o-mini":       ModelPrice(inputPerMTok: 0.15,  outputPerMTok: 0.60),
    ]

    /// Dollar cost of a single turn's usage on `model`. Unknown models cost 0.
    static func cost(model: String, inputTokens: Int, outputTokens: Int) -> Double {
        guard let p = price(for: model) else { return 0 }
        return (Double(inputTokens) / 1_000_000.0) * p.inputPerMTok
            + (Double(outputTokens) / 1_000_000.0) * p.outputPerMTok
    }
}

// MARK: - Shared storage location

/// Resolves the on-disk home for the JSON stores. Concrete stores accept an
/// optional override directory (used by tests) and otherwise fall back here.
enum StorageLocations {
    /// `~/Library/Application Support/PromptRewriter/`, created if absent.
    static func defaultDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = base.appendingPathComponent("PromptRewriter", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

/// Shared JSON read/write helpers so the three stores encode/decode identically
/// (ISO-8601 dates, pretty-printed, atomic writes).
enum JSONFile {
    static func makeEncoder() -> JSONEncoder {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return enc
    }

    static func makeDecoder() -> JSONDecoder {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return dec
    }

    /// Decodes `T` from `url`, or returns `fallback` when the file is absent.
    static func read<T: Decodable>(_ type: T.Type, from url: URL, fallback: T) throws -> T {
        guard FileManager.default.fileExists(atPath: url.path) else { return fallback }
        let data = try Data(contentsOf: url)
        if data.isEmpty { return fallback }
        return try makeDecoder().decode(T.self, from: data)
    }

    /// Atomically writes `value` as JSON to `url`.
    static func write<T: Encodable>(_ value: T, to url: URL) throws {
        let data = try makeEncoder().encode(value)
        try data.write(to: url, options: .atomic)
    }
}
