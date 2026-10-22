import AppKit
import ClipDuneCore

@MainActor
public final class OverlayPanel: NSPanel {
    public var handleShortcut: ((NSEvent) -> Bool)?
    public var handleEvent: ((NSEvent) -> Bool)?
    public override var canBecomeKey: Bool { true }
    public override var canBecomeMain: Bool { false }

    public override func sendEvent(_ event: NSEvent) {
        if handleEvent?(event) == true { return }
        super.sendEvent(event)
    }

    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let editor = firstResponder as? NSTextView, editor.hasMarkedText() {
            return super.performKeyEquivalent(with: event)
        }
        return handleShortcut?(event) == true || super.performKeyEquivalent(with: event)
    }
}

@MainActor
public final class ClipboardPanelController: NSObject, NSWindowDelegate, NSSearchFieldDelegate,
                                               NSCollectionViewDataSource, NSCollectionViewDelegate {
    public var onSearch: ((String, Bool) -> Void)?
    public var onChoose: ((ClipSummary, Bool, Bool) -> Void)?
    public var onPin: ((ClipSummary) -> Void)?
    public var onPreview: ((ClipSummary) -> Void)?
    public var onDelete: ((ClipSummary) -> Void)?
    public var onSettings: (() -> Void)?
    public var onRename: ((ClipSummary) -> Void)?
    public let panel: OverlayPanel
    public let searchField = NSSearchField()
    public private(set) var summaries: [ClipSummary] = []
    private let collection = NSCollectionView()
    private let scrollView = NSScrollView()
    private let filter = NSSegmentedControl(labels: ["历史", "收藏"], trackingMode: .selectOne, target: nil, action: nil)
    private let typeFilter = NSPopUpButton()
    private let timeFilter = NSPopUpButton()
    private let clearFilters = NSButton()
    private let latestButton = NSButton()
    private var pinButton: NSButton?
    private var sourceIcons: [String: NSImage] = [:]
    private let statusLabel = NSTextField(labelWithString: "仅保存在这台 Mac")
    private let countLabel = NSTextField(labelWithString: "")
    private let emptyLabel = NSTextField(wrappingLabelWithString: "你的下一次复制，会出现在这里。\n无需整理，随时找回。")
    private var selectedIndex = 0
    private var generation = 0
    private var clickMonitor: Any?
    private var spaceObserver: NSObjectProtocol?
    private var previewWindow: OverlayPanel?
    private var buttons: [NSButton] = []

    public var isVisible: Bool { panel.isVisible }
    public var isSearchFocused: Bool { panel.firstResponder === searchField.currentEditor() && searchField.currentEditor() != nil }
    public var query: String { searchField.stringValue }
    public var pinnedOnly: Bool { filter.selectedSegment == 1 }
    public var searchFilter: HistoryFilter {
        HistoryFilter(kind: typeFilter.indexOfSelectedItem > 0 ? ClipKind.allCases[typeFilter.indexOfSelectedItem - 1] : nil,
                      period: HistoryFilter.Period.allCases[max(0, timeFilter.indexOfSelectedItem)])
    }

    public static func frame(on visibleFrame: NSRect) -> NSRect {
        let inset = min(16, visibleFrame.width / 20)
        return NSRect(x: visibleFrame.minX + inset, y: visibleFrame.minY + 18,
                      width: visibleFrame.width - inset * 2, height: min(382, visibleFrame.height - 40))
    }

    public override init() {
        panel = OverlayPanel(contentRect: NSRect(x: 0, y: 0, width: 1_060, height: 382),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.delegate = self
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .canJoinAllApplications, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.title = "ClipDune — 拾贴"
        panel.setAccessibilityLabel("ClipDune 剪贴板检索")
        panel.handleShortcut = { [weak self] event in self?.handleShortcut(event) ?? false }
        panel.handleEvent = { [weak self] event in self?.handlePanelEvent(event) ?? false }
        configureContent()
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                                                                          object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
    }

    public func show() {
        if panel.isVisible { hide(); return }
        generation += 1
        let session = generation
        searchField.stringValue = ""
        filter.selectedSegment = 0
        typeFilter.selectItem(at: 0)
        timeFilter.selectItem(at: 0)
        clearFilters.isEnabled = false
        selectedIndex = 0
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main
        let available = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1_200, height: 800)
        panel.setFrame(Self.frame(on: available), display: true)
        selectCurrent(scrollIntoView: false)
        scrollToBeginning()
        panel.orderFrontRegardless()
        panel.makeKey()
        focusSearch()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == session, self.panel.isVisible else { return }
            self.focusSearch()
        }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
        onSearch?("", false)
    }

    public func hide() {
        generation += 1
        previewWindow?.orderOut(nil)
        previewWindow = nil
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        panel.orderOut(nil)
    }

    public func focusSearch() {
        guard panel.isVisible, panel.attachedSheet == nil else { return }
        panel.makeFirstResponder(searchField)
        if let editor = searchField.currentEditor() as? NSTextView {
            editor.setSelectedRange(NSRange(location: (searchField.stringValue as NSString).length, length: 0))
        }
    }

    public func update(_ results: [ClipSummary], resetSelection: Bool = false) {
        let selectedID = summaries.indices.contains(selectedIndex) ? summaries[selectedIndex].id : nil
        summaries = results
        if resetSelection { selectedIndex = 0 }
        else { selectedIndex = selectedID.flatMap { identity in results.firstIndex(where: { $0.id == identity }) } ?? 0 }
        collection.reloadData()
        emptyLabel.isHidden = !results.isEmpty
        emptyLabel.stringValue = query.isEmpty && searchFilter == HistoryFilter() ? "你的下一次复制，会出现在这里。\n无需整理，随时找回。" : "没有找到匹配内容\n试试调整关键词、类型或时间筛选。"
        countLabel.stringValue = results.isEmpty ? "" : (results.count == 200 ? "最近 200 项 · 可继续搜索" : "\(results.count) 项")
        buttons.forEach { $0.isEnabled = !results.isEmpty }
        selectCurrent(scrollIntoView: !resetSelection)
        if resetSelection { scrollToBeginning() }
    }

    public func setStatus(_ status: String) { statusLabel.stringValue = status }

    public func applyAppearance(_ appearance: AppPreferences.Appearance, compactCards: Bool) {
        switch appearance {
        case .system: panel.appearance = nil
        case .light: panel.appearance = NSAppearance(named: .aqua)
        case .dark: panel.appearance = NSAppearance(named: .darkAqua)
        }
        if let layout = collection.collectionViewLayout as? NSCollectionViewFlowLayout {
            layout.itemSize = NSSize(width: compactCards ? 184 : 222, height: 232)
            layout.invalidateLayout()
        }
        collection.reloadData()
    }

    public func showPreview(_ content: ClipboardContent) {
        let preview = OverlayPanel(contentRect: NSRect(x: panel.frame.midX - 320, y: panel.frame.maxY + 18, width: 640, height: 360),
                                   styleMask: [.titled, .closable, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
        preview.title = "内容预览 · 只读"
        preview.level = .floating
        preview.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .canJoinAllApplications]
        preview.isReleasedWhenClosed = false
        preview.delegate = self
        if content.kind == .image, let data = content.fragments.flatMap(\.representations).first(where: {
            ["public.png", "public.tiff", "public.jpeg", "com.compuserve.gif", "public.heic"].contains($0.type)
        })?.data, let image = NSImage(data: data) {
            let imageView = NSImageView(frame: preview.contentView!.bounds)
            imageView.image = image
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.autoresizingMask = [.width, .height]
            preview.contentView = imageView
        } else {
            let scroll = NSScrollView(frame: preview.contentView!.bounds)
            scroll.hasVerticalScroller = true
            scroll.autoresizingMask = [.width, .height]
            let text = NSTextView(frame: scroll.bounds)
            text.isEditable = false
            text.isSelectable = true
            text.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
            text.string = content.text.isEmpty ? "\(content.kind.title) · \(ByteCountFormatter.string(fromByteCount: Int64(content.contentByteCount), countStyle: .file))\n\n" +
                content.fragments.flatMap(\.representations).map(\.type).joined(separator: "\n") : content.text
            text.textContainerInset = NSSize(width: 16, height: 16)
            text.autoresizingMask = [.width]
            text.textContainer?.widthTracksTextView = true
            text.isVerticallyResizable = true
            scroll.documentView = text
            preview.contentView = scroll
        }
        if let screen = panel.screen {
            let frame = preview.frame
            preview.setFrameOrigin(NSPoint(x: min(max(frame.minX, screen.visibleFrame.minX), screen.visibleFrame.maxX - frame.width),
                                           y: min(frame.minY, screen.visibleFrame.maxY - frame.height)))
        }
        preview.handleShortcut = { [weak self] event in
            guard event.keyCode == 53 else { return false }
            self?.previewWindow?.close()
            return true
        }
        previewWindow = preview
        preview.makeKeyAndOrderFront(nil)
    }

    public func windowDidBecomeKey(_ notification: Notification) {
        if notification.object as? NSWindow === panel { focusSearch() }
    }

    public func windowDidResignKey(_ notification: Notification) {
        guard notification.object as? NSWindow === panel else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.panel.isKeyWindow, self.previewWindow?.isVisible != true, self.panel.attachedSheet == nil else { return }
            self.hide()
        }
    }

    public func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow === previewWindow {
            previewWindow = nil
            panel.makeKey()
            focusSearch()
        }
    }

    public func controlTextDidChange(_ notification: Notification) {
        onSearch?(query, pinnedOnly)
    }

    public func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard !textView.hasMarkedText() else { return false }
        switch commandSelector {
        case #selector(NSResponder.moveDown(_:)): moveSelection(1)
        case #selector(NSResponder.moveUp(_:)): moveSelection(-1)
        case #selector(NSResponder.insertNewline(_:)):
            let flags = NSApp.currentEvent?.modifierFlags ?? []
            choose(plainText: flags.contains(.shift), copyOnly: flags.contains(.option))
        case #selector(NSResponder.cancelOperation(_:)): hide()
        default: return false
        }
        return true
    }

    public func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { summaries.count }

    public func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: NSUserInterfaceItemIdentifier("clip"), for: indexPath) as! ClipCard
        let summary = summaries[indexPath.item]
        item.configure(summary, number: indexPath.item + 1, sourceIcon: icon(for: summary.sourceBundleID))
        item.onAction = { [weak self] action in
            guard let self, let current = self.summaries.firstIndex(where: { $0.id == summary.id }) else { return }
            self.selectedIndex = current
            self.selectCurrent()
            switch action {
            case .pin: self.pinSelection()
            case .rename: self.renameSelection()
            case .preview: self.previewSelection()
            case .copy: self.copySelection()
            case .paste: self.pasteSelection()
            case .alternateFormat: self.choose(plainText: true, copyOnly: false)
            case .delete: self.deleteSelection()
            }
        }
        return item
    }

    public func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        if let index = indexPaths.first?.item { selectedIndex = index; updateSelectionActions() }
    }

    private func icon(for bundleID: String) -> NSImage {
        if let cached = sourceIcons[bundleID] { return cached }
        let image: NSImage
        if !bundleID.isEmpty, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            image = NSWorkspace.shared.icon(forFile: url.path)
        } else { image = NSImage(systemSymbolName: "app.dashed", accessibilityDescription: "来源应用未安装")! }
        if sourceIcons.count < 256 { sourceIcons[bundleID] = image }
        return image
    }

    private func configureContent() {
        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 20
        background.layer?.masksToBounds = true
        panel.contentView = background

        let brand = NSTextField(labelWithString: "ClipDune")
        brand.font = .systemFont(ofSize: 19, weight: .bold)
        let subtitle = NSTextField(labelWithString: "拾贴 · 随手复制，随时找回")
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        let branding = NSStackView(views: [brand, subtitle])
        branding.orientation = .vertical
        branding.alignment = .leading
        branding.spacing = 3
        filter.selectedSegment = 0
        filter.target = self
        filter.action = #selector(changeFilter)
        filter.segmentStyle = .rounded
        searchField.placeholderString = "直接输入搜索 · 内容或来源应用"
        searchField.font = .systemFont(ofSize: 15)
        searchField.controlSize = .large
        searchField.focusRingType = .none
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        searchField.sendsWholeSearchString = false
        searchField.setAccessibilityLabel("搜索剪贴板历史")
        searchField.identifier = NSUserInterfaceItemIdentifier("clipdune.search")
        typeFilter.addItems(withTitles: ["全部类型"] + ClipKind.allCases.map(\.title))
        timeFilter.addItems(withTitles: HistoryFilter.Period.allCases.map(\.title))
        typeFilter.identifier = NSUserInterfaceItemIdentifier("clipdune.filter.type")
        timeFilter.identifier = NSUserInterfaceItemIdentifier("clipdune.filter.time")
        typeFilter.setAccessibilityLabel("按内容类型筛选")
        timeFilter.setAccessibilityLabel("按复制时间筛选")
        for picker in [typeFilter, timeFilter] {
            picker.target = self
            picker.action = #selector(changeSearchFilter)
            picker.controlSize = .small
        }
        clearFilters.image = NSImage(systemSymbolName: "line.3.horizontal.decrease.circle", accessibilityDescription: "清除类型和时间筛选")
        clearFilters.target = self
        clearFilters.action = #selector(resetSearchFilters)
        clearFilters.isBordered = false
        clearFilters.isEnabled = false
        clearFilters.toolTip = "清除类型和时间筛选，保留关键词"
        clearFilters.identifier = NSUserInterfaceItemIdentifier("clipdune.filter.clear")
        let settingsButton = NSButton(image: NSImage(systemSymbolName: "gearshape", accessibilityDescription: "设置")!,
                                      target: self, action: #selector(showSettings))
        settingsButton.isBordered = false
        settingsButton.toolTip = "设置 ⌘,"
        let header = NSStackView(views: [branding, filter, searchField, typeFilter, timeFilter, clearFilters, settingsButton])
        header.spacing = 12
        header.alignment = .centerY
        searchField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true

        let layout = NSCollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.itemSize = NSSize(width: 222, height: 232)
        layout.minimumLineSpacing = 12
        layout.sectionInset = NSEdgeInsets(top: 3, left: 2, bottom: 3, right: 2)
        collection.collectionViewLayout = layout
        collection.dataSource = self
        collection.delegate = self
        collection.isSelectable = true
        collection.allowsMultipleSelection = false
        collection.backgroundColors = [.clear]
        collection.register(ClipCard.self, forItemWithIdentifier: NSUserInterfaceItemIdentifier("clip"))
        scrollView.documentView = collection
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = false
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true
        emptyLabel.alignment = .center
        emptyLabel.font = .systemFont(ofSize: 16, weight: .medium)
        emptyLabel.textColor = .secondaryLabelColor

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        countLabel.font = .systemFont(ofSize: 11)
        countLabel.textColor = .tertiaryLabelColor
        let pin = NSButton(title: "收藏 ⌘P", target: self, action: #selector(pinSelection))
        pinButton = pin
        let rename = NSButton(title: "重命名 ⌘R", target: self, action: #selector(renameSelection))
        let preview = NSButton(title: "预览 ⌘Y", target: self, action: #selector(previewSelection))
        let copy = NSButton(title: "复制 ⌥↩", target: self, action: #selector(copySelection))
        let delete = NSButton(title: "删除", target: self, action: #selector(deleteSelection))
        let paste = NSButton(title: "粘贴 ↩", target: self, action: #selector(pasteSelection))
        paste.bezelColor = NSColor.systemTeal
        latestButton.title = "回到最新"
        latestButton.image = NSImage(systemSymbolName: "arrow.left.to.line", accessibilityDescription: "回到最新")
        latestButton.imagePosition = .imageLeading
        latestButton.target = self
        latestButton.action = #selector(returnToLatest)
        latestButton.identifier = NSUserInterfaceItemIdentifier("clipdune.returnToLatest")
        latestButton.isEnabled = false
        latestButton.toolTip = "回到当前结果最左侧并选中最新项，保留关键词与筛选条件"
        latestButton.setAccessibilityLabel("回到最新")
        buttons = [latestButton, delete, pin, rename, preview, copy, paste]
        buttons.forEach { $0.bezelStyle = .rounded; $0.controlSize = .small }
        let actions = NSStackView(views: [latestButton, delete, pin, rename, preview, copy, paste])
        actions.spacing = 8
        let footer = NSStackView(views: [statusLabel, countLabel, actions])
        footer.spacing = 16
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let help = NSTextField(labelWithString: "↑ ↓ 选择   ·   ⇧↩ 纯文本   ·   ⌘1–9 快捷粘贴   ·   Esc 关闭")
        help.font = .systemFont(ofSize: 10)
        help.textColor = .tertiaryLabelColor

        [header, scrollView, footer, help, emptyLabel].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; background.addSubview($0) }
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 22),
            header.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -22),
            header.topAnchor.constraint(equalTo: background.topAnchor, constant: 17),
            header.heightAnchor.constraint(equalToConstant: 43),
            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 14),
            scrollView.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 18),
            scrollView.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -18),
            scrollView.heightAnchor.constraint(equalToConstant: 248),
            footer.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            footer.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 9),
            footer.heightAnchor.constraint(equalToConstant: 22),
            help.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            help.topAnchor.constraint(equalTo: footer.bottomAnchor, constant: 6),
            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor)
        ])
    }

    private func handleShortcut(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command), let key = event.charactersIgnoringModifiers?.lowercased() else { return false }
        if key == "f" { focusSearch(); return true }
        if key == "p" { pinSelection(); return true }
        if key == "r" { renameSelection(); return true }
        if key == "y" { previewSelection(); return true }
        if key == "," { showSettings(); return true }
        if let number = Int(key), (1...9).contains(number), summaries.indices.contains(number - 1) {
            selectedIndex = number - 1
            choose(plainText: event.modifierFlags.contains(.shift), copyOnly: false)
            return true
        }
        return false
    }

    private func handlePanelEvent(_ event: NSEvent) -> Bool {
        guard panel.isKeyWindow, panel.attachedSheet == nil else { return false }
        if event.type == .leftMouseDown, event.clickCount == 2 {
            var hit = panel.contentView?.hitTest(event.locationInWindow)
            while let view = hit {
                if view is NSButton { return false }
                hit = view.superview
            }
            let point = collection.convert(event.locationInWindow, from: nil)
            if collection.visibleRect.contains(point), let indexPath = collection.indexPathForItem(at: point), summaries.indices.contains(indexPath.item) {
                selectedIndex = indexPath.item
                selectCurrent()
                choose(plainText: event.modifierFlags.contains(.shift), copyOnly: event.modifierFlags.contains(.option))
                return true
            }
        }
        guard event.type == .keyDown, !(panel.firstResponder is NSTextView),
              !event.modifierFlags.contains(.command), !event.modifierFlags.contains(.control) else { return false }
        switch event.keyCode {
        case 53: hide(); return true
        case 36, 76:
            choose(plainText: event.modifierFlags.contains(.shift), copyOnly: event.modifierFlags.contains(.option))
            return true
        case 123, 126: moveSelection(-1); return true
        case 124, 125: moveSelection(1); return true
        case 48, 51, 117, 115, 119, 116, 121: return false
        default:
            guard event.characters?.unicodeScalars.contains(where: { $0.value >= 32 && !($0.value >= 0xF700 && $0.value <= 0xF8FF) }) == true || event.characters?.isEmpty == true else { return false }
            focusSearch()
            return false
        }
    }

    private func moveSelection(_ offset: Int) {
        selectedIndex = min(max(0, selectedIndex + offset), max(0, summaries.count - 1))
        selectCurrent()
    }

    private func selectCurrent(scrollIntoView: Bool = true) {
        updateSelectionActions()
        guard summaries.indices.contains(selectedIndex) else { return }
        let selection: Set<IndexPath> = [IndexPath(item: selectedIndex, section: 0)]
        collection.selectionIndexPaths = selection
        if scrollIntoView { collection.scrollToItems(at: selection, scrollPosition: .nearestHorizontalEdge) }
    }

    private func scrollToBeginning() {
        panel.contentView?.layoutSubtreeIfNeeded()
        collection.layoutSubtreeIfNeeded()
        let clip = scrollView.contentView
        clip.scroll(to: NSPoint(x: 0, y: clip.bounds.minY))
        scrollView.reflectScrolledClipView(clip)
    }

    @objc private func returnToLatest() {
        selectedIndex = 0
        selectCurrent(scrollIntoView: false)
        scrollToBeginning()
        focusSearch()
    }

    private func updateSelectionActions() {
        pinButton?.title = summaries.indices.contains(selectedIndex) && summaries[selectedIndex].isPinned ? "取消收藏 ⌘P" : "收藏 ⌘P"
    }

    @objc private func changeSearchFilter() {
        clearFilters.isEnabled = searchFilter != HistoryFilter()
        onSearch?(query, pinnedOnly)
        focusSearch()
    }

    @objc private func resetSearchFilters() {
        typeFilter.selectItem(at: 0)
        timeFilter.selectItem(at: 0)
        changeSearchFilter()
    }

    private func choose(plainText: Bool, copyOnly: Bool) {
        guard summaries.indices.contains(selectedIndex) else { return }
        onChoose?(summaries[selectedIndex], plainText, copyOnly)
    }

    @objc private func changeFilter() { onSearch?(query, pinnedOnly); focusSearch() }
    @objc private func pinSelection() { if summaries.indices.contains(selectedIndex) { onPin?(summaries[selectedIndex]) } }
    @objc private func renameSelection() { if summaries.indices.contains(selectedIndex) { onRename?(summaries[selectedIndex]) } }
    @objc private func previewSelection() { if summaries.indices.contains(selectedIndex) { onPreview?(summaries[selectedIndex]) } }
    @objc private func deleteSelection() { if summaries.indices.contains(selectedIndex) { onDelete?(summaries[selectedIndex]) } }
    @objc private func copySelection() { choose(plainText: false, copyOnly: true) }
    @objc private func pasteSelection() { choose(plainText: NSEvent.modifierFlags.contains(.shift), copyOnly: false) }
    @objc private func showSettings() { onSettings?() }
}
