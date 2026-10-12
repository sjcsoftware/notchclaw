import Carbon.HIToolbox
import Foundation

/// A system-wide hold-to-talk hotkey built on Carbon's `RegisterEventHotKey`,
/// which reports both press and release and needs no Accessibility permission.
@MainActor
final class HotKey {
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var isDown = false
    private static let signature: OSType = 0x4E_43_4C_57  // "NCLW"

    init() {
        var types = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            let kind = GetEventKind(event)
            let hotKey = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated {
                hotKey.handle(pressed: kind == UInt32(kEventHotKeyPressed))
            }
            return noErr
        }, types.count, &types, context, &handlerRef)
    }

    /// Registers the combo (or clears it with nil). Returns false if the system refused it.
    @discardableResult
    func register(_ combo: KeyCombo?) -> Bool {
        unregister()
        guard let combo else { return true }
        let id = EventHotKeyID(signature: Self.signature, id: 1)
        let status = RegisterEventHotKey(combo.keyCode, combo.modifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef)
        if status != noErr {
            Log.error("RegisterEventHotKey failed (\(status)) for \(combo.display)")
            hotKeyRef = nil
            return false
        }
        Log.info("Registered push-to-talk \(combo.display)")
        return true
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
        if isDown {
            isDown = false
            onRelease?()
        }
    }

    private func handle(pressed: Bool) {
        // Key auto-repeat re-sends "pressed"; only act on edges.
        if pressed {
            guard !isDown else { return }
            isDown = true
            onPress?()
        } else {
            guard isDown else { return }
            isDown = false
            onRelease?()
        }
    }
}
