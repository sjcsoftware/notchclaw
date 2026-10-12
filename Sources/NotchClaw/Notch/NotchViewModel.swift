import AppKit
import Observation

/// Physical notch measurements for the screen hosting the overlay.
struct NotchGeometry: Equatable {
    var screenFrame: CGRect
    var notchWidth: CGFloat
    var notchHeight: CGFloat
    var hasNotch: Bool

    static let fallback = NotchGeometry(
        screenFrame: CGRect(x: 0, y: 0, width: 1470, height: 956), notchWidth: 185, notchHeight: 32, hasNotch: false)

    @MainActor
    static func of(_ screen: NSScreen) -> NotchGeometry {
        let hasNotch = screen.safeAreaInsets.top > 0
        var width: CGFloat = 185
        if let left = screen.auxiliaryTopLeftArea?.width, let right = screen.auxiliaryTopRightArea?.width {
            width = screen.frame.width - left - right
        }
        let menuBarHeight = screen.frame.maxY - screen.visibleFrame.maxY
        let height = hasNotch ? screen.safeAreaInsets.top : max(24, min(menuBarHeight, 32))
        return NotchGeometry(screenFrame: screen.frame, notchWidth: width, notchHeight: height, hasNotch: hasNotch)
    }

    /// Prefer the built-in display with a notch; otherwise the main screen.
    @MainActor
    static func preferredScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens.first
    }
}

enum NotchLayout {
    static let earWidth: CGFloat = 14
    static let homeWidth: CGFloat = 520
    static let baseExpandedWidth: CGFloat = 580
    static let minExpandedHeight: CGFloat = 150
    static let glowPadding: CGFloat = 36
    static let closedCorners = (top: CGFloat(6), bottom: CGFloat(13))
    static let openCorners = (top: CGFloat(14), bottom: CGFloat(26))
}

/// UI state for the notch overlay.
@MainActor
@Observable
final class NotchViewModel {
    enum Page { case home, chat }

    var geometry: NotchGeometry = .fallback
    private(set) var isExpanded = false
    /// Home (agent + controls) is the default; chat opens on demand or when a reply arrives.
    var page: Page = .home
    /// A reply arrived while collapsed: the next open goes straight to chat.
    var chatPending = false
    var isHovering = false
    /// SwiftUI's own hover signal for the visible notch content.
    var viewHovering = false
    /// Visible notch content frame in the hosting view's (top-left origin) coordinates.
    var contentFrame: CGRect = .zero
    var composerText = ""
    var composerFocused = false
    var isPinned = false
    var isMenuOpen = false
    /// Asks the composer to take keyboard focus once it is on screen.
    var wantsComposerFocus = false
    /// Makes the overlay panel key so the composer can receive typing.
    @ObservationIgnored var requestKeyWindow: () -> Void = {}

    var closedSize: CGSize {
        CGSize(width: geometry.notchWidth + NotchLayout.earWidth * 2, height: geometry.notchHeight)
    }

    func maxExpandedSize(settings: AppSettings) -> CGSize {
        let frame = geometry.screenFrame
        let width = max(NotchLayout.baseExpandedWidth, frame.width * settings.maxWidthFraction)
        let height = max(NotchLayout.minExpandedHeight + 120, frame.height * settings.maxHeightFraction)
        return CGSize(width: min(width, frame.width - 40), height: min(height, frame.height - 40))
    }

    func expand(page requested: Page? = nil) {
        if let requested { page = requested }
        guard !isExpanded else { return }
        if requested == nil { page = chatPending ? .chat : .home }
        chatPending = false
        isExpanded = true
        if UserDefaults.standard.object(forKey: "hapticFeedback") as? Bool ?? true {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
    }

    func collapse() {
        guard isExpanded else { return }
        isExpanded = false
        composerFocused = false
        viewHovering = false
        if !isPinned { page = .home }
    }

    func showChat(focusComposer: Bool) {
        page = .chat
        if focusComposer { wantsComposerFocus = true }
    }

    /// Whether leaving the panel should close it.
    var canAutoCollapse: Bool {
        !isPinned && !isMenuOpen && !(composerFocused && !composerText.trimmed.isEmpty)
    }
}
