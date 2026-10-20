import Carbon
import os

/// A choice of shortcut in Settings.
protocol HotKeyPreset {
    var title: String { get }
    var keyCode: UInt32? { get }
    var modifiers: UInt32 { get }
}

/// A system-wide shortcut via Carbon's RegisterEventHotKey: works in any
/// app and needs no Accessibility permission. Each `HotKey` has its own id,
/// so several can be registered side by side.
final class HotKey {
    /// The timer field's shortcut.
    enum Preset: String, CaseIterable, Identifiable, HotKeyPreset {
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

    /// The reminder field's shortcut.
    enum ReminderPreset: String, CaseIterable, Identifiable, HotKeyPreset {
        case optionCommandR, controlOptionR, none

        var id: String { rawValue }
        var title: String {
            switch self {
            case .optionCommandR: "⌥⌘R"
            case .controlOptionR: "⌃⌥R"
            case .none: "None"
            }
        }
        var keyCode: UInt32? { self == .none ? nil : UInt32(kVK_ANSI_R) }
        var modifiers: UInt32 {
            switch self {
            case .optionCommandR: UInt32(optionKey | cmdKey)
            case .controlOptionR: UInt32(controlKey | optionKey)
            case .none: 0
            }
        }
    }

    private static var nextID: UInt32 = 1

    private let id: UInt32
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
        id = Self.nextID
        Self.nextID += 1
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                let hotKey = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
                var pressed = EventHotKeyID()
                GetEventParameter(
                    event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                    MemoryLayout<EventHotKeyID>.size, nil, &pressed)
                // Every handler sees every hot key: pass on the others'.
                guard pressed.signature == HotKey.signature, pressed.id == hotKey.id else {
                    return OSStatus(eventNotHandledErr)
                }
                MainActor.assumeIsolated { hotKey.action() }
                return noErr
            }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
    }

    private static let signature = OSType(0x5550_5448)  // 'UPTH'

    func register(_ preset: some HotKeyPreset) {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
        guard let keyCode = preset.keyCode else { return }
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        let status = RegisterEventHotKey(keyCode, preset.modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
        if status != noErr { log.error("hot key \(preset.title, privacy: .public) unavailable (\(status))") }
    }
}
