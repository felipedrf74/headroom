import AppKit
import SwiftUI

private final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
final class StatusItemController: NSObject {
    private let store: QuotaStore
    private let onSettings: () -> Void
    private let item: NSStatusItem
    private let popover = NSPopover()
    private var hosting: PassthroughHostingView<MenuBarLabel>?
    private var lastMeters: [MenuMeter] = []
    private var lastStyle: MenuBarStyle?
    private var renderTask: Task<Void, Never>?
    private var localClickMonitor: Any?
    private var globalClickMonitor: Any?

    init(store: QuotaStore, onSettings: @escaping () -> Void) {
        self.store = store
        self.onSettings = onSettings
        self.item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        item.autosaveName = "Headroom"
        item.isVisible = true

        let content = NSHostingController(
            rootView: PopoverView(store: store, onSettings: { [weak self] in
                self?.closePopover()
                onSettings()
            })
        )
        content.sizingOptions = [.preferredContentSize]
        popover.behavior = .applicationDefined
        popover.animates = true
        popover.contentViewController = content
        popover.delegate = self

        if let button = item.button {
            button.image = nil
            button.title = ""
            button.imagePosition = .noImage
            button.toolTip = "Headroom"
            button.target = self
            button.action = #selector(togglePopover)
            button.sendAction(on: [.leftMouseUp])
        }

        let hosted = PassthroughHostingView(rootView: MenuBarLabel(meters: []))
        hosted.translatesAutoresizingMaskIntoConstraints = true
        item.button?.addSubview(hosted)
        hosting = hosted

        render()
        observe()
    }

    private func observe() {
        withObservationTracking {
            _ = store.menuMeters
            _ = store.settings.menuStyle
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.scheduleRender()
                self?.observe()
            }
        }
    }

    private func scheduleRender() {
        renderTask?.cancel()
        renderTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
            guard !Task.isCancelled else { return }
            render()
        }
    }

    private func render() {
        guard let button = item.button, let hosting else { return }
        let meters = store.menuMeters
        let style = store.settings.menuStyle
        if meters == lastMeters, style == lastStyle {
            return
        }
        lastMeters = meters
        lastStyle = style
        hosting.rootView = MenuBarLabel(meters: meters, style: style)
        hosting.layoutSubtreeIfNeeded()
        let fitted = hosting.fittingSize
        let height = max(button.bounds.height, 22)
        let width = max(ceil(fitted.width), 36)
        let drawHeight = min(max(fitted.height, 1), height)
        hosting.frame = NSRect(
            x: 0,
            y: ((height - drawHeight) / 2).rounded(.toNearestOrAwayFromZero),
            width: width,
            height: drawHeight
        )
        item.length = width
        button.toolTip = MenuBarLayout.tooltip(for: meters)
    }

    @objc
    private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            closePopover()
        } else {
            showPopover()
        }
    }

    func closePopover() {
        stopClickMonitors()
        if popover.isShown {
            popover.performClose(nil)
        }
    }

    func showPopover() {
        guard item.button != nil else { return }
        NSApp.activate()
        // The mouse-up that opened the extra must finish first, or AppKit
        // treats it as a click outside and closes the popover immediately.
        DispatchQueue.main.async { [weak self] in
            guard let self, let button = self.item.button else { return }
            self.popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            self.startClickMonitors()
        }
    }

    private func startClickMonitors() {
        stopClickMonitors()
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.closeIfClickOutside()
            return event
        }
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            self?.closeIfClickOutside()
        }
    }

    private func stopClickMonitors() {
        if let localClickMonitor {
            NSEvent.removeMonitor(localClickMonitor)
            self.localClickMonitor = nil
        }
        if let globalClickMonitor {
            NSEvent.removeMonitor(globalClickMonitor)
            self.globalClickMonitor = nil
        }
    }

    private func closeIfClickOutside() {
        guard popover.isShown else { return }
        let point = NSEvent.mouseLocation
        if let popoverWindow = popover.contentViewController?.view.window,
           popoverWindow.frame.contains(point) {
            return
        }
        if let button = item.button, let statusWindow = button.window {
            let buttonRect = button.convert(button.bounds, to: nil)
            if statusWindow.convertToScreen(buttonRect).contains(point) {
                return
            }
        }
        closePopover()
    }
}

extension StatusItemController: NSPopoverDelegate {
    nonisolated func popoverDidClose(_ notification: Notification) {
        Task { @MainActor in
            stopClickMonitors()
        }
    }
}
