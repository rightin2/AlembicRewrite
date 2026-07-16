//
//  KeychainStore.swift
//  PromptRewriter
//
//  Implements: KeychainStoring (Security framework, generic-password items).
//  One item per provider, keyed by service + account. The account is the
//  provider raw value so the two keys never collide.
//

import Foundation
import Security

public final class KeychainStore: KeychainStoring {
    /// Keychain service string shared by every PromptRewriter API-key item.
    private let service = "com.jeanlucalder.PromptRewriter.apikeys"

    public init() {}

    public func setKey(_ key: String, for provider: Provider) throws {
        let account = provider.rawValue
        guard let data = key.data(using: .utf8) else {
            throw KeychainError.encodingFailed
        }

        // Upsert: try to update an existing item first, add it if absent.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.unhandled(addStatus)
            }
        default:
            throw KeychainError.unhandled(updateStatus)
        }
    }

    public func key(for provider: Provider) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data,
                  let key = String(data: data, encoding: .utf8) else {
                throw KeychainError.decodingFailed
            }
            return key
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unhandled(status)
        }
    }

    public func deleteKey(for provider: Provider) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.rawValue
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unhandled(status)
        }
    }
}

/// Errors from Keychain item access.
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
            return "Keychain error \(status): \(message)"
        }
    }
}
