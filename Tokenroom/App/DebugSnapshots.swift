#if DEBUG
import AppKit
import SwiftUI

/// `-TokenroomSnapshots <folder>`: renders the popover, Settings, and News with sample data to
/// PNGs, then quits. For README images and layout checks. It uses its own settings and a
/// throwaway folder, so real readings, keys, and settings are never read or changed.
/// `-TokenroomSnapshotNews <news.json>` adds a saved News cache.
@MainActor
enum DebugSnapshots {
    static func runIfRequested() -> Bool {
        guard let path = UserDefaults.standard.string(forKey: "TokenroomSnapshots") else { return false }
        let output = URL(fileURLWithPath: path, isDirectory: true)
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: output, withIntermediateDirectories: true)
        let scratch = fileManager.temporaryDirectory.appendingPathComponent("TokenroomSnapshots-\(UUID().uuidString)", isDirectory: true)
        try? fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: scratch) }

        let now = Date()
        let samples = SampleData.snapshots(now: now)
        var weeks: [String: UsageHistory] = [:]
        for snapshot in samples {
            for (window, week) in SampleData.history(for: snapshot, now: now) {
                weeks[RelayHistory.key(provider: snapshot.provider.rawValue, window: window)] = week
            }
        }
        if let data = try? RelayEnvelope.encoder.encode(weeks) {
            try? data.write(to: scratch.appendingPathComponent(HistoryStore.fileName))
        }
        if let news = UserDefaults.standard.string(forKey: "TokenroomSnapshotNews") {
            try? fileManager.copyItem(at: URL(fileURLWithPath: news), to: scratch.appendingPathComponent(NewsCache.fileName))
        }

        let suite = "TokenroomSnapshots-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { return true }
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let disconnected: [Provider] = [.devin, .antigravity]
        for provider in Provider.allCases {
            settings.setEnabled(provider, samples.contains { $0.provider == provider } || disconnected.contains(provider))
        }
        settings.newsEnabled = true
        settings.showsAlertsOnMac = true
        settings.setBudget(1000, for: .anthropicOrg)
        let news = NewsStore(defaults: defaults, directory: scratch, now: now.addingTimeInterval(-2 * 86_400))
        let store = QuotaStore(settings: settings, clients: [], cache: SnapshotCache(directory: scratch), relay: nil, news: news)
        for snapshot in samples {
            store.statuses[snapshot.provider] = .live(snapshot)
            store.checkedAt[snapshot.provider] = now.addingTimeInterval(-120)
        }
        for provider in disconnected {
            store.statuses[provider] = .signedOut(provider.signInHint)
        }
        store.lastAttempt = now.addingTimeInterval(-60)

        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let suffix = appearance == .aqua ? "" : "-dark"
            render(PopoverView(store: store, onSettings: {}), width: TokenroomTokens.popoverWidth, appearance: appearance, to: output.appendingPathComponent("popover\(suffix).png"))
            render(PopoverView(store: store, onSettings: {}, expanded: [.openai, .deepseek]), width: TokenroomTokens.popoverWidth, appearance: appearance, to: output.appendingPathComponent("popover-expanded\(suffix).png"))
        }
        for tab in [SettingsTab.general, .providers, .keys, .alerts, .news, .menuBar] {
            let request = SettingsTabRequest()
            request.tab = tab
            render(SettingsView(store: store, request: request), width: 600, height: 640, appearance: .aqua, to: output.appendingPathComponent("settings-\(tab.rawValue).png"))
        }
        render(NewsWindowView(store: store, onOpenSettings: {}), width: 520, height: 640, appearance: .aqua, to: output.appendingPathComponent("news.png"))

        // The menu bar in each style, on a light and a dark bar. A few providers, as people keep it.
        let meters = store.menuMeters.filter { [.claude, .openai, .cursor, .copilot].contains($0.provider) }
        for style in MenuBarStyle.allCases {
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                let suffix = appearance == .aqua ? "" : "-dark"
                let bar = MenuBarLabel(meters: meters, style: style)
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                    .background(appearance == .aqua ? Color(white: 0.93) : Color(white: 0.16))
                render(bar, width: nil, height: 24, appearance: appearance, to: output.appendingPathComponent("menubar-\(style.rawValue)\(suffix).png"))
            }
        }
        return true
    }

    private static func render<Content: View>(_ view: Content, width: CGFloat?, height: CGFloat? = nil, appearance: NSAppearance.Name, to url: URL) {
        let hosting = NSHostingView(rootView: view
            .frame(width: width, height: height)
            .background(Color(nsColor: .windowBackgroundColor)))
        hosting.appearance = NSAppearance(named: appearance)
        let fitting = hosting.fittingSize
        let size = NSSize(width: width ?? fitting.width, height: height ?? fitting.height)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = hosting
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
        // One turn of the run loop so lists and layout settle.
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        // Twice the points, for Retina screens.
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return }
        rep.size = size
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
#endif
