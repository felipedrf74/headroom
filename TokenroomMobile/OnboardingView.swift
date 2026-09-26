import SwiftUI

struct OnboardingView: View {
    @Bindable var store: MobileStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        Image(systemName: "gauge.with.dots.needle.67percent")
                            .font(.system(size: 44, weight: .semibold))
                            .foregroundStyle(.tint)
                        Text("Welcome to Tokenroom")
                            .font(.largeTitle.bold())
                        Text("See how much of your AI plans you've used, and when they reset.")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.bottom, 4)

                    LazyVGrid(columns: [GridItem(.flexible(), alignment: .top), GridItem(.flexible(), alignment: .top)], alignment: .leading, spacing: 14) {
                        Feature(symbol: "chart.line.uptrend.xyaxis", text: "Pace, and when you'd run out")
                        Feature(symbol: "bell.badge", text: "Alerts at 80%, 95%, and resets")
                        Feature(symbol: "rectangle.stack", text: "Widgets, Live Activity, Watch")
                        Feature(symbol: "newspaper", text: "New models and updates")
                    }
                    .padding(.bottom, 8)

                    Text("Get started")
                        .font(.title3.weight(.semibold))

                    NavigationLink {
                        ConnectMacView(store: store) { dismiss() }
                    } label: {
                        OptionCard(symbol: "laptopcomputer.and.iphone", title: "Connect your Mac", text: "Claude, Codex, Cursor, Copilot, and more, from Tokenroom on your Mac through your iCloud.")
                    }
                    NavigationLink {
                        KeysView(store: store)
                    } label: {
                        OptionCard(symbol: "key", title: "Add an API key", text: "OpenRouter, DeepSeek, Kimi Code, Z.ai, and more, read right from this iPhone.")
                    }
                    Button {
                        store.sampleMode = true
                        dismiss()
                    } label: {
                        OptionCard(symbol: "sparkles", title: "Try sample data", text: "Look around with made-up readings. Turn them off in Settings.")
                    }

                    Text("Tokenroom isn't affiliated with any of the providers it shows.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                }
                .buttonStyle(.plain)
                .padding(20)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Not Now") { dismiss() }
                }
            }
        }
    }
}

private struct Feature: View {
    var symbol: String
    var text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.tint)
                .frame(width: 22)
            Text(text)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct OptionCard: View {
    var symbol: String
    var title: String
    var text: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contentShape(Rectangle())
    }
}

private struct ConnectMacView: View {
    var store: MobileStore
    /// Closes the whole welcome sheet, not just this step.
    var close: () -> Void

    var body: some View {
        List {
            Section {
                Step(number: 1, text: "Install Tokenroom on your Mac.")
                Link("Get Tokenroom for Mac", destination: TokenroomIdentity.repositoryURL.appendingPathComponent("releases"))
                Step(number: 2, text: "Open it. It sends its readings to your iCloud on its own (Settings › iPhone & Watch).")
                Step(number: 3, text: "Use the same Apple Account on your Mac and this iPhone.")
            } footer: {
                Text("Your Mac sends only usage, reset times, and plan names. Logins and keys never leave it.")
            }
        }
        .navigationTitle("Connect your Mac")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    store.hasOnboarded = true
                    Task { await store.refresh(force: true) }
                    close()
                }
            }
        }
    }

    private struct Step: View {
        var number: Int
        var text: String

        var body: some View {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("\(number)")
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(.tint)
                Text(text)
            }
        }
    }
}
