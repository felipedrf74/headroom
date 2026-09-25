import Foundation

/// Where the iPhone app and its widgets share readings and API keys. Nil on the Mac, and in builds
/// that don't carry the App Group (tests, unsigned builds), which then keep everything to themselves.
enum AppGroup {
    static var identifier: String? {
        configured("TokenroomAppGroup")
    }

    /// `TEAMID.app.tokenroom.shared`: the Keychain group for API keys widgets can read too.
    static var keychainGroup: String? {
        guard let group = configured("TokenroomKeychainGroup"),
              group.split(separator: ".").first?.count == 10
        else { return nil }
        return group
    }

    static var containerURL: URL? {
        identifier.flatMap { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) }
    }

    /// An Info.plist value that the build filled in.
    private static func configured(_ key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !value.isEmpty, !value.contains("$(")
        else { return nil }
        return value
    }
}
