import Carbon.HIToolbox
import Foundation

enum KeyboardInputSourcePair {
    static func next(current: String, enabled: Set<String>) -> String? {
        let english = "com.apple.keylayout.ABC"
        let korean = "com.apple.inputmethod.Korean.2SetKorean"
        guard enabled.contains(english), enabled.contains(korean) else { return nil }
        if current == english { return korean }
        if current == korean { return english }
        return nil
    }
}

enum KeyboardInputSourceSwitcher {
    private static func identifier(_ source: TISInputSource) -> String? {
        guard let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }
    private static var enabledSources: [TISInputSource] {
        TISCreateInputSourceList([kTISPropertyInputSourceIsEnabled as String: true] as CFDictionary, false)
            .takeRetainedValue() as? [TISInputSource] ?? []
    }
    static var isAvailable: Bool {
        let current = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        return KeyboardInputSourcePair.next(current: identifier(current) ?? "", enabled: Set(enabledSources.compactMap(identifier))) != nil
    }
    static func toggle() -> String? {
        let sources = enabledSources
        let current = identifier(TISCopyCurrentKeyboardInputSource().takeRetainedValue()) ?? ""
        guard let target = KeyboardInputSourcePair.next(current: current, enabled: Set(sources.compactMap(identifier))),
              let source = sources.first(where: { identifier($0) == target }), TISSelectInputSource(source) == noErr else { return nil }
        return target
    }
}
