import SwiftUI

enum SettingsRoute: Hashable {
    case keys
    case alerts
    case widgets
}

struct MobileSettingsView: View {
    @Bindable var store: MobileStore
    @Binding var path: [SettingsRoute]
    @State private var confirmsDelete = false
    @State private var deleteError: String?

    var body: some View {
        NavigationStack(path: $path) {
            Form {
                Section {
                    LabeledContent("iCloud", value: store.relayStatusText)
                    ForEach(store.relaySources) { source in
                        LabeledContent(source.label, value: source.envelope.map { RelativeTime.ago($0.checkedAt) } ?? "Needs a newer Tokenroom")
                    }
                    Toggle("Sample Data", isOn: $store.sampleMode)
                } header: {
                    Text("Readings")
                } footer: {
                    Text("Your Mac sends its readings through your iCloud. Only usage, reset times, and plan names are sent, never logins or keys.")
                }

                Section {
                    NavigationLink(value: SettingsRoute.alerts) {
                        Label("Alerts", systemImage: "bell.badge")
                    }
                    NavigationLink(value: SettingsRoute.keys) {
                        Label("API Keys", systemImage: "key")
                    }
                    NavigationLink(value: SettingsRoute.widgets) {
                        Label("Widgets, Live Activity & Watch", systemImage: "rectangle.stack")
                    }
                } footer: {
                    Text("Read providers right from this iPhone with API keys. Keys stay in its Keychain; they're never synced or sent to your other devices.")
                }

                Section {
                    Button("Delete Tokenroom Data from iCloud", role: .destructive) {
                        confirmsDelete = true
                    }
                    .disabled(store.relayPhase == .unavailable)
                } footer: {
                    Text(deleteError ?? "Removes every Tokenroom reading and history from your iCloud, for all your devices. Keys on this iPhone stay.")
                }

                Section("About") {
                    LabeledContent("Version", value: TokenroomIdentity.version)
                    LabeledContent("Widget updates, last 24 hours", value: "\(WidgetReloadLog.count())")
                    Link("Privacy", destination: TokenroomIdentity.privacyURL)
                    Link("Source Code", destination: TokenroomIdentity.repositoryURL)
                    Text("Tokenroom isn't affiliated with any of the providers it shows.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .navigationDestination(for: SettingsRoute.self) { route in
                switch route {
                case .keys: KeysView(store: store)
                case .alerts: AlertsSettingsView(store: store)
                case .widgets: WidgetsHelpView()
                }
            }
            .confirmationDialog("Delete Tokenroom data from iCloud?", isPresented: $confirmsDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    Task {
                        do {
                            try await store.deleteICloudData()
                            deleteError = nil
                        } catch {
                            deleteError = "Couldn't delete Tokenroom's data from iCloud. Try again later."
                        }
                    }
                }
            } message: {
                Text("Macs with iPhone sync on send fresh readings on their next check.")
            }
        }
    }
}

/// Providers this iPhone can read with a key, grouped like the Mac's settings.
struct KeysView: View {
    @Bindable var store: MobileStore

    private let groups: [(title: String, providers: [Provider])] = [
        ("Coding plans", Provider.allCases.filter { $0.access == .codingPlanKey || $0.descriptor.fallbackKey != nil }),
        ("Pay as you go", Provider.allCases.filter { $0.access == .pastedKey && $0.category == .apiBalance }),
        ("Organization billing", Provider.allCases.filter { $0.category == .orgSpend }),
    ]

    var body: some View {
        List {
            ForEach(groups, id: \.title) { group in
                Section(group.title) {
                    ForEach(group.providers) { provider in
                        NavigationLink {
                            KeyEditorView(store: store, provider: provider)
                        } label: {
                            KeyRowLabel(store: store, provider: provider)
                        }
                    }
                }
            }
        }
        .navigationTitle("API Keys")
    }
}

private struct KeyRowLabel: View {
    var store: MobileStore
    var provider: Provider
    @State private var metadata: APIKeyStore.Metadata?

    var body: some View {
        HStack(spacing: 12) {
            MonogramMark(text: provider.monogram, tint: Color(hex: provider.tintHex), size: 30)
            Text(provider.displayName)
            Spacer()
            Text(metadata.map { "•••• \($0.last4)" } ?? "Add")
                .font(metadata == nil ? .body : .body.monospaced())
                .foregroundStyle(.secondary)
        }
        .task(id: store.keyedProviders) {
            metadata = await store.metadata(for: provider)
        }
    }
}

struct KeyEditorView: View {
    var store: MobileStore
    var provider: Provider
    @Environment(\.dismiss) private var dismiss
    @State private var metadata: APIKeyStore.Metadata?
    @State private var key = ""
    @State private var region: String
    @State private var replacing = false
    @State private var working = false
    @State private var message: String?
    @State private var offerSaveAnyway = false
    @State private var acknowledgedAdmin = false
    @State private var budgetText = ""
    /// Set when the key's test found something to warn about (an xAI key with write access).
    @State private var warning: String?

    init(store: MobileStore, provider: Provider) {
        self.store = store
        self.provider = provider
        _region = State(initialValue: provider.keySpec?.regions.first ?? "")
        _budgetText = State(initialValue: store.budget(for: provider).map { String(format: "%.2f", $0) } ?? "")
    }

    private var spec: KeySpec? { provider.keySpec }

