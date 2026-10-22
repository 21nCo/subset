import Foundation
import Security

/// The Keychain calls the key store makes, as `SecItem` takes them, so tests run against a double.
public protocol KeychainItems: Sendable {
    func add(_ attributes: [String: Any]) -> OSStatus
    /// The status and the matched item's data when the query asks for it.
    func copyMatching(_ query: [String: Any]) -> (OSStatus, Data?)
    func update(_ query: [String: Any], _ attributes: [String: Any]) -> OSStatus
    func delete(_ query: [String: Any]) -> OSStatus
}

/// The Keychain through `SecItem`.
public struct SystemKeychain: KeychainItems {
    public init() {}

    public func add(_ attributes: [String: Any]) -> OSStatus {
        SecItemAdd(attributes as CFDictionary, nil)
    }

    public func copyMatching(_ query: [String: Any]) -> (OSStatus, Data?) {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result as? Data)
    }

    public func update(_ query: [String: Any], _ attributes: [String: Any]) -> OSStatus {
        SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    }

    public func delete(_ query: [String: Any]) -> OSStatus {
        SecItemDelete(query as CFDictionary)
    }
}

public struct KeychainError: Error, Equatable, Sendable {
    public let status: OSStatus

    public var message: String {
        let text = SecCopyErrorMessageString(status, nil).map { $0 as String } ?? "Unknown error"
        return "The Keychain failed (\(status)): \(text)"
    }
}

/// The user's OpenRouter API key: one generic password, service `dev.subset.system.openrouter`, readable only while
/// this Mac is unlocked and never migrated to another (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`). The key is
/// kept nowhere else: not in user defaults, a file, a log, or the pasteboard. It is stored in the data protection
/// keychain, which honors that accessibility; a build without the entitlement that keychain needs (System has none)
/// stores it in the login keychain on this Mac instead, which keeps it on this Mac but does not apply the attribute.
public struct OpenRouterKeyStore: Sendable {
    public static let service = "dev.subset.system.openrouter"
    static let account = "api-key"
    static let label = "Subset System OpenRouter API key"
    /// The longest key accepted; OpenRouter's keys are about 70 characters.
    static let keyLimit = 512

    private let items: any KeychainItems

    public init(items: any KeychainItems = SystemKeychain()) {
        self.items = items
    }

    /// The keychains tried, in order: the data protection keychain, then the login keychain when the build lacks the
    /// entitlement for the first.
    private enum Keychain: CaseIterable {
        case dataProtection, login
    }

    private func query(_ keychain: Keychain) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account
        ]
        if keychain == .dataProtection { query[kSecUseDataProtectionKeychain as String] = true }
        return query
    }

    /// The key as the user pasted it, without the whitespace around it, when it can be a key: one run of visible ASCII
    /// characters, so it cannot add a line to the header it is sent in.
    public static func normalized(_ key: String) -> String? {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key.count <= keyLimit, key.unicodeScalars.allSatisfy({ (0x21...0x7E).contains($0.value) })
        else { return nil }
        return key
    }

    /// Whether a key is stored, without reading it.
    public func containsKey() throws -> Bool {
        for keychain in Keychain.allCases {
            var query = query(keychain)
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            switch items.copyMatching(query).0 {
            case errSecSuccess: return true
            case errSecItemNotFound, errSecMissingEntitlement: continue
            case let status: throw KeychainError(status: status)
            }
        }
        return false
    }

    /// The stored key, read for one request's authorization header; `nil` when none is stored.
    public func readKey() throws -> String? {
        for keychain in Keychain.allCases {
            var query = query(keychain)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            switch items.copyMatching(query) {
            case (errSecSuccess, let data?):
                guard let text = String(data: data, encoding: .utf8), let key = Self.normalized(text) else {
                    throw KeychainError(status: errSecDecode)
                }
                return key
            case (errSecSuccess, nil): throw KeychainError(status: errSecDecode)
            case (errSecItemNotFound, _), (errSecMissingEntitlement, _): continue
            case let (status, _): throw KeychainError(status: status)
            }
        }
        return nil
    }

    /// Stores `key`, replacing the one stored, as this-device-only; the copy in the other keychain, if any, is removed.
    public func save(_ key: String) throws {
        let attributes: [String: Any] = [
            kSecValueData as String: Data(key.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        for keychain in Keychain.allCases {
            var status = items.update(query(keychain), attributes)
            if status == errSecItemNotFound {
                var add = query(keychain).merging(attributes) { $1 }
                add[kSecAttrLabel as String] = Self.label
                status = items.add(add)
            }
            switch status {
            case errSecSuccess:
                for other in Keychain.allCases where other != keychain { try delete(from: other) }
                return
            case errSecMissingEntitlement: continue
            default: throw KeychainError(status: status)
            }
        }
        throw KeychainError(status: errSecMissingEntitlement)
    }

    /// Removes the key from both keychains.
    public func remove() throws {
        for keychain in Keychain.allCases { try delete(from: keychain) }
    }

    private func delete(from keychain: Keychain) throws {
        switch items.delete(query(keychain)) {
        case errSecSuccess, errSecItemNotFound, errSecMissingEntitlement: return
        case let status: throw KeychainError(status: status)
        }
    }
}
