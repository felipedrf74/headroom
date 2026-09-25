import Foundation
import ServiceManagement

enum MenuBarStyle: String, CaseIterable, Identifiable {
    case percents
    case meters
    /// One glyph and the percent of the most used provider.
    case highest

    var id: String { rawValue }

    var title: String {
        switch self {
        case .percents: "Percents"
        case .meters: "Meters"
        case .highest: "Highest only"
        }
    }
}

@Observable
final class AppSettings {
    var enabled: Set<Provider> {
        didSet { persist() }
    }

    var refreshMinutes: Int {
        didSet { persist() }
    }

    var menuStyle: MenuBarStyle {
        didSet { persist() }
    }

    /// Enabled providers that stay in the popover but out of the menu bar.
    var hiddenFromMenuBar: Set<Provider> {
        didSet { persist() }
    }

    /// Dollar budgets that turn spend and balances into meters.
    var budgets: [Provider: Double] {
        didSet { persist() }
    }

    var launchAtLogin: Bool {
        didSet { applyLaunchAtLogin() }
    }

    /// Usage alerts as notifications on this Mac too. The iPhone gets them either way.
    var showsAlertsOnMac: Bool {
        didSet { persist() }
    }

    /// Opt-in: check OpenRouter's public model list and official changelogs for the News window.
    var newsEnabled: Bool {
        didSet { persist() }
    }

    /// This Mac's copy of the alert preferences. Either device can change them; the newer copy
    /// in iCloud wins.
    var alertPreferences: AlertPreferences {
        didSet { persist() }
    }

    private var applyingLogin = false

    var refreshInterval: TimeInterval {
        TimeInterval(refreshMinutes * 60)
    }

    private let defaults: UserDefaults
    private var isReady = false
    /// Choices a newer Tokenroom saved for providers this one doesn't know, kept as they were so
    /// going back to that version finds them intact.
    @ObservationIgnored private var foreign = ForeignChoices()

    private struct ForeignChoices {
        var enabled: [String] = []
        var known: [String] = []
        var hidden: [String] = []
        var budgets: [String: Double] = [:]
    }
    /// Providers these settings hadn't seen before this launch, so detection can turn them on.
    private(set) var newlyKnown: [Provider] = []

    enum Keys {
        static let version = "settingsVersion"
        static let enabled = "enabledProviders"
        static let known = "knownProviders"
        static let refreshMinutes = "refreshMinutes"
        static let menuStyle = "menuStyle"
        static let hiddenFromMenuBar = "menuBarHidden"
        static let budgets = "budgets"
        static let alertsOnMac = "alertsOnMac"
        static let newsEnabled = "newsEnabled"
        static let alertPreferences = "alertPreferences"
    }

    static let currentVersion = 2

    /// - Parameter detectsSession: whether a provider this install has never seen already has a
    ///   local session. Such providers start enabled; others wait in Settings.
    init(defaults: UserDefaults = .standard, detectsSession: (Provider) -> Bool = { _ in false }) {
        self.defaults = defaults
        enabled = Self.resolveEnabled(defaults: defaults, detectsSession: detectsSession)
        newlyKnown = Self.unknownProviders(defaults: defaults)
        let minutes = defaults.object(forKey: Keys.refreshMinutes) as? Int ?? 10
        refreshMinutes = [5, 10, 15, 30].contains(minutes) ? minutes : 10
        if let raw = defaults.string(forKey: Keys.menuStyle), let style = MenuBarStyle(rawValue: raw) {
            menuStyle = style
        } else {
            menuStyle = .meters
        }
        hiddenFromMenuBar = Set((defaults.array(forKey: Keys.hiddenFromMenuBar) as? [String] ?? []).compactMap(Provider.init(rawValue:)))
        var budgets: [Provider: Double] = [:]
        for (key, value) in defaults.dictionary(forKey: Keys.budgets) as? [String: Double] ?? [:] {
            if let provider = Provider(rawValue: key), value > 0 {
                budgets[provider] = value
            }
        }
        self.budgets = budgets
        showsAlertsOnMac = defaults.bool(forKey: Keys.alertsOnMac)
        newsEnabled = defaults.bool(forKey: Keys.newsEnabled)
        alertPreferences = defaults.data(forKey: Keys.alertPreferences)
            .flatMap { try? RelayEnvelope.decoder.decode(AlertPreferences.self, from: $0) } ?? AlertPreferences()
        launchAtLogin = SMAppService.mainApp.status == .enabled
        foreign = ForeignChoices(
            enabled: Self.foreignIDs(defaults.array(forKey: Keys.enabled)),
            known: Self.foreignIDs(defaults.array(forKey: Keys.known)),
            hidden: Self.foreignIDs(defaults.array(forKey: Keys.hiddenFromMenuBar)),
            budgets: (defaults.dictionary(forKey: Keys.budgets) as? [String: Double] ?? [:]).filter { Provider(rawValue: $0.key) == nil }
        )
        isReady = true
        persist()
    }

