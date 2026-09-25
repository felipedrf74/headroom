import Foundation
import Security

/// API keys the user pasted, one Keychain item per provider on this device.
/// Never synchronized through iCloud Keychain and never sent to another device.
/// Reads can block (a Keychain prompt on the Mac): call through `BlockingIO`.
struct APIKeyStore: Sendable {
    enum KeyError: Error, Equatable {
        case empty
        case keychain(OSStatus)
    }

    /// Kept next to the key; not secret. The key itself is only ever shown as `•••• last4`.
    struct Metadata: Codable, Equatable, Sendable {
        var last4: String
        var addedAt: Date
        /// Moonshot's "Global" or "China" platform.
        var region: String?
    }

    /// Keychain access group shared with the widget extension on iPhone; nil on the Mac.
    var accessGroup: String? = nil
    /// Tests use their own prefix so they never touch real keys.
    var servicePrefix = "app.tokenroom.key."

    func service(for provider: Provider) -> String {
        servicePrefix + provider.rawValue
    }

    func key(for provider: Provider) -> String? {
        var query = baseQuery(provider)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8), !key.isEmpty
        else { return nil }
        return key
    }

    func metadata(for provider: Provider) -> Metadata? {
        var query = baseQuery(provider)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let attributes = item as? [String: Any],
              let data = attributes[kSecAttrGeneric as String] as? Data
        else { return nil }
        return try? JSONDecoder().decode(Metadata.self, from: data)
    }

    func hasKey(for provider: Provider) -> Bool {
        metadata(for: provider) != nil
    }

    func save(_ key: String, for provider: Provider, region: String? = nil, now: Date = .now) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw KeyError.empty }
        let metadata = Metadata(last4: String(trimmed.suffix(4)), addedAt: now, region: region)
        try? remove(for: provider)

        var attributes = baseQuery(provider)
        attributes[kSecValueData as String] = Data(trimmed.utf8)
        attributes[kSecAttrGeneric as String] = try JSONEncoder().encode(metadata)
        attributes[kSecAttrLabel as String] = "Tokenroom · \(provider.displayName) key"
        #if !os(macOS)
        // Readable by widgets and background refresh once the phone has been unlocked; stays on this device.
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        #endif
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeyError.keychain(status) }
    }

    func remove(for provider: Provider) throws {
        let status = SecItemDelete(baseQuery(provider) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeyError.keychain(status) }
    }

    private func baseQuery(_ provider: Provider) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service(for: provider),
            kSecAttrAccount as String: "default",
            kSecAttrSynchronizable as String: false,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }
}
