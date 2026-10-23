import AppKit
import ApplicationServices
import ClipDuneCore
@testable import ClipDuneMac

final class PasteFocusTests {
    func unchangedWindowWithoutAccessibilityElementCanPaste() {
        var allowed = false
        for _ in 0..<16 {
            allowed = PasteFocusPolicy.evaluate(expectedPID: 100, currentPID: 100,
                                                focusedElementMatches: nil, targetWindowMatches: true,
                                                hasPermission: true, targetTerminated: false) == .ready
            if allowed { break }
        }
        expectTrue(allowed)
    }

    func windowFallbackRequiresPositiveIdentityAndNoContradictions() {
        for windowMatch in [true, false, nil] as [Bool?] {
            for serverMatch in [true, false, nil] as [Bool?] {
                let result = PasteFocusPolicy.evaluate(expectedPID: 100, currentPID: 100,
                                                       focusedElementMatches: nil, targetWindowMatches: windowMatch,
                                                       hasPermission: true, targetTerminated: false,
                                                       windowServerMatches: serverMatch)
                let expected: PasteReadiness = windowMatch == false || serverMatch == false ? .targetChanged :
                    windowMatch == true || serverMatch == true ? .ready : .waitingForFocus
                expectEqual(result, expected)
            }
        }
        expectEqual(PasteFocusPolicy.evaluate(expectedPID: 100, currentPID: 100, focusedElementMatches: true,
                                              targetWindowMatches: nil, hasPermission: true, targetTerminated: false,
                                              windowServerMatches: false), .targetChanged)
    }

    func knownChangedOrLostFocusDoesNotUseWindowFallback() {
        expectEqual(PasteFocusPolicy.evaluate(expectedPID: 100, currentPID: 100, focusedElementMatches: false,
                                              targetWindowMatches: true, hasPermission: true, targetTerminated: false), .targetChanged)
        expectEqual(PasteFocusPolicy.evaluate(expectedPID: 100, currentPID: 100, focusedElementMatches: nil,
                                              targetWindowMatches: true, hasPermission: true, targetTerminated: false,
                                              allowsWindowFallback: false, windowServerMatches: true), .waitingForFocus)
        for currentPID in [200, nil] as [Int32?] {
            expectEqual(PasteFocusPolicy.evaluate(expectedPID: 100, currentPID: currentPID, focusedElementMatches: nil,
                                                  targetWindowMatches: true, hasPermission: true, targetTerminated: false), .targetChanged)
        }
        expectEqual(PasteFocusPolicy.evaluate(expectedPID: 100, currentPID: 100, focusedElementMatches: nil,
                                              targetWindowMatches: true, hasPermission: false, targetTerminated: false), .unavailable)
        expectEqual(PasteFocusPolicy.evaluate(expectedPID: 100, currentPID: 100, focusedElementMatches: nil,
                                              targetWindowMatches: true, hasPermission: true, targetTerminated: true), .unavailable)
    }

    func recoveryWaitsForContinuousStableFocus() {
        var recovery = PasteFocusRecovery()
        expectEqual(recovery.observe(.ready, usingWindowFallback: false, at: 0), .waitingForFocus)
        expectEqual(recovery.observe(.ready, usingWindowFallback: false, at: 0.03), .ready)
        expectEqual(recovery.observe(.ready, usingWindowFallback: true, at: 0.04), .waitingForFocus)
        expectEqual(recovery.observe(.ready, usingWindowFallback: true, at: 0.08), .waitingForFocus)
        expectEqual(recovery.observe(.waitingForFocus, usingWindowFallback: true, at: 0.09), .waitingForFocus)
        expectEqual(recovery.observe(.ready, usingWindowFallback: true, at: 0.1), .waitingForFocus)
        expectEqual(recovery.observe(.ready, usingWindowFallback: true, at: 0.15), .waitingForFocus)
        expectEqual(recovery.observe(.ready, usingWindowFallback: true, at: 0.21), .ready)
        expectEqual(recovery.observe(.targetChanged, usingWindowFallback: true, at: 0.22), .targetChanged)
        expectEqual(recovery.observe(.ready, usingWindowFallback: true, at: 0.23), .waitingForFocus)
        expectEqual(recovery.observe(.unavailable, usingWindowFallback: true, at: 0.24), .unavailable)
    }

    func unsupportedAXAttributesAreNotConfusedWithErrors() {
        for error in [AXError.noValue, .attributeUnsupported, .notImplemented] {
            let read = PasteDestination.ElementRead(element: nil, error: error)
            expectTrue(read.isUnavailable)
            expectTrue(read.isReadable)
        }
        for error in [AXError.apiDisabled, .cannotComplete, .invalidUIElement, .failure] {
            let read = PasteDestination.ElementRead(element: nil, error: error)
            expectFalse(read.isUnavailable)
            expectFalse(read.isReadable)
        }
        let available = PasteDestination.ElementRead(element: AXUIElementCreateApplication(getpid()), error: .success)
        expectFalse(available.isUnavailable)
        expectTrue(available.isReadable)
    }

    @MainActor
    func windowServerTracksWindowSwitchesWithoutReadingContents() async throws {
        _ = NSApplication.shared
        let first = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 220, height: 120),
                             styleMask: [.titled], backing: .buffered, defer: false)
        let second = NSWindow(contentRect: NSRect(x: 140, y: 140, width: 220, height: 120),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let overlay = NSPanel(contentRect: NSRect(x: 160, y: 160, width: 100, height: 60),
                              styleMask: [.nonactivatingPanel], backing: .buffered, defer: false)
        overlay.level = .floating
        defer { overlay.orderOut(nil); second.orderOut(nil); first.orderOut(nil) }
        func settledWindow(_ expected: CGWindowID?) async throws -> CGWindowID? {
            for _ in 0..<20 {
                let current = PasteDestination.frontWindowNumber(for: getpid())
                if current == expected { return current }
                try await Task.sleep(for: .milliseconds(25))
            }
            return PasteDestination.frontWindowNumber(for: getpid())
        }
        first.orderFrontRegardless()
        let original = try await settledWindow(CGWindowID(first.windowNumber))
        expectEqual(original, CGWindowID(first.windowNumber))
        second.orderFrontRegardless()
        let changed = try await settledWindow(CGWindowID(second.windowNumber))
        expectEqual(changed, CGWindowID(second.windowNumber))
        expectNotEqual(original, changed)
        expectNil(PasteDestination.frontWindowNumber(for: -1))
        overlay.orderFrontRegardless()
        expectNil(try await settledWindow(nil))
        overlay.orderOut(nil)
        second.orderOut(nil)
        expectEqual(try await settledWindow(original), original)
    }

    func failureMessagesExplainWhatWasRejected() {
        expectNotEqual(PasteDestination.Result.focusUnavailable.fallbackMessage, PasteDestination.Result.targetChanged.fallbackMessage)
        expectNotEqual(PasteDestination.Result.focusChanged.fallbackMessage, PasteDestination.Result.targetChanged.fallbackMessage)
        expectTrue(PasteDestination.Result.inputChanged.fallbackMessage.contains("新的输入操作"))
        expectTrue(PasteDestination.Result.unsupportedKeyboard.fallbackMessage.contains("键盘布局"))
        expectTrue(PasteDestination.Result.permissionRequired.fallbackMessage.contains("辅助功能"))
    }
}
