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

    var launchAtLogin: Bool {
        didSet { applyLaunchAtLogin() }
    }

    private var applyingLogin = false

    var refreshInterval: TimeInterval {
        TimeInterval(refreshMinutes * 60)
    }

    private let defaults: UserDefaults
    private var isReady = false

    enum Keys {
        static let version = "settingsVersion"
        static let enabled = "enabledProviders"
        static let known = "knownProviders"
        static let refreshMinutes = "refreshMinutes"
        static let menuStyle = "menuStyle"
        static let hiddenFromMenuBar = "menuBarHidden"
    }

    static let currentVersion = 2

    /// - Parameter detectsSession: whether a provider this install has never seen already has a
    ///   local session. Such providers start enabled; others wait in Settings.
    init(defaults: UserDefaults = .standard, detectsSession: (Provider) -> Bool = { _ in false }) {
        self.defaults = defaults
        enabled = Self.resolveEnabled(defaults: defaults, detectsSession: detectsSession)
        let minutes = defaults.object(forKey: Keys.refreshMinutes) as? Int ?? 10
        refreshMinutes = [5, 10, 15, 30].contains(minutes) ? minutes : 10
        if let raw = defaults.string(forKey: Keys.menuStyle), let style = MenuBarStyle(rawValue: raw) {
            menuStyle = style
        } else {
            menuStyle = .meters
        }
        hiddenFromMenuBar = Set((defaults.array(forKey: Keys.hiddenFromMenuBar) as? [String] ?? []).compactMap(Provider.init(rawValue:)))
        launchAtLogin = SMAppService.mainApp.status == .enabled
        isReady = true
        persist()
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
            if provider.enabledByDefault || detectsSession(provider) {
                enabled.insert(provider)
            }
        }
        return enabled
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
        defaults.set(enabled.map(\.rawValue).sorted(), forKey: Keys.enabled)
        defaults.set(Provider.allCases.map(\.rawValue).sorted(), forKey: Keys.known)
        defaults.set(refreshMinutes, forKey: Keys.refreshMinutes)
        defaults.set(menuStyle.rawValue, forKey: Keys.menuStyle)
        defaults.set(hiddenFromMenuBar.map(\.rawValue).sorted(), forKey: Keys.hiddenFromMenuBar)
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
