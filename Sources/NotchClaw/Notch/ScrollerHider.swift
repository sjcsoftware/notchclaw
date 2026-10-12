import AppKit
import SwiftUI

/// Replaces an enclosing NSScrollView's scroll bars with slim ones that blend into the notch.
///
/// SwiftUI's `.scrollIndicators(.never)` removes the scroller on macOS (and with it
/// wheel/trackpad scrolling), and the stock bar looks heavy on black. This keeps a real,
/// draggable scroller, drawn as a thin translucent capsule with no track.
struct ScrollerHider: NSViewRepresentable {
    /// Horizontal scrollers (code blocks) stay invisible; only the chat gets a slim bar.
    var vertical: SlimScroller.Style = .slim

    func makeNSView(context: Context) -> HiderView { HiderView(style: vertical) }
    func updateNSView(_ view: HiderView, context: Context) { view.apply() }

    final class HiderView: NSView {
        private var observer: NSObjectProtocol?
        private let style: SlimScroller.Style

        init(style: SlimScroller.Style) {
            self.style = style
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
            if observer == nil {
                // Changing "Show scroll bars" in System Settings resets the style; re-apply.
                observer = NotificationCenter.default.addObserver(
                    forName: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.apply() }
                }
            }
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }

        func apply() {
            DispatchQueue.main.async { [weak self] in
                guard let self, let scrollView = self.enclosingScrollView else { return }
                scrollView.scrollerStyle = .overlay
                scrollView.autohidesScrollers = true
                if (scrollView.verticalScroller as? SlimScroller)?.style != self.style {
                    scrollView.verticalScroller = SlimScroller(style: self.style)
                }
                if (scrollView.horizontalScroller as? SlimScroller)?.style != .invisible {
                    scrollView.horizontalScroller = SlimScroller(style: .invisible)
                }
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// A thin, trackless scroller: a translucent capsule that brightens on hover and while
/// dragging. `.invisible` draws nothing and ignores clicks.
final class SlimScroller: NSScroller {
    enum Style { case slim, invisible }

    let style: Style
    private var hovering = false
    private var tracking: NSTrackingArea?

    init(style: Style) {
        self.style = style
        super.init(frame: NSRect(x: 0, y: 0, width: 8, height: 100))
        alphaValue = 1
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override class var isCompatibleWithOverlayScrollers: Bool { true }

    override class func scrollerWidth(for controlSize: NSControl.ControlSize, scrollerStyle: NSScroller.Style) -> CGFloat { 8 }

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}

    override func draw(_ dirtyRect: NSRect) {
        guard style == .slim, knobProportion < 1 else { return }
        drawKnob()
    }

    override func drawKnob() {
        guard style == .slim else { return }
        let knob = rect(for: .knob).insetBy(dx: 2.5, dy: 2)
        let width: CGFloat = hovering ? 4 : 3
        let capsule = NSRect(x: knob.maxX - width, y: knob.minY, width: width, height: max(knob.height, 16))
        NSColor.white.withAlphaComponent(hovering ? 0.35 : 0.16).setFill()
        NSBezierPath(roundedRect: capsule, xRadius: width / 2, yRadius: width / 2).fill()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        style == .slim ? super.hitTest(point) : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        guard style == .slim else { return }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }
}
