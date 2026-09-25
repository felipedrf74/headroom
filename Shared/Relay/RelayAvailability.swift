import Foundation
#if os(macOS)
import Security
#endif

/// The iCloud container this build may use, or nil when it isn't signed for iCloud.
/// Creating a `CKContainer` without the entitlement crashes, so check this first.
enum RelayAvailability {
    static let containerIdentifier: String? = {
        #if os(macOS)
        // Ad-hoc builds can't carry iCloud entitlements; read what this binary was signed with.
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(
                task,
                "com.apple.developer.icloud-container-identifiers" as CFString,
                nil
              ),
              let containers = value as? [String]
        else { return nil }
        return containers.first
        #else
        // Set from Config/*.xcconfig; empty in builds without a team.
        // An unfilled `$(…)` means the build had no team: sample data only.
        guard let identifier = Bundle.main.object(forInfoDictionaryKey: "TokenroomCloudContainer") as? String,
              !identifier.isEmpty, !identifier.hasPrefix("$(")
        else { return nil }
        return identifier
        #endif
    }()

    static var isAvailable: Bool {
        containerIdentifier != nil
    }
}
