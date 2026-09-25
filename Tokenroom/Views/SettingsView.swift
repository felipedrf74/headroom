import AppKit
import SwiftUI

struct SettingsView: View {
    @Bindable var store: QuotaStore
    @State private var tab = "providers"

    var body: some View {
        TabView(selection: $tab) {
            ProvidersSettings(store: store)
                .tabItem { Label("Providers", systemImage: "square.stack.3d.up") }
                .tag("providers")
            MenuBarSettings(store: store)
                .tabItem { Label("Menu Bar", systemImage: "menubar.rectangle") }
                .tag("menubar")
            if let relay = store.relay {
                Form {
                    RelaySettingsSection(relay: relay)
                }
                .formStyle(.grouped)
                .tabItem { Label("iPhone & Watch", systemImage: "iphone.gen3") }
                .tag("iphone")
            }
            Form {
                Section {
                    Toggle("Launch at login", isOn: $store.settings.launchAtLogin)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("General", systemImage: "gearshape") }
            .tag("general")
        }
        .frame(minWidth: 460, idealWidth: 480, minHeight: 520)
        .navigationTitle("Settings")
        .onChange(of: store.pendingKeyProvider) { _, provider in
            if provider != nil {
                tab = "providers"
            }
        }
    }
}

// MARK: Providers

private struct ProvidersSettings: View {
    @Bindable var store: QuotaStore
    @State private var keySheet: Provider?

