import AppKit

/// Native pop-up menus built from closures. Used instead of SwiftUI `Menu`
/// so the trigger can be any custom-styled view inside the notch.
@MainActor
enum PopupMenu {
    enum Entry {
        case item(String, checked: Bool = false, enabled: Bool = true, action: () -> Void)
        case header(String)
        case separator
    }

    static func show(_ entries: [Entry]) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for entry in entries {
            switch entry {
            case .item(let title, let checked, let enabled, let action):
                let item = ClosureMenuItem(title: title, handler: action)
                item.state = checked ? .on : .off
                item.isEnabled = enabled
                menu.addItem(item)
            case .header(let title):
                if #available(macOS 14.0, *) {
                    menu.addItem(.sectionHeader(title: title))
                } else {
                    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                    item.isEnabled = false
                    menu.addItem(item)
                }
            case .separator:
                menu.addItem(.separator())
            }
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
}

private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func fire() { handler() }
}
