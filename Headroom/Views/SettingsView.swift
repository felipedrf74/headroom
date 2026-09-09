import SwiftUI

struct SettingsView: View {
    @Bindable var store: QuotaStore

    var body: some View {
        Form {
            Section {
                ForEach(Provider.allCases) { provider in
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(isOn: enabledBinding(provider)) {
                            HStack(spacing: 8) {
                                ProviderIcon(provider: provider, size: 20)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(provider.displayName)
                                    Text(store.accountCaption(provider))
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        accountActions(provider)
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text("Accounts")
            } footer: {
                Text("Headroom reuses the login you already have for each tool. Percentages stay on this Mac. Tokens, names, and emails are not stored.")
            }

            Section("Menu bar") {
                Picker("Style", selection: $store.settings.menuStyle) {
                    ForEach(MenuBarStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
            }
            Section("Refresh") {
                Picker("Interval", selection: $store.settings.refreshMinutes) {
                    Text("5 minutes").tag(5)
                    Text("10 minutes").tag(10)
                    Text("15 minutes").tag(15)
                    Text("30 minutes").tag(30)
                }
            }
            Section("General") {
                Toggle("Launch at login", isOn: $store.settings.launchAtLogin)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 380, idealWidth: 400, minHeight: 420)
        .navigationTitle("Settings")
    }

    @ViewBuilder
    private func accountActions(_ provider: Provider) -> some View {
        let status = store.statuses[provider] ?? .loading
        let needsSignIn: Bool = {
            switch status {
            case .signedOut, .expired, .unreachable(nil):
                return true
            default:
                return false
            }
        }()
        if store.signIn.isWorking(provider) {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Waiting for \(provider.installToolName)…")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Button("Cancel") {
                    store.signIn.cancel()
                }
                .buttonStyle(.plain)
            }
            .padding(.leading, 28)
        } else if case .needsInstall(let active, let tool, _) = store.signIn.phase, active == provider {
            HStack(spacing: 8) {
                Button("Install \(tool)") {
                    store.signIn.openInstallPage(provider)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Button("Try Again") {
                    store.signIn.signIn(provider)
                }
                .buttonStyle(.plain)
            }
            .padding(.leading, 28)
        } else if needsSignIn {
            Button(provider.signInTitle) {
                store.signIn.signIn(provider)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help(provider.signInHint)
            .padding(.leading, 28)
        }
    }

    private func enabledBinding(_ provider: Provider) -> Binding<Bool> {
        Binding(
            get: { store.settings.isEnabled(provider) },
            set: { store.settings.setEnabled(provider, $0) }
        )
    }
}