    func budget(for provider: Provider) -> Double? {
        budgets[provider]
    }

    func setBudget(_ value: Double?, for provider: Provider) {
        if let value, value > 0 {
            budgets[provider] = value
        } else {
            budgets.removeValue(forKey: provider)
        }
    }

    func showsInMenuBar(_ provider: Provider) -> Bool {
        !hiddenFromMenuBar.contains(provider)
    }

    func setShowsInMenuBar(_ provider: Provider, _ isOn: Bool) {
        if isOn {
            hiddenFromMenuBar.remove(provider)
        } else {
            hiddenFromMenuBar.insert(provider)
        }
    }

    /// The saved list is authoritative for every provider the saved settings already knew,
    /// including an empty list. Only providers the settings never saw get default handling.
    private static func resolveEnabled(defaults: UserDefaults, detectsSession: (Provider) -> Bool) -> Set<Provider> {
        let saved = (defaults.array(forKey: Keys.enabled) as? [String]).map {
            Set($0.compactMap(Provider.init(rawValue:)))
        }
        let known: Set<Provider>
        if defaults.integer(forKey: Keys.version) >= 2 {
            known = Set((defaults.array(forKey: Keys.known) as? [String] ?? []).compactMap(Provider.init(rawValue:)))
        } else if saved != nil {
            // Version 1 stored only the enabled list; it knew Headroom 1.x's providers.
            known = Provider.legacy
        } else {
            known = []
        }
        var enabled = saved ?? []
        for provider in Provider.allCases where !known.contains(provider) {
            // Organization keys can change billing and settings: they're only turned on by hand.
            guard provider.category != .orgSpend else { continue }
            if provider.enabledByDefault || detectsSession(provider) {
                enabled.insert(provider)
            }
        }
        return enabled
    }

    private static func foreignIDs(_ saved: [Any]?) -> [String] {
        (saved as? [String] ?? []).filter { Provider(rawValue: $0) == nil }
    }

    /// Providers the saved settings never knew, before this launch saves them as known.
    private static func unknownProviders(defaults: UserDefaults) -> [Provider] {
        if defaults.integer(forKey: Keys.version) >= 2 {
            let known = Set((defaults.array(forKey: Keys.known) as? [String] ?? []).compactMap(Provider.init(rawValue:)))
            return Provider.allCases.filter { !known.contains($0) }
        }
        if defaults.array(forKey: Keys.enabled) != nil {
            return Provider.allCases.filter { !Provider.legacy.contains($0) }
        }
        return Provider.allCases
    }

    /// Turns on providers new to this install that turned out to have a session on this Mac.
    /// Organization keys never turn on by themselves.
    func enableDetected(_ providers: Set<Provider>) {
        for provider in newlyKnown where providers.contains(provider) && provider.category != .orgSpend {
            enabled.insert(provider)
        }
        newlyKnown = []
    }

    func isEnabled(_ provider: Provider) -> Bool {
        enabled.contains(provider)
    }

    func setEnabled(_ provider: Provider, _ isOn: Bool) {
        if isOn {
            enabled.insert(provider)
        } else {
            enabled.remove(provider)
        }
    }

    private func persist() {
        guard isReady else { return }
        defaults.set(Self.currentVersion, forKey: Keys.version)
        defaults.set((enabled.map(\.rawValue) + foreign.enabled).sorted(), forKey: Keys.enabled)
        defaults.set((Provider.allCases.map(\.rawValue) + foreign.known).sorted(), forKey: Keys.known)
        defaults.set(refreshMinutes, forKey: Keys.refreshMinutes)
        defaults.set(menuStyle.rawValue, forKey: Keys.menuStyle)
        defaults.set((hiddenFromMenuBar.map(\.rawValue) + foreign.hidden).sorted(), forKey: Keys.hiddenFromMenuBar)
        defaults.set(Dictionary(uniqueKeysWithValues: budgets.map { ($0.key.rawValue, $0.value) }).merging(foreign.budgets) { mine, _ in mine }, forKey: Keys.budgets)
        defaults.set(showsAlertsOnMac, forKey: Keys.alertsOnMac)
        defaults.set(newsEnabled, forKey: Keys.newsEnabled)
        if let data = try? RelayEnvelope.encoder.encode(alertPreferences) {
            defaults.set(data, forKey: Keys.alertPreferences)
        }
    }

    private func applyLaunchAtLogin() {
        guard !applyingLogin else { return }
        do {
            if launchAtLogin {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            applyingLogin = true
            launchAtLogin = SMAppService.mainApp.status == .enabled
            applyingLogin = false
        }
    }
}
