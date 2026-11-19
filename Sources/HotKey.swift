import Carbon.HIToolbox

/// System wide keyboard shortcuts registered through the Carbon hot key API, which needs
/// no Accessibility permission.
final class HotKeys {
    struct Binding {
        let keyCode: Int
        let modifiers: Int
        let action: () -> Void
    }

    private var references: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    private var actions: [UInt32: () -> Void] = [:]

    init(_ bindings: [Binding]) {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr else { return status }
            let keys = Unmanaged<HotKeys>.fromOpaque(context).takeUnretainedValue()
            guard let action = keys.actions[id.id] else { return OSStatus(eventNotHandledErr) }
            DispatchQueue.main.async(execute: action)
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)

        for (index, binding) in bindings.enumerated() {
            let id = UInt32(index + 1)
            var reference: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: OSType(0x54504E50), id: id) // "TPNP"
            if RegisterEventHotKey(UInt32(binding.keyCode), UInt32(binding.modifiers), hotKeyID,
                                   GetApplicationEventTarget(), 0, &reference) == noErr, let reference {
                references.append(reference)
                actions[id] = binding.action
            }
        }
    }

    deinit {
        references.forEach { UnregisterEventHotKey($0) }
        if let handler { RemoveEventHandler(handler) }
    }

    static let controlOption = controlKey | optionKey
}
