import SwiftUI
import UserNotifications

struct UsageView: View {
    @Bindable var store: MobileStore
    var news: NewsStore
    @Binding var path: [String]
    var openNews: (NewsView.NewsSection) -> Void = { _ in }
    var openAlerts: () -> Void = {}
    @State private var showsDisconnected = false
    @State private var notificationsOff = false
    /// Why following a row's window failed, from its swipe action or menu.
    @State private var followError: String?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if store.sampleMode {
                    Section {
                        SampleBanner(store: store)
                    }
                }
                if let hero {
                    Section {
                        UsageHeroCard(reading: hero)
                            .contentShape(Rectangle())
                            .onTapGesture { path = [hero.id] }
                    } header: {
                        Text("Next up")
                    }
                }
                if !highlights.isEmpty {
                    Section {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(highlights) { highlight in
                                    Button(action: highlight.action) {
                                        Label(highlight.title, systemImage: highlight.symbol)
                                            .font(.subheadline.weight(.medium))
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 8)
                                            .background(Capsule().fill(Color(.secondarySystemGroupedBackground)))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 20)
                        }
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                    }
                    .listSectionSpacing(8)
                }
                if !store.readings.isEmpty {
                    Section {
                        ForEach(store.readings) { reading in
                            NavigationLink(value: reading.id) {
                                ReadingRow(reading: reading)
                            }
                            .swipeActions(edge: .leading) {
                                if let window = LiveActivities.candidate(in: reading.provider) {
                                    Button("Follow", systemImage: "timer") {
                                        follow(reading.provider, window: window)
                                    }
                                    .tint(.orange)
                                }
                            }
                            .contextMenu {
                                FollowButton(provider: reading.provider) { error in
                                    if let error { followError = error }
                                }
                                Button("Details", systemImage: "info.circle") { path = [reading.id] }
                            }
                        }
                    } header: {
                        Text(header ?? "All plans")
                    }
                }
                if !store.disconnected.isEmpty {
                    Section {
                        DisclosureGroup(isExpanded: $showsDisconnected) {
                            ForEach(store.disconnected) { reading in
                                DisconnectedRow(reading: reading)
                            }
                        } label: {
                            Text("Not connected (\(store.disconnected.count))")
                        }
                    } footer: {
                        Text(disconnectedFooter)
                    }
                }
            }
            .navigationTitle("Usage")
            .navigationDestination(for: String.self) { id in
                if let reading = store.reading(id: id) {
                    ProviderDetailView(reading: reading)
                }
            }
            .overlay {
                if store.readings.isEmpty, store.disconnected.isEmpty {
                    UsageEmptyState(store: store)
                }
            }
            .refreshable {
                await store.refresh(force: true)
            }
            .task {
                await checkNotifications()
            }
            .onChange(of: scenePhase) { _, phase in
                // Back from Settings, where notifications may have been turned on.
                if phase == .active {
                    Task { await checkNotifications() }
                }
            }
            .alert("Couldn't follow it", isPresented: Binding(get: { followError != nil }, set: { if !$0 { followError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(followError ?? "")
            }
        }
    }

    private func follow(_ provider: RelayProvider, window: RelayWindow) {
        guard LiveActivities.isEnabled else {
            followError = "Live Activities are off for Tokenroom. Turn them on in Settings › Tokenroom."
            return
        }
        Task {
            do {
                try await LiveActivities.start(provider, window: window)
            } catch {
                followError = "Couldn't start the Live Activity."
            }
        }
    }

    /// The most pressing metered window that's live: what the summary card leads with.
    private var hero: MobileStore.Reading? {
        store.readings.first { reading in
            reading.provider.isLive && reading.provider.primaryWindow?.isMetered == true
        }
    }

    private struct Highlight: Identifiable {
        var id: String
        var title: String
        var symbol: String
        var action: () -> Void
    }

    /// Banked resets, news, and alerts that need a look, as chips under the summary.
    private var highlights: [Highlight] {
        var items: [Highlight] = []
        let banked = store.readings.filter { ($0.provider.banked?.available ?? 0) > 0 }
        let bankedCount = banked.reduce(0) { $0 + ($1.provider.banked?.available ?? 0) }
        if bankedCount > 0, let first = banked.first {
            items.append(Highlight(id: "banked", title: bankedCount == 1 ? "1 banked reset" : "\(bankedCount) banked resets", symbol: "arrow.counterclockwise") {
                path = [first.id]
            })
        }
        let models = news.unseenModelCount
        if models > 0 {
            items.append(Highlight(id: "models", title: models == 1 ? "1 new model" : "\(models) new models", symbol: "sparkles") {
                openNews(.models)
            })
        }
        let updates = news.unseenAnnouncementCount
        if updates > 0 {
            items.append(Highlight(id: "updates", title: updates == 1 ? "1 update" : "\(updates) updates", symbol: "megaphone") {
                openNews(.announcements)
            })
        }
        if notificationsOff, !store.sampleMode {
            items.append(Highlight(id: "alerts", title: "Turn on alerts", symbol: "bell.badge") {
                openAlerts()
            })
        }
        return items
    }

    private func checkNotifications() async {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        notificationsOff = status == .denied || status == .notDetermined
    }

    private var header: String? {
        guard !store.sampleMode, let source = store.sourceSummary else { return nil }
        guard let checked = store.lastChecked else { return "From \(source)" }
        return "From \(source) · checked \(RelativeTime.ago(checked))"
    }

    /// Mac providers wait for a sign-in there; this iPhone's key providers for their key to work.
    private var disconnectedFooter: String {
        let fromKeys = store.disconnected.contains { store.keyedProviders.map(\.rawValue).contains($0.id) }
        let fromMac = store.disconnected.contains { !store.keyedProviders.map(\.rawValue).contains($0.id) }
        switch (fromMac, fromKeys) {
        case (true, true): return "Sign in to these on your Mac, or check their keys in Settings › API Keys."
        case (false, true): return "Check these keys in Settings › API Keys."
        default: return "Sign in to these on your Mac to see them here."
        }
    }
}

