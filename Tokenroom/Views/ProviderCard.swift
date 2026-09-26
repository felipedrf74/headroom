import SwiftUI

struct ProviderCard: View {
    var provider: Provider
    var status: ProviderStatus
    /// Last successful check; stale captions use it instead of when the value first appeared.
    var checkedAt: Date?
    /// The primary window's pace.
    var pace: Pace?
    /// Pace for every window, keyed by window ID, for the expanded card.
    var windowPaces: [String: Pace] = [:]
    /// A week of hourly usage per window ID.
    var weeks: [String: UsageHistory] = [:]
    var isExpanded = false
    /// One line per provider when many are connected; a click expands it like the full card.
    var isCompact = false
    var onToggleExpanded: (() -> Void)? = nil
    var signInPhase: SignInCoordinator.Phase = .idle
    var onSignIn: () -> Void = {}
    var onCancelSignIn: () -> Void = {}
    var onInstall: () -> Void = {}

    var body: some View {
        if isCompact, !isExpanded, let snapshot = compactSnapshot {
            compactRow(snapshot)
        } else {
            fullCard
        }
    }

    private var fullCard: some View {
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
                caption(Self.rateLimitedText(provider, until: until))
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

    /// Readings that can collapse to one line: nothing to sign in to.
    private var compactSnapshot: QuotaSnapshot? {
        switch status {
        case .live(let snapshot), .stale(let snapshot), .rateLimited(_, let snapshot?), .unreachable(let snapshot?):
            snapshot
        default:
            nil
        }
    }

    private func compactRow(_ snapshot: QuotaSnapshot) -> some View {
        let stale = status.isStale
        let metered = snapshot.windows.first?.isMetered ?? true
        let value = headlineValue(snapshot) ?? "—"
        let note = Self.compactNote(status, provider: provider, checkedAt: checkedAt)
        return Button {
            onToggleExpanded?()
        } label: {
            HStack(spacing: 8) {
                ProviderIcon(provider: provider, size: 18)
                Text(provider.displayName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(stale ? Color.secondary : Color.primary)
                    .lineLimit(1)
                    .frame(width: 104, alignment: .leading)
                if metered {
                    MeterTrack(
                        usedPercent: snapshot.usedPercent,
                        remaining: snapshot.remainingPercent,
                        isStale: stale,
                        paceMark: pace?.elapsedFraction,
                        height: 6
                    )
                } else {
                    Spacer(minLength: 0)
                }
                if !stale, let pace, pace.verdict == .ahead || pace.verdict == .limitReached {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(paceColor(pace))
                        .help(pace.caption())
                }
                if let note {
                    Image(systemName: note.symbol)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .help(note.text)
                }
                Text(value)
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                    .foregroundStyle(TokenroomTokens.ink(remaining: metered ? snapshot.remainingPercent : 100, isStale: stale))
                    .lineLimit(1)
                    .frame(minWidth: 44, alignment: .trailing)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        )
        .help("Show details")
        .accessibilityLabel("\(provider.displayName), \(value)\(note.map { ", \($0.text)" } ?? "")\(pace.map { ", \($0.caption())" } ?? "")")
        .accessibilityHint("Shows every window and the last 7 days")
    }

    /// What a one-line row says about a reading that isn't current, besides graying it: a symbol
    /// with this text as its tooltip, and the text for VoiceOver.
    static func compactNote(_ status: ProviderStatus, provider: Provider, checkedAt: Date?, now: Date = .now) -> (symbol: String, text: String)? {
        switch status {
        case .rateLimited(let until, .some):
            return ("hourglass", rateLimitedText(provider, until: until))
        case .stale(let snapshot), .unreachable(let snapshot?), .expired(_, let snapshot?):
            return ("clock.arrow.circlepath", lastGoodText(checkedAt ?? snapshot.fetchedAt, now: now))
        default:
            return nil
        }
    }

    static func rateLimitedText(_ provider: Provider, until: Date) -> String {
        "Couldn't refresh. \(provider.displayName) asked to wait until \(until.formatted(date: .omitted, time: .shortened))."
    }

    static func lastGoodText(_ checkedAt: Date?, now: Date = .now) -> String {
        "Last good reading, \(RelativeTime.ago(checkedAt, now: now))."
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
            toggleable {
                header(value: headlineValue(snapshot), remaining: 100, stale: stale)
            }
            caption(primary.title)
            if !stale, let forecast = Forecast.text(for: primary, history: weeks[primary.id], checkedAt: checkedAt ?? snapshot.fetchedAt) {
                caption(forecast)
            }
        } else {
            toggleable {
                VStack(alignment: .leading, spacing: TokenroomTokens.rhythm) {
                    header(percent: snapshot.usedPercent, remaining: snapshot.remainingPercent, stale: stale)
                    MeterTrack(
                        usedPercent: snapshot.usedPercent,
                        remaining: snapshot.remainingPercent,
                        isStale: stale,
                        paceMark: pace?.elapsedFraction
                    )
                }
            }
            caption(primaryCaption(snapshot))
            if !stale, let primary = snapshot.windows.first, let forecast = Forecast.text(for: primary, history: weeks[primary.id], checkedAt: checkedAt ?? snapshot.fetchedAt) {
                caption(forecast)
            }
        }
        if !stale, let pace {
            Text(pace.caption())
                .font(.system(size: TokenroomTokens.captionSize, weight: pace.needsAttention ? .medium : .regular))
                .foregroundStyle(paceColor(pace))
                .fixedSize(horizontal: false, vertical: true)
        }
        if isExpanded {
            expandedDetails(snapshot, stale: stale)
        } else {
            let others = extraWindows(snapshot)
            if !others.isEmpty {
                caption(others.prefix(3).map { windowSummary($0) }.joined(separator: " · "))
            }
            if let banked = snapshot.banked, banked.available > 0 {
                caption(Self.bankedText(banked))
            }
            if let extra = snapshot.extra, let text = Self.extraText(extra) {
                caption(text)
            }
        }
        if let source = Self.sourceCaption(snapshot) {
            caption(source)
        }
        if !isExpanded, let plan = snapshot.planLabel, plan != snapshot.primaryTitle {
            caption(plan)
        }
        if stale {
            caption(Self.lastGoodText(checkedAt ?? snapshot.fetchedAt))
        }
    }

    /// Where a reading came from when it isn't the provider's own usage call. No time: a status
    /// line reading the direct call repeats is confirmed by that call, and "Checked …" says when.
    static func sourceCaption(_ snapshot: QuotaSnapshot) -> String? {
        if snapshot.source == "bridge" {
            return "via Claude Code's status line"
        }
        return LocalKeys.caption(forSource: snapshot.source)
    }

    /// Every window, the week behind the primary one, banked resets, and where the reading came from.
    @ViewBuilder
    private func expandedDetails(_ snapshot: QuotaSnapshot, stale: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let primary = snapshot.windows.first, let resetsAt = primary.resetsAt, resetsAt > .now {
                caption("Resets \(resetsAt.formatted(date: .abbreviated, time: .shortened))")
            }
            if let primary = snapshot.windows.first, primary.isMetered, let week = weeks[primary.id], !week.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Last 7 days")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                    Sparkline(history: week, tint: Color(hex: provider.tintHex))
                        .frame(height: 36)
                }
                // The line itself is hidden from VoiceOver; the group says what it shows.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Usage over the last 7 days")
                .accessibilityValue(Self.weekSummary(week))
            }
            ForEach(extraWindows(snapshot)) { window in
                WindowRow(
                    title: window.title,
                    headline: windowHeadline(window),
                    usedPercent: window.isMetered ? window.usedPercent : nil,
                    isStale: stale,
                    paceMark: windowPaces[window.id]?.elapsedFraction,
                    caption: windowDetail(window, stale: stale),
                    titleFont: .system(size: 11),
                    captionFont: .system(size: 10)
                )
            }
            if let banked = snapshot.banked, banked.available > 0 {
                VStack(alignment: .leading, spacing: 2) {
                    Text(banked.available == 1 ? "1 banked reset" : "\(banked.available) banked resets")
                        .font(.system(size: 11, weight: .medium))
                    Text("Use one in \(provider.toolName) to reset a limit early.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    ForEach(banked.expiries.filter { $0 > .now }.sorted(), id: \.self) { expiry in
                        Text("Expires \(expiry.formatted(date: .abbreviated, time: .shortened))")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if let extra = snapshot.extra, let text = Self.extraText(extra) {
                caption(text)
            }
            if let plan = snapshot.planLabel, plan != snapshot.primaryTitle {
                caption("Plan: \(plan)")
            }
            if let checked = checkedAt {
                caption("Checked \(RelativeTime.ago(checked))")
            }
            if Self.readsUnofficially(provider, snapshot: snapshot) {
                caption("Unofficial: read from the same endpoint \(provider.toolName) uses. It can change without notice.")
            }
        }
        .padding(.top, 2)
    }

    /// Read from the endpoint the provider's own app uses. Copilot read with a pasted token goes
    /// through GitHub's documented billing API instead.
    static func readsUnofficially(_ provider: Provider, snapshot: QuotaSnapshot) -> Bool {
        provider.isUnofficial && snapshot.source != "copilot-token"
    }

    /// What the week's line shows, for VoiceOver: its highest hour and the latest.
    static func weekSummary(_ week: UsageHistory) -> String {
        Sparkline.summary(week)
    }

    /// The header and meter toggle the details when the popover allows it.
    @ViewBuilder
    private func toggleable<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        if let onToggleExpanded {
            Button(action: onToggleExpanded) {
                content()
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "Show less" : "Show details")
            .accessibilityHint(isExpanded ? "Shows less" : "Shows every window and the last 7 days")
        } else {
            content()
        }
    }

    private func header(percent: Double?, remaining: Double, stale: Bool) -> some View {
        header(value: percent.map { "\(QuotaStore.percentText($0))%" }, remaining: remaining, stale: stale)
    }

    /// "$12.40 left" for balances, "$3.10 spent" when only spend is known.
    static func amountHeadline(_ amount: QuotaAmount) -> String? {
        ReadingText.amountHeadline(amount)
    }

    private func headlineValue(_ snapshot: QuotaSnapshot) -> String? {
        guard let primary = snapshot.windows.first else { return nil }
        if !primary.isMetered {
            return primary.amount.flatMap { Self.amountHeadline($0) }
        }
        return "\(QuotaStore.percentText(snapshot.usedPercent))%"
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
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if onToggleExpanded != nil {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .accessibilityHidden(true)
            }
        }
    }

