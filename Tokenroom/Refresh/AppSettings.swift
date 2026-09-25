import Foundation
import ServiceManagement

enum MenuBarStyle: String, CaseIterable, Identifiable {
    case percents
    case meters

    var id: String { rawValue }

    var title: String {
        switch self {
        case .percents: "Percents"
        case .meters: "Meters"
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

    var launchAtLogin: Bool {
        didSet { applyLaunchAtLogin() }
    }

    private var applyingLogin = false

    var refreshInterval: TimeInterval {
        TimeInterval(refreshMinutes * 60)
    }

    private let defaults: UserDefaults
    private var isReady = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var enabledProviders = Set(Provider.allCases)
        if let raw = defaults.array(forKey: "enabledProviders") as? [String] {
            let parsed = Set(raw.compactMap(Provider.init(rawValue:)))
            if !parsed.isEmpty {
                enabledProviders = parsed
                if !raw.contains(Provider.grokBot.rawValue) {
                    enabledProviders.insert(.grokBot)
                }
            }
        }
        enabled = enabledProviders
        let minutes = defaults.object(forKey: "refreshMinutes") as? Int ?? 10
        refreshMinutes = [5, 10, 15, 30].contains(minutes) ? minutes : 10
        if let raw = defaults.string(forKey: "menuStyle"), let style = MenuBarStyle(rawValue: raw) {
            menuStyle = style
        } else {
            menuStyle = .meters
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
        isReady = true
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
        defaults.set(enabled.map(\.rawValue).sorted(), forKey: "enabledProviders")
        defaults.set(refreshMinutes, forKey: "refreshMinutes")
        defaults.set(menuStyle.rawValue, forKey: "menuStyle")
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
