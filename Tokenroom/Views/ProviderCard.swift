import SwiftUI

struct ProviderCard: View {
    var provider: Provider
    var status: ProviderStatus
    /// Last successful check; stale captions use it instead of when the value first appeared.
    var checkedAt: Date?
    /// Shown only when it matters: ahead of pace or limit reached.
    var pace: Pace?
    var signInPhase: SignInCoordinator.Phase = .idle
    var onSignIn: () -> Void = {}
    var onCancelSignIn: () -> Void = {}
    var onInstall: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: TokenroomTokens.rhythm) {
            switch status {
            case .loading:
                header(percent: nil, remaining: 100, stale: false)
                caption("Refreshing…")
            case .live(let snapshot), .stale(let snapshot):
                snapshotBlock(snapshot, stale: status.isStale)
            case .signedOut(let hint):
                header(percent: nil, remaining: 100, stale: false)
                caption(hint)
                signInControls
            case .expired(let hint, let cached):
                if let cached {
                    snapshotBlock(cached, stale: true)
                } else {
                    header(percent: nil, remaining: 100, stale: false)
                }
                caption(hint)
                signInControls
            case .notEntitled(let hint):
                header(percent: nil, remaining: 100, stale: false)
                caption(hint)
            case .rateLimited(let until, let cached):
                if let cached {
                    snapshotBlock(cached, stale: true)
                } else {
                    header(percent: nil, remaining: 100, stale: false)
                }
                caption("Couldn't refresh. \(provider.displayName) asked to wait until \(until.formatted(date: .omitted, time: .shortened)).")
            case .unreachable(let cached):
                if let cached {
                    snapshotBlock(cached, stale: true)
                } else {
                    header(percent: nil, remaining: 100, stale: false)
                    caption("Couldn't reach \(provider.displayName).")
                    signInControls
                }
            }
        }
        .padding(TokenroomTokens.cardPadding)
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
                    .font(.system(size: TokenroomTokens.captionSize))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button("Cancel", action: onCancelSignIn)
                    .buttonStyle(.plain)
                    .font(.system(size: TokenroomTokens.captionSize, weight: .medium))
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
                    .font(.system(size: TokenroomTokens.captionSize, weight: .medium))
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
        if let primary = snapshot.windows.first, !primary.isMetered {
            // A balance with no limit: the amount is the headline, no meter.
            header(value: primary.amount.flatMap(Self.amountHeadline), remaining: 100, stale: stale)
            caption(primary.title)
        } else {
            header(percent: snapshot.usedPercent, remaining: snapshot.remainingPercent, stale: stale)
            MeterTrack(
                usedPercent: snapshot.usedPercent,
                remaining: snapshot.remainingPercent,
                isStale: stale
            )
            caption(primaryCaption(snapshot))
        }
        if !stale, let pace, pace.verdict == .ahead || pace.verdict == .limitReached {
            Text(pace.caption())
                .font(.system(size: TokenroomTokens.captionSize, weight: .medium))
                .foregroundStyle(paceColor(pace.severity))
                .fixedSize(horizontal: false, vertical: true)
        }
        ForEach(extraWindows(snapshot)) { window in
            caption(windowCaption(window))
        }
        if snapshot.source == "bridge" {
            caption("via Claude Code · \(RelativeTime.ago(snapshot.fetchedAt))")
        } else if let source = LocalKeys.caption(forSource: snapshot.source) {
            caption(source)
        }
        if let banked = snapshot.banked {
            caption(Self.bankedText(banked))
        }
        if let extra = snapshot.extra, let text = Self.extraText(extra) {
            caption(text)
        }
        if let plan = snapshot.planLabel, plan != snapshot.primaryTitle {
            caption(plan)
        }
        if stale {
            caption("Last good reading, \(RelativeTime.ago(checkedAt ?? snapshot.fetchedAt)).")
        }
    }

    private func header(percent: Double?, remaining: Double, stale: Bool) -> some View {
        header(value: percent.map { "\(QuotaStore.percentText($0))%" }, remaining: remaining, stale: stale)
    }

    /// "$12.40 left" for balances, "$3.10 spent" when only spend is known.
    static func amountHeadline(_ amount: QuotaAmount) -> String? {
        if let remaining = amount.remainingOrComputed {
            return AmountFormat.text(remaining, unit: amount.unit)
        }
        return amount.used.map { "\(AmountFormat.text($0, unit: amount.unit)) spent" }
    }

    private func header(value: String?, remaining: Double, stale: Bool) -> some View {
        HStack(alignment: .center, spacing: 10) {
            ProviderIcon(provider: provider, size: 28)
            Text(provider.displayName)
                .font(.system(size: TokenroomTokens.popoverNameSize, weight: .semibold))
                .foregroundStyle(stale ? Color.secondary.opacity(TokenroomTokens.staleOpacity) : Color.primary)
            Spacer(minLength: 8)
            Text(value ?? "—")
                .font(.system(size: TokenroomTokens.popoverPercentSize, weight: .medium).monospacedDigit())
                .foregroundStyle(TokenroomTokens.ink(remaining: remaining, isStale: stale))
        }
    }

    static func bankedText(_ banked: BankedResets, now: Date = .now) -> String {
        let count = banked.available == 1 ? "1 banked reset" : "\(banked.available) banked resets"
        guard let next = banked.nextExpiry(after: now) else { return count }
        return "\(count) · next expires \(next.formatted(.dateTime.month(.abbreviated).day()))"
    }

    static func extraText(_ extra: ExtraUsage) -> String? {
        guard extra.isEnabled, let remaining = extra.amount.remainingOrComputed else { return nil }
        return "\(extra.title) · \(AmountFormat.text(remaining, unit: extra.amount.unit)) left"
    }

    private func paceColor(_ severity: Pace.Severity) -> Color {
        switch severity {
        case .critical: TokenroomTokens.critical
        case .tight: TokenroomTokens.tight
        case .watch, .none: Color.secondary
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: TokenroomTokens.captionSize))
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
        Array(snapshot.windows.dropFirst())
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
