import AppKit
import SwiftUI

enum SettingsTab: String {
    case general
    case providers
    case keys
    case alerts
    case news
    case menuBar
    case iPhone
}

/// Which tab Settings shows; the app sets it before opening Settings from elsewhere.
@Observable
@MainActor
final class SettingsTabRequest {
    var tab: SettingsTab = .providers
}

struct SettingsView: View {
    @Bindable var store: QuotaStore
    @Bindable var request: SettingsTabRequest

    var body: some View {
        TabView(selection: $request.tab) {
            GeneralSettings(store: store)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            ProvidersSettings(store: store) { request.tab = .keys }
                .tabItem { Label("Providers", systemImage: "square.stack.3d.up") }
                .tag(SettingsTab.providers)
            KeysSettings(store: store)
                .tabItem { Label("API Keys", systemImage: "key") }
                .tag(SettingsTab.keys)
            AlertsSettings(store: store)
                .tabItem { Label("Alerts", systemImage: "bell.badge") }
                .tag(SettingsTab.alerts)
            NewsSettings(store: store)
                .tabItem { Label("News", systemImage: "newspaper") }
                .tag(SettingsTab.news)
            MenuBarSettings(store: store)
                .tabItem { Label("Menu Bar", systemImage: "menubar.rectangle") }
                .tag(SettingsTab.menuBar)
            if let relay = store.relay {
                Form {
                    RelaySettingsSection(relay: relay)
                }
                .formStyle(.grouped)
                .tabItem { Label("iPhone & Watch", systemImage: "iphone.gen3") }
                .tag(SettingsTab.iPhone)
            }
        }
        .frame(minWidth: 580, idealWidth: 600, minHeight: 560)
        .navigationTitle("Settings")
        .onChange(of: store.pendingKeyProvider, initial: true) { _, provider in
            if provider != nil {
                request.tab = .keys
            }
        }
    }
}

// MARK: General

