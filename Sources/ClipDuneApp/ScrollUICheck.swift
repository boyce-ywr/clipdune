import AppKit
import ClipDuneMac
import ClipDuneCore

@MainActor
enum ScrollUICheck {
    static func run(panel: ClipboardPanelController, open: () -> Void) async throws -> [String: Bool] {
        guard let root = panel.panel.contentView,
              let collection = descendants(root).compactMap({ $0 as? NSCollectionView }).first,
              let scroll = collection.enclosingScrollView else { return ["scrollFixtureReady": false] }
        panel.hide()
        open()
        try await Task.sleep(for: .milliseconds(150))
        root.layoutSubtreeIfNeeded()
        let clip = scroll.contentView
        let maximumX = max(0, collection.bounds.width - clip.bounds.width)
        var results = ["scrollFixtureReady": panel.summaries.count >= 40 && maximumX > 500]
        guard results["scrollFixtureReady"] == true else { return results }

        let index = IndexPath(item: 20, section: 0)
        collection.selectionIndexPaths = [index]
        panel.collectionView(collection, didSelectItemsAt: [index])
        clip.scroll(to: NSPoint(x: maximumX / 2 + 63, y: clip.bounds.minY))
        scroll.reflectScrolledClipView(clip)
        results["scrolledAwayBeforeReopen"] = clip.bounds.minX > 100
        panel.hide()
        open()
        results["reopenImmediatelyResetsScroll"] = atStart(scroll)
        try await Task.sleep(for: .milliseconds(150))
        results["reopenAfterResultsResetsScroll"] = atStart(scroll)
        results["reopenSelectsNewest"] = collection.selectionIndexPaths == [IndexPath(item: 0, section: 0)]
        results["reopenKeepsSearchFocused"] = panel.isSearchFocused

        clip.scroll(to: NSPoint(x: 73, y: clip.bounds.minY))
        scroll.reflectScrolledClipView(clip)
        panel.hide()
        open()
        try await Task.sleep(for: .milliseconds(150))
        results["partiallyVisibleFirstCardResetsCompletely"] = atStart(scroll)
        guard let latest = descendants(root).compactMap({ $0 as? NSButton }).first(where: { $0.identifier?.rawValue == "clipdune.returnToLatest" }) else {
            results["returnToLatestButtonPresent"] = false
            return results
        }
        results["returnToLatestButtonPresent"] = !latest.isHidden && latest.isEnabled && latest.title == "回到最新"
        let previousChoose = panel.onChoose
        var pasteCalled = false
        panel.onChoose = { _, _, _ in pasteCalled = true }
        defer { panel.onChoose = previousChoose }
        collection.selectionIndexPaths = [index]
        panel.collectionView(collection, didSelectItemsAt: [index])
        moveAway(scroll, collection: collection)
        click(latest, in: panel.panel)
        try await Task.sleep(for: .milliseconds(80))
        results["latestButtonResetsScrollAndSelection"] = atStart(scroll) && collection.selectionIndexPaths == [IndexPath(item: 0, section: 0)]
        results["latestButtonKeepsInputFocusWithoutPasting"] = panel.isSearchFocused && !pasteCalled
        let firstFrame = collection.layoutAttributesForItem(at: IndexPath(item: 0, section: 0))?.frame
        results["latestCardFullyVisible"] = firstFrame.map { collection.visibleRect.contains($0) } == true

        if let type = descendants(root).compactMap({ $0 as? NSPopUpButton }).first(where: { $0.identifier?.rawValue == "clipdune.filter.type" }),
           let period = descendants(root).compactMap({ $0 as? NSPopUpButton }).first(where: { $0.identifier?.rawValue == "clipdune.filter.time" }),
           let favorites = descendants(root).compactMap({ $0 as? NSSegmentedControl }).first {
            panel.searchField.stringValue = "横向滚动"
            type.selectItem(withTitle: "文本")
            period.selectItem(withTitle: "最近 30 天")
            type.sendAction(type.action, to: type.target)
            try await Task.sleep(for: .milliseconds(150))
            let identities = panel.summaries.map(\.id)
            results["filteredScrollFixtureReady"] = identities.count >= 40
            moveAway(scroll, collection: collection)
            click(latest, in: panel.panel)
            try await Task.sleep(for: .milliseconds(80))
            results["latestButtonPreservesQueryAndFilters"] = panel.query == "横向滚动" && panel.searchFilter == HistoryFilter(kind: .text, period: .lastThirtyDays) && panel.summaries.map(\.id) == identities && atStart(scroll)

            favorites.selectedSegment = 1
            favorites.sendAction(favorites.action, to: favorites.target)
            try await Task.sleep(for: .milliseconds(150))
            results["emptyResultsDisableLatestButton"] = panel.summaries.isEmpty && !latest.isEnabled && atStart(scroll)
            panel.searchField.stringValue = ""
            type.selectItem(at: 0)
            period.selectItem(at: 0)
            type.sendAction(type.action, to: type.target)
            try await Task.sleep(for: .milliseconds(150))
            click(latest, in: panel.panel)
            try await Task.sleep(for: .milliseconds(80))
            results["latestButtonPreservesFavorites"] = panel.pinnedOnly && !panel.summaries.isEmpty && panel.summaries.allSatisfy(\.isPinned) && atStart(scroll)

            panel.hide()
            open()
            try await Task.sleep(for: .milliseconds(150))
            results["reopenClearsFiltersAndReturnsToHistoryStart"] = !panel.pinnedOnly && panel.query.isEmpty && panel.searchFilter == HistoryFilter() && panel.summaries.count >= 40 && atStart(scroll)
        } else { results["latestButtonPreservesQueryAndFilters"] = false }

        var allCyclesPassed = true
        for _ in 0..<6 {
            moveAway(scroll, collection: collection)
            panel.hide()
            open()
            allCyclesPassed = allCyclesPassed && atStart(scroll)
            try await Task.sleep(for: .milliseconds(80))
            allCyclesPassed = allCyclesPassed && atStart(scroll) && panel.isSearchFocused
        }
        results["repeatedScrolledReopensStayAtStart"] = allCyclesPassed
        results["latestNavigationNeverPastes"] = !pasteCalled
        return results
    }

    private static func atStart(_ scroll: NSScrollView) -> Bool {
        abs(scroll.contentView.bounds.minX) <= 0.5
    }

    private static func descendants(_ view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap(descendants) }

    private static func moveAway(_ scroll: NSScrollView, collection: NSCollectionView) {
        collection.layoutSubtreeIfNeeded()
        let maximumX = max(0, collection.bounds.width - scroll.contentView.bounds.width)
        scroll.contentView.scroll(to: NSPoint(x: maximumX / 2, y: scroll.contentView.bounds.minY))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    private static func click(_ button: NSButton, in window: NSWindow) {
        let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        let timestamp = ProcessInfo.processInfo.systemUptime
        let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: timestamp,
                                     windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: timestamp + 0.01,
                                   windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 0)!
        NSApp.postEvent(up, atStart: true)
        window.sendEvent(down)
    }
}
