import AppKit
import SwiftUI

struct PopoverView: View {
    @Bindable var store: QuotaStore
    var onSettings: () -> Void
    var onNews: (NewsSection) -> Void
    @State private var showsDisconnected = false
    @State private var expanded: Set<Provider>

    init(store: QuotaStore, onSettings: @escaping () -> Void, onNews: @escaping (NewsSection) -> Void = { _ in }, expanded: Set<Provider> = []) {
        self.store = store
        self.onSettings = onSettings
        self.onNews = onNews
        _expanded = State(initialValue: expanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, TokenroomTokens.cardPadding)
                .padding(.top, 14)
                .padding(.bottom, 12)

            if store.showsLegacyNotice {
                legacyNotice
                    .padding(.horizontal, TokenroomTokens.cardPadding)
                    .padding(.bottom, TokenroomTokens.cardGap)
            }

            let providers = store.popoverProviders
            if providers.isEmpty {
                emptyProviders
                    .padding(.horizontal, TokenroomTokens.cardPadding)
                    .padding(.bottom, 8)
            } else {
                ViewThatFits(in: .vertical) {
                    providerList
                    ScrollView {
                        providerList
                    }
                }
                .frame(maxHeight: 520)
            }

            highlights
                .padding(.horizontal, TokenroomTokens.cardPadding)
                .padding(.top, 10)

            Divider()
                .padding(.top, 10)
                .opacity(0.7)

            footer
                .padding(.horizontal, TokenroomTokens.cardPadding)
                .padding(.vertical, 10)
        }
        .frame(width: TokenroomTokens.popoverWidth)
        .transaction { $0.animation = nil }
    }

    private var providerList: some View {
        VStack(spacing: TokenroomTokens.cardGap) {
            cards(store.connectedProviders)
            let disconnected = store.disconnectedProviders
            if !disconnected.isEmpty {
                Button {
                    showsDisconnected.toggle()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: showsDisconnected ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Not connected (\(disconnected.count))")
                        Spacer()
                    }
                    .font(.system(size: TokenroomTokens.captionSize, weight: .medium))
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, TokenroomTokens.cardPadding)
                .accessibilityLabel("Not connected, \(disconnected.count) providers")
                if showsDisconnected {
                    cards(disconnected)
                }
            }
        }
    }

    /// More than five connected providers: one line each until clicked.
    private var isCompact: Bool {
        store.connectedProviders.count > 5
    }

    private func cards(_ providers: [Provider]) -> some View {
        VStack(spacing: isCompact ? 6 : TokenroomTokens.cardGap) {
            ForEach(providers, id: \.self) { provider in
                let isExpanded = expanded.contains(provider)
                ProviderCard(
                    provider: provider,
                    status: store.statuses[provider] ?? .loading,
                    checkedAt: store.lastChecked(provider),
                    pace: store.pace(for: provider),
                    windowPaces: isExpanded ? store.windowPaces(for: provider) : [:],
                    weeks: store.weeks(for: provider),
                    isExpanded: isExpanded,
                    isCompact: isCompact,
                    onToggleExpanded: { toggle(provider) },
                    signInPhase: store.signIn.phase,
                    onSignIn: { store.signIn.signIn(provider) },
                    onCancelSignIn: { store.signIn.cancel() },
                    onInstall: { store.signIn.openInstallPage(provider) }
                )
            }
        }
        .padding(.horizontal, TokenroomTokens.cardPadding)
    }

    private func toggle(_ provider: Provider) {
        if expanded.contains(provider) {
            expanded.remove(provider)
        } else {
            expanded.insert(provider)
        }
    }

    /// Banked resets and news at a glance: "2 banked resets · 3 new models · 5 updates".
    @ViewBuilder
    private var highlights: some View {
        let banked = store.bankedResets
        let news = store.settings.newsEnabled ? store.news : nil
        let models = news?.unseenModelCount ?? 0
        let updates = news?.unseenAnnouncementCount ?? 0
        if banked.count > 0 || models > 0 || updates > 0 {
            // Full labels when they fit, shorter ones when all three show.
            ViewThatFits(in: .horizontal) {
                highlightPills(banked: banked, models: models, updates: updates, short: false)
                highlightPills(banked: banked, models: models, updates: updates, short: true)
            }
        }
    }

    private func highlightPills(banked: (count: Int, providers: [Provider]), models: Int, updates: Int, short: Bool) -> some View {
        HStack(spacing: 6) {
            if banked.count > 0 {
                HighlightPill(
                    title: short ? "\(banked.count) banked" : (banked.count == 1 ? "1 banked reset" : "\(banked.count) banked resets"),
                    systemImage: "arrow.counterclockwise"
                ) {
                    expanded.formUnion(banked.providers)
                }
                .help("Resets you can use when a limit runs out")
            }
            if models > 0 {
                HighlightPill(title: short ? "\(models) model\(models == 1 ? "" : "s")" : (models == 1 ? "1 new model" : "\(models) new models"), systemImage: "sparkles") {
                    onNews(.models)
                }
                .help("New models from the labs you follow")
            }
            if updates > 0 {
                HighlightPill(title: updates == 1 ? "1 update" : "\(updates) updates", systemImage: "megaphone") {
                    onNews(.announcements)
                }
                .help("Changelogs and announcements")
            }
            Spacer(minLength: 0)
        }
        .fixedSize(horizontal: !short, vertical: false)
    }

    private var legacyNotice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tokenroom replaces Headroom")
                .font(.system(size: TokenroomTokens.popoverNameSize, weight: .semibold))
            Text("Quit Headroom, remove it from Login Items in System Settings › General, and move it to the Trash so only one extra runs.")
                .font(.system(size: TokenroomTokens.captionSize))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            // Headroom's own login item can't be read or carried over; this takes its place.
            Toggle("Launch Tokenroom at login", isOn: $store.settings.launchAtLogin)
                .toggleStyle(.checkbox)
                .font(.system(size: TokenroomTokens.captionSize))
            HStack(spacing: 12) {
                if LegacyMigration.isLegacyAppRunning {
                    Button("Quit Headroom") {
                        store.quitLegacyApp()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                if let url = LegacyMigration.legacyAppURL {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: TokenroomTokens.captionSize, weight: .medium))
                }
                Button("Dismiss") {
                    store.dismissLegacyNotice()
                }
                .buttonStyle(.plain)
                .font(.system(size: TokenroomTokens.captionSize, weight: .medium))
            }
        }
        .padding(TokenroomTokens.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        )
    }

    private var emptyProviders: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No providers on")
                .font(.system(size: TokenroomTokens.popoverNameSize, weight: .semibold))
            Text("Turn on the tools you use in Settings, such as Claude, Codex, Cursor, or Copilot, then sign in to see usage.")
                .font(.system(size: TokenroomTokens.captionSize))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(TokenroomTokens.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        )
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Tokenroom")
                    .font(.system(size: 15, weight: .semibold))
                Text(store.isRefreshing ? "Updating…" : "Updated \(RelativeTime.ago(store.lastAttempt))")
                    .font(.system(size: TokenroomTokens.captionSize))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button {
                Task { await store.refresh(force: true) }
            } label: {
                if store.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 28, height: 28)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
            }
            .buttonStyle(.plain)
            .disabled(store.isRefreshing)
            .help("Refresh")
            .accessibilityLabel("Refresh")
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button("Settings") {
                onSettings()
            }
            .buttonStyle(.plain)
            Button("News") {
                onNews(.models)
            }
            .buttonStyle(.plain)
            Spacer()
            Button("Quit Tokenroom") {
                NSApp.terminate(nil)
            }
            .buttonStyle(.plain)
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.secondary)
        .frame(minHeight: 22)
    }
}

/// A small action in the popover's footer strip.
private struct HighlightPill: View {
    var title: String
    var systemImage: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.primary.opacity(0.07)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
