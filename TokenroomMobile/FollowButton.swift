import SwiftUI

/// Starts or stops the Live Activity for a provider's window that resets soon: a countdown on
/// the Lock Screen and in the Dynamic Island. Hidden when nothing resets within 8 hours.
struct FollowButton: View {
    var provider: RelayProvider
    /// Reports why following failed, for a caption next to the button.
    var onError: (String?) -> Void = { _ in }
    @State private var isFollowing = false

    var body: some View {
        if let window = LiveActivities.candidate(in: provider) {
            Button {
                toggle(window)
            } label: {
                Label(isFollowing ? "Stop Following" : "Follow on Lock Screen", systemImage: isFollowing ? "xmark.circle" : "timer")
            }
            .onAppear {
                isFollowing = LiveActivities.activity(for: provider.id) != nil
            }
            .accessibilityHint(isFollowing ? "Removes the countdown from the Lock Screen" : "Shows a countdown to the \(window.title.lowercased()) reset on the Lock Screen and in the Dynamic Island")
        }
    }

    private func toggle(_ window: RelayWindow) {
        if isFollowing {
            Task {
                await LiveActivities.stop(provider.id)
                isFollowing = false
            }
            return
        }
        guard LiveActivities.isEnabled else {
            onError("Live Activities are off for Tokenroom. Turn them on in Settings › Tokenroom.")
            return
        }
        do {
            isFollowing = try LiveActivities.start(provider, window: window)
            onError(nil)
        } catch {
            onError("Couldn't start the Live Activity.")
        }
    }
}
