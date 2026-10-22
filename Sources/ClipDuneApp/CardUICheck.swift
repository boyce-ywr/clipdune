import AppKit
import ClipDuneMac
import ClipDuneCore

@MainActor
enum CardUICheck {
    static func run(panel: ClipboardPanelController, directory: URL) async throws -> [String: Bool] {
        var results: [String: Bool] = [:]
        guard let root = panel.panel.contentView, let collection = descendants(root).compactMap({ $0 as? NSCollectionView }).first else {
            return ["cardControlsPresent": false]
        }
        let available = panel.panel.screen!.visibleFrame
        results["panelNearlyFullWidth"] = abs(panel.panel.frame.minX - available.minX - 16) < 1 && abs(available.maxX - panel.panel.frame.maxX - 16) < 1
        guard panel.summaries.count > 1, let card = collection.item(at: IndexPath(item: 1, section: 0)),
              let pin = button("pin", in: card.view) else { return ["cardControlsPresent": false] }
        let identity = panel.summaries[1].id
        results["cardControlsPresent"] = ["pin", "rename", "preview", "copy", "paste", "more"].allSatisfy { button($0, in: card.view) != nil }
        results["sourceIconPresent"] = descendants(card.view).compactMap({ $0 as? NSImageView }).contains { $0.identifier?.rawValue == "clipdune.card.sourceIcon" && $0.image != nil }
        results["sizeLabelPresent"] = descendants(card.view).compactMap({ $0 as? NSTextField }).contains { $0.identifier?.rawValue == "clipdune.card.size" && !$0.stringValue.isEmpty }
        let originalChoose = panel.onChoose
        let originalPreview = panel.onPreview
        let originalDelete = panel.onDelete
        defer { panel.onChoose = originalChoose; panel.onPreview = originalPreview; panel.onDelete = originalDelete }
        var chosen: (String, Bool, Bool)?
        var previewID: String?
        var deletedID: String?
        panel.onChoose = { chosen = ($0.id, $1, $2) }
        panel.onPreview = { previewID = $0.id }
        panel.onDelete = { deletedID = $0.id }
        click(pin, in: panel.panel, count: 1)
        try await Task.sleep(for: .milliseconds(120))
        results["pinButtonUpdatesClickedCard"] = panel.summaries.first(where: { $0.id == identity })?.isPinned == true && chosen == nil
        guard let index = panel.summaries.firstIndex(where: { $0.id == identity }),
              let updated = collection.item(at: IndexPath(item: index, section: 0)) else { return results.merging(["cardIdentityStable": false]) { _, new in new } }
        button("copy", in: updated.view)?.performClick(nil)
        results["copyButtonTargetsClickedCard"] = chosen?.0 == identity && chosen?.2 == true
        button("paste", in: updated.view)?.performClick(nil)
        results["pasteButtonTargetsClickedCard"] = chosen?.0 == identity && chosen?.2 == false
        button("preview", in: updated.view)?.performClick(nil)
        results["previewButtonTargetsClickedCard"] = previewID == identity
        chosen = nil
        if let pin = button("pin", in: updated.view) { click(pin, in: panel.panel, count: 2) }
        results["doubleClickButtonNeverPastes"] = chosen == nil
        let menuEvent = NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                           windowNumber: panel.panel.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 1)!
        if let menu = updated.view.menu(for: menuEvent) {
            results["contextMenuHasAllActions"] = ["pin", "rename", "copy", "paste", "preview", "delete", "alternateFormat"].allSatisfy { action in
                menu.items.contains { $0.identifier?.rawValue == "clipdune.card.\(action)" }
            }
            if let delete = menu.items.firstIndex(where: { $0.identifier?.rawValue == "clipdune.card.delete" }) {
                menu.performActionForItem(at: delete)
            }
            results["contextDeleteTargetsClickedCard"] = deletedID == identity
        } else { results["contextMenuHasAllActions"] = false }

        button("rename", in: updated.view)?.performClick(nil)
        try await Task.sleep(for: .milliseconds(100))
        if let sheet = panel.panel.attachedSheet, let sheetRoot = sheet.contentView,
           let name = descendants(sheetRoot).compactMap({ $0 as? NSTextField }).first(where: { $0.identifier?.rawValue == "clipdune.rename.title" }),
           let save = descendants(sheetRoot).compactMap({ $0 as? NSButton }).first(where: { $0.title == "保存" }) {
            name.stringValue = "颜色参考：演示命名"
            save.performClick(nil)
            try await Task.sleep(for: .milliseconds(180))
            results["renameSheetSavesWithoutClosingPanel"] = panel.isVisible && panel.summaries.first(where: { $0.id == identity })?.userTitle == "颜色参考：演示命名"
        } else { results["renameSheetSavesWithoutClosingPanel"] = false }
        panel.searchField.stringValue = "演示命名"
        panel.onSearch?(panel.query, false)
        try await Task.sleep(for: .milliseconds(120))
        results["renamedItemSearchableInPanel"] = panel.summaries.map(\.id) == [identity]
        if let segment = descendants(root).compactMap({ $0 as? NSSegmentedControl }).first {
            segment.selectedSegment = 1
            segment.sendAction(segment.action, to: segment.target)
            try await Task.sleep(for: .milliseconds(120))
            results["renamedFavoriteSearchable"] = panel.summaries.map(\.id) == [identity]
            segment.selectedSegment = 0
            segment.sendAction(segment.action, to: segment.target)
        }
        panel.searchField.stringValue = ""
        let types = descendants(root).compactMap({ $0 as? NSPopUpButton }).first { $0.identifier?.rawValue == "clipdune.filter.type" }
        let dates = descendants(root).compactMap({ $0 as? NSPopUpButton }).first { $0.identifier?.rawValue == "clipdune.filter.time" }
        if let types, let dates {
            types.selectItem(withTitle: "HTML")
            dates.selectItem(withTitle: "昨天")
            types.sendAction(types.action, to: types.target)
            try await Task.sleep(for: .milliseconds(120))
            results["typeAndTimeFiltersApply"] = panel.summaries.count == 1 && panel.summaries.first?.kind == .html
            if let clear = descendants(root).compactMap({ $0 as? NSButton }).first(where: { $0.identifier?.rawValue == "clipdune.filter.clear" }) {
                clear.performClick(nil)
                try await Task.sleep(for: .milliseconds(120))
                results["clearFiltersRestoresResults"] = panel.searchFilter == HistoryFilter() && panel.summaries.count > 1 && !clear.isEnabled
            }
        } else { results["typeAndTimeFiltersApply"] = false }
        panel.applyAppearance(.dark, compactCards: true)
        panel.panel.contentView?.layoutSubtreeIfNeeded()
        if let compact = collection.item(at: IndexPath(item: 0, section: 0)) {
            results["compactActionsFit"] = descendants(compact.view).compactMap { $0 as? NSButton }.allSatisfy {
                compact.view.bounds.contains(compact.view.convert($0.bounds, from: $0))
            }
        }
        panel.applyAppearance(.dark, compactCards: false)
        panel.focusSearch()
        return results
    }

    private static func button(_ action: String, in view: NSView) -> NSButton? {
        descendants(view).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "clipdune.card.\(action)" }
    }

    private static func descendants(_ view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap(descendants) }

    private static func click(_ button: NSButton, in window: NSWindow, count: Int) {
        let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                     windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: count, pressure: 1)!
        let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime + 0.01,
                                   windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: count, pressure: 0)!
        NSApp.postEvent(up, atStart: true)
        window.sendEvent(down)
    }
}
