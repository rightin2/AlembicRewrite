//
//  KeychainStore.swift
//  AlembicRewrite
//
//  Implements: KeychainStoring.
//
//  STORAGE BACKEND: a plain JSON file, not the macOS Keychain.
//
//  Rationale: this app is ad-hoc re-signed on every rebuild. Keychain item ACLs
//  are bound to the signing identity, so after each rebuild macOS treats the app
//  as a different caller and demands the login password on every key read. That
//  makes the Keychain unusable for a personal, frequently-rebuilt tool.
//
//  Instead the keys live in
//    ~/Library/Application Support/AlembicRewrite/credentials.json
//  as a { provider-raw-value: key } map. The file is chmod 0600 and its parent
//  directory 0700, so only the current user account can read it.
//
//  The type name and the KeychainStoring API are unchanged so every caller keeps
//  compiling untouched; only the internals moved from Security items to a file.
//
//  MIGRATION: on first file access we read any keys the OLD Keychain build wrote
//  (service "com.jeanlucalder.AlembicRewrite.apikeys") and fold them into the
//  file, so the user does not have to re-enter keys. That read is wrapped so a
//  Keychain prompt denial fails soft — the key simply needs re-entering in
//  Settings, and we never prompt again.
//

import Foundation
import Security

public final class KeychainStore: KeychainStoring {
    private let overrideDirectory: URL?

    /// Legacy Keychain service string, read once during migration.
    private let legacyService = "com.jeanlucalder.AlembicRewrite.apikeys"
    /// UserDefaults flag so the one-time Keychain -> file migration runs at most
    /// once (a denied Keychain prompt must not re-prompt on every launch).
    private let migrationFlagKey = "AlembicRewrite.keychainToFileMigrated"

    /// - Parameter directory: override the storage directory (tests inject a
    ///   temp dir). `nil` uses the shared Application Support location and enables
    ///   the one-time legacy-Keychain migration.
    public init(directory: URL? = nil) {
        self.overrideDirectory = directory
    }

    // MARK: - KeychainStoring

    public func setKey(_ key: String, for provider: Provider) throws {
        var dict = try readAll()
        dict[provider.rawValue] = key
        try writeAll(dict)
    }

    public func key(for provider: Provider) throws -> String? {
        let value = try readAll()[provider.rawValue]
        return (value?.isEmpty ?? true) ? nil : value
    }

    public func deleteKey(for provider: Provider) throws {
        var dict = try readAll()
        dict.removeValue(forKey: provider.rawValue)
        try writeAll(dict)
    }

    // MARK: - File backing

    private func directory() throws -> URL {
        let dir = try overrideDirectory ?? StorageLocations.defaultDirectory()
        // Tighten the containing directory to owner-only.
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: dir.path
        )
        return dir
    }

    private func fileURL() throws -> URL {
        try directory().appendingPathComponent("credentials.json")
    }

    private func readAll() throws -> [String: String] {
        try migrateFromKeychainIfNeeded()
        return try JSONFile.read([String: String].self, from: fileURL(), fallback: [:])
    }

    private func writeAll(_ dict: [String: String]) throws {
        let url = try fileURL()
        try JSONFile.write(dict, to: url)
        // The atomic write replaces the inode; re-assert owner-only perms.
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: url.path
        )
    }

    // MARK: - One-time migration from the old Keychain items

    private func migrateFromKeychainIfNeeded() throws {
        // Only the real store migrates; tests inject a directory and never touch
        // the shared Keychain or UserDefaults.
        guard overrideDirectory == nil else { return }

        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: migrationFlagKey) else { return }
        // Set the flag first so a denied Keychain prompt fails soft and never
        // re-prompts on a later launch.
        defaults.set(true, forKey: migrationFlagKey)

        let url = try fileURL()
        var dict = try JSONFile.read([String: String].self, from: url, fallback: [:])
        var changed = false
        for provider in Provider.allCases where dict[provider.rawValue] == nil {
            if let legacy = legacyKeychainKey(for: provider), !legacy.isEmpty {
                dict[provider.rawValue] = legacy
                changed = true
            }
        }
        if changed {
            try writeAll(dict)
        }
    }

    /// Reads one key from the legacy Keychain item, returning `nil` on absence
    /// OR on any failure (including a denied authentication prompt), so migration
    /// fails soft.
    private func legacyKeychainKey(for provider: Provider) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: legacyService,
            kSecAttrAccount as String: provider.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8) else {
            return nil
        }
        return key
    }
}

/// Errors from API-key storage. Retained for API compatibility with callers that
/// reference `KeychainError`.
public enum KeychainError: LocalizedError {
    case encodingFailed
    case decodingFailed
    case unhandled(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .encodingFailed:
            return "Could not encode the API key for storage."
        case .decodingFailed:
            return "Stored API key could not be read back."
        case .unhandled(let status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "Unknown error"
            return "Key storage error \(status): \(message)"
        }
    }
}
