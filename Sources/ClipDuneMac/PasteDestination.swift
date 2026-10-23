import AppKit
import ApplicationServices
import ClipDuneCore

@MainActor
public struct PasteDestination {
    public enum Result: Equatable {
        case sent, permissionRequired, targetChanged, focusChanged, inputChanged, focusUnavailable, unsupportedKeyboard, cancelled

        public var fallbackMessage: String {
            switch self {
            case .targetChanged: return "原应用或窗口已切换 · 已复制，可按 ⌘V 粘贴"
            case .focusChanged: return "原输入控件已切换 · 已复制，可按 ⌘V 粘贴"
            case .inputChanged: return "检测到新的输入操作 · 已复制，请按 ⌘V 粘贴"
            case .focusUnavailable: return "未能确认原窗口的输入焦点 · 已复制，可按 ⌘V 粘贴"
            case .unsupportedKeyboard: return "无法发送当前键盘布局的粘贴快捷键 · 已复制，可手动粘贴"
            case .permissionRequired: return "需要辅助功能权限 · 已复制，可按 ⌘V 粘贴"
            case .sent: return "已向原应用发送粘贴"
            case .cancelled: return "粘贴已取消 · 内容已复制"
            }
        }
    }
    private let application: NSRunningApplication
    private let focusedElement: ElementRead
    private let focusedWindow: AXUIElement?
    private let windowNumber: CGWindowID?

    struct ElementRead {
        let element: AXUIElement?
        let error: AXError

        var isUnavailable: Bool { [.noValue, .attributeUnsupported, .notImplemented].contains(error) }
        var isReadable: Bool { error == .success || isUnavailable }
    }

    public static func capture() -> PasteDestination? {
        guard let application = NSWorkspace.shared.frontmostApplication,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        let target = AXUIElementCreateApplication(application.processIdentifier)
        AXUIElementSetMessagingTimeout(target, 0.05)
        let windowNumber = frontWindowNumber(for: application.processIdentifier)
        return PasteDestination(application: application,
                                focusedElement: hasPermission ? attribute(kAXFocusedUIElementAttribute, of: target) : ElementRead(element: nil, error: .apiDisabled),
                                focusedWindow: hasPermission ? attribute(kAXFocusedWindowAttribute, of: target).element : nil,
                                windowNumber: windowNumber)
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
        AXUIElementSetMessagingTimeout(target, 0.05)
        var recovery = PasteFocusRecovery()
        let deadline = ProcessInfo.processInfo.systemUptime + 0.6
        var inputChanged = false
        var focusChanged = false
        let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]) { _ in
            MainActor.assumeIsolated { inputChanged = true }
        }
        defer { if let monitor { NSEvent.removeMonitor(monitor) } }
        while ProcessInfo.processInfo.systemUptime < deadline {
            guard !isCancelled(), !Task.isCancelled else { return .cancelled }
            guard !inputChanged else { return .inputChanged }
            guard Self.hasPermission else { return .permissionRequired }
            guard !application.isTerminated,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier else { return .targetChanged }
            let currentWindow = Self.attribute(kAXFocusedWindowAttribute, of: target)
            let currentElement = Self.attribute(kAXFocusedUIElementAttribute, of: target)
            let sameWindow = focusedWindow.flatMap { old in currentWindow.element.map { CFEqual(old, $0) } }
            let sameElement = focusedElement.element.flatMap { old in currentElement.element.map { CFEqual(old, $0) } }
            let currentNumber = Self.frontWindowNumber(for: application.processIdentifier)
            let sameNumber = windowNumber.flatMap { old in currentNumber.map { old == $0 } }
            let readiness = PasteFocusPolicy.evaluate(expectedPID: application.processIdentifier,
                                                      currentPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                                                      focusedElementMatches: sameElement,
                                                      targetWindowMatches: sameWindow,
                                                      hasPermission: Self.hasPermission, targetTerminated: application.isTerminated,
                                                      allowsWindowFallback: monitor != nil && focusedElement.isUnavailable && currentElement.isReadable && currentWindow.isReadable,
                                                      windowServerMatches: sameNumber)
            focusChanged = sameElement == false
            if readiness == .targetChanged && (sameWindow == false || sameNumber == false || NSWorkspace.shared.frontmostApplication?.processIdentifier != application.processIdentifier) {
                return .targetChanged
            }
            if readiness == .unavailable { return .focusUnavailable }
            if recovery.observe(readiness, usingWindowFallback: sameElement != true, at: ProcessInfo.processInfo.systemUptime) == .ready {
                guard ProcessInfo.processInfo.systemUptime < deadline else { return .focusUnavailable }
                guard !isCancelled(), !Task.isCancelled else { return .cancelled }
                guard !inputChanged else { return .inputChanged }
                guard Self.hasPermission else { return .permissionRequired }
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier else { return .targetChanged }
                guard let keyCode = pasteKeyCode(),
                      let source = CGEventSource(stateID: .combinedSessionState),
                      let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
                      let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else { return .unsupportedKeyboard }
                down.flags = .maskCommand
                up.flags = .maskCommand
                down.postToPid(application.processIdentifier)
                up.postToPid(application.processIdentifier)
                return .sent
            }
            do { try await Task.sleep(for: .milliseconds(25)) }
            catch { return .cancelled }
        }
        return focusChanged ? .focusChanged : .focusUnavailable
    }

    private static func attribute(_ name: String, of element: AXUIElement) -> ElementRead {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        guard error == .success else { return ElementRead(element: nil, error: error) }
        guard let value else { return ElementRead(element: nil, error: .noValue) }
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return ElementRead(element: nil, error: .failure) }
        return ElementRead(element: (value as! AXUIElement), error: .success)
    }

    static func frontWindowNumber(for processID: pid_t) -> CGWindowID? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        for window in windows where (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == processID {
            guard (window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 0 > 0 else { continue }
            guard (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0 else { return nil }
            return (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value
        }
        return nil
    }
}
