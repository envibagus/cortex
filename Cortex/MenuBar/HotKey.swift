import AppKit
import Carbon.HIToolbox

// MARK: - HotKeyCombo
//
// A global shortcut stored as a Carbon virtual keycode + Carbon modifier mask, which is
// what RegisterEventHotKey wants. Built from an NSEvent during recording, persisted as
// two ints on AppModel, and rendered back to a "⌘⌥U"-style string for the Settings UI.

struct HotKeyCombo: Equatable {
    var keyCode: UInt32
    var carbonModifiers: UInt32

    init(keyCode: UInt32, carbonModifiers: UInt32) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
    }

    /// Build from a recorded key event, requiring at least one modifier so we never grab
    /// a bare key. Returns nil for modifier-only presses.
    init?(event: NSEvent) {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var carbon: UInt32 = 0
        if mods.contains(.command) { carbon |= UInt32(cmdKey) }
        if mods.contains(.option) { carbon |= UInt32(optionKey) }
        if mods.contains(.control) { carbon |= UInt32(controlKey) }
        if mods.contains(.shift) { carbon |= UInt32(shiftKey) }
        // Need a non-shift modifier (Shift alone isn't a valid global trigger).
        guard carbon != 0, carbon != UInt32(shiftKey) else { return nil }
        self.keyCode = UInt32(event.keyCode)
        self.carbonModifiers = carbon
    }

    /// "⌃⌥⇧⌘U"-style label for display.
    var displayString: String {
        var s = ""
        if carbonModifiers & UInt32(controlKey) != 0 { s += "\u{2303}" }
        if carbonModifiers & UInt32(optionKey) != 0 { s += "\u{2325}" }
        if carbonModifiers & UInt32(shiftKey) != 0 { s += "\u{21E7}" }
        if carbonModifiers & UInt32(cmdKey) != 0 { s += "\u{2318}" }
        return s + HotKeyCombo.keyName(keyCode)
    }

    /// Human label for a virtual keycode (ANSI letters/digits + common keys; falls back
    /// to a hex code for anything exotic).
    static func keyName(_ code: UInt32) -> String {
        if let named = specialKeys[Int(code)] { return named }
        if let ansi = ansiKeys[Int(code)] { return ansi }
        return "Key \(code)"
    }

    private static let specialKeys: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "\u{21A9}", kVK_Tab: "\u{21E5}",
        kVK_Escape: "esc", kVK_Delete: "\u{232B}",
        kVK_LeftArrow: "\u{2190}", kVK_RightArrow: "\u{2192}",
        kVK_UpArrow: "\u{2191}", kVK_DownArrow: "\u{2193}",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4",
        kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8",
    ]

    private static let ansiKeys: [Int: String] = [
        kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E",
        kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J",
        kVK_ANSI_K: "K", kVK_ANSI_L: "L", kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O",
        kVK_ANSI_P: "P", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
        kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X", kVK_ANSI_Y: "Y",
        kVK_ANSI_Z: "Z",
        kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3", kVK_ANSI_4: "4",
        kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9",
    ]
}

// MARK: - HotKey
//
// A registered global hotkey. RegisterEventHotKey works without Accessibility permission
// (unlike a global NSEvent monitor) and fires on the main run loop. The Carbon event
// handler is installed once and dispatches by hot-key id to the matching instance.

final class HotKey {
    private var ref: EventHotKeyRef?
    private let id: UInt32
    private let onFire: () -> Void

    private static var handlerRef: EventHandlerRef?
    private static var instances: [UInt32: HotKey] = [:]
    private static var nextID: UInt32 = 1
    private static let signature: OSType = 0x43525458 // "CRTX"

    init(combo: HotKeyCombo, onFire: @escaping () -> Void) {
        self.onFire = onFire
        self.id = HotKey.nextID
        HotKey.nextID += 1
        HotKey.instances[id] = self
        HotKey.installHandlerIfNeeded()

        let hkID = EventHotKeyID(signature: HotKey.signature, id: id)
        RegisterEventHotKey(combo.keyCode, combo.carbonModifiers,
                            hkID, GetApplicationEventTarget(), 0, &ref)
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        HotKey.instances.removeValue(forKey: id)
    }

    private static func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            HotKey.instances[hkID.id]?.onFire()
            return noErr
        }, 1, &spec, nil, &handlerRef)
    }
}