/// The most urgent window at a glance: a ring, the pace forecast, a live countdown to the
/// reset, and Follow on Lock Screen.
private struct UsageHeroCard: View {
    var reading: MobileStore.Reading
    @State private var followError: String?

    private var provider: RelayProvider { reading.provider }

    var body: some View {
        let window = provider.primaryWindow
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 16) {
                UsageRing(used: window?.used ?? 0, isStale: !provider.isLive, label: ReadingText.headline(window), lineWidth: 9)
                    .frame(width: 84, height: 84)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        MonogramMark(provider: provider, size: 22)
                        Text(provider.name)
                            .font(.headline)
                            .lineLimit(1)
                    }
                    if let window {
                        Text(window.title)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    if let pace = reading.pace {
                        Text(pace.caption())
                            .font(.subheadline.weight(pace.needsAttention ? .semibold : .regular))
                            .foregroundStyle(pace.needsAttention ? PaceStyle.color(pace.severity) : .secondary)
                    }
                    if let resetsAt = window?.resetsAt, resetsAt > .now {
                        Text("Resets in \(Text(resetsAt, style: .relative))")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            // The window shown here, when it resets within 8 hours; else a session.
            FollowButton(provider: provider, preferring: window?.id) { followError = $0 }
                .buttonStyle(.bordered)
                .controlSize(.small)
            if let followError {
                Text(followError)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
    }
}

struct ReadingRow: View {
    var reading: MobileStore.Reading

    private var provider: RelayProvider { reading.provider }
    private var window: RelayWindow? { provider.primaryWindow }
    private var isStale: Bool { !provider.isLive }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                MonogramMark(provider: provider)
                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.name)
                        .font(.headline)
                    HStack(spacing: 6) {
                        if let plan = provider.plan {
                            Text(plan)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let banked = provider.banked, banked.available > 0 {
                            Text(banked.available == 1 ? "1 banked" : "\(banked.available) banked")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                                .foregroundStyle(.tint)
                        }
                    }
                }
                Spacer(minLength: 8)
                Text(ReadingText.headline(window))
                    .font(.system(.title2, design: .rounded, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(headlineColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            if let window {
                if window.isMetered {
                    MeterTrack(usedPercent: window.used, remaining: 100 - window.used, isStale: isStale, paceMark: reading.pace?.elapsedFraction)
                }
                HStack(alignment: .center, spacing: 8) {
                    Text(ReadingText.caption(window))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    if window.isMetered, let week = reading.history[window.id], !week.isEmpty {
                        Sparkline(history: week, tint: Color(hex: provider.tint), lineWidth: 1.2)
                            .frame(width: 64, height: 18)
                            // The line itself is hidden from VoiceOver; this element says what it shows.
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("Last 7 days")
                            .accessibilityValue(Sparkline.summary(week))
                    }
                }
            }
            if let pace = reading.pace, pace.needsAttention {
                Text(pace.caption())
                    .font(.caption.weight(.medium))
                    .foregroundStyle(PaceStyle.color(pace.severity))
            }
            if let window, let forecast = Forecast.text(for: window, history: reading.history[window.id], checkedAt: provider.checkedAt ?? provider.fetchedAt) {
                Text(forecast)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let others = otherWindows {
                Text(others)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if isStale {
                Text(provider.message ?? "Last reading \(RelativeTime.ago(provider.fetchedAt)).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .opacity(isStale ? 0.7 : 1)
        .accessibilityElement(children: .combine)
    }

    private var headlineColor: Color {
        guard let window, window.isMetered else { return .primary }
        return TokenroomTokens.ink(remaining: 100 - window.used, isStale: isStale)
    }

    /// "Session 18% · Opus weekly 41%".
    private var otherWindows: String? {
        let others = provider.windows.filter { $0.id != window?.id && $0.isMetered }
        guard !others.isEmpty else { return nil }
        return others.prefix(3).map { "\($0.title) \(ReadingText.headline($0))" }.joined(separator: " · ")
    }
}

private struct DisconnectedRow: View {
    var reading: MobileStore.Reading

    var body: some View {
        HStack(spacing: 12) {
            MonogramMark(provider: reading.provider, size: 28)
                .opacity(0.6)
            VStack(alignment: .leading, spacing: 2) {
                Text(reading.provider.name)
                if let message = reading.provider.message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct SampleBanner: View {
    @Bindable var store: MobileStore

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Sample data")
                    .font(.subheadline.weight(.semibold))
                Text("These readings aren't real.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Turn Off") {
                store.sampleMode = false
                Task { await store.refresh(force: true) }
            }
            .buttonStyle(.bordered)
        }
    }
}

struct UsageEmptyState: View {
    @Bindable var store: MobileStore
    @State private var addsKey = false

    var body: some View {
        Group {
            if store.relayPhase == .loading || store.relayPhase == .idle {
                ProgressView()
            } else {
                ContentUnavailableView {
                    Label(content.title, systemImage: content.symbol)
                } description: {
                    Text(content.description)
                } actions: {
                    Button("Add an API Key") { addsKey = true }
                        .buttonStyle(.borderedProminent)
                    Button("Try Sample Data") {
                        store.hasOnboarded = true
                        store.sampleMode = true
                    }
                }
            }
        }
        .sheet(isPresented: $addsKey) {
            NavigationStack {
                KeysView(store: store)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { addsKey = false }
                        }
                    }
            }
        }
    }

    private var content: (title: String, symbol: String, description: String) {
        switch store.relayPhase {
        case .unavailable:
            ("No readings yet", "key", "This build can't use iCloud. Add an API key to read providers on this iPhone.")
        case .noAccount:
            ("Sign in to iCloud", "icloud.slash", "Use the same Apple Account as your Mac to see its readings, or add an API key.")
        case .failed(let message):
            (message, "exclamationmark.icloud", "Pull down to try again, or add an API key.")
        case .ready where store.needsNewerApp:
            ("Update Tokenroom", "arrow.down.app", "Your Mac sends readings this version can't read yet.")
        default:
            ("No readings yet", "laptopcomputer.and.iphone", "Open Tokenroom on your Mac, signed in to the same iCloud account: it sends its readings here. Or add an API key to read providers on this iPhone.")
        }
    }
}

enum PaceStyle {
    static func color(_ severity: Pace.Severity) -> Color {
        switch severity {
        case .critical: TokenroomTokens.critical
        case .tight: TokenroomTokens.tight
        case .watch, .none: .secondary
        }
    }
}
