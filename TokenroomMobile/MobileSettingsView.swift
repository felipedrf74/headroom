import SwiftUI

enum SettingsRoute: Hashable {
    case keys
    case alerts
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
                    NavigationLink("Alerts", value: SettingsRoute.alerts)
                    NavigationLink("API Keys", value: SettingsRoute.keys)
                } footer: {
                    Text("Read providers right from this iPhone. Keys stay in its Keychain; they're never synced or sent to your other devices.")
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
                    Link("Privacy", destination: TokenroomIdentity.repositoryURL.appendingPathComponent("blob/main/PRIVACY.md"))
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
        ("Coding plans", Provider.allCases.filter { $0.access == .codingPlanKey }),
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

    init(store: MobileStore, provider: Provider) {
        self.store = store
        self.provider = provider
        _region = State(initialValue: provider.key?.regions.first ?? "")
        _budgetText = State(initialValue: store.budget(for: provider).map { String(format: "%.2f", $0) } ?? "")
    }

    private var spec: KeySpec? { provider.key }

    var body: some View {
        Form {
            if let metadata, !replacing {
                Section {
                    LabeledContent("Key", value: "•••• \(metadata.last4)\(metadata.region.map { " · \($0)" } ?? "")")
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
                        Picker("Account", selection: $region) {
                            ForEach(regions, id: \.self) { Text($0).tag($0) }
                        }
                    }
                    if let url = spec?.createURL {
                        Link("Create a key", destination: url)
                    }
                } header: {
                    Text(spec?.label ?? "API key")
                } footer: {
                    Text(message ?? "Tokenroom only reads usage, balance, or spend with this key. It stays in this iPhone's Keychain.")
                }
                if spec?.isAdmin == true {
                    Section {
                        Text("This is an organization-wide key. It can read and change your organization's settings. Tokenroom only reads cost and billing with it.")
                            .font(.footnote)
                        Toggle("I created a dedicated key I can revoke", isOn: $acknowledgedAdmin)
                    }
                }
                Section {
                    Button(working ? "Testing…" : "Test & Save") { test() }
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
                    Text(provider.category == .orgSpend ? "Monthly budget (USD)" : "Budget (USD)")
                } footer: {
                    Text("A budget turns a balance or spend into a meter.")
                }
            }
        }
        .navigationTitle(provider.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            metadata = await store.metadata(for: provider)
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
                _ = try await APIKeyClient.snapshot(for: provider, key: key, region: region)
                save()
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
        Task {
            do {
                try await store.saveKey(key, for: provider, region: region)
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
