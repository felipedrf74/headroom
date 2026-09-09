import SwiftUI

struct ProviderCard: View {
    var provider: Provider
    var status: ProviderStatus
    var signInPhase: SignInCoordinator.Phase = .idle
    var onSignIn: () -> Void = {}
    var onCancelSignIn: () -> Void = {}
    var onInstall: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: HeadroomTokens.rhythm) {
            switch status {
            case .loading:
                header(percent: nil, remaining: 100, stale: false)
                caption("Refreshing…")
            case .live(let snapshot), .stale(let snapshot):
                snapshotBlock(snapshot, stale: status.isStale)
            case .signedOut(let hint), .expired(let hint):
                header(percent: nil, remaining: 100, stale: false)
                caption(hint)
                signInControls
            case .unreachable(let cached):
                if let cached {
                    snapshotBlock(cached, stale: true)
                    caption("Last good reading, \(RelativeTime.ago(cached.fetchedAt)).")
                } else {
                    header(percent: nil, remaining: 100, stale: false)
                    caption("Couldn't reach \(provider.displayName).")
                    signInControls
                }
            }
        }
        .padding(HeadroomTokens.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        )
    }

    @ViewBuilder
    private var signInControls: some View {
        if isWorking {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Waiting for \(provider.installToolName)…")
                    .font(.system(size: HeadroomTokens.captionSize))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button("Cancel", action: onCancelSignIn)
                    .buttonStyle(.plain)
                    .font(.system(size: HeadroomTokens.captionSize, weight: .medium))
            }
        } else if let install = installState {
            HStack(spacing: 8) {
                Button("Install \(install.tool)") {
                    onInstall()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Button("Try Again", action: onSignIn)
                    .buttonStyle(.plain)
                    .font(.system(size: HeadroomTokens.captionSize, weight: .medium))
            }
        } else {
            Button(provider.signInTitle, action: onSignIn)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(provider.signInHint)
        }
        if case .failed(let active, let message) = signInPhase, active == provider {
            caption(message)
        }
    }

    private var isWorking: Bool {
        if case .running(let active) = signInPhase {
            return active == provider
        }
        return false
    }

    private var installState: (tool: String, url: URL)? {
        if case .needsInstall(let active, let tool, let url) = signInPhase, active == provider {
            return (tool, url)
        }
        return nil
    }

    @ViewBuilder
    private func snapshotBlock(_ snapshot: QuotaSnapshot, stale: Bool) -> some View {
        header(percent: snapshot.usedPercent, remaining: snapshot.remainingPercent, stale: stale)
        MeterTrack(
            usedPercent: snapshot.usedPercent,
            remaining: snapshot.remainingPercent,
            isStale: stale
        )
        caption(primaryCaption(snapshot))
        ForEach(extraWindows(snapshot)) { window in
            caption(windowCaption(window))
        }
        if stale {
            caption("Last good reading, \(RelativeTime.ago(snapshot.fetchedAt)).")
        }
    }

    private func header(percent: Double?, remaining: Double, stale: Bool) -> some View {
        HStack(alignment: .center, spacing: 10) {
            ProviderIcon(provider: provider, size: 28)
            Text(provider.displayName)
                .font(.system(size: HeadroomTokens.popoverNameSize, weight: .semibold))
                .foregroundStyle(stale ? Color.secondary.opacity(HeadroomTokens.staleOpacity) : Color.primary)
            Spacer(minLength: 8)
            Text(percent.map { "\(QuotaStore.percentText($0))%" } ?? "—")
                .font(.system(size: HeadroomTokens.popoverPercentSize, weight: .medium).monospacedDigit())
                .foregroundStyle(HeadroomTokens.ink(remaining: remaining, isStale: stale))
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: HeadroomTokens.captionSize))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func primaryCaption(_ snapshot: QuotaSnapshot) -> String {
        let reset: String?
        if snapshot.primaryTitle == "This cycle" {
            reset = RelativeTime.cycleDay(snapshot.resetsAt)
        } else {
            reset = RelativeTime.resets(snapshot.resetsAt)
        }
        if let reset {
            return "\(snapshot.primaryTitle) · \(reset)"
        }
        return snapshot.primaryTitle
    }

    private func extraWindows(_ snapshot: QuotaSnapshot) -> [QuotaWindow] {
        Array(snapshot.windows.dropFirst()).filter { $0.id != "plan" || $0.title != snapshot.primaryTitle }
    }

    private func windowCaption(_ window: QuotaWindow) -> String {
        let used = "\(QuotaStore.percentText(window.usedPercent))%"
        if window.kind == .pool, window.resetsAt == nil {
            return window.title
        }
        if window.kind == .session, let reset = RelativeTime.resets(window.resetsAt) {
            let short = reset.replacingOccurrences(of: "resets in ", with: "")
            return "\(window.title) \(used) · \(short)"
        }
        if let reset = RelativeTime.resets(window.resetsAt) {
            return "\(window.title) \(used) · \(reset)"
        }
        return "\(window.title) \(used)"
    }
}
