import AppKit
import SwiftUI
import Observation
import QuartzCore

// MARK: - MenuBarController
//
// Owns the NSStatusItem + the click-to-open panel + the global hotkey. It holds no state
// of its own: it renders AppModel's usage / activity / preferences into the status-item
// button and hosts the SwiftUI MenuBarPanel in a borderless KeyablePanel window (no popover
// arrow; click-outside dismissal is wired by hand). An NSStatusItem (not a SwiftUI
// MenuBarExtra) is used deliberately so the icon can be a custom-drawn ring/bars image and so
// the panel can be opened programmatically from the global hotkey.

@MainActor
final class MenuBarController: NSObject {
    private unowned let model: AppModel
    private var statusItem: NSStatusItem?
    // The button's effectiveAppearance isn't the menu bar's until it's placed, so the
    // first paint after (re)enabling can draw the adaptive (labelColor) parts dark. We
    // observe it and repaint once it resolves / changes.
    private var appearanceObservation: NSKeyValueObservation?
    // The dropdown is a borderless rounded panel, not an NSPopover: NSPopover forces an arrow
    // whose material we can't match the body, and we want full control over click-outside
    // dismissal. nil while closed.
    private var panelWindow: NSPanel?
    private var panelHost: NSHostingController<AnyView>?
    private var panelSizeObservation: NSKeyValueObservation?
    private var panelDismissMonitor: Any?
    private var panelResignObserver: NSObjectProtocol?
    private weak var panelAnchorButton: NSStatusBarButton?
    // When the panel last closed, so the same status-item click that dismisses it (via resign
    // / the outside-click monitor) doesn't immediately reopen it through the toggle.
    private var lastPanelDismiss: Date?
    private var hotKey: HotKey?
    private var tickTimer: Timer?
    // Turn-complete celebration: a one-shot confetti burst shown in place of a "Done"
    // label. `wasCelebrating` debounces it to fire once per transition into `.done`.
    private let confetti = ConfettiOverlay()
    private var wasCelebrating = false

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
            // Plain creation with the system-managed default autosave identity. Do NOT set
            // `autosaveName` (or force `isVisible`) here: on macOS 26 renaming a status
            // item's autosave name after creation orphans the menu bar engine's hosting
            // registration for it - the item keeps a valid frame on the app side but is
            // never drawn in the bar.
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.button?.target = self
            item.button?.action = #selector(handleClick(_:))
            // Fire on both buttons so we can route left-click to the panel and
            // right-click (or Control-click) to the context menu.
            item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
            item.button?.setAccessibilityIdentifier("cortex-menubar")
            statusItem = item
            render()
            // Repaint when the button's appearance resolves to the menu bar's (it starts
            // as the app's appearance, which draws the adaptive parts dark on re-enable),
            // and on any later light/dark flip.
            appearanceObservation = item.button?.observe(\.effectiveAppearance) { [weak self] _, _ in
                Task { @MainActor in self?.render() }
            }
        } else {
            stopTimer()
            appearanceObservation = nil
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

    func closePanel() { dismissPanel() }

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
             model.activity.current, model.usage.providers.count, model.activity.activeSessions.count,
             model.workflows.workflows)

        guard let button = statusItem?.button else { return }
        let appearance = button.effectiveAppearance
        let act = model.activity.current
        // Live activity is shown ALONGSIDE the usage readout, never replacing it: the
        // icon still reflects usage, and the activity label + timer trail the title.
        let live = model.menuBarLiveActivityEnabled && act.isActive

        // With two or more sessions actually IN A TURN at once, a single label would flip
        // between them, so show a stable "N running" aggregate. This counts running turns
        // (from the per-session hooks), not open-but-idle windows.
        let running = model.activity.activeSessions.count
        let multiRunning = live && running >= 2

        // A finished turn is celebrated with a one-shot confetti burst plus a green "Done".
        // Fire it once, on the transition into `.done` - but not while several sessions run
        // (it would fire whenever any one of them finishes a turn), and only when the user
        // hasn't turned the confetti off.
        let celebrating = live && model.menuBarConfetti && act.state == .done && !multiRunning
        if celebrating && !wasCelebrating { celebrate() }
        wasCelebrating = celebrating

        switch model.menuBarIconMode {
        case .text:
            // The whole text-mode content (glyph + % + activity) is rendered as ONE image so
            // it can be a template that adapts to the actual menu bar background (legible on
            // any wallpaper / when highlighted), instead of an attributedTitle that only
            // tracks the app's light/dark mode and goes white-on-white over a light bar.
            button.image = textModeImage(act: act, live: live, running: running, appearance: appearance)
            button.imagePosition = .imageOnly
            button.attributedTitle = NSAttributedString(string: "")
        case .donut:
            button.image = MenuBarIcon.donut(percent: primaryMetric()?.percent ?? 0, appearance: appearance)
            applyImageTitle(button, live: live, act: act, running: running)
        case .bars:
            button.image = MenuBarIcon.bars(session: metricPercent(.session),
                                            weekly: metricPercent(.weekly),
                                            appearance: appearance)
            applyImageTitle(button, live: live, act: act, running: running)
        case .both:
            button.image = MenuBarIcon.both(session: metricPercent(.session),
                                            weekly: metricPercent(.weekly),
                                            mode: model.menuBarUsageMode,
                                            appearance: appearance)
            applyImageTitle(button, live: live, act: act, running: running)
        }

        // Tick the elapsed timer only while a single turn is genuinely running (the done
        // flash and the multi-session aggregate have no single start time to tick).
        if live && act.turnStartedAt != nil && !multiRunning { startTimer() } else { stopTimer() }
    }

    /// Fire the turn-complete confetti, anchored just under the status item.
    private func celebrate() {
        guard let window = statusItem?.button?.window else { return }
        confetti.play(anchoredTo: window.frame)
    }

    /// For the image-based modes (ring / bars / both): the image alone when idle, or the
    /// image plus the trailing activity label while a turn is running.
    private func applyImageTitle(_ button: NSStatusBarButton, live: Bool, act: ClaudeActivity, running: Int) {
        if let wf = model.workflows.aggregate {
            button.imagePosition = .imageLeading
            button.attributedTitle = trailingLabel(" \u{00B7} \(wf.done)/\(wf.total) agents")
        } else if live && running >= 2 {
            button.imagePosition = .imageLeading
            button.attributedTitle = trailingLabel(" \u{00B7} \(running) running")
        } else if live {
            button.imagePosition = .imageLeading
            button.attributedTitle = activitySegment(act)
        } else {
            button.imagePosition = .imageOnly
            button.attributedTitle = NSAttributedString(string: "")
        }
    }

    /// A trailing caption (regular weight, label color) for the image-based icon modes.
    private func trailingLabel(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .regular),
            .foregroundColor: NSColor.labelColor,
        ])
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

    /// The text-mode content (leading glyph/dot + usage % + activity) as ONE status-item
    /// image, via MenuBarIcon.textImage so the common case is a template that adapts to the
    /// real menu bar background; accent states (orange warning, green Done, yellow awaiting
    /// dot) render in their colors, which read on any bar.
    private func textModeImage(act: ClaudeActivity, live: Bool, running: Int, appearance: NSAppearance) -> NSImage {
        // Percent run: adaptive normally, orange once mostly spent.
        let usage = usageSegment(primaryMetric())
        let percentColor: NSColor? = (usage.color == .systemOrange) ? .systemOrange : nil
        // Regular weight to match the native menu bar clock/battery (not bold).
        var runs = [MenuBarIcon.MenuTitleRun(text: usage.text, color: percentColor, weight: .regular)]

        var leadingGlyph: String? = "sparkle"
        var leadingDot: NSColor? = nil

        if let wf = model.workflows.aggregate {
            // A dynamic workflow is running: show subagent progress (takes precedence over the
            // generic per-session activity, which is just the parent waiting on its agents).
            runs.append(.init(text: "  \u{00B7} \(wf.done)/\(wf.total) agents", color: nil, weight: .regular))
        } else if live && running >= 2 {
            // Stable aggregate instead of flickering between sessions.
            runs.append(.init(text: "  \u{00B7} \(running) running", color: nil, weight: .regular))
        } else if live {
            switch act.state {
            case .done:
                // Green "Done" alongside the confetti burst.
                runs.append(.init(text: "  Done", color: .systemGreen, weight: .semibold))
            case .error:
                // Red "Error": the turn ended on an API error, not a success (no confetti).
                runs.append(.init(text: "  Error", color: .systemRed, weight: .semibold))
            case .awaitingPermission:
                leadingGlyph = nil
                leadingDot = .systemYellow
                runs.append(.init(text: "  \u{00B7} " + act.label, color: nil, weight: .regular))
            default:
                var t = "  \u{00B7} " + act.label
                if let start = act.turnStartedAt { t += " " + MenuBarController.elapsed(since: start) }
                runs.append(.init(text: t, color: nil, weight: .regular))
            }
        }
        return MenuBarIcon.textImage(leadingGlyph: leadingGlyph, leadingDot: leadingDot,
                                     runs: runs, appearance: appearance)
    }

    /// The trailing activity label + timer used by the image-based modes.
    private func activitySegment(_ act: ClaudeActivity) -> NSAttributedString {
        // A failed turn: a red "Error" flash instead of the green "Done".
        if act.state == .error {
            return NSAttributedString(string: " Error", attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: NSColor.systemRed,
            ])
        }
        // The turn-complete flash: a green "Done" alongside the confetti burst.
        if act.state == .done {
            return NSAttributedString(string: " Done", attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: NSColor.systemGreen,
            ])
        }
        var text = " " + act.label
        if let start = act.turnStartedAt { text += " " + MenuBarController.elapsed(since: start) }
        let color: NSColor = act.state == .awaitingPermission ? .systemOrange : .labelColor
        return NSAttributedString(string: text, attributes: [
            // Regular weight: the activity label is a caption, not bold like the usage %.
            .font: NSFont.systemFont(ofSize: 13, weight: .regular),
            .foregroundColor: color,
        ])
    }

    /// Claude's metrics for the gauge. Prefer the latest successful probe; on a transient
    /// failure (network / rate-limit / token hiccup) fall back to the last-known-good
    /// metrics so the bar keeps showing numbers instead of blanking to "--%". The panel
    /// still reads `providers` directly, so it surfaces the live error/not-configured state.
    private func claudeMetrics() -> [UsageMetric] {
        if case let .ok(_, metrics) = model.usage.providers.first(where: { $0.id == .claude })?.result,
           !metrics.isEmpty {
            return metrics
        }
        return model.usage.lastClaudeMetrics
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
        if panelWindow != nil { dismissPanel() } // don't overlap the menu

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

    // MARK: Panel (borderless rounded dropdown)

    @objc private func togglePanel(_ sender: Any?) {
        guard let button = statusItem?.button else { return }
        if panelWindow != nil { dismissPanel(); return }
        // The click that closed the panel (resignKey / outside-click monitor) can be the same
        // click that re-fires this toggle; ignore a reopen within a moment of a dismiss.
        if let last = lastPanelDismiss, Date().timeIntervalSince(last) < 0.25 { return }
        presentPanel(from: button)
    }

    /// Show the panel as a borderless, rounded `.menu`-material window hanging just under the
    /// status item - no arrow, dismisses on any click outside it.
    private func presentPanel(from button: NSStatusBarButton) {
        let host = NSHostingController(rootView: AnyView(MenuBarPanel().environment(model)))
        host.sizingOptions = .preferredContentSize
        panelHost = host
        panelAnchorButton = button

        // The whole window is the `.menu` material with rounded corners, so it reads as a
        // native dropdown (legible over any wallpaper) with no mismatched arrow.
        let effect = NSVisualEffectView()
        effect.material = .menu
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true

        host.view.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: effect.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])

        let win = KeyablePanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
                               styleMask: [.borderless, .nonactivatingPanel],
                               backing: .buffered, defer: false)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = true
        win.isFloatingPanel = true
        win.level = .popUpMenu
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        win.appearance = NSApp.appearance
        win.contentView = effect
        panelWindow = win

        layoutPanel()
        win.makeKeyAndOrderFront(nil)

        // Reposition/resize as the SwiftUI content's size changes (sessions start/stop, etc.).
        panelSizeObservation = host.observe(\.preferredContentSize, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.layoutPanel() }
        }
        // Close on click outside: a global monitor catches clicks in other apps / the desktop
        // / the status bar; resignKey catches focus moving to our own other windows.
        panelDismissMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.dismissPanel() }
        }
        panelResignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: win, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.dismissPanel() }
        }
    }

    /// Size the panel to its SwiftUI content and hang it top-center under the status item,
    /// clamped to the screen.
    private func layoutPanel() {
        guard let win = panelWindow, let host = panelHost,
              let button = panelAnchorButton, let bFrame = button.window?.frame else { return }
        var size = host.preferredContentSize
        if size.width < 1 || size.height < 1 {
            host.view.layoutSubtreeIfNeeded()
            size = host.view.fittingSize
        }
        if size.width < 1 || size.height < 1 { size = NSSize(width: 320, height: 240) }
        let gap: CGFloat = 6
        var x = bFrame.midX - size.width / 2
        let y = bFrame.minY - gap - size.height
        if let vis = button.window?.screen?.visibleFrame {
            x = min(max(vis.minX + 8, x), vis.maxX - size.width - 8)
        }
        win.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
    }

    /// Tear down the panel window and its observers.
    private func dismissPanel() {
        guard panelWindow != nil else { return }
        panelSizeObservation?.invalidate(); panelSizeObservation = nil
        if let m = panelDismissMonitor { NSEvent.removeMonitor(m); panelDismissMonitor = nil }
        if let o = panelResignObserver { NotificationCenter.default.removeObserver(o); panelResignObserver = nil }
        panelWindow?.orderOut(nil)
        panelWindow = nil
        panelHost = nil
        panelAnchorButton = nil
        lastPanelDismiss = Date()
    }
}

