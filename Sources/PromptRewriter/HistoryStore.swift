//
//  HistoryStore.swift
//  PromptRewriter
//
//  Implements: HistoryStoring (JSON-file-backed — see storage decision in
//  Protocols.swift). Persists to
//  ~/Library/Application Support/PromptRewriter/history.json
//  Caps at the most recent 200 entries.
//

import Foundation

public final class HistoryStore: HistoryStoring {
    /// Retention cap: keep at most this many most-recent entries.
    public static let cap = 200

    private let overrideDirectory: URL?

    /// - Parameter directory: override the storage directory (tests inject a
    ///   temp dir). `nil` uses the shared Application Support location.
    public init(directory: URL? = nil) {
        self.overrideDirectory = directory
    }

    private func fileURL() throws -> URL {
        let dir = try overrideDirectory ?? StorageLocations.defaultDirectory()
        return dir.appendingPathComponent("history.json")
    }

    /// Most-recent-first.
    public func recent() throws -> [HistoryEntry] {
        let entries = try JSONFile.read([HistoryEntry].self, from: fileURL(), fallback: [])
        return entries.sorted { $0.timestamp > $1.timestamp }
    }

    public func add(_ entry: HistoryEntry) throws {
        var entries = try recent()
        entries.insert(entry, at: 0)
        if entries.count > Self.cap {
            entries = Array(entries.prefix(Self.cap))
        }
        try JSONFile.write(entries, to: fileURL())
    }

    public func clear() throws {
        try JSONFile.write([HistoryEntry](), to: fileURL())
    }
}
