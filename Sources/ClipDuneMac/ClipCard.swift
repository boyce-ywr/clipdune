import AppKit
import ClipDuneCore

enum CardAction: String, CaseIterable {
    case pin, rename, preview, copy, paste, alternateFormat, delete
}

@MainActor
private final class CardSurface: NSView {
    var contextMenu: (() -> NSMenu)?
    override func menu(for event: NSEvent) -> NSMenu? { contextMenu?() }
}

@MainActor
final class ClipCard: NSCollectionViewItem {
    var onAction: ((CardAction) -> Void)?
    private let source = NSTextField(labelWithString: "")
    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let content = NSTextField(wrappingLabelWithString: "")
    private let caption = NSTextField(labelWithString: "")
    private let size = NSTextField(labelWithString: "")
    private let picture = NSImageView()
    private let swatch = NSView()
    private let pin = NSButton()
    private let more = NSButton()
    private var summary: ClipSummary?
    private var pictureTop: NSLayoutConstraint?
    private var swatchTop: NSLayoutConstraint?

    override var isSelected: Bool { didSet { updateAppearance() } }

    override func loadView() {
        let surface = CardSurface()
        surface.wantsLayer = true
        surface.layer?.cornerRadius = 12
        surface.contextMenu = { [weak self] in self?.makeMenu() ?? NSMenu() }
        view = surface
        source.font = .systemFont(ofSize: 11, weight: .semibold)
        source.textColor = .systemTeal
        source.lineBreakMode = .byTruncatingTail
        icon.imageScaling = .scaleProportionallyDown
        name.font = .systemFont(ofSize: 13, weight: .semibold)
        name.lineBreakMode = .byTruncatingTail
        name.textColor = .labelColor
        content.font = .systemFont(ofSize: 12)
        content.maximumNumberOfLines = 7
        content.lineBreakMode = .byWordWrapping
        content.cell?.wraps = true
        content.cell?.usesSingleLineMode = false
        for label in [source, name, content, caption, size] {
            label.isSelectable = false
            label.isEditable = false
            label.isBezeled = false
        }
        caption.font = .systemFont(ofSize: 10)
        caption.textColor = .secondaryLabelColor
        caption.lineBreakMode = .byTruncatingTail
        size.font = .systemFont(ofSize: 10, weight: .medium)
        size.textColor = .secondaryLabelColor
        size.lineBreakMode = .byTruncatingTail
        size.identifier = NSUserInterfaceItemIdentifier("clipdune.card.size")
        picture.imageScaling = .scaleProportionallyUpOrDown
        swatch.wantsLayer = true
        swatch.layer?.cornerRadius = 8

        configureButton(pin, symbol: "star", title: "收藏", action: .pin)
        let rename = button(symbol: "pencil", title: "重命名 · ⌘R", action: .rename)
        let preview = button(symbol: "eye", title: "预览 · ⌘Y", action: .preview)
        let copy = button(symbol: "doc.on.doc", title: "仅复制，不粘贴 · ⌥↩", action: .copy)
        let paste = button(symbol: "arrow.down.doc", title: "粘贴到原光标位置 · ↩", action: .paste)
        paste.contentTintColor = .systemTeal
        configureButton(more, symbol: "ellipsis", title: "更多操作", action: nil)
        more.action = #selector(showMore)
        more.identifier = NSUserInterfaceItemIdentifier("clipdune.card.more")
        let actions = NSStackView(views: [rename, preview, copy, paste, more])
        actions.orientation = .horizontal
        actions.distribution = .equalSpacing
        let textStack = NSStackView(views: [name, content])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 6
        name.isHidden = true
        for child in [source, icon, pin, textStack, picture, swatch, caption, size, actions] {
            child.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(child)
        }
        pictureTop = picture.topAnchor.constraint(equalTo: source.bottomAnchor, constant: 12)
        swatchTop = swatch.topAnchor.constraint(equalTo: source.bottomAnchor, constant: 12)
        NSLayoutConstraint.activate([
            source.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            source.topAnchor.constraint(equalTo: view.topAnchor, constant: 14),
            source.trailingAnchor.constraint(equalTo: icon.leadingAnchor, constant: -6),
            icon.widthAnchor.constraint(equalToConstant: 22), icon.heightAnchor.constraint(equalToConstant: 22),
            icon.centerYAnchor.constraint(equalTo: source.centerYAnchor),
            icon.trailingAnchor.constraint(equalTo: pin.leadingAnchor, constant: -5),
            pin.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            pin.centerYAnchor.constraint(equalTo: source.centerYAnchor),
            textStack.topAnchor.constraint(equalTo: source.bottomAnchor, constant: 12),
            textStack.leadingAnchor.constraint(equalTo: source.leadingAnchor),
            textStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            textStack.bottomAnchor.constraint(lessThanOrEqualTo: size.topAnchor, constant: -9),
            content.widthAnchor.constraint(equalTo: textStack.widthAnchor),
            name.widthAnchor.constraint(equalTo: textStack.widthAnchor),
            picture.leadingAnchor.constraint(equalTo: textStack.leadingAnchor),
            picture.trailingAnchor.constraint(equalTo: textStack.trailingAnchor),
            pictureTop!,
            picture.bottomAnchor.constraint(equalTo: size.topAnchor, constant: -9),
            swatch.leadingAnchor.constraint(equalTo: textStack.leadingAnchor),
            swatch.trailingAnchor.constraint(equalTo: textStack.trailingAnchor),
            swatchTop!,
            swatch.bottomAnchor.constraint(equalTo: size.topAnchor, constant: -9),
            size.leadingAnchor.constraint(equalTo: source.leadingAnchor),
            size.bottomAnchor.constraint(equalTo: actions.topAnchor, constant: -8),
            caption.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            caption.centerYAnchor.constraint(equalTo: size.centerYAnchor),
            size.trailingAnchor.constraint(lessThanOrEqualTo: caption.leadingAnchor, constant: -5),
            actions.leadingAnchor.constraint(equalTo: source.leadingAnchor),
            actions.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            actions.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8),
            actions.heightAnchor.constraint(equalToConstant: 26)
        ])
        updateAppearance()
    }

    func configure(_ summary: ClipSummary, number: Int, sourceIcon: NSImage) {
        self.summary = summary
        source.stringValue = summary.kind.title + (number < 10 ? "  ⌘\(number)" : "")
        source.toolTip = "\(summary.kind.title) · \(summary.sourceName)"
        icon.image = sourceIcon
        icon.identifier = NSUserInterfaceItemIdentifier("clipdune.card.sourceIcon")
        icon.toolTip = "来源：\(summary.sourceName)"
        icon.setAccessibilityLabel("来源应用：\(summary.sourceName)")
        name.stringValue = summary.userTitle
        if summary.kind == .color, name.stringValue.isEmpty { name.stringValue = summary.text }
        name.isHidden = name.stringValue.isEmpty
        name.toolTip = summary.userTitle
        name.identifier = NSUserInterfaceItemIdentifier("clipdune.card.name")
        content.stringValue = summary.text.isEmpty ? "其他数据 · 点击预览查看格式" : String(summary.text.prefix(600))
        picture.image = summary.thumbnail.flatMap(NSImage.init(data:))
        picture.isHidden = picture.image == nil
        swatch.isHidden = summary.kind != .color
        swatch.layer?.backgroundColor = PasteboardCodec.colorFromHex(summary.text)?.cgColor ?? NSColor.clear.cgColor
        if !picture.isHidden || !swatch.isHidden {
            content.isHidden = true
        } else { content.isHidden = false }
        pictureTop?.constant = name.isHidden ? 12 : 36
        swatchTop?.constant = name.isHidden ? 12 : 36
        size.stringValue = summary.sizeLabel
        size.toolTip = summary.kind == .image ? "保存的首选图像表示大小，不含缩略图" : summary.kind == .files ? "仅保存文件引用，不读取文件实际大小" : summary.sizeLabel
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.unitsStyle = .short
        caption.stringValue = formatter.localizedString(for: summary.copiedAt, relativeTo: Date())
        caption.toolTip = "\(number < 10 ? "⌘\(number) · " : "")\(summary.copiedAt.formatted())"
        pin.image = NSImage(systemSymbolName: summary.isPinned ? "star.fill" : "star", accessibilityDescription: summary.isPinned ? "取消收藏" : "收藏")
        pin.contentTintColor = summary.isPinned ? .systemYellow : .secondaryLabelColor
        pin.toolTip = summary.isPinned ? "取消收藏 · ⌘P" : "收藏 · ⌘P"
        pin.setAccessibilityLabel(summary.isPinned ? "取消收藏" : "收藏")
        view.toolTip = summary.userTitle.isEmpty ? nil : summary.userTitle
        view.setAccessibilityLabel("\(summary.userTitle)，\(summary.kind.title)，\(summary.sourceName)，\(summary.sizeLabel)")
    }

    private func button(symbol: String, title: String, action: CardAction) -> NSButton {
        let button = NSButton()
        configureButton(button, symbol: symbol, title: title, action: action)
        return button
    }

    private func configureButton(_ button: NSButton, symbol: String, title: String, action: CardAction?) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        button.imagePosition = .imageOnly
        button.bezelStyle = .inline
        button.isBordered = false
        button.controlSize = .small
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = title
        button.setAccessibilityLabel(title)
        button.target = self
        button.action = #selector(performAction(_:))
        button.identifier = NSUserInterfaceItemIdentifier("clipdune.card.\(action?.rawValue ?? "more")")
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 26).isActive = true
        button.heightAnchor.constraint(equalToConstant: 26).isActive = true
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        for (action, title) in [(CardAction.pin, summary?.isPinned == true ? "取消收藏" : "收藏"),
                                (.rename, "重命名…"), (.preview, "预览"), (.copy, "仅复制"),
                                (.paste, "粘贴"), (.alternateFormat, "切换格式粘贴（Shift-Return）"), (.delete, "删除")] {
            if action == .delete { menu.addItem(.separator()) }
            let item = NSMenuItem(title: title, action: #selector(performAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = action.rawValue
            item.identifier = NSUserInterfaceItemIdentifier("clipdune.card.\(action.rawValue)")
            menu.addItem(item)
        }
        return menu
    }

    @objc private func performAction(_ sender: AnyObject) {
        if let event = NSApp.currentEvent, [.leftMouseDown, .leftMouseUp].contains(event.type), event.clickCount > 1 { return }
        let value = (sender as? NSMenuItem)?.representedObject as? String ?? (sender as? NSButton)?.identifier?.rawValue.replacingOccurrences(of: "clipdune.card.", with: "")
        if let value, let action = CardAction(rawValue: value) { onAction?(action) }
    }

    @objc private func showMore() {
        makeMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: more.bounds.maxY), in: more)
    }

    private func updateAppearance() {
        view.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        view.layer?.borderWidth = isSelected ? 2 : 1
        view.layer?.borderColor = (isSelected ? NSColor.systemTeal : NSColor.separatorColor.withAlphaComponent(0.45)).cgColor
    }
}
