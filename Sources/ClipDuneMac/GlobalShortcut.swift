import AppKit
import Carbon

@MainActor
public final class GlobalShortcut {
    public enum Preset: Int, CaseIterable {
        case commandShiftV, controlOptionSpace, controlShiftV

        public var label: String {
            switch self {
            case .commandShiftV: return "⌘⇧V"
            case .controlOptionSpace: return "⌃⌥Space"
            case .controlShiftV: return "⌃⇧V"
            }
        }

        var modifiers: UInt32 {
            switch self {
            case .commandShiftV: return UInt32(cmdKey | shiftKey)
            case .controlOptionSpace: return UInt32(controlKey | optionKey)
            case .controlShiftV: return UInt32(controlKey | shiftKey)
            }
        }
    }

    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void

    public init(action: @escaping () -> Void) { self.action = action }

    public func register(_ preset: Preset) -> Bool {
        unregister()
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var identity = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                          nil, MemoryLayout<EventHotKeyID>.size, nil, &identity)
            guard result == noErr, identity.signature == 0x434C444E else { return OSStatus(eventNotHandledErr) }
            MainActor.assumeIsolated {
                Unmanaged<GlobalShortcut>.fromOpaque(context).takeUnretainedValue().action()
            }
            return noErr
        }, 1, &event, pointer, &handler)
        guard status == noErr else { return false }
        let key = preset == .controlOptionSpace ? UInt32(kVK_Space) : UInt32(pasteKeyCode() ?? CGKeyCode(kVK_ANSI_V))
        let result = RegisterEventHotKey(key, preset.modifiers,
                                        EventHotKeyID(signature: 0x434C444E, id: 1), GetApplicationEventTarget(), 0, &hotKey)
        if result != noErr { unregister() }
        return result == noErr
    }

    public func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
        hotKey = nil
        handler = nil
    }
}

public func pasteKeyCode() -> CGKeyCode? {
    guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
          let rawData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
    let data = Unmanaged<CFData>.fromOpaque(rawData).takeUnretainedValue()
    guard let bytes = CFDataGetBytePtr(data) else { return nil }
    let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
    for keyCode in UInt16(0)..<UInt16(128) {
        var deadKeyState: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)
        let result = UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDown), 0, UInt32(LMGetKbdType()),
                                    OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadKeyState, 4, &length, &characters)
        if result == noErr, length == 1, characters[0] == 118 { return keyCode }
    }
    return nil
}