// MARK: - ConfettiOverlay
//
// A transient, click-through overlay window that plays a short confetti burst falling from
// just beneath the menu-bar icon - the turn-complete celebration shown in place of a "Done"
// label. Built on CAEmitterLayer (native, GPU-accelerated, no third-party dependency). It
// is self-tearing-down: it emits for a brief burst, then closes once the particles have
// fallen. The window never takes focus and passes all clicks through to whatever is behind.

@MainActor
final class ConfettiOverlay {
    private var window: NSWindow?
    private var closeTask: Task<Void, Never>?

    // A small, festive palette. CAEmitterCell.color tints the white particle image.
    private static let palette: [NSColor] = [
        .systemRed, .systemOrange, .systemYellow, .systemGreen,
        .systemBlue, .systemPurple, .systemPink, .systemTeal,
    ]

    /// Play one small burst from the menu-bar item (`anchor` is its frame in screen coords).
    /// It stays up in the menu-bar area - a quick puff just under the icon, not a screen-wide
    /// rain.
    func play(anchoredTo anchor: NSRect) {
        dismiss()   // never stack two bursts

        // A wide, shallow region under the menu bar, so the burst fans out sideways and
        // stays up near the bar rather than clumping into one spot.
        let width: CGFloat = 520
        let height: CGFloat = 200
        let top = anchor.midY                       // emit right where the menu bar lives
        let frame = NSRect(x: anchor.midX - width / 2, y: top - height, width: width, height: height)

        let win = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = false
        win.ignoresMouseEvents = true
        win.level = .statusBar
        win.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

        let view = NSView(frame: NSRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        win.contentView = view

        let emitter = Self.makeEmitter(size: frame.size)
        view.layer?.addSublayer(emitter)
        win.orderFrontRegardless()
        window = win

        // A quick dense puff, then stop emitting; tear the window down once it has faded.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { emitter.birthRate = 0 }
        closeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            self?.dismiss()
        }
    }