    var body: some View {
        Form {
            if let metadata, !replacing {
                Section {
                    LabeledContent("Key", value: "•••• \(metadata.last4)\(metadata.region.map { " · \($0)" } ?? "")")
                    if let warning = metadata.warning {
                        Label(warning, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(TokenroomTokens.tight)
                    }
                    Button("Replace Key") { replacing = true }
                    Button("Remove Key", role: .destructive) { remove() }
                } footer: {
                    Text("Added \(metadata.addedAt.formatted(date: .abbreviated, time: .omitted)).")
                }
            } else {
                Section {
                    SecureField(spec?.prefixHint.isEmpty == false ? "\(spec!.prefixHint)…" : "Paste your key", text: $key)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(.password)
                    if let regions = spec?.regions, !regions.isEmpty {
                        Picker(spec?.choiceLabel ?? "Account", selection: $region) {
                            ForEach(regions, id: \.self) { Text($0).tag($0) }
                        }
                    }
                    if let url = spec?.createURL {
                        Link("Create a \(spec?.label ?? "key")", destination: url)
                    }
                } header: {
                    Text(spec?.label ?? "API key")
                } footer: {
                    Text(message ?? [spec?.note, "Tokenroom only reads usage, balance, or spend with this key. It stays in this iPhone's Keychain."].compactMap { $0 }.joined(separator: " "))
                }
                if let warning {
                    Section {
                        Label(warning, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(TokenroomTokens.tight)
                    }
                }
                if spec?.isAdmin == true {
                    Section {
                        Text("This is an organization-wide key. It can read and change your organization's settings. Tokenroom only reads cost and billing with it.")
                            .font(.footnote)
                        Toggle("I created a dedicated key I can revoke", isOn: $acknowledgedAdmin)
                    }
                }
                Section {
                    Button(working ? "Testing…" : (warning == nil ? "Test & Save" : "Save With This Key")) {
                        warning == nil ? test() : save()
                    }
                        .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || working || (spec?.isAdmin == true && !acknowledgedAdmin))
                    if offerSaveAnyway {
                        Button("Save Anyway") { save() }
                    }
                }
            }
            if provider.category != .subscription {
                Section {
                    TextField("None", text: $budgetText)
                        .keyboardType(.decimalPad)
                        .onSubmit(saveBudget)
                } header: {
                    Text(provider.category == .orgSpend ? "Monthly budget (\(store.budgetCurrency(for: provider)))" : "Reference (\(store.budgetCurrency(for: provider)))")
                } footer: {
                    Text(provider.category == .orgSpend
                        ? "A budget turns this month's spend into a meter, with alerts at 80% and 95%."
                        : "The amount you topped up to. It turns the balance into a meter, with an alert when it runs low.")
                }
            }
        }
        .navigationTitle(provider.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            metadata = await store.metadata(for: provider)
        }
        .onChange(of: key) { _, _ in
            // A different key needs its own test.
            warning = nil
        }
        .onDisappear(perform: saveBudget)
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
                message = spec?.regions.isEmpty == false
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
        let key = self.key.trimmingCharacters(in: .whitespacesAndNewlines)
        let region = regionValue
        let warning = self.warning
        Task {
            do {
                try await store.saveKey(key, for: provider, region: region, warning: warning)
                dismiss()
            } catch {
                message = "Couldn't save the key in the Keychain."
            }
        }
    }

    private func remove() {
        Task {
            do {
                try await store.removeKey(for: provider)
                metadata = nil
                key = ""
            } catch {
                message = "Couldn't remove the key from the Keychain."
            }
        }
    }

    private func saveBudget() {
        let trimmed = budgetText.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let value = Double(trimmed)
        guard value != store.budget(for: provider) else { return }
        store.setBudget(value, for: provider)
    }
}

/// Where Tokenroom shows up outside the app, and how to add each.
struct WidgetsHelpView: View {
    var body: some View {
        List {
            Section {
                HelpRow(symbol: "square.grid.2x2", title: "Home Screen widgets", text: "Touch and hold the Home Screen, tap Edit, then Add Widget, and search for Tokenroom. Small shows one provider or the most urgent; Medium and Large show several, with a week of history on Large.")
                HelpRow(symbol: "lock.rectangle", title: "Lock Screen widgets", text: "Touch and hold the Lock Screen, tap Customize, then Lock Screen, and add Tokenroom's ring, list, or one-line widget.")
            } header: {
                Text("Widgets")
            }
            Section {
                HelpRow(symbol: "timer", title: "Follow a reset", text: "When a session, or a busy week, resets within 8 hours, open the provider and tap Follow on Lock Screen. A countdown stays on the Lock Screen and in the Dynamic Island until it resets.")
                HelpRow(symbol: "switch.2", title: "Control Center and the Action button", text: "Add the Follow Usage control to Control Center, or assign it to the Action button, to follow the most urgent reset with one press.")
            } header: {
                Text("Live Activity")
            }
            Section {
                HelpRow(symbol: "applewatch", title: "Apple Watch", text: "Install Tokenroom from the Watch app on this iPhone. The Watch reads your iCloud directly, so it keeps working when this iPhone is away. Add a Tokenroom complication to a watch face, and the Smart Stack shows a limit as it nears its reset.")
            }
        }
        .navigationTitle("Widgets & Watch")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct HelpRow: View {
    var symbol: String
    var title: String
    var text: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}
