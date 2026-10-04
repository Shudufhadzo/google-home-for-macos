import Foundation
import HomeCore
import LocalAuthentication
import Security

struct HomeBridgeConfiguration: Codable, Equatable {
    let id: UUID
    let url: URL
}

struct HomeSettings: Codable, Equatable {
    var version = 1
    var devices: [SavedHomeDevice] = []
    var annotations: [String: DeviceAnnotation] = [:]
    var bridge: HomeBridgeConfiguration?
}

protocol HomeSettingsPersisting {
    func load() throws -> HomeSettings
    func save(_ settings: HomeSettings) throws
}

struct HomeSettingsStore: HomeSettingsPersisting {
    let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    func load() throws -> HomeSettings {
        guard let data = defaults.data(forKey: "home-management.settings.v1") else { return HomeSettings() }
        return try JSONDecoder().decode(HomeSettings.self, from: data)
    }
    func save(_ settings: HomeSettings) throws {
        defaults.set(try JSONEncoder().encode(settings), forKey: "home-management.settings.v1")
    }
}

protocol HomeCredentialStoring: Sendable {
    func read(account: String) throws -> String?
    func save(_ token: String, account: String) throws
    func remove(account: String) throws
}

/// Serializes potentially blocking Security framework calls away from the UI executor.
actor HomeCredentialWorker {
    private let store: any HomeCredentialStoring
    init(_ store: any HomeCredentialStoring) { self.store = store }
    func read(account: String) throws -> String? { try store.read(account: account) }
    func save(_ token: String, account: String) throws { try store.save(token, account: account) }
    func remove(account: String) throws { try store.remove(account: account) }
}

/// Home Assistant tokens are kept in the login Keychain, never in preferences or logs.
struct HomeCredentialStore: HomeCredentialStoring {
    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "za.shudu.homespeaker.home-assistant",
         kSecAttrAccount as String: account]
    }
    func read(account: String) throws -> String? {
        try withoutInteraction { try readItem(account: account) }
    }
    private func readItem(account: String) throws -> String? {
        var query = query(account)
        // The authentication context covers the data-protection implementation;
        // withoutInteraction also handles the login Keychain used by desktop builds.
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw CredentialError(status: status)
        }
        return value
    }
    func save(_ token: String, account: String) throws {
        try withoutInteraction { try saveItem(token, account: account) }
    }
    private func saveItem(_ token: String, account: String) throws {
        let key = query(account)
        let changes: [String: Any] = [kSecValueData as String: Data(token.utf8)]
        var status = SecItemUpdate(key as CFDictionary, changes as CFDictionary)
        if status == errSecItemNotFound {
            var item = key
            item[kSecValueData as String] = Data(token.utf8)
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw CredentialError(status: status) }
    }
    func remove(account: String) throws {
        try withoutInteraction { try removeItem(account: account) }
    }
    private func removeItem(account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CredentialError(status: status) }
    }
    private func withoutInteraction<T>(_ operation: () throws -> T) throws -> T {
        // SecItem's modern LAContext flag does not suppress legacy login-Keychain
        // approval dialogs. This compatibility API declines optional interaction
        // in this process only; it never changes item permissions or unlocks a vault.
        // HomeCredentialWorker serializes these calls and the prior flag is restored.
        var allowed: DarwinBoolean = true
        let previous = SecKeychainGetUserInteractionAllowed(&allowed)
        guard previous == errSecSuccess else { throw CredentialError(status: previous) }
        let status = SecKeychainSetUserInteractionAllowed(false)
        guard status == errSecSuccess else { throw CredentialError(status: status) }
        defer { SecKeychainSetUserInteractionAllowed(allowed.boolValue) }
        return try operation()
    }
    private struct CredentialError: LocalizedError {
        let status: OSStatus
        var errorDescription: String? { "Keychain access failed (\(status)). Unlock the login Keychain or reconnect Home Assistant." }
    }
}
