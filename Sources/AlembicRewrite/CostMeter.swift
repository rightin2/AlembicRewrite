//
//  CostMeter.swift
//  AlembicRewrite
//
//  Implements: CostMetering. Folds UsageRecords into a running token/dollar
//  tally priced via PriceTable. Persisted to
//  ~/Library/Application Support/AlembicRewrite/cost.json so the tally survives
//  relaunch. Aggregates per model so per-model pricing stays accurate; cost is
//  computed on read from the current PriceTable.
//

import Foundation

public final class CostMeter: CostMetering {
    /// Per-model running token totals since the last reset.
    private struct ModelTally: Codable, Hashable {
        var provider: Provider
        var inputTokens: Int
        var outputTokens: Int
    }

    private struct State: Codable {
        /// Keyed by model identifier string.
        var tallies: [String: ModelTally]

        init(tallies: [String: ModelTally] = [:]) {
            self.tallies = tallies
        }
    }

    private let overrideDirectory: URL?

    /// - Parameter directory: override the storage directory (tests inject a
    ///   temp dir). `nil` uses the shared Application Support location.
    public init(directory: URL? = nil) {
        self.overrideDirectory = directory
    }

    private func fileURL() throws -> URL {
        let dir = try overrideDirectory ?? StorageLocations.defaultDirectory()
        return dir.appendingPathComponent("cost.json")
    }

    private func load() throws -> State {
        try JSONFile.read(State.self, from: fileURL(), fallback: State())
    }

    public func record(_ usage: UsageRecord) throws {
        var state = try load()
        var tally = state.tallies[usage.model]
            ?? ModelTally(provider: usage.provider, inputTokens: 0, outputTokens: 0)
        tally.inputTokens += usage.inputTokens
        tally.outputTokens += usage.outputTokens
        state.tallies[usage.model] = tally
        try JSONFile.write(state, to: fileURL())
    }

    public func totalCostUSD() -> Double {
        guard let state = try? load() else { return 0 }
        return state.tallies.reduce(0.0) { sum, entry in
            let (model, tally) = entry
            return sum + PriceTable.cost(
                model: model,
                inputTokens: tally.inputTokens,
                outputTokens: tally.outputTokens
            )
        }
    }

    public func totalTokens() -> Int {
        guard let state = try? load() else { return 0 }
        return state.tallies.values.reduce(0) { $0 + $1.inputTokens + $1.outputTokens }
    }

    public func reset() throws {
        try JSONFile.write(State(), to: fileURL())
    }
}