    /// Close and release the overlay (also called before a new burst).
    func dismiss() {
        closeTask?.cancel(); closeTask = nil
        window?.orderOut(nil)
        window = nil
    }

    // MARK: Emitter

    private static func makeEmitter(size: NSSize) -> CAEmitterLayer {
        let emitter = CAEmitterLayer()
        emitter.frame = CGRect(origin: .zero, size: size)   // so emitterPosition is in view space
        emitter.emitterShape = .line                        // originate across a wide line, not one spot
        emitter.emitterPosition = CGPoint(x: size.width / 2, y: size.height)   // at the menu bar
        emitter.emitterSize = CGSize(width: size.width * 0.6, height: 1)
        emitter.birthRate = 1
        emitter.beginTime = CACurrentMediaTime()
        let particle = particleImage()
        emitter.emitterCells = palette.map { cell(color: $0, image: particle) }
        return emitter
    }

    private static func cell(color: NSColor, image: CGImage?) -> CAEmitterCell {
        let c = CAEmitterCell()
        c.contents = image
        c.color = color.cgColor
        c.birthRate = 28                   // lots of small pieces in the burst
        c.lifetime = 1.8
        c.lifetimeRange = 0.5
        c.velocity = 95                    // scatter outward across the width
        c.velocityRange = 70
        c.emissionLongitude = -.pi / 2     // centred downward (the layer's y points up)
        c.emissionRange = .pi * 0.9        // wide fan: pieces shoot down-left, down, down-right
        c.yAcceleration = -70              // light gravity
        c.spin = 3.5
        c.spinRange = 5.0
        c.scale = 0.5                      // small confetti
        c.scaleRange = 0.3
        c.alphaSpeed = -0.7                // fade out within the menu-bar area
        return c
    }

    /// A small white rounded-rect confetti piece; CAEmitterCell.color tints it per cell.
    private static func particleImage() -> CGImage? {
        let size = NSSize(width: 6, height: 9)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: 1.4, yRadius: 1.4).fill()
        image.unlockFocus()
        var rect = CGRect(origin: .zero, size: size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }
}

// MARK: - KeyablePanel
//
// A borderless NSPanel that can still become the key window (borderless windows refuse key
// by default). Needed so the dropdown's SwiftUI controls receive clicks AND so resignKey
// fires for click-outside dismissal.

final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
