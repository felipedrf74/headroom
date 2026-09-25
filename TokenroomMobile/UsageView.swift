import SwiftUI

struct UsageView: View {
    @Bindable var store: MobileStore
    @Binding var path: [String]
    @State private var showsDisconnected = false

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if store.sampleMode {
                    Section {
                        SampleBanner(store: store)
                    }
                }
                if !store.readings.isEmpty {
                    Section {
                        ForEach(store.readings) { reading in
                            NavigationLink(value: reading.id) {
                                ReadingRow(reading: reading)
                            }
                        }
                    } header: {
                        if let header {
                            Text(header)
                        }
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
                        Text("Sign in to these on your Mac to see them here.")
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
        }
    }

    private var header: String? {
        guard !store.sampleMode, let source = store.sourceSummary else { return nil }
        guard let checked = store.lastChecked else { return "From \(source)" }
        return "From \(source) · checked \(RelativeTime.ago(checked))"
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
                    if let plan = provider.plan {
                        Text(plan)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                Text(ReadingText.headline(window))
                    .font(.system(.title2, design: .rounded, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(headlineColor)
            }
            if let window {
                if window.isMetered {
                    MeterTrack(usedPercent: window.used, remaining: 100 - window.used, isStale: isStale, paceMark: reading.pace?.elapsedFraction)
                }
                Text(ReadingText.caption(window))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let pace = reading.pace, pace.verdict == .ahead || pace.verdict == .limitReached {
                Text(pace.caption())
                    .font(.caption.weight(.medium))
                    .foregroundStyle(PaceStyle.color(pace.severity))
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
            ("No readings yet", "laptopcomputer.and.iphone", "On your Mac, open Tokenroom Settings and turn on iPhone & Apple Watch. Or add an API key to read providers here.")
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
