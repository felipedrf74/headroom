import SwiftUI

struct UsageListView: View {
    var store: MobileStore

    var body: some View {
        NavigationStack {
            List {
                if !store.entries.isEmpty {
                    Section {
                        ForEach(store.entries) { entry in
                            ProviderRow(entry: entry)
                        }
                    } header: {
                        if let checked = store.lastChecked {
                            Text("From your Mac · checked \(checked.formatted(.relative(presentation: .named)))")
                        }
                    }
                }
            }
            .overlay {
                emptyState
            }
            .navigationTitle("Tokenroom")
            .refreshable {
                await store.refresh()
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if store.entries.isEmpty {
            switch store.phase {
            case .unavailable:
                ContentUnavailableView(
                    "iCloud isn't set up in this build",
                    systemImage: "icloud.slash",
                    description: Text("Sample data and API-key providers arrive in the next milestone.")
                )
            case .noAccount:
                ContentUnavailableView(
                    "Couldn't reach iCloud",
                    systemImage: "icloud.slash",
                    description: Text("Sign in to iCloud in Settings with the same Apple Account as your Mac.")
                )
            case .failed(let message):
                ContentUnavailableView(message, systemImage: "exclamationmark.icloud", description: Text("Pull to try again."))
            case .ready where store.needsNewerApp:
                ContentUnavailableView(
                    "Update Tokenroom",
                    systemImage: "arrow.down.app",
                    description: Text("Your Mac sends readings this version can't read yet.")
                )
            case .ready:
                ContentUnavailableView(
                    "No readings yet",
                    systemImage: "laptopcomputer.and.iphone",
                    description: Text("On your Mac, open Tokenroom Settings and turn on iPhone & Apple Watch.")
                )
            case .idle, .loading:
                ProgressView()
            }
        }
    }
}

private struct ProviderRow: View {
    var entry: RelayMerge.Entry

    private var provider: RelayProvider {
        entry.provider
    }

    private var isLive: Bool {
        provider.state == "live"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                MonogramMark(text: provider.monogram, tint: Color(hex: provider.tint))
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
                Text(headline)
                    .font(.system(.title, design: .rounded, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(TokenroomTokens.ink(remaining: 100 - (provider.primaryWindow?.used ?? 0), isStale: !isLive))
            }
            if let window = provider.primaryWindow {
                if window.metered ?? true {
                    MeterTrack(usedPercent: window.used, remaining: 100 - window.used, isStale: !isLive)
                }
                Text(caption(for: window))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(provider.windows.filter { $0.id != provider.primaryWindow?.id }) { window in
                Text("\(window.title) \(Int(window.used.rounded()))%\(resetSuffix(window))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let message = provider.message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    /// Used % for metered windows; the amount for balances without a limit.
    private var headline: String {
        guard let window = provider.primaryWindow else { return "—" }
        if window.metered == false, let amount = window.amount {
            if let remaining = amount.remainingOrComputed {
                return AmountFormat.text(remaining, unit: amount.unit)
            }
            return amount.used.map { AmountFormat.text($0, unit: amount.unit) } ?? "—"
        }
        return "\(Int(window.used.rounded()))%"
    }

    private func caption(for window: RelayWindow) -> String {
        "\(window.title)\(resetSuffix(window))"
    }

    private func resetSuffix(_ window: RelayWindow) -> String {
        guard let reset = window.resetsAt, reset > .now else { return "" }
        return " · resets \(reset.formatted(.relative(presentation: .named)))"
    }
}

/// Provider mark drawn from its monogram and tint. The phone never ships provider logos.
struct MonogramMark: View {
    var text: String
    var tint: Color
    var size: CGFloat = 36

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(tint.gradient)
            .frame(width: size, height: size)
            .overlay {
                Text(text)
                    .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
    }
}

extension Color {
    /// `#RRGGBB`; gray when malformed.
    init(hex: String) {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else {
            self = .gray
            return
        }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}