    var body: some View {
        Form {
            Section {
                ForEach(Provider.allCases.filter { !$0.usesAPIKey }) { provider in
                    VStack(alignment: .leading, spacing: 8) {
                        providerToggle(provider)
                        signInActions(provider)
                        if provider == .claude {
                            ClaudeBridgeRow()
                                .padding(.leading, 28)
                        }
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text("Subscriptions")
            } footer: {
                Text("Tokenroom reuses the login you already have for each tool and never refreshes it. Tokens, names, and emails are never stored or sent anywhere.")
            }

            Section {
                ForEach(Provider.allCases.filter(\.usesAPIKey)) { provider in
                    VStack(alignment: .leading, spacing: 8) {
                        providerToggle(provider)
                        KeyRow(provider: provider, keys: CredentialReaders.apiKeys) {
                            keySheet = provider
                        } onRemoved: {
                            store.settings.setEnabled(provider, false)
                        }
                        .padding(.leading, 28)
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text("Pay as you go")
            } footer: {
                Text("API keys stay in this Mac's Keychain. They're never synced or sent to your iPhone; only the readings are.")
            }
        }
        .formStyle(.grouped)
        .sheet(item: $keySheet) { provider in
            AddKeySheet(provider: provider, keys: CredentialReaders.apiKeys) {
                store.settings.setEnabled(provider, true)
                Task { await store.refresh(force: true, providers: [provider]) }
            }
        }
        .onChange(of: store.pendingKeyProvider, initial: true) { _, provider in
            guard let provider else { return }
            keySheet = provider
            store.pendingKeyProvider = nil
        }
    }

    private func providerToggle(_ provider: Provider) -> some View {
        Toggle(isOn: Binding(
            get: { store.settings.isEnabled(provider) },
            set: { store.settings.setEnabled(provider, $0) }
        )) {
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
    }

    @ViewBuilder
    private func signInActions(_ provider: Provider) -> some View {
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
}

/// A pasted key: `•••• a1b2` with Replace and Remove, or Add Key.
private struct KeyRow: View {
    var provider: Provider
    var keys: APIKeyStore
    var onAdd: () -> Void
    var onRemoved: () -> Void
    @State private var metadata: APIKeyStore.Metadata?
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if let metadata {
                    Text("•••• \(metadata.last4)\(metadata.region.map { " · \($0)" } ?? "")")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Button("Replace…", action: onAdd)
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                    Button("Remove", role: .destructive) {
                        remove()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                } else {
                    Button("Add Key…", action: onAdd)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
            if let message {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .task {
            let keys = self.keys
            let provider = self.provider
            metadata = await BlockingIO.run { keys.metadata(for: provider) }
        }
    }

    private func remove() {
        do {
            try keys.remove(for: provider)
            metadata = nil
            message = nil
            onRemoved()
        } catch {
            message = "Couldn't remove the key from the Keychain."
        }
    }
}

/// Paste → Test & Save: one call with the key before it's stored.
private struct AddKeySheet: View {
    var provider: Provider
    var keys: APIKeyStore
    var onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var region: String
    @State private var working = false
    @State private var message: String?
    @State private var offerSaveAnyway = false

    init(provider: Provider, keys: APIKeyStore, onSaved: @escaping () -> Void) {
        self.provider = provider
        self.keys = keys
        self.onSaved = onSaved
        _region = State(initialValue: provider.key?.regions.first ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                ProviderIcon(provider: provider, size: 28)
                Text("Add \(provider.displayName) \(provider.key?.label ?? "API key")")
                    .font(.headline)
            }
            SecureField(provider.key?.prefixHint.isEmpty == false ? "\(provider.key!.prefixHint)…" : "Paste your key", text: $key)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 320)
            if let regions = provider.key?.regions, !regions.isEmpty {
                Picker("Account", selection: $region) {
                    ForEach(regions, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            if let url = provider.key?.createURL {
                Link("Create a key", destination: url)
                    .font(.system(size: 11))
            }
            Text(message ?? "Tokenroom only reads your balance and usage with this key. It stays in this Mac's Keychain.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if offerSaveAnyway {
                    Button("Save Anyway") { save() }
                }
                Button(working ? "Testing…" : "Test & Save") { test() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || working)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private var regionValue: String? {
        region.isEmpty ? nil : region
    }

    private func test() {
        working = true
        message = nil
        offerSaveAnyway = false
        let key = self.key.trimmingCharacters(in: .whitespacesAndNewlines)
        let provider = self.provider
        let region = regionValue
        Task {
            do {
                _ = try await APIKeyClient.snapshot(for: provider, key: key, region: region)
                save()
            } catch ProviderError.expired {
                message = "Couldn't use this key. Check it and try again."
            } catch ProviderError.unreachable, ProviderError.rateLimited {
                message = "Couldn't reach \(provider.displayName) to check the key."
                offerSaveAnyway = true
            } catch {
                message = "Couldn't read \(provider.displayName)'s answer with this key."
                offerSaveAnyway = true
            }
            working = false
        }
    }

    private func save() {
        do {
            try keys.save(key, for: provider, region: regionValue)
            onSaved()
            dismiss()
        } catch {
            message = "Couldn't save the key in the Keychain."
        }
    }
}

// MARK: Menu bar

private struct MenuBarSettings: View {
    @Bindable var store: QuotaStore

    var body: some View {
        Form {
            Section {
                Picker("Style", selection: $store.settings.menuStyle) {
                    ForEach(MenuBarStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
                Picker("Refresh every", selection: $store.settings.refreshMinutes) {
                    Text("5 minutes").tag(5)
                    Text("10 minutes").tag(10)
                    Text("15 minutes").tag(15)
                    Text("30 minutes").tag(30)
                }
            } footer: {
                if store.menuMeters.count > 6, store.settings.menuStyle != .highest {
                    Text("Many providers are showing. Highest only keeps the menu bar narrow so macOS doesn't hide it.")
                }
            }
            Section {
                ForEach(store.popoverProviders) { provider in
                    Toggle(isOn: Binding(
                        get: { store.settings.showsInMenuBar(provider) },
                        set: { store.settings.setShowsInMenuBar(provider, $0) }
                    )) {
                        HStack(spacing: 8) {
                            ProviderIcon(provider: provider, size: 18)
                            Text(provider.displayName)
                        }
                    }
                }
            } header: {
                Text("Show in menu bar")
            } footer: {
                Text("Hidden providers stay in the popover. Balances without a limit never show in the menu bar.")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: iPhone & Apple Watch

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
            Text("Only percentages, reset times, window labels, plan names, and balances go to your private iCloud. Tokens and keys never leave this Mac.")
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
