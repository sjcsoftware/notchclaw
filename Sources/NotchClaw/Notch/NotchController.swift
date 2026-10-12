import AppKit
import SwiftUI

/// Borderless, non-activating overlay panel that can still take keyboard focus
/// for the composer (Spotlight-style) without stealing activation from other apps.
final class NotchPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        acceptsMouseMovedEvents = true
        ignoresMouseEvents = true
        level = .mainMenu + 3
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Lets the first click on the notch press a button even while another app is active.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Owns the overlay panel: positions it over the notch, decides when the pointer
/// is "in" the notch, toggles click-through, and drives expand/collapse.
@MainActor
final class NotchController {
    private let app: AppModel
    private let panel = NotchPanel()
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []
    private var hoverTask: Task<Void, Never>?
    private var collapseTask: Task<Void, Never>?
    private var pollTimer: Timer?

    private var notch: NotchViewModel { app.notch }

    init(app: AppModel) {
        self.app = app
        let hosting = FirstMouseHostingView(rootView: NotchRootView(app: app))
        hosting.sizingOptions = []
        panel.contentView = hosting
        notch.requestKeyWindow = { [weak self] in self?.panel.makeKey() }
        layout()
        panel.orderFrontRegardless()
        installMonitors()
        observeLayoutSettings()
    }

    // MARK: Layout

    func layout() {
        guard let screen = NotchGeometry.preferredScreen() else { return }
        notch.geometry = .of(screen)
        let maxSize = notch.maxExpandedSize(settings: app.settings)
        let width = maxSize.width + NotchLayout.glowPadding * 2
        let height = maxSize.height + NotchLayout.glowPadding
        let frame = CGRect(
            x: screen.frame.midX - width / 2, y: screen.frame.maxY - height, width: width, height: height)
        panel.setFrame(frame.integral, display: true)
    }

