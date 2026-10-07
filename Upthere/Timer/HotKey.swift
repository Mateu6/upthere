import Carbon
import os

/// A system-wide shortcut via Carbon's RegisterEventHotKey: works in any
/// app and needs no Accessibility permission.
final class HotKey {
    enum Preset: String, CaseIterable, Identifiable {
        case optionCommandT, controlOptionT, controlOptionSpace, none

        var id: String { rawValue }
        var title: String {
            switch self {
            case .optionCommandT: "⌥⌘T"
            case .controlOptionT: "⌃⌥T"
            case .controlOptionSpace: "⌃⌥Space"
            case .none: "None"
            }
        }
        var keyCode: UInt32? {
            switch self {
            case .optionCommandT, .controlOptionT: UInt32(kVK_ANSI_T)
            case .controlOptionSpace: UInt32(kVK_Space)
            case .none: nil
            }
        }
        var modifiers: UInt32 {
            switch self {
            case .optionCommandT: UInt32(optionKey | cmdKey)
            case .controlOptionT, .controlOptionSpace: UInt32(controlKey | optionKey)
            case .none: 0
            }
        }
    }

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else { return noErr }
                let hotKey = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
                MainActor.assumeIsolated { hotKey.action() }
                return noErr
            }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
    }

    func register(_ preset: Preset) {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
        guard let keyCode = preset.keyCode else { return }
        let id = EventHotKeyID(signature: OSType(0x5550_5448), id: 1)  // 'UPTH'
        let status = RegisterEventHotKey(keyCode, preset.modifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef)
        if status != noErr { log.error("hot key \(preset.title, privacy: .public) unavailable (\(status))") }
    }
}
