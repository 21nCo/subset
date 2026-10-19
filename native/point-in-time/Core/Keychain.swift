import Foundation
import Security

/// The Security calls `KeychainSecret` makes; tests replace them with a double.
public protocol KeychainAPI: Sendable {
    func add(_ attributes: [String: Any]) -> OSStatus
    func copyMatching(_ query: [String: Any]) -> (OSStatus, AnyObject?)
    func update(_ query: [String: Any], _ attributes: [String: Any]) -> OSStatus
    func delete(_ query: [String: Any]) -> OSStatus
}

public struct SystemKeychain: KeychainAPI {
    public init() {}
    public func add(_ attributes: [String: Any]) -> OSStatus { SecItemAdd(attributes as CFDictionary, nil) }
    public func copyMatching(_ query: [String: Any]) -> (OSStatus, AnyObject?) {
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result)
    }
    public func update(_ query: [String: Any], _ attributes: [String: Any]) -> OSStatus {
        SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    }
    public func delete(_ query: [String: Any]) -> OSStatus { SecItemDelete(query as CFDictionary) }
}

public struct KeychainError: Error, Equatable, CustomStringConvertible {
    public let status: OSStatus
    public var description: String { "Keychain error \(status)" }
}

/// One generic-password item that only this Mac can read (`WhenUnlockedThisDeviceOnly`, never synchronized). The value
/// lives only in the Keychain and in memory while a request is built; it is never written to a file, a log, the database,
/// or the app's defaults.
///
/// The item goes in the data protection keychain. A build without the entitlement that keychain needs (an ad hoc signed
/// local build) gets `errSecMissingEntitlement` there and uses the login keychain instead, which stays on this Mac.
public struct KeychainSecret: Sendable {
    public static let openRouterKey = KeychainSecret(service: "dev.subset.point-in-time.openrouter", account: "api-key")

    public let service: String
    public let account: String
    private let api: any KeychainAPI

    public init(service: String, account: String, api: any KeychainAPI = SystemKeychain()) {
        self.service = service
        self.account = account
        self.api = api
    }

    public func read() throws -> String? {
        var result: AnyObject?
        let status = attempt { query in
            let (status, value) = api.copyMatching(query.merging([kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]) { $1 })
            result = value
            return status
        }
        guard status != errSecItemNotFound else { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw KeychainError(status: status) }
        return String(data: data, encoding: .utf8)
    }

    public func save(_ value: String) throws {
        let data = Data(value.utf8)
        let protection: [String: Any] = [kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                                         kSecAttrSynchronizable as String: false]
        let status = attempt { query in
            let updated = api.update(query, protection.merging([kSecValueData as String: data]) { $1 })
            guard updated == errSecItemNotFound else { return updated }
            return api.add(query.merging(protection) { $1 }.merging([kSecValueData as String: data]) { $1 })
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    public func delete() throws {
        let status = attempt { api.delete($0) }
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }

    /// Runs `body` against the data protection keychain, and against the login keychain when this build lacks the
    /// entitlement for the former.
    private func attempt(_ body: ([String: Any]) -> OSStatus) -> OSStatus {
        let item: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: account]
        let status = body(item.merging([kSecUseDataProtectionKeychain as String: true]) { $1 })
        return status == errSecMissingEntitlement ? body(item) : status
    }
}
