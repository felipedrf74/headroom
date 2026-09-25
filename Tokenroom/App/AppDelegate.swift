import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let store: QuotaStore
    private var statusItem: StatusItemController?
    private var settingsWindow: NSWindow?
    private var newsWindow: NSWindow?
    /// Set before Settings opens to show a tab other than the last one.
    let settingsTab = SettingsTabRequest()

    override init() {
        // Headroom 1.x settings and cache must be in place before the store reads them.
        LegacyMigration.runIfNeeded()
        // Sessions for providers new to this install are looked for after launch, off the main
        // thread: they mean file, database, and Keychain reads.
        store = QuotaStore(
            settings: AppSettings(),
            relay: RelayPublisher(),
            news: NewsStore(defaults: .standard, directory: SnapshotCache.defaultDirectory),
            showsLegacyNotice: LegacyMigration.shouldShowNotice()
        )
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if DebugSnapshots.runIfRequested() {
            NSApp.terminate(nil)
            return
        }
        #endif
        store.signIn.onAddKey = { [weak self] provider in
            self?.store.pendingKeyProvider = provider
            self?.openSettings()
        }
        let candidates = store.settings.newlyKnown.filter { !$0.enabledByDefault }
        if !candidates.isEmpty {
            Task { [store] in
                let detected = await BlockingIO.run { Set(candidates.filter { CredentialReaders.hasSession($0) }) }
                store.settings.enableDetected(detected)
                if !detected.isEmpty {
                    await store.refresh(force: true, providers: Array(detected))
                }
            }
        }
        store.start()
        statusItem = StatusItemController(store: store, onSettings: { [weak self] in
            self?.openSettings()
        }, onNews: { [weak self] section in
            self?.openNews(section)
        })
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if settingsWindow?.isVisible == true {
            settingsWindow?.makeKeyAndOrderFront(nil)
            return false
        }
        if newsWindow?.isVisible == true {
            newsWindow?.makeKeyAndOrderFront(nil)
            return false
        }
        statusItem?.showPopover()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.stop()
    }

    func openSettings(tab: SettingsTab? = nil) {
        statusItem?.closePopover()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        if let tab {
            settingsTab.tab = tab
        }
        if settingsWindow == nil {
            let hosting = NSHostingController(rootView: SettingsView(store: store, request: settingsTab))
            let window = NSWindow(contentViewController: hosting)
            window.title = "Tokenroom Settings"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.setContentSize(NSSize(width: 600, height: 640))
            window.isReleasedWhenClosed = false
            window.hidesOnDeactivate = false
            window.delegate = self
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    /// The News window, on the given section. Opening it clears the popover's news counts.
    func openNews(_ section: NewsSection) {
        statusItem?.closePopover()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        UserDefaults.standard.set(section.rawValue, forKey: NewsSection.defaultsKey)
        if newsWindow == nil {
            let view = NewsWindowView(store: store) { [weak self] in
                self?.openSettings(tab: .news)
            }
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "News"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 520, height: 640))
            window.isReleasedWhenClosed = false
            window.hidesOnDeactivate = false
            window.delegate = self
            window.center()
            newsWindow = window
        }
        store.news?.markSeen()
        newsWindow?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing === settingsWindow || closing === newsWindow else { return }
        // Back to a menu-bar extra once no window is left.
        let others = [settingsWindow, newsWindow].compactMap { $0 }.filter { $0 !== closing && $0.isVisible }
        if others.isEmpty {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
