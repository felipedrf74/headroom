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
        /// Moonshot's "Global" or "China" platform, or the Copilot plan picked with the token.
        var region: String?
        /// Set when the key's test found something to warn about, e.g. write access.
        var warning: String? = nil
    }

    /// Keychain access group shared with the widget extension on iPhone; nil on the Mac.
    var accessGroup: String? = nil
    /// Tests use their own prefix so they never touch real keys.
    var servicePrefix = "app.tokenroom.key."
    #if os(macOS)
    /// Team-signed Mac builds keep keys in the data-protection keychain, tied to the team and
    /// free of prompts. Ad-hoc builds can't, and use the login keychain; keys saved there move
    /// over the first time a team build reads them.
    var usesDataProtection = KeychainAvailability.dataProtection
    #endif

    func service(for provider: Provider) -> String {
        servicePrefix + provider.rawValue
    }

    func key(for provider: Provider) -> String? {
        if let key = readKey(baseQuery(provider)) {
            return key
        }
        #if os(macOS)
        if usesDataProtection, let legacy = readItem(legacyQuery(provider)) {
            migrate(provider, key: legacy.key, saved: legacy.metadata)
            return legacy.key
        }
        #endif
        return nil
    }

    func metadata(for provider: Provider) -> Metadata? {
        if let metadata = readMetadata(baseQuery(provider)) {
            return metadata
        }
        #if os(macOS)
        if usesDataProtection {
            return readMetadata(legacyQuery(provider))
        }
        #endif
        return nil
    }

    private func readKey(_ base: [String: Any]) -> String? {
        var query = base
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8), !key.isEmpty
        else { return nil }
        return key
    }

    private func readMetadata(_ base: [String: Any]) -> Metadata? {
        var query = base
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let attributes = item as? [String: Any],
              let data = attributes[kSecAttrGeneric as String] as? Data
        else { return nil }
        return try? JSONDecoder().decode(Metadata.self, from: data)
    }

    #if os(macOS)
    /// The same item in the login keychain, where ad-hoc builds and older versions saved it.
    private func legacyQuery(_ provider: Provider) -> [String: Any] {
        var query = baseQuery(provider)
        query.removeValue(forKey: kSecUseDataProtectionKeychain as String)
        return query
    }

    /// The key and its metadata in one read, so both come from the same item even while another
    /// read is moving it.
    private func readItem(_ base: [String: Any]) -> (key: String, metadata: Metadata?)? {
        var query = base
        query[kSecReturnData as String] = true
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let attributes = item as? [String: Any],
              let data = attributes[kSecValueData as String] as? Data,
              let key = String(data: data, encoding: .utf8), !key.isEmpty
        else { return nil }
        let metadata = (attributes[kSecAttrGeneric as String] as? Data).flatMap { try? JSONDecoder().decode(Metadata.self, from: $0) }
        return (key, metadata)
    }

    /// Moves a login-keychain key into the data-protection keychain, keeping its metadata. A
    /// delete with the login-keychain query can match the data-protection copy too (a key saved
    /// and then deleted that way reads back as nothing), so the old item goes first and the new
    /// one is added last; if it can't be, the old one comes back. A read racing this one ends
    /// with an add too, so the key is never left in neither keychain.
    private func migrate(_ provider: Provider, key: String, saved: Metadata?) {
        let metadata = Metadata(last4: String(key.suffix(4)), addedAt: saved?.addedAt ?? .now, region: saved?.region, warning: saved?.warning)
        SecItemDelete(legacyQuery(provider) as CFDictionary)
        let status = (try? add(key, metadata: metadata, to: baseQuery(provider), for: provider)) ?? errSecParam
        guard status == errSecSuccess || status == errSecDuplicateItem else {
            // Back where it was; moved on a later read.
            _ = try? add(key, metadata: metadata, to: legacyQuery(provider), for: provider)
            return
        }
    }
    #endif

    func hasKey(for provider: Provider) -> Bool {
        metadata(for: provider) != nil
    }

    func save(_ key: String, for provider: Provider, region: String? = nil, warning: String? = nil, now: Date = .now) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw KeyError.empty }
        let metadata = Metadata(last4: String(trimmed.suffix(4)), addedAt: now, region: region, warning: warning)
        #if os(macOS)
        if usesDataProtection {
            // A key replaced before it moved over would otherwise stay in the login keychain.
            // Before the add: this query also matches the data-protection copy.
            SecItemDelete(legacyQuery(provider) as CFDictionary)
        }
        #endif
        SecItemDelete(baseQuery(provider) as CFDictionary)
        let status = try add(trimmed, metadata: metadata, to: baseQuery(provider), for: provider)
        guard status == errSecSuccess else { throw KeyError.keychain(status) }
    }

    private func add(_ key: String, metadata: Metadata, to query: [String: Any], for provider: Provider) throws -> OSStatus {
        var attributes = query
        attributes[kSecValueData as String] = Data(key.utf8)
        attributes[kSecAttrGeneric as String] = try JSONEncoder().encode(metadata)
        attributes[kSecAttrLabel as String] = "Tokenroom · \(provider.displayName) key"
        #if !os(macOS)
        // Readable by widgets and background refresh once the phone has been unlocked; stays on this device.
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        #endif
        return SecItemAdd(attributes as CFDictionary, nil)
    }

    func remove(for provider: Provider) throws {
        let status = SecItemDelete(baseQuery(provider) as CFDictionary)
        #if os(macOS)
        if usesDataProtection {
            SecItemDelete(legacyQuery(provider) as CFDictionary)
        }
        #endif
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
        #if os(macOS)
        if usesDataProtection {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        #endif
        return query
    }
}

extension KeySpec {
    /// The choice a key form starts on: the one saved with the current key (its Copilot plan or
    /// Moonshot region), else the first, so replacing a key doesn't quietly change it.
    func initialChoice(saved: APIKeyStore.Metadata?) -> String {
        if let region = saved?.region, regions.contains(region) {
            return region
        }
        return regions.first ?? ""
    }
}

#if os(macOS)
/// Whether this Mac build can use the data-protection keychain: only builds signed with an
/// application identifier (team or Developer ID with a profile) can.
enum KeychainAvailability {
    static let dataProtection: Bool = {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, "com.apple.application-identifier" as CFString, nil)
        else { return false }
        return (value as? String)?.isEmpty == false
    }()
}
#endif