    private func observeLayoutSettings() {
        withObservationTracking {
            _ = app.settings.maxWidthFraction
            _ = app.settings.maxHeightFraction
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.layout()
                self?.observeLayoutSettings()
            }
        }
    }

    // MARK: Pointer tracking

    private func installMonitors() {
        let moveEvents: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: moveEvents, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.pointerMoved() }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: moveEvents, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.pointerMoved() }
            return event
        }) { monitors.append(local) }
        // Safety net: if a scroll over the open notch is delivered to another app, apply it to
        // the scroll view under the pointer ourselves. (Events we receive normally never get here.)
        if let scrolls = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.forwardScroll(event) }
        }) { monitors.append(scrolls) }
        // Clicks in other apps dismiss the expanded notch.
        if let clicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.clickedOutside() }
        }) { monitors.append(clicks) }

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.layout() }
        })
        observers.append(center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.notch.isMenuOpen = true }
        })
        observers.append(center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.notch.isMenuOpen = false
                self?.pointerMoved()
            }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.panel.orderFrontRegardless() }
        })

        // Safety net: monitors can miss exits (e.g. fast flicks, menus). Poll cheaply.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.notch.isExpanded || self.notch.isHovering else { return }
                self.pointerMoved()
            }
        }
    }

    /// The region that currently counts as "the notch" in screen coordinates.
    private func interactiveRect() -> CGRect {
        let screen = notch.geometry.screenFrame
        if notch.isExpanded, notch.contentFrame.width > 0 {
            // Convert the measured SwiftUI frame (top-left origin) to screen space.
            let f = notch.contentFrame
            let rect = CGRect(x: panel.frame.minX + f.minX, y: panel.frame.maxY - f.maxY, width: f.width, height: f.height)
            return rect.insetBy(dx: -16, dy: -16)
        }
        if notch.isExpanded {
            let w = NotchLayout.homeWidth
            return CGRect(x: screen.midX - w / 2 - 16, y: screen.maxY - 260, width: w + 32, height: 262)
        }
        // Minimized: exactly the black notch, so passing near it doesn't open it.
        let size = notch.closedSize
        return CGRect(x: screen.midX - size.width / 2, y: screen.maxY - size.height,
                      width: size.width, height: size.height)
    }

    /// Inclusive hit test: points on the notch's edge count as inside.
    private static func containsInclusive(_ rect: CGRect, _ point: CGPoint) -> Bool {
        point.x >= rect.minX && point.x <= rect.maxX && point.y >= rect.minY && point.y <= rect.maxY
    }

    private func pointerMoved() {
        let location = NSEvent.mouseLocation
        let inside = Self.containsInclusive(interactiveRect(), location) || (notch.isExpanded && notch.viewHovering)
        // Only touch the flag on change: re-setting it resets the window's event routing,
        // which can cut a trackpad scroll gesture off mid-stream.
        if panel.ignoresMouseEvents == inside { panel.ignoresMouseEvents = !inside }
        guard inside != notch.isHovering else { return }
        notch.isHovering = inside
        inside ? pointerEntered() : pointerExited()
    }

    private func pointerEntered() {
        collapseTask?.cancel()
        guard !notch.isExpanded else { return }
        // Don't pop open while the user is dragging something across the top edge.
        guard NSEvent.pressedMouseButtons == 0 else { return }
        hoverTask?.cancel()
        hoverTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(90))
            guard !Task.isCancelled, let self, self.notch.isHovering else { return }
            self.notch.expand()
            self.app.session.clearAttention()
        }
    }

    private func pointerExited() {
        hoverTask?.cancel()
        guard notch.isExpanded else { return }
        scheduleCollapse(after: 0.5)
    }

    private func forwardScroll(_ event: NSEvent) {
        let location = NSEvent.mouseLocation
        guard notch.isExpanded, Self.containsInclusive(interactiveRect(), location),
              let content = panel.contentView
        else { return }
        if panel.ignoresMouseEvents { panel.ignoresMouseEvents = false }
        let point = content.convert(panel.convertPoint(fromScreen: location), from: nil)
        var view = content.hitTest(point)
        // Find the nearest scroll view that can actually scroll vertically.
        while let current = view {
            if let scroll = current as? NSScrollView ?? current.enclosingScrollView,
               let document = scroll.documentView,
               document.frame.height > scroll.contentView.bounds.height + 1 {
                let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 12
                let maxY = document.frame.height - scroll.contentView.bounds.height
                var origin = scroll.contentView.bounds.origin
                origin.y = (document.isFlipped ? origin.y - delta : origin.y + delta).clamped(to: 0...maxY)
                scroll.contentView.scroll(to: origin)
                scroll.reflectScrolledClipView(scroll.contentView)
                return
            }
            view = current.enclosingScrollView?.superview
        }
    }

    private func clickedOutside() {
        // A click can slip through if click-through state was stale; never treat clicks on the notch as outside.
        if Self.containsInclusive(interactiveRect(), NSEvent.mouseLocation) {
            pointerMoved()
            return
        }
        guard notch.isExpanded, !notch.isPinned, !app.voice.isActive else { return }
        collapse()
    }

    private func scheduleCollapse(after delay: TimeInterval) {
        collapseTask?.cancel()
        collapseTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            guard !self.notch.isHovering, !self.notch.viewHovering, self.notch.canAutoCollapse,
                  !self.app.voice.isActive, NSEvent.pressedMouseButtons == 0
            else { return }
            self.collapse()
        }
    }

    private func collapse() {
        notch.collapse()
        if panel.isKeyWindow {
            // Hand keyboard focus back to whatever the user was using.
            panel.resignKey()
            panel.orderOut(nil)
            panel.orderFrontRegardless()
        }
        pointerMoved()
    }

    func toggle() {
        if notch.isExpanded {
            collapse()
        } else {
            notch.expand()
            app.session.clearAttention()
        }
    }
}
