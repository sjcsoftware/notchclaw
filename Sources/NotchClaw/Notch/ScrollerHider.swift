import AppKit
import SwiftUI

/// Hides an enclosing NSScrollView's scroll bars without disabling scrolling.
///
/// SwiftUI's `.scrollIndicators(.never)` can turn off wheel/trackpad scrolling on macOS,
/// and `.hidden` still draws a bar when "Show scroll bars: Always" is set. Swapping in an
/// invisible overlay scroller keeps scrolling intact under every system setting.
struct ScrollerHider: NSViewRepresentable {
    func makeNSView(context: Context) -> HiderView { HiderView() }
    func updateNSView(_ view: HiderView, context: Context) { view.apply() }

    final class HiderView: NSView {
        private var observer: NSObjectProtocol?

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
                guard let scrollView = self?.enclosingScrollView else { return }
                scrollView.scrollerStyle = .overlay
                scrollView.autohidesScrollers = true
                if !(scrollView.verticalScroller is InvisibleScroller) {
                    scrollView.verticalScroller = InvisibleScroller()
                }
                if !(scrollView.horizontalScroller is InvisibleScroller) {
                    scrollView.horizontalScroller = InvisibleScroller()
                }
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// A scroller that never draws and never takes clicks.
final class InvisibleScroller: NSScroller {
    override class var isCompatibleWithOverlayScrollers: Bool { true }
    override class func scrollerWidth(for controlSize: NSControl.ControlSize, scrollerStyle: NSScroller.Style) -> CGFloat { 0 }
    override func draw(_ dirtyRect: NSRect) {}
    override func drawKnob() {}
    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
