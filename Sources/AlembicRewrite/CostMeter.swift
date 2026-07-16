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
        /// Lifetime-since-reset totals, keyed by model identifier string. Drives
        /// the menu-bar spend display and is what `reset()` zeroes.
        var tallies: [String: ModelTally]
        /// Per-calendar-month totals for the spend cap (setting 3.3), keyed by
        /// month ("yyyy-MM") then model. Survives `reset()` so the cap keeps
        /// tracking across a display reset.
        var monthly: [String: [String: ModelTally]]

        init(tallies: [String: ModelTally] = [:],
             monthly: [String: [String: ModelTally]] = [:]) {
            self.tallies = tallies
            self.monthly = monthly
        }

        private enum CodingKeys: String, CodingKey { case tallies, monthly }

        /// Tolerant decoder: an older cost.json without `monthly` loads with an
        /// empty month map rather than throwing (which would wipe the display).
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.tallies = try c.decodeIfPresent([String: ModelTally].self, forKey: .tallies) ?? [:]
            self.monthly = try c.decodeIfPresent([String: [String: ModelTally]].self, forKey: .monthly) ?? [:]
        }
    }

    /// The "yyyy-MM" key for a given instant, in the user's calendar.
    private static func monthKey(for date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM"
        return f.string(from: date)
    }

    private static func cost(of tallies: [String: ModelTally]) -> Double {
        tallies.reduce(0.0) { sum, entry in
            let (model, tally) = entry
            return sum + PriceTable.cost(
                model: model,
                inputTokens: tally.inputTokens,
                outputTokens: tally.outputTokens
            )
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

        // Fold the same usage into the current month's bucket for the spend cap.
        let key = Self.monthKey(for: usage.timestamp)
        var month = state.monthly[key] ?? [:]
        var monthTally = month[usage.model]
            ?? ModelTally(provider: usage.provider, inputTokens: 0, outputTokens: 0)
        monthTally.inputTokens += usage.inputTokens
        monthTally.outputTokens += usage.outputTokens
        month[usage.model] = monthTally
        state.monthly[key] = month

        try JSONFile.write(state, to: fileURL())
    }

    public func monthToDateCostUSD() -> Double {
        guard let state = try? load() else { return 0 }
        return Self.cost(of: state.monthly[Self.monthKey()] ?? [:])
    }

    public func totalCostUSD() -> Double {
        guard let state = try? load() else { return 0 }
        return Self.cost(of: state.tallies)
    }

    public func totalTokens() -> Int {
        guard let state = try? load() else { return 0 }
        return state.tallies.values.reduce(0) { $0 + $1.inputTokens + $1.outputTokens }
    }

    public func reset() throws {
        // Zero the lifetime display totals only; keep the per-month buckets so
        // the spend cap (setting 3.3) is not defeated by a display reset.
        var state = (try? load()) ?? State()
        state.tallies = [:]
        try JSONFile.write(state, to: fileURL())
    }
}