    static func bankedText(_ banked: BankedResets, now: Date = .now) -> String {
        ReadingText.banked(banked, now: now)
    }

    static func extraText(_ extra: ExtraUsage) -> String? {
        ReadingText.extra(extra)
    }

    /// Tight or critical when usage runs ahead; quiet otherwise.
    private func paceColor(_ pace: Pace) -> Color {
        guard pace.needsAttention else { return Color.secondary }
        switch pace.severity {
        case .critical: return TokenroomTokens.critical
        case .tight: return TokenroomTokens.tight
        case .watch, .none: return Color.secondary
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

    /// "Session 18%", or the amount for a window without a meter.
    private func windowSummary(_ window: QuotaWindow) -> String {
        "\(window.title) \(windowHeadline(window))"
    }

    private func windowHeadline(_ window: QuotaWindow) -> String {
        if !window.isMetered, let amount = window.amount, let text = Self.amountHeadline(amount) {
            return text
        }
        return "\(QuotaStore.percentText(window.usedPercent))%"
    }

    /// "resets in 2h 10m · Ahead of pace".
    private func windowDetail(_ window: QuotaWindow, stale: Bool) -> String? {
        var parts: [String] = []
        if let reset = RelativeTime.resets(window.resetsAt) {
            parts.append(reset)
        }
        if !stale, let pace = windowPaces[window.id] {
            parts.append(pace.caption())
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
