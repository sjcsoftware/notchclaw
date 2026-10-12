import Carbon.HIToolbox
import Foundation
import Observation

enum UsageWindowChoice: String, CaseIterable, Identifiable, Codable {
    case fiveHour, daily, weekly
    var id: String { rawValue }
    var title: String {
        switch self {
        case .fiveHour: return "5 hours"
        case .daily: return "Daily"
        case .weekly: return "Weekly"
        }
    }
    var shortTitle: String {
        switch self {
        case .fiveHour: return "5h"
        case .daily: return "Day"
        case .weekly: return "Week"
        }
    }
}

/// A global keyboard shortcut (Carbon virtual key code + Carbon modifier mask).
struct KeyCombo: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32

    static let defaultPushToTalk = KeyCombo(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey))

    var display: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + KeyNames.name(for: keyCode)
    }
}

/// User preferences, persisted in UserDefaults. The gateway token lives in `SecureStore`.
@MainActor
@Observable
final class AppSettings {
    @ObservationIgnored private let defaults: UserDefaults

    var gatewayURL: String { didSet { defaults.set(gatewayURL, forKey: "gatewayURL") } }
    var gatewayToken: String { didSet { SecureStore.shared.gatewayToken = gatewayToken } }
    var sessionKey: String { didSet { defaults.set(sessionKey, forKey: "sessionKey") } }
    var agentEmoji: String { didSet { defaults.set(agentEmoji, forKey: "agentEmoji") } }
    var agentName: String { didSet { defaults.set(agentName, forKey: "agentName") } }
    var showUsage: Bool { didSet { defaults.set(showUsage, forKey: "showUsage") } }
    var usageWindow: UsageWindowChoice { didSet { defaults.set(usageWindow.rawValue, forKey: "usageWindow") } }
    var maxHeightFraction: Double { didSet { defaults.set(maxHeightFraction, forKey: "maxHeightFraction") } }
    var maxWidthFraction: Double { didSet { defaults.set(maxWidthFraction, forKey: "maxWidthFraction") } }
    var glowOnReply: Bool { didSet { defaults.set(glowOnReply, forKey: "glowOnReply") } }
    var injectMarkdownInstruction: Bool { didSet { defaults.set(injectMarkdownInstruction, forKey: "injectMarkdown") } }
    var pushToTalk: KeyCombo {
        didSet { defaults.set(try? JSONEncoder().encode(pushToTalk), forKey: "pushToTalk") }
    }
    var pushToTalkEnabled: Bool { didSet { defaults.set(pushToTalkEnabled, forKey: "pushToTalkEnabled") } }
    var speechLocale: String { didSet { defaults.set(speechLocale, forKey: "speechLocale") } }
    var autoSendVoice: Bool { didSet { defaults.set(autoSendVoice, forKey: "autoSendVoice") } }
    var showMenuBarIcon: Bool { didSet { defaults.set(showMenuBarIcon, forKey: "showMenuBarIcon") } }
    var hapticFeedback: Bool { didSet { defaults.set(hapticFeedback, forKey: "hapticFeedback") } }
    /// Fine-tuning for the minimized notch, in points, relative to the detected hardware notch.
    /// Ask the gateway for `operator.admin` (needed for New session and Compact).
    var requestAdminAccess: Bool { didSet { defaults.set(requestAdminAccess, forKey: "requestAdminAccess") } }
    var notchWidthAdjust: Double { didSet { defaults.set(notchWidthAdjust, forKey: "notchWidthAdjust") } }
    var notchHeightAdjust: Double { didSet { defaults.set(notchHeightAdjust, forKey: "notchHeightAdjust") } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        gatewayURL = defaults.string(forKey: "gatewayURL") ?? "ws://127.0.0.1:18789"
        gatewayToken = SecureStore.shared.gatewayToken
        sessionKey = defaults.string(forKey: "sessionKey") ?? "main"
        agentEmoji = defaults.string(forKey: "agentEmoji") ?? "🦞"
        agentName = defaults.string(forKey: "agentName") ?? "OpenClaw"
        showUsage = defaults.object(forKey: "showUsage") as? Bool ?? true
        usageWindow = UsageWindowChoice(rawValue: defaults.string(forKey: "usageWindow") ?? "") ?? .fiveHour
        maxHeightFraction = defaults.object(forKey: "maxHeightFraction") as? Double ?? 0.5
        maxWidthFraction = defaults.object(forKey: "maxWidthFraction") as? Double ?? (1.0 / 3.0)
        glowOnReply = defaults.object(forKey: "glowOnReply") as? Bool ?? true
        injectMarkdownInstruction = defaults.object(forKey: "injectMarkdown") as? Bool ?? true
        pushToTalk = (defaults.data(forKey: "pushToTalk")).flatMap { try? JSONDecoder().decode(KeyCombo.self, from: $0) }
            ?? .defaultPushToTalk
        pushToTalkEnabled = defaults.object(forKey: "pushToTalkEnabled") as? Bool ?? true
        speechLocale = defaults.string(forKey: "speechLocale") ?? ""
        autoSendVoice = defaults.object(forKey: "autoSendVoice") as? Bool ?? true
        showMenuBarIcon = defaults.object(forKey: "showMenuBarIcon") as? Bool ?? true
        hapticFeedback = defaults.object(forKey: "hapticFeedback") as? Bool ?? true
        requestAdminAccess = defaults.object(forKey: "requestAdminAccess") as? Bool ?? false
        notchWidthAdjust = defaults.object(forKey: "notchWidthAdjust") as? Double ?? 0
        notchHeightAdjust = defaults.object(forKey: "notchHeightAdjust") as? Double ?? 0
    }

    static let notchWidthAdjustRange: ClosedRange<Double> = -80...160
    static let notchHeightAdjustRange: ClosedRange<Double> = -16...24

    var resolvedSessionKey: String { sessionKey.nonEmpty ?? "main" }
    var resolvedEmoji: String { agentEmoji.nonEmpty ?? "🦞" }
    var resolvedName: String { agentName.nonEmpty ?? "OpenClaw" }
}

enum KeyNames {
    static func name(for keyCode: UInt32) -> String {
        switch Int(keyCode) {
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Escape: return "⎋"
        case kVK_Delete: return "⌫"
        case kVK_ForwardDelete: return "⌦"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        case kVK_F13: return "F13"
        case kVK_F14: return "F14"
        case kVK_F15: return "F15"
        case kVK_F16: return "F16"
        case kVK_F17: return "F17"
        case kVK_F18: return "F18"
        case kVK_F19: return "F19"
        default: return characterName(for: keyCode) ?? "Key \(keyCode)"
        }
    }

    /// Resolves the printable character for a key code using the current keyboard layout.
    private static func characterName(for keyCode: UInt32) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        return data.withUnsafeBytes { raw -> String? in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            var deadKeys: UInt32 = 0
            var length = 0
            var chars = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(
                layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, chars.count, &length, &chars)
            guard status == noErr, length > 0 else { return nil }
            return String(utf16CodeUnits: chars, count: length).uppercased()
        }
    }
}
