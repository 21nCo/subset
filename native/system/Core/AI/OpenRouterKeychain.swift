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
        if status == errSecMissingEntitlement {
            return "This build of System cannot store the key: it is kept only in the data protection keychain, which "
                + "keeps it on this Mac, and only a signed build of System can use that keychain. Nothing was stored."
        }
        let text = SecCopyErrorMessageString(status, nil).map { $0 as String } ?? "Unknown error"
        return "The Keychain failed (\(status)): \(text)"
    }
}

/// The user's OpenRouter API key: one generic password, service `dev.subset.system.openrouter`, readable only while
/// this Mac is unlocked and never migrated to another (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`). The key is
/// kept nowhere else: not in user defaults, a file, a log, or the pasteboard. It is stored only in the data protection
/// keychain, which honors that accessibility. The login keychain does not (it drops the attribute and moves with a
/// Migration Assistant or Time Machine restore), so it is never used: a build without the keychain access group the
/// data protection keychain needs gets `errSecMissingEntitlement`, and the key is not stored.
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

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecUseDataProtectionKeychain as String: true
        ]
    }

    /// The key as the user pasted it, without the whitespace around it, when it can be a key: one run of visible ASCII
    /// characters, so it cannot add a line to the header it is sent in.
    public static func normalized(_ key: String) -> String? {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key.count <= keyLimit, key.unicodeScalars.allSatisfy({ (0x21...0x7E).contains($0.value) })
        else { return nil }
        return key
    }

    /// Whether a key is stored, without reading it. A build that cannot use the data protection keychain has none.
    public func containsKey() throws -> Bool {
        var query = query
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        switch items.copyMatching(query).0 {
        case errSecSuccess: return true
        case errSecItemNotFound, errSecMissingEntitlement: return false
        case let status: throw KeychainError(status: status)
        }
    }

    /// The stored key, read for one request's authorization header; `nil` when none is stored.
    public func readKey() throws -> String? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        switch items.copyMatching(query) {
        case (errSecSuccess, let data?):
            guard let text = String(data: data, encoding: .utf8), let key = Self.normalized(text) else {
                throw KeychainError(status: errSecDecode)
            }
            return key
        case (errSecSuccess, nil): throw KeychainError(status: errSecDecode)
        case (errSecItemNotFound, _), (errSecMissingEntitlement, _): return nil
        case let (status, _): throw KeychainError(status: status)
        }
    }

    /// Stores `key`, replacing the one stored, as this-device-only. Throws `errSecMissingEntitlement` (with a message
    /// that says so) when this build cannot use the data protection keychain; nothing is stored anywhere then.
    public func save(_ key: String) throws {
        let attributes: [String: Any] = [
            kSecValueData as String: Data(key.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        var status = items.update(query, attributes)
        if status == errSecItemNotFound {
            var add = query.merging(attributes) { $1 }
            add[kSecAttrLabel as String] = Self.label
            status = items.add(add)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    /// Removes the key.
    public func remove() throws {
        switch items.delete(query) {
        case errSecSuccess, errSecItemNotFound, errSecMissingEntitlement: return
        case let status: throw KeychainError(status: status)
        }
    }
}
