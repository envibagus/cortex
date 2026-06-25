import AppKit
import SwiftUI
import Observation

// MARK: - MenuBarController
//
// Owns the NSStatusItem + the click-to-open panel + the global hotkey. It holds no state
// of its own: it renders AppModel's usage / activity / preferences into the status-item
// button and hosts the SwiftUI MenuBarPanel in an NSPopover. An NSStatusItem (not a
// SwiftUI MenuBarExtra) is used deliberately so the icon can be a custom-drawn ring/bars
// image and so the panel can be opened programmatically from the global hotkey.

@MainActor
final class MenuBarController: NSObject {
    private unowned let model: AppModel
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var hotKey: HotKey?
    private var tickTimer: Timer?

    init(model: AppModel) {
        self.model = model
        super.init()
    }

    // MARK: Lifecycle

    func start() {
        applyVisibility(model.showMenuBarItem)
        applyHotKey(model.menuBarHotKey)
        // First usage probe so the bar shows numbers (and the one-time keychain grant
        // happens here for the menu-bar user).
        Task { await model.usage.load() }
        beginObserving()
        // Re-tint the drawn ring/bars when the system appearance flips.
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.render() }
        }
    }

    /// Show or hide the status item live (driven by the "Show in menu bar" preference).
    func applyVisibility(_ visible: Bool) {
        if visible {
            guard statusItem == nil else { return }
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.button?.target = self
            item.button?.action = #selector(handleClick(_:))
            // Fire on both buttons so we can route left-click to the panel and
            // right-click (or Control-click) to the context menu.
            item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
            item.button?.setAccessibilityIdentifier("cortex-menubar")
            statusItem = item
            render()
        } else {
            stopTimer()
            if let item = statusItem { NSStatusBar.system.removeStatusItem(item) }
            statusItem = nil
        }
    }

    /// (Re)register the global hotkey, or clear it when nil.
    func applyHotKey(_ combo: HotKeyCombo?) {
        hotKey = nil
        guard let combo else { return }
        hotKey = HotKey(combo: combo) { [weak self] in
            Task { @MainActor in self?.togglePanel(nil) }
        }
    }

    func closePanel() { popover.performClose(nil) }

    // MARK: Rendering

    /// Render once and re-register for the next change. AppModel is @Observable, so
    /// reading its usage / activity / preferences inside the tracked closure means any
    /// change re-invokes this and repaints the button.
    private func beginObserving() {
        withObservationTracking {
            render()
        } onChange: { [weak self] in
            Task { @MainActor in self?.beginObserving() }
        }
    }

    private func render() {
        // Touch the observables we depend on first, so observation re-arms even while the
        // status item is hidden (a later "Show in menu bar" toggle then repaints live).
        _ = (model.menuBarLiveActivityEnabled,
             model.menuBarIconMode, model.menuBarUsageMode, model.menuBarPrimaryWindow,
             model.activity.current, model.usage.providers.count)

        guard let button = statusItem?.button else { return }
        let appearance = button.effectiveAppearance
        let act = model.activity.current
        // Live activity is shown ALONGSIDE the usage readout, never replacing it: the
        // icon still reflects usage, and the activity label + timer trail the title.
        let live = model.menuBarLiveActivityEnabled && act.isActive

        switch model.menuBarIconMode {
        case .text:
            // Lead with a state glyph while active (yellow dot when awaiting permission,
            // green check on the "Done" flash), but keep the usage % in the title.
            button.image = leadingImage(live: live, act: act)
            button.imagePosition = .imageLeading
            button.attributedTitle = composedTitle(usage: usageSegment(primaryMetric()), activity: live ? act : nil)
        case .donut:
            button.image = MenuBarIcon.donut(percent: primaryMetric()?.percent ?? 0, appearance: appearance)
            applyImageTitle(button, live: live, act: act)
        case .bars:
            button.image = MenuBarIcon.bars(session: metricPercent(.session),
                                            weekly: metricPercent(.weekly),
                                            appearance: appearance)
            applyImageTitle(button, live: live, act: act)
        case .both:
            button.image = MenuBarIcon.both(session: metricPercent(.session),
                                            weekly: metricPercent(.weekly),
                                            mode: model.menuBarUsageMode,
                                            appearance: appearance)
            applyImageTitle(button, live: live, act: act)
        }

        if live { startTimer() } else { stopTimer() }
    }

    /// For the image-based modes (ring / bars / both): the image alone when idle, or the
    /// image plus the trailing activity label while a turn is running.
    private func applyImageTitle(_ button: NSStatusBarButton, live: Bool, act: ClaudeActivity) {
        if live {
            button.imagePosition = .imageLeading
            button.attributedTitle = activitySegment(act)
        } else {
            button.imagePosition = .imageOnly
            button.attributedTitle = NSAttributedString(string: "")
        }
    }

    /// The usage portion of the title: the chosen window's percent (used/left aware),
    /// orange once mostly spent. "--%" until the probe lands.
    private func usageSegment(_ metric: UsageMetric?) -> (text: String, color: NSColor) {
        if let metric {
            return (UsageDisplay.barLabel(metric.percent, mode: model.menuBarUsageMode),
                    metric.percent >= 75 ? .systemOrange : .labelColor)
        }
        return ("--%", .secondaryLabelColor)
    }

    /// The leading image for text mode: usage glyph when idle; while live, the activity
    /// glyph, a yellow dot when awaiting permission, or a green check on the Done flash.
    private func leadingImage(live: Bool, act: ClaudeActivity) -> NSImage? {
        guard live else { return MenuBarIcon.glyph("sparkle") }
        switch act.state {
        case .awaitingPermission: return MenuBarIcon.coloredDot(.systemYellow)
        case .done: return MenuBarIcon.tintedGlyph("checkmark.circle.fill", color: .systemGreen)
        default: return MenuBarIcon.glyph(ActivityLabels.symbol(for: act.state, tool: act.tool))
        }
    }

    /// White-on-green badge attributes for the "Done" flash (the attention grab).
    private static func doneBadgeAttributes() -> [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: 13, weight: .semibold),
         .foregroundColor: NSColor.white,
         .backgroundColor: NSColor.systemGreen]
    }

    /// Text-mode title: the usage percent, plus " · <activity> <timer>" while active (or
    /// a green "Done" badge on completion).
    private func composedTitle(usage: (text: String, color: NSColor), activity: ClaudeActivity?) -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        let result = NSMutableAttributedString(
            string: " " + usage.text,
            attributes: [.font: font, .foregroundColor: usage.color])
        guard let act = activity else { return result }
        if act.state == .done {
            result.append(NSAttributedString(string: "  Done  ", attributes: Self.doneBadgeAttributes()))
        } else {
            var trailing = "  \u{00B7} " + act.label
            if let start = act.turnStartedAt { trailing += " " + MenuBarController.elapsed(since: start) }
            // Awaiting permission is signalled by the yellow dot, so keep the label legible.
            let color: NSColor = act.state == .awaitingPermission ? .labelColor : .secondaryLabelColor
            result.append(NSAttributedString(string: trailing, attributes: [.font: font, .foregroundColor: color]))
        }
        return result
    }

    /// The trailing activity label + timer used by the image-based modes (or the green
    /// "Done" badge on completion).
    private func activitySegment(_ act: ClaudeActivity) -> NSAttributedString {
        if act.state == .done {
            return NSAttributedString(string: "  Done  ", attributes: Self.doneBadgeAttributes())
        }
        var text = " " + act.label
        if let start = act.turnStartedAt { text += " " + MenuBarController.elapsed(since: start) }
        let color: NSColor = act.state == .awaitingPermission ? .systemOrange : .labelColor
        return NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: color,
        ])
    }

    /// Claude's metrics from the latest probe (empty unless the probe is `.ok`).
    private func claudeMetrics() -> [UsageMetric] {
        if case let .ok(_, metrics) = model.usage.providers.first(where: { $0.id == .claude })?.result {
            return metrics
        }
        return []
    }

    private func metricPercent(_ window: UsageWindow) -> Double? {
        claudeMetrics().first { $0.label == window.metricLabel }?.percent
    }

    private func primaryMetric() -> UsageMetric? {
        claudeMetrics().first { $0.label == model.menuBarPrimaryWindow.metricLabel }
    }

    /// "0:25" / "12s" elapsed since a turn began (shared with the panel's live timer).
    static func elapsed(since: Date) -> String {
        let total = Int(max(0, Date().timeIntervalSince(since)))
        let minutes = total / 60
        let seconds = total % 60
        return minutes > 0 ? "\(minutes):\(String(format: "%02d", seconds))" : "\(seconds)s"
    }

    // MARK: Turn timer (ticks the elapsed time while active)

    private func startTimer() {
        guard tickTimer == nil else { return }
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.render() }
        }
    }

    private func stopTimer() {
        tickTimer?.invalidate()
        tickTimer = nil
    }

    // MARK: Click routing

    /// Left-click opens the usage panel; right-click (or Control-click) opens the
    /// context menu (Open / Quit).
    @objc private func handleClick(_ sender: Any?) {
        let event = NSApp.currentEvent
        let isRight = event?.type == .rightMouseUp || (event?.modifierFlags.contains(.control) ?? false)
        if isRight {
            showContextMenu()
        } else {
            togglePanel(sender)
        }
    }

    /// A minimal right-click menu: open the main window or quit the app.
    private func showContextMenu() {
        guard let button = statusItem?.button else { return }
        if popover.isShown { popover.performClose(nil) } // don't overlap the menu

        let menu = NSMenu()
        let open = NSMenuItem(title: "Open Cortex", action: #selector(menuOpen), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Cortex", action: #selector(menuQuit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        // Anchor the menu just below the status item (does not touch statusItem.menu, so
        // the left-click panel action stays intact).
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 5), in: button)
    }

    @objc private func menuOpen() { model.revealMainWindow() }
    @objc private func menuQuit() { NSApp.terminate(nil) }

    // MARK: Panel

    @objc private func togglePanel(_ sender: Any?) {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            if popover.contentViewController == nil {
                let host = NSHostingController(rootView: MenuBarPanel().environment(model))
                host.sizingOptions = .preferredContentSize
                popover.contentViewController = host
                popover.behavior = .transient
                popover.animates = true
            }
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }
}
