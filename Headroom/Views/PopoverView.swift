import AppKit
import SwiftUI

struct PopoverView: View {
    @Bindable var store: QuotaStore
    var onSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, HeadroomTokens.cardPadding)
                .padding(.top, 14)
                .padding(.bottom, 12)

            let providers = store.popoverProviders
            if providers.isEmpty {
                emptyProviders
                    .padding(.horizontal, HeadroomTokens.cardPadding)
                    .padding(.bottom, 8)
            } else {
                ViewThatFits(in: .vertical) {
                    cards(providers)
                    ScrollView {
                        cards(providers)
                    }
                }
                .frame(maxHeight: 520)
            }

            Divider()
                .padding(.top, 10)
                .opacity(0.7)

            footer
                .padding(.horizontal, HeadroomTokens.cardPadding)
                .padding(.vertical, 10)
        }
        .frame(width: HeadroomTokens.popoverWidth)
        .transaction { $0.animation = nil }
    }

    private func cards(_ providers: [Provider]) -> some View {
        VStack(spacing: HeadroomTokens.cardGap) {
            ForEach(providers, id: \.self) { provider in
                ProviderCard(
                    provider: provider,
                    status: store.statuses[provider] ?? .loading,
                    signInPhase: store.signIn.phase,
                    onSignIn: { store.signIn.signIn(provider) },
                    onCancelSignIn: { store.signIn.cancel() },
                    onInstall: { store.signIn.openInstallPage(provider) }
                )
            }
        }
        .padding(.horizontal, HeadroomTokens.cardPadding)
    }

    private var emptyProviders: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No providers on")
                .font(.system(size: HeadroomTokens.popoverNameSize, weight: .semibold))
            Text("Turn on Grok, Claude, OpenAI, or Cursor in Settings, then sign in to see usage.")
                .font(.system(size: HeadroomTokens.captionSize))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(HeadroomTokens.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        )
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Headroom")
                    .font(.system(size: 15, weight: .semibold))
                Text(store.isRefreshing ? "Updating…" : "Updated \(RelativeTime.ago(store.lastAttempt))")
                    .font(.system(size: HeadroomTokens.captionSize))
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
            Spacer()
            Button("Quit Headroom") {
                NSApp.terminate(nil)
            }
            .buttonStyle(.plain)
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.secondary)
        .frame(minHeight: 22)
    }
}