private struct GeneralSettings: View {
    @Bindable var store: QuotaStore

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: $store.settings.launchAtLogin)
            }
            if let legacy = LegacyMigration.legacyAppURL {
                Section {
                    Text("Headroom is still on this Mac. Quit it, remove it from Login Items in System Settings › General, and move it to the Trash.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 12) {
                        if LegacyMigration.isLegacyAppRunning {
                            Button("Quit Headroom") { store.quitLegacyApp() }
                        }
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([legacy])
                        }
                    }
                } header: {
                    Text("Headroom")
                }
            }
            Section {
                LabeledContent("Version", value: TokenroomIdentity.version)
                Link("Privacy", destination: TokenroomIdentity.privacyURL)
                Link("Source code", destination: TokenroomIdentity.repositoryURL)
            } header: {
                Text("About")
            } footer: {
                Text("Tokenroom isn't affiliated with any of the providers it shows.")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: Providers

private struct ProvidersSettings: View {
    @Bindable var store: QuotaStore
    var onManageKeys: () -> Void
    /// Providers signed in or configured on this Mac, checked off the main thread.
    @State private var detected: Set<Provider> = []

    var body: some View {
        Form {
            let personal = Provider.allCases.filter { $0.category != .orgSpend }
            let connected = personal.filter { store.settings.isEnabled($0) }
            let detectedOff = personal.filter { !store.settings.isEnabled($0) && detected.contains($0) }
            let available = personal.filter { !store.settings.isEnabled($0) && !detected.contains($0) }

            if !connected.isEmpty {
                Section {
                    ForEach(connected) { providerRow($0) }
                } header: {
                    Text("Connected")
                } footer: {
                    Text("Tokenroom reuses the login you already have for each tool and never refreshes it. Tokens, names, and emails are never stored or sent anywhere. Tools you sign in to are read from the same endpoints their own apps use: unofficial, and they can change without notice.")
                }
            }
            if !detectedOff.isEmpty {
                Section {
                    ForEach(detectedOff) { providerRow($0) }
                } header: {
                    Text("Detected on this Mac")
                } footer: {
                    Text("Signed in or set up on this Mac. Turn one on to see its usage.")
                }
            }
            if !available.isEmpty {
                Section("Available") {
                    ForEach(available) { providerRow($0) }
                }
            }
            Section {
                ForEach(Provider.allCases.filter { $0.category == .orgSpend }) { providerRow($0) }
            } header: {
                Text("Organization billing")
            } footer: {
                Text("Month-to-date spend with an admin or management key. These never turn on by themselves; add a dedicated key you can revoke in API Keys.")
            }
        }
        .formStyle(.grouped)
        .task {
            detected = await BlockingIO.run {
                Set(Provider.allCases.filter { CredentialReaders.hasSession($0) })
            }
        }
    }

    private func providerRow(_ provider: Provider) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            providerToggle(provider)
            if provider.usesAPIKey {
                if needsKey(provider) {
                    Button("Add a key in API Keys", action: onManageKeys)
                        .buttonStyle(.link)
                        .font(.system(size: 11))
                        .padding(.leading, 28)
                }
            } else {
                signInActions(provider)
            }
            if provider == .claude {
                ClaudeBridgeRow()
                    .padding(.leading, 28)
            }
            if provider == .claude {
                Text("Unofficial: read from the same endpoint \(provider.toolName) uses. It can change without notice.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 28)
            }
        }
        .padding(.vertical, 2)
    }

    private func needsKey(_ provider: Provider) -> Bool {
        guard store.settings.isEnabled(provider) else { return false }
        if case .signedOut = store.statuses[provider] ?? .loading { return true }
        return false
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
                    Text(caption(provider))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func caption(_ provider: Provider) -> String {
        if store.settings.isEnabled(provider) {
            return store.accountCaption(provider)
        }
        if detected.contains(provider) {
            return provider.usesAPIKey ? "Key found on this Mac" : "Signed in on this Mac"
        }
        return provider.usesAPIKey ? "Needs an API key" : "Sign in with \(provider.installToolName)"
    }

    @ViewBuilder
    private func signInActions(_ provider: Provider) -> some View {
        let status = store.statuses[provider] ?? .loading
        let needsSignIn: Bool = {
            guard store.settings.isEnabled(provider) else { return false }
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

// MARK: API keys

private struct KeysSettings: View {
    @Bindable var store: QuotaStore
    @State private var keySheet: Provider?

    var body: some View {
        Form {
            Section {
                ForEach(Provider.allCases.filter { $0.access == .codingPlanKey }) { provider in
                    VStack(alignment: .leading, spacing: 8) {
                        keyHeader(provider)
                        KeyRow(provider: provider, keys: CredentialReaders.apiKeys) {
                            keySheet = provider
                        } onRemoved: {
                            // A key the coding tool keeps may still be there.
                            Task { await store.refresh(force: true, providers: [provider]) }
                        }
                        .padding(.leading, 28)
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text("Coding plans")
            } footer: {
                Text("Tokenroom uses the key your coding tool already has on this Mac (Claude Code settings, the kimi CLI, or OpenCode), or one you add here. Added keys stay in this Mac's Keychain.")
            }

            Section {
                ForEach(Provider.allCases.filter { $0.descriptor.fallbackKey != nil }) { provider in
                    VStack(alignment: .leading, spacing: 8) {
                        keyHeader(provider)
                        KeyRow(provider: provider, keys: CredentialReaders.apiKeys) {
                            keySheet = provider
                        } onRemoved: {
                            Task { await store.refresh(force: true, providers: [provider]) }
                        }
                        .padding(.leading, 28)
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text("Official APIs")
            } footer: {
                Text("Used when the app's own login is missing or refused: GitHub's documented billing API reads Copilot's AI credits with a fine-grained token.")
            }

            Section {
                ForEach(Provider.allCases.filter { $0.category == .apiBalance }) { provider in
                    keyedProvider(provider, budgetLabel: "Reference")
                }
            } header: {
                Text("Pay as you go")
            } footer: {
                Text("API keys stay in this Mac's Keychain. They're never synced or sent to your iPhone; only the readings are. A reference amount in the key's currency turns a balance into a meter.")
            }

            Section {
                ForEach(Provider.allCases.filter { $0.category == .orgSpend }) { provider in
                    keyedProvider(provider, budgetLabel: "Monthly budget")
                }
            } header: {
                Text("Organization billing")
            } footer: {
                Text("Admin and management keys can change your organization. Tokenroom only reads cost and billing with them. Create a dedicated key you can revoke.")
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

    private func keyHeader(_ provider: Provider) -> some View {
        HStack(spacing: 8) {
            ProviderIcon(provider: provider, size: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(provider.displayName)
                Text(store.settings.isEnabled(provider) ? store.accountCaption(provider) : "Off")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func keyedProvider(_ provider: Provider, budgetLabel: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            keyHeader(provider)
            KeyRow(provider: provider, keys: CredentialReaders.apiKeys) {
                keySheet = provider
            } onRemoved: {
                store.settings.setEnabled(provider, false)
            }
            .padding(.leading, 28)
            BudgetField(label: budgetLabel, currency: store.budgetCurrency(for: provider), value: Binding(
                get: { store.settings.budget(for: provider) },
                set: { value in
                    store.settings.setBudget(value, for: provider)
                    store.budgetDidChange(for: provider)
                }
            ))
            .padding(.leading, 28)
        }
        .padding(.vertical, 2)
    }
}

/// A pasted key: `•••• a1b2` with Replace and Remove, or Add Key.
private struct KeyRow: View {
    var provider: Provider
    var keys: APIKeyStore
    var onAdd: () -> Void
    var onRemoved: () -> Void
    @State private var metadata: APIKeyStore.Metadata?
    @State private var localKey: String?
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if metadata == nil, let localKey {
                Text(localKey)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
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
            if let warning = metadata?.warning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(TokenroomTokens.tight)
                    .fixedSize(horizontal: false, vertical: true)
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
            let loaded = await BlockingIO.run { (keys.metadata(for: provider), LocalKeys.settingsCaption(for: provider)) }
            metadata = loaded.0
            localKey = loaded.1
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

/// An amount in the key's currency; empty means no reference or budget.
private struct BudgetField: View {
    var label: String
    var currency: String
    @Binding var value: Double?

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField("None", value: $value, format: .currency(code: currency))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
                .frame(width: 110)
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
    @State private var acknowledgedAdmin = false
    /// Set when a test shows the key can change things (an xAI key with write access).
    @State private var warning: String?

    init(provider: Provider, keys: APIKeyStore, onSaved: @escaping () -> Void) {
        self.provider = provider
        self.keys = keys
        self.onSaved = onSaved
        _region = State(initialValue: provider.keySpec?.regions.first ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                ProviderIcon(provider: provider, size: 28)
                Text("Add \(provider.displayName) \(provider.keySpec?.label ?? "API key")")
                    .font(.headline)
            }
            SecureField(provider.keySpec?.prefixHint.isEmpty == false ? "\(provider.keySpec!.prefixHint)…" : "Paste your key", text: $key)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 320)
            if let regions = provider.keySpec?.regions, !regions.isEmpty {
                Picker(provider.keySpec?.choiceLabel ?? "Account", selection: $region) {
                    ForEach(regions, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            if let url = provider.keySpec?.createURL {
                Link("Create a \(provider.keySpec?.label ?? "key")", destination: url)
                    .font(.system(size: 11))
            }
            if let note = provider.keySpec?.note {
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if provider.key?.isAdmin == true {
                VStack(alignment: .leading, spacing: 6) {
                    Text("This is an organization-wide key. It can read and change your organization's settings\(provider == .xaiOrg ? ", billing, and keys" : ""). Tokenroom only reads cost and billing with it, keeps it in this Mac's Keychain, and never sends it to other devices.")
                        .font(.system(size: 11))
                        .fixedSize(horizontal: false, vertical: true)
                    Toggle("I created a dedicated key I can revoke", isOn: $acknowledgedAdmin)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 11))
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.orange.opacity(0.12)))
            }
            if let warning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(TokenroomTokens.tight)
                    .fixedSize(horizontal: false, vertical: true)
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
                Button(working ? "Testing…" : (warning == nil ? "Test & Save" : "Save With This Key")) {
                    warning == nil ? test() : save()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || working || (provider.key?.isAdmin == true && !acknowledgedAdmin))
            }
        }
        .padding(20)
        .frame(width: 420)
        .onChange(of: key) { _, _ in
            // A different key needs its own test.
            warning = nil
        }
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
                let check = try await APIKeyClient.check(for: provider, key: key, region: region)
                if let found = check.warning {
                    warning = found
                } else {
                    save()
                }
            } catch ProviderError.expired {
                message = provider.keySpec?.regions.isEmpty == false
                    ? "Couldn't use this key. Check it, and the account it belongs to, and try again."
                    : "Couldn't use this key. Check it and try again."
            } catch ProviderError.notEntitled(let reason) {
                message = reason
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
            try keys.save(key.trimmingCharacters(in: .whitespacesAndNewlines), for: provider, region: regionValue, warning: warning)
            onSaved()
            dismiss()
        } catch {
            message = "Couldn't save the key in the Keychain."
        }
    }
}

// MARK: Alerts

private struct AlertsSettings: View {
    @Bindable var store: QuotaStore
    @State private var denied = false

    private var preferences: AlertPreferences {
        store.settings.alertPreferences
    }

    var body: some View {
        Form {
            Section {
                Toggle("Show alerts on this Mac", isOn: Binding(
                    get: { store.settings.showsAlertsOnMac },
                    set: { isOn in
                        guard isOn else {
                            store.settings.showsAlertsOnMac = false
                            return
                        }
                        Task {
                            let allowed = await MacAlerts.requestPermission()
                            store.settings.showsAlertsOnMac = allowed
                            denied = !allowed
                        }
                    }
                ))
            } header: {
                Text("This Mac")
            } footer: {
                Text(denied
                    ? "Notifications are off for Tokenroom. Turn them on in System Settings › Notifications."
                    : "Your iPhone gets these through iCloud either way, once each, whichever device sees them first.")
            }

            Section {
                ForEach(AlertPreferences.supportedThresholds, id: \.self) { level in
                    Toggle("\(level)% of a limit is used", isOn: binding(
                        get: { $0.thresholds.contains(level) },
                        set: { preferences, isOn in
                            if isOn {
                                preferences.thresholds = Array(Set(preferences.thresholds + [level])).sorted()
                            } else {
                                preferences.thresholds.removeAll { $0 == level }
                            }
                        }
                    ))
                }
                Toggle("A busy window resets", isOn: binding(get: \.resets, set: { $0.resets = $1 }))
                Toggle("Banked resets arrive or are about to expire", isOn: binding(get: \.banked, set: { $0.banked = $1 }))
                Toggle("A balance or budget runs low", isOn: binding(get: \.lowBalance, set: { $0.lowBalance = $1 }))
                Toggle("New models from labs you follow", isOn: binding(get: \.newModels, set: { $0.newModels = $1 }))
            } header: {
                Text("Alert me when")
            } footer: {
                Text("Shared with Tokenroom on your iPhone through iCloud; a change on either device applies to both. Low balance alerts need a reference or budget in API Keys.")
            }

            Section {
                Toggle("Quiet hours", isOn: binding(get: \.quietHours, set: { $0.quietHours = $1 }))
                if preferences.quietHours {
                    Picker("From", selection: binding(get: \.quietStartHour, set: { $0.quietStartHour = $1 })) {
                        ForEach(0..<24, id: \.self) { Text(Self.hourText($0)).tag($0) }
                    }
                    Picker("Until", selection: binding(get: \.quietEndHour, set: { $0.quietEndHour = $1 })) {
                        ForEach(0..<24, id: \.self) { Text(Self.hourText($0)).tag($0) }
                    }
                }
            } footer: {
                Text("Only 95% alerts and banked resets about to expire come through. The rest wait until quiet hours end.")
            }
        }
        .formStyle(.grouped)
        .task {
            // Pick up changes made on the iPhone.
            _ = await store.currentAlertPreferences()
        }
    }

    private func binding<Value>(get: @escaping (AlertPreferences) -> Value, set: @escaping (inout AlertPreferences, Value) -> Void) -> Binding<Value> {
        Binding(
            get: { get(store.settings.alertPreferences) },
            set: { value in store.updateAlertPreferences { set(&$0, value) } }
        )
    }

    private func binding<Value>(get keyPath: KeyPath<AlertPreferences, Value>, set: @escaping (inout AlertPreferences, Value) -> Void) -> Binding<Value> {
        binding(get: { $0[keyPath: keyPath] }, set: set)
    }

    static func hourText(_ hour: Int) -> String {
        var components = DateComponents()
        components.hour = hour
        let date = Calendar.current.date(from: components) ?? .now
        return date.formatted(date: .omitted, time: .shortened)
    }
}

// MARK: News

private struct NewsSettings: View {
    @Bindable var store: QuotaStore

    var body: some View {
        Form {
            Section {
                Toggle("Check for new models and announcements", isOn: Binding(
                    get: { store.settings.newsEnabled },
                    set: { isOn in
                        store.settings.newsEnabled = isOn
                        if isOn {
                            Task { await store.refreshNews(force: true) }
                        }
                    }
                ))
            } footer: {
                Text("Reads OpenRouter's public model list every 6 hours and official changelogs and blogs every 12. No account, key, or usage is sent. Open News from the popover.")
            }
            if store.settings.newsEnabled, let news = store.news {
                Section("Labs") {
                    ForEach(news.vendorChoices, id: \.id) { vendor in
                        Toggle(vendor.name, isOn: Binding(
                            get: { news.followedVendors.contains(vendor.id) },
                            set: { isOn in
                                if isOn { news.followedVendors.insert(vendor.id) } else { news.followedVendors.remove(vendor.id) }
                            }
                        ))
                    }
                }
                Section {
                    ForEach(FeedSource.toggles) { source in
                        Toggle(source.name, isOn: Binding(
                            get: { news.followedSources.contains(source.id) },
                            set: { isOn in
                                if isOn { news.followedSources.insert(source.id) } else { news.followedSources.remove(source.id) }
                            }
                        ))
                    }
                } header: {
                    Text("Announcements")
                } footer: {
                    Text("Official feeds only. Tokenroom shows titles and links, and opens the rest in your browser.")
                }
            }
        }
        .formStyle(.grouped)
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
    @State private var overrides: [String] = []

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
            if isOn, !overrides.isEmpty {
                Text("\(overrides.count == 1 ? "A project sets" : "\(overrides.count) projects set") its own status line, which replaces the bridge there: \(overrides.joined(separator: ", ")). Tokenroom never edits project settings.")
                    .font(.system(size: 11))
                    .foregroundStyle(TokenroomTokens.tight)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task(id: isOn) {
            guard isOn else {
                overrides = []
                return
            }
            overrides = await BlockingIO.run { ClaudeStatusLineBridge.standard.projectOverrides().map(\.lastPathComponent) }
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
