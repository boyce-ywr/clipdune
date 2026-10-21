import AppKit
import ApplicationServices

@MainActor
public struct PasteDestination {
    private let application: NSRunningApplication
    private let focusedElement: AXUIElement?

    public static func capture() -> PasteDestination? {
        guard let application = NSWorkspace.shared.frontmostApplication,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        var value: CFTypeRef?
        let element = AXUIElementCreateApplication(application.processIdentifier)
        let status = AXIsProcessTrusted() ? AXUIElementCopyAttributeValue(element, kAXFocusedUIElementAttribute as CFString, &value) : .apiDisabled
        let focused = status == .success && value.map({ CFGetTypeID($0) == AXUIElementGetTypeID() }) == true ? (value as! AXUIElement) : nil
        return PasteDestination(application: application, focusedElement: focused)
    }

    public static var hasPermission: Bool { AXIsProcessTrusted() }

    public static func requestPermission() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    public func pasteIfStillFocused() -> Bool {
        guard AXIsProcessTrusted(), !application.isTerminated,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier,
              let focusedElement else { return false }
        var current: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(application.processIdentifier),
                                           kAXFocusedUIElementAttribute as CFString, &current) == .success,
              let current, CFEqual(focusedElement, current), let keyCode = pasteKeyCode(),
              let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else { return false }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.postToPid(application.processIdentifier)
        up.postToPid(application.processIdentifier)
        return true
    }
}
