import AppKit
import ApplicationServices
import ClipDuneCore

@MainActor
public struct PasteDestination {
    public enum Result: Equatable { case sent, permissionRequired, targetChanged, focusUnavailable, unsupportedKeyboard, cancelled }
    private let application: NSRunningApplication
    private let focusedElement: AXUIElement?
    private let focusedWindow: AXUIElement?

    public static func capture() -> PasteDestination? {
        guard let application = NSWorkspace.shared.frontmostApplication,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        let target = AXUIElementCreateApplication(application.processIdentifier)
        return PasteDestination(application: application,
                                focusedElement: hasPermission ? attribute(kAXFocusedUIElementAttribute, of: target) : nil,
                                focusedWindow: hasPermission ? attribute(kAXFocusedWindowAttribute, of: target) : nil)
    }

    public static var hasPermission: Bool { AXIsProcessTrusted() }

    public static func requestPermission() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        SystemSettings.open(.accessibility)
    }

    public func pasteWhenReady(isCancelled: () -> Bool) async -> Result {
        guard Self.hasPermission else { return .permissionRequired }
        let target = AXUIElementCreateApplication(application.processIdentifier)
        for attempt in 0..<16 {
            guard !isCancelled(), !Task.isCancelled else { return .cancelled }
            guard Self.hasPermission else { return .permissionRequired }
            guard !application.isTerminated,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier else { return .targetChanged }
            let currentWindow = Self.attribute(kAXFocusedWindowAttribute, of: target)
            let currentElement = Self.attribute(kAXFocusedUIElementAttribute, of: target)
            let sameWindow = focusedWindow.flatMap { old in currentWindow.map { CFEqual(old, $0) } }
            let sameElement = focusedElement.flatMap { old in currentElement.map { CFEqual(old, $0) } }
            let ready = sameElement == true || (focusedElement == nil && sameWindow == true && currentElement != nil)
            let readiness = PasteFocusPolicy.evaluate(expectedPID: application.processIdentifier,
                                                      currentPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                                                      focusedElementMatches: ready ? true : nil,
                                                      targetWindowMatches: sameWindow,
                                                      hasPermission: Self.hasPermission, targetTerminated: application.isTerminated)
            if readiness == .targetChanged { return .targetChanged }
            if readiness == .unavailable { return .focusUnavailable }
            if readiness == .ready, attempt > 0 {
                guard !isCancelled(), let keyCode = pasteKeyCode(),
                      let source = CGEventSource(stateID: .combinedSessionState),
                      let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
                      let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else { return .unsupportedKeyboard }
                down.flags = .maskCommand
                up.flags = .maskCommand
                down.postToPid(application.processIdentifier)
                up.postToPid(application.processIdentifier)
                return .sent
            }
            if attempt == 15 { return sameElement == false ? .targetChanged : .focusUnavailable }
            do { try await Task.sleep(for: .milliseconds(25)) }
            catch { return .cancelled }
        }
        return .focusUnavailable
    }

    private static func attribute(_ name: String, of element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
}
