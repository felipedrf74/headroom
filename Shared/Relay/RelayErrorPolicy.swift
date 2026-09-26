import CloudKit
import Foundation

/// What an iCloud failure means for the next try. The Mac's publisher and the iPhone share it, so
/// both back off, pause, and explain failures the same way.
enum RelayErrorPolicy {
    enum Outcome: Equatable {
        /// No iCloud account on this device.
        case noAccount
        /// Needs the user: iCloud is full, or Tokenroom's data was deleted elsewhere.
        case paused(String)
        /// Temporary: try again after this many seconds.
        case retry(after: TimeInterval, message: String)
        /// This build can't use the container (missing entitlement).
        case unavailable
        /// The call was cancelled, e.g. for a newer refresh: nothing to report or wait for.
        case cancelled
        case failed(String)

        /// Whether other saves in the same batch are worth trying.
        var stopsBatch: Bool {
            switch self {
            case .failed: false
            case .noAccount, .paused, .retry, .unavailable, .cancelled: true
            }
        }
    }

    static func outcome(for error: Error, defaultRetry: TimeInterval) -> Outcome {
        if error is CancellationError || (error as? CKError)?.code == .operationCancelled {
            return .cancelled
        }
        guard let error = error as? CKError else {
            return .failed("Couldn't reach iCloud.")
        }
        switch error.code {
        case .notAuthenticated:
            return .noAccount
        case .userDeletedZone:
            // Deleted in iCloud settings. CloudKit asks apps not to re-create it on their own,
            // so it starts again when the user turns the Mac's sync back on.
            #if os(macOS)
            return .paused("Tokenroom's iCloud data was deleted. To start again, turn Send readings to iCloud off and on in Settings › iPhone & Watch.")
            #else
            return .paused("Tokenroom's iCloud data was deleted. To start again, turn Send readings to iCloud off and on in Tokenroom on your Mac, or choose Delete Tokenroom Data from iCloud in Settings here.")
            #endif
        case .quotaExceeded:
            return .paused("Couldn't save: iCloud storage is full.")
        case .requestRateLimited, .zoneBusy, .serviceUnavailable, .networkUnavailable, .networkFailure:
            return .retry(after: error.retryAfterSeconds ?? defaultRetry, message: "Couldn't reach iCloud. Trying again soon.")
        case .badContainer:
            // A newly created container takes a while to reach every CloudKit server.
            return .retry(after: max(error.retryAfterSeconds ?? 0, defaultRetry), message: "Couldn't reach Tokenroom's iCloud container yet. Trying again soon.")
        case .missingEntitlement, .permissionFailure:
            return .unavailable
        default:
            return .failed("Couldn't reach iCloud.")
        }
    }
}
