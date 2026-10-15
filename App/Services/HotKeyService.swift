import AppKit
import Carbon.HIToolbox

/// One global shortcut that opens the quick-copy panel. Carbon's
/// RegisterEventHotKey works in the sandbox and needs no Accessibility access.
@MainActor
final class HotKeyService {
    static let shared = HotKeyService()

    enum Preset: String, CaseIterable, Identifiable {
        case off, optCmdE, ctrlOptCmdE, ctrlOptSpace, shiftCmdE
        var id: String { rawValue }

        var title: String {
            switch self {
            case .off: "Off"
            case .optCmdE: "⌥⌘E"
            case .ctrlOptCmdE: "⌃⌥⌘E"
            case .ctrlOptSpace: "⌃⌥Space"
            case .shiftCmdE: "⇧⌘E"
            }
        }

        fileprivate var key: (code: Int, modifiers: Int)? {
            switch self {
            case .off: nil
            case .optCmdE: (kVK_ANSI_E, optionKey | cmdKey)
            case .ctrlOptCmdE: (kVK_ANSI_E, controlKey | optionKey | cmdKey)
            case .ctrlOptSpace: (kVK_Space, controlKey | optionKey)
            case .shiftCmdE: (kVK_ANSI_E, shiftKey | cmdKey)
            }
        }

        static var current: Preset {
            Preset(rawValue: UserDefaults.standard.string(forKey: Prefs.quickCopyHotKey) ?? "") ?? .optCmdE
        }
    }

    var action: (() -> Void)?
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    /// False when another app already owns the chosen shortcut.
    private(set) var registered = false

    func apply(_ preset: Preset = .current) {
        if let hotKey { UnregisterEventHotKey(hotKey); self.hotKey = nil }
        registered = false
        guard let key = preset.key else { return }
        if handler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), hotKeyHandler, 1, &spec, nil, &handler)
        }
        let id = EventHotKeyID(signature: OSType(0x6576_6C74), id: 1) // 'evlt'
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(key.code), UInt32(key.modifiers), id, GetApplicationEventTarget(), 0, &ref)
        hotKey = ref
        registered = status == noErr
    }
}

private func hotKeyHandler(_ next: EventHandlerCallRef?, _ event: EventRef?, _ data: UnsafeMutableRawPointer?) -> OSStatus {
    MainActor.assumeIsolated { HotKeyService.shared.action?() }
    return noErr
}
