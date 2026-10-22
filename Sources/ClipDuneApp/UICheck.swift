import AppKit
import ClipDuneMac

@MainActor
enum UICheck {
    static func run(panel: ClipboardPanelController, directory: URL, open: () -> Void) async {
        var results: [String: Any] = [:]
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let session = CGSessionCopyCurrentDictionary() as? [String: Any]
            if session?["CGSSessionScreenIsLocked"] as? Bool == true {
                results["status"] = "blocked_screen_locked"
            } else {
                let previousPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
                open()
                results["searchFocusedImmediately"] = panel.isSearchFocused
                try await Task.sleep(for: .milliseconds(150))
                results["visible"] = panel.panel.isVisible
                results["activeSpace"] = panel.panel.isOnActiveSpace
                results["keyWindow"] = panel.panel.isKeyWindow
                results["searchFocusStable"] = panel.isSearchFocused
                let number = panel.panel.windowNumber
                let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
                results["windowServerOnScreen"] = windows.contains { ($0[kCGWindowNumber as String] as? Int) == number }
                if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                windowNumber: number, context: nil, characters: "d", charactersIgnoringModifiers: "d", isARepeat: false, keyCode: 2) {
                    panel.panel.sendEvent(event)
                }
                results["typedWithoutClick"] = panel.query == "d"
                if let editor = panel.searchField.currentEditor() as? NSTextView {
                    editor.selectAll(nil)
                    editor.setMarkedText("bu", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
                    results["markedTextSupported"] = editor.hasMarkedText()
                    editor.insertText("部署", replacementRange: NSRange(location: NSNotFound, length: 0))
                }
                try await Task.sleep(for: .milliseconds(120))
                results["chineseQuery"] = panel.query == "部署"
                results["chineseSearchResult"] = panel.summaries.count == 1 && panel.summaries.first?.text.contains("部署") == true
                panel.hide()
                var cyclesPassed = true
                for _ in 0..<12 {
                    open()
                    try await Task.sleep(for: .milliseconds(30))
                    cyclesPassed = cyclesPassed && panel.panel.isVisible && panel.isSearchFocused && panel.query.isEmpty
                    panel.hide()
                }
                results["twelveReopenCycles"] = cyclesPassed
                open()
                try await Task.sleep(for: .milliseconds(150))
                if let root = panel.panel.contentView,
                   let collection = descendants(of: root).compactMap({ $0 as? NSCollectionView }).first {
                    panel.panel.makeFirstResponder(collection)
                    results["focusLossReproduced"] = !panel.isSearchFocused
                    sendKey("x", keyCode: 7, to: panel.panel)
                    results["typeToSearchFromCards"] = panel.isSearchFocused && panel.query == "x"
                    panel.searchField.stringValue = ""
                    panel.onSearch?("", false)
                    try await Task.sleep(for: .milliseconds(100))
                    let originalChoose = panel.onChoose
                    var chosenID: String?
                    panel.onChoose = { summary, _, copyOnly in
                        if !copyOnly { chosenID = summary.id }
                    }
                    if let item = collection.item(at: IndexPath(item: 0, section: 0)) {
                        let point = item.view.convert(NSPoint(x: item.view.bounds.midX, y: item.view.bounds.midY), to: nil)
                        if let event = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
                                                         timestamp: ProcessInfo.processInfo.systemUptime,
                                                         windowNumber: number, context: nil, eventNumber: 1, clickCount: 2, pressure: 1) {
                            panel.panel.sendEvent(event)
                        }
                    }
                    results["doubleClickChoosesPaste"] = chosenID == panel.summaries.first?.id && chosenID != nil
                    panel.onChoose = originalChoose
                }
                let cardResults = try await CardUICheck.run(panel: panel, directory: directory)
                for (name, passed) in cardResults { results[name] = passed }
                let scrollResults = try await ScrollUICheck.run(panel: panel, open: open)
                for (name, passed) in scrollResults { results[name] = passed }
                if let view = panel.panel.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    if let image = bitmap.representation(using: .png, properties: [:]) {
                        try image.write(to: directory.appendingPathComponent("panel.png"))
                    }
                }
                panel.hide()
                results["hiddenAfterDismissal"] = !panel.panel.isVisible
                results["originalApplicationPreserved"] = NSWorkspace.shared.frontmostApplication?.processIdentifier == previousPID
                DistributedNotificationCenter.default().postNotificationName(
                    NSNotification.Name("app.clipdune.qa.focus.\(directory.lastPathComponent)"), object: nil, userInfo: nil, deliverImmediately: true)
                let focusFile = directory.appendingPathComponent("host-focus.json")
                for _ in 0..<30 {
                    if FileManager.default.fileExists(atPath: focusFile.path) { break }
                    try await Task.sleep(for: .milliseconds(50))
                }
                if let focusData = try? Data(contentsOf: focusFile),
                   let focus = try? JSONSerialization.jsonObject(with: focusData) as? [String: Bool] {
                    results["originalFieldRestored"] = focus["keyWindow"] == true && focus["inputFocused"] == true
                } else {
                    results["originalFieldRestored"] = false
                }
                let checks = results.values.compactMap { $0 as? Bool }
                results["status"] = checks.allSatisfy { $0 } ? "passed" : "failed"
                results["scope"] = "WindowServer visibility and synthetic focused-window input; not physical global shortcut or third-party terminal validation"
            }
            let data = try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: directory.appendingPathComponent("ui-check.json"), options: .atomic)
        } catch {
            let data = Data("{\"status\":\"failed\",\"reason\":\"QA execution failed\"}".utf8)
            try? data.write(to: directory.appendingPathComponent("ui-check.json"), options: .atomic)
        }
    }

    private static func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }

    private static func sendKey(_ characters: String, keyCode: UInt16, to window: NSWindow) {
        if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: window.windowNumber, context: nil, characters: characters,
                                        charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode) {
            window.sendEvent(event)
        }
    }
}
