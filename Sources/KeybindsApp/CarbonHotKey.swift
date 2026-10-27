import Carbon.HIToolbox
import KeybindsCore

/// A system-wide key combo via `RegisterEventHotKey`. Needs no permission. The combo is
/// consumed: the frontmost app won't see it while registered.
@MainActor
final class CarbonHotKey {
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var nextID: UInt32 = 1
    private static var handlerInstalled = false

    private let id: UInt32
    private var ref: EventHotKeyRef?

    init?(combo: KeyCombo, action: @escaping () -> Void) {
        Self.installHandlerIfNeeded()
        id = Self.nextID
        Self.nextID += 1
        let hotKeyID = EventHotKeyID(signature: OSType(0x4B42_4E44), id: id)  // 'KBND'
        let status = RegisterEventHotKey(combo.keyCode, combo.carbonModifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr else { return nil }
        Self.handlers[id] = action
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        Self.handlers[id] = nil
    }

    private static func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let id = hotKeyID.id
            // Carbon delivers hotkey events on the main thread.
            MainActor.assumeIsolated { CarbonHotKey.handlers[id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}

private extension KeyCombo {
    var carbonModifiers: UInt32 {
        var m = 0
        if modifiers.contains(.command) { m |= cmdKey }
        if modifiers.contains(.option) { m |= optionKey }
        if modifiers.contains(.control) { m |= controlKey }
        if modifiers.contains(.shift) { m |= shiftKey }
        return UInt32(m)
    }
}
