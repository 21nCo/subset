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

/// One generic-password item, never synchronized and asked for as `WhenUnlockedThisDeviceOnly`. The value lives only in
/// the Keychain and in memory while a request is built; it is never written to a file, a log, the database, or the app's
/// defaults.
///
/// The item goes in the data protection keychain when the build has the entitlement that keychain needs, which takes a
/// provisioning profile. Current builds, Developer ID releases included, do not have it: they get
/// `errSecMissingEntitlement` there and use the login keychain, which does not enforce this-device-only, so the item
/// moves with Migration Assistant and keychain backups (accepted for SET-20; enforced this-device-only storage is
/// SET-118). A read looks in the login keychain too, a save to the data protection keychain removes a login-keychain
/// copy, and a delete removes both, so a key saved by either kind of build is found, replaced, and removed.
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
        for query in [dataProtection, login] {
            let (status, value) = api.copyMatching(query.merging([kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]) { $1 })
            if status == errSecItemNotFound || status == errSecMissingEntitlement { continue }
            guard status == errSecSuccess, let data = value as? Data else { throw KeychainError(status: status) }
            return String(data: data, encoding: .utf8)
        }
        return nil
    }

    public func save(_ value: String) throws {
        let data = Data(value.utf8)
        let protection: [String: Any] = [kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                                         kSecAttrSynchronizable as String: false]
        func store(_ query: [String: Any]) -> OSStatus {
            let updated = api.update(query, protection.merging([kSecValueData as String: data]) { $1 })
            guard updated == errSecItemNotFound else { return updated }
            return api.add(query.merging(protection) { $1 }.merging([kSecValueData as String: data]) { $1 })
        }
        var status = store(dataProtection)
        if status == errSecMissingEntitlement {
            status = store(login)
        } else if status == errSecSuccess {
            // A copy an unentitled build left in the login keychain would otherwise outlive this one.
            _ = api.delete(login)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    public func delete() throws {
        for (query, absent) in [(dataProtection, [errSecItemNotFound, errSecMissingEntitlement]), (login, [errSecItemNotFound])] {
            let status = api.delete(query)
            guard status == errSecSuccess || absent.contains(status) else { throw KeychainError(status: status) }
        }
    }

    private var login: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    private var dataProtection: [String: Any] {
        login.merging([kSecUseDataProtectionKeychain as String: true]) { $1 }
    }
}
