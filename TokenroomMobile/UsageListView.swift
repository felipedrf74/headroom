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
    var entry: MobileStore.Entry

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
                Text(provider.primaryWindow.map { "\(Int($0.used.rounded()))%" } ?? "—")
                    .font(.system(.title, design: .rounded, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(isLive ? Color.primary : Color.secondary)
            }
            if let window = provider.primaryWindow {
                ProgressView(value: min(max(window.used, 0), 100), total: 100)
                    .tint(isLive ? UsageColor.color(for: window.used) : .secondary)
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

/// Same thresholds as the Mac menu bar: light blue, yellow from 50%, orange from 75%, red from 90%.
enum UsageColor {
    static let healthy = Color(red: 110 / 255, green: 196 / 255, blue: 245 / 255)
    static let watch = Color(red: 242 / 255, green: 196 / 255, blue: 22 / 255)
    static let tight = Color(red: 232 / 255, green: 122 / 255, blue: 16 / 255)
    static let critical = Color(red: 214 / 255, green: 45 / 255, blue: 38 / 255)

    static func color(for used: Double) -> Color {
        if used >= 90 { return critical }
        if used >= 75 { return tight }
        if used >= 50 { return watch }
        return healthy
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
