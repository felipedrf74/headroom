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
                        if provider == .claude {
                            ClaudeBridgeRow()
                                .padding(.leading, 28)
                        }
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text("Accounts")
            } footer: {
                Text("Tokenroom reuses the login you already have for each tool. Tokens, names, and emails are never stored or sent anywhere.")
            }

            if let relay = store.relay {
                RelaySettingsSection(relay: relay)
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

private struct RelaySettingsSection: View {
    @Bindable var relay: RelayPublisher
    @State private var sendingTest = false

    var body: some View {
        Section {
            if relay.isAvailable {
                Toggle("Send readings to iCloud", isOn: $relay.isEnabled)
                TextField("Name on iPhone", text: $relay.label)
                Button("Send Test Alert") {
                    sendingTest = true
                    Task {
                        await relay.sendTestAlert()
                        sendingTest = false
                    }
                }
                .disabled(!relay.isEnabled || sendingTest)
            }
            Text(relay.statusText)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        } header: {
            Text("iPhone & Apple Watch")
        } footer: {
            Text("Only percentages, reset times, window labels, and plan names go to your private iCloud. Tokens never leave this Mac.")
        }
    }
}

/// Opt-in: read Claude usage from Claude Code's own status line.
private struct ClaudeBridgeRow: View {
    @State private var isOn = ClaudeStatusLineBridge.standard.isInstalled
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Read usage from Claude Code's status line", isOn: Binding(
                get: { isOn },
                set: { apply($0) }
            ))
            .toggleStyle(.checkbox)
            Text(message ?? "Keeps Claude usage current without Claude's login. Adds a status line command to ~/.claude/settings.json (after a backup) and runs any status line you already have.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func apply(_ enable: Bool) {
        let bridge = ClaudeStatusLineBridge.standard
        do {
            if enable {
                try bridge.install()
            } else {
                try bridge.uninstall()
            }
            isOn = bridge.isInstalled
            message = nil
        } catch ClaudeStatusLineBridge.BridgeError.invalidSettings {
            isOn = bridge.isInstalled
            message = "Couldn't change ~/.claude/settings.json: it isn't valid JSON. Fix it, then try again."
        } catch {
            isOn = bridge.isInstalled
            message = "Couldn't change ~/.claude/settings.json."
        }
    }
}
