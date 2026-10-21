import AppKit
import ClipDuneCore
import ClipDuneMac
import ServiceManagement
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: HistoryStore?
    private var panel: ClipboardPanelController?
    private var monitor: ClipboardMonitor?
    private var shortcut: GlobalShortcut?
    private var statusItem: NSStatusItem?
    private var statusMenuItem: NSMenuItem?
    private var pauseMenuItem: NSMenuItem?
    private var excludedMenu: NSMenu?
    private var destination: PasteDestination?
    private var searchGeneration = 0
    private var interactionGeneration = 0
    private var dataDirectory: URL?
    private var temporaryDirectory: URL?
    private var pasteboard: NSPasteboard?
    private var toast: NSPanel?
    private var toastGeneration = 0
    private var isDemo = false
    private var qaDirectory: URL?
    private var lastStatus = "正在初始化…"
    private var exclusionList = CapturePolicy.defaultExcludedApplications

    func applicationDidFinishLaunching(_ notification: Notification) {
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--ui-check"), arguments.indices.contains(index + 1) {
            qaDirectory = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        }
        isDemo = arguments.contains("--demo") || qaDirectory != nil
        if isDemo {
            temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("clipdune-demo-\(UUID().uuidString)")
            dataDirectory = temporaryDirectory
            pasteboard = NSPasteboard(name: NSPasteboard.Name("app.clipdune.demo.\(UUID().uuidString)"))
        } else {
            dataDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ClipDune")
            pasteboard = .general
            if let saved = UserDefaults.standard.stringArray(forKey: "excludedApplications") { exclusionList = Set(saved) }
        }
        do {
            store = try HistoryStore(directory: dataDirectory!)
        } catch {
            showError(error.localizedDescription)
            NSApp.terminate(nil)
            return
        }
        configureMainMenu()
        let controller = ClipboardPanelController()
        panel = controller
        controller.onSearch = { [weak self] query, pinned in self?.search(query, pinned: pinned, reset: true) }
        controller.onChoose = { [weak self] summary, plain, copyOnly in self?.choose(summary, plain: plain, copyOnly: copyOnly) }
        controller.onPin = { [weak self] summary in
            Task { @MainActor in
                guard let self, let store = self.store else { return }
                do {
                    try await store.setPinned(!summary.isPinned, for: summary.id)
                    self.refresh()
                } catch { self.showError(error.localizedDescription) }
            }
        }
        controller.onPreview = { [weak self] summary in
            guard let self else { return }
            let generation = self.interactionGeneration
            Task { @MainActor in
                do {
                    guard let content = try await self.store?.content(for: summary.id),
                          self.interactionGeneration == generation, self.panel?.isVisible == true else { return }
                    self.panel?.showPreview(content)
                } catch { self.showError(error.localizedDescription) }
            }
        }
        controller.onDelete = { [weak self] summary in
            Task { @MainActor in
                guard let self else { return }
                do { try await self.store?.delete(summary.id); self.refresh() }
                catch { self.showError(error.localizedDescription) }
            }
        }
        configureStatusMenu()
        if !isDemo {
            let observer = ClipboardMonitor(pasteboard: pasteboard!)
            observer.excludedApplications = exclusionList
            observer.onStatus = { [weak self] in self?.setStatus($0) }
            observer.onCapture = { [weak self] content in
                let copiedAt = Date()
                Task { @MainActor in
                    guard let self, let store = self.store else { return }
                    do {
                        try await store.record(content, at: copiedAt)
                        self.refresh()
                    } catch { self.setStatus(error.localizedDescription) }
                }
            }
            monitor = observer
            observer.start()
            shortcut = GlobalShortcut { [weak self] in self?.togglePanel() }
            let preset = GlobalShortcut.Preset(rawValue: UserDefaults.standard.integer(forKey: "shortcutPreset")) ?? .commandShiftV
            registerShortcut(preset)
        }
        Task { @MainActor in
            do {
                try await store?.pruneExpired()
                if isDemo {
                    try await seedDemo()
                    setStatus("演示模式 · 不读取真实剪贴板 · 不保存个人数据")
                    if let qaDirectory { await runUICheck(directory: qaDirectory) }
                    else { togglePanel() }
                }
            } catch { showError(error.localizedDescription) }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor?.stop()
        shortcut?.unregister()
        panel?.hide()
        if isDemo { pasteboard?.releaseGlobally() }
        if let temporaryDirectory { try? FileManager.default.removeItem(at: temporaryDirectory) }
    }

    private func configureMainMenu() {
        let menu = NSMenu()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "退出 ClipDune", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        menu.addItem(appItem)
        let editItem = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
        let edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        menu.addItem(editItem)
        NSApp.mainMenu = menu
    }

    private func configureStatusMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem?.button?.image = NSImage(systemSymbolName: "square.stack.3d.up", accessibilityDescription: "ClipDune")
        statusItem?.button?.toolTip = "ClipDune — 拾贴"
        let menu = NSMenu()
        add("打开 ClipDune", action: #selector(togglePanel), to: menu)
        statusMenuItem = add(lastStatus, action: nil, to: menu)
        menu.addItem(.separator())
        pauseMenuItem = add("暂停记录", action: #selector(togglePause), to: menu)
        add("允许后台读取剪贴板…", action: #selector(requestClipboardAccess), to: menu)
        add("启用直接粘贴…", action: #selector(requestPasteAccess), to: menu)
        let shortcuts = NSMenu()
        for preset in GlobalShortcut.Preset.allCases {
            let item = add(preset.label, action: #selector(changeShortcut(_:)), to: shortcuts)
            item.tag = preset.rawValue
            item.state = UserDefaults.standard.integer(forKey: "shortcutPreset") == preset.rawValue ? .on : .off
        }
        let shortcutItem = add("唤出快捷键", action: nil, to: menu)
        shortcutItem.submenu = shortcuts
        let exclusions = NSMenu()
        excludedMenu = exclusions
        let exclusionItem = add("不记录这些应用", action: nil, to: menu)
        exclusionItem.submenu = exclusions
        refreshExclusions()
        let loginItem = add("登录时启动", action: #selector(toggleLogin(_:)), to: menu)
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        loginItem.isEnabled = !isDemo
        menu.addItem(.separator())
        add("清理未收藏历史…", action: #selector(clearHistory), to: menu)
        add("导出本地备份…", action: #selector(exportHistory), to: menu)
        add("导入本地备份…", action: #selector(importHistory), to: menu)
        add("打开数据文件夹", action: #selector(revealData), to: menu)
        menu.addItem(.separator())
        add("关于 ClipDune", action: #selector(showAbout), to: menu)
        add("退出", action: #selector(quit), to: menu)
        statusItem?.menu = menu
    }

    @discardableResult
    private func add(_ title: String, action: Selector?, to menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return item
    }

    @objc private func togglePanel() {
        guard let panel else { return }
        interactionGeneration += 1
        if !panel.isVisible { destination = PasteDestination.capture() }
        panel.show()
        panel.setStatus(lastStatus)
    }

    private func search(_ query: String, pinned: Bool, reset: Bool) {
        searchGeneration += 1
        let generation = searchGeneration
        Task { @MainActor in
            guard let store else { return }
            do {
                let results = try await store.search(query, pinnedOnly: pinned)
                guard generation == searchGeneration else { return }
                panel?.update(results, resetSelection: reset)
            } catch { setStatus(error.localizedDescription) }
        }
    }

    private func refresh() {
        guard let panel, panel.isVisible else { return }
        search(panel.query, pinned: panel.pinnedOnly, reset: false)
    }

    private func choose(_ summary: ClipSummary, plain: Bool, copyOnly: Bool) {
        let generation = interactionGeneration
        let target = destination
        Task { @MainActor in
            do {
                guard let content = try await store?.content(for: summary.id), let panel, let pasteboard,
                      generation == interactionGeneration, panel.isVisible else { return }
                guard PasteboardCodec.write(content, to: pasteboard, plainText: plain) else {
                    setStatus("未能写入剪贴板，内容仍保留在历史中")
                    return
                }
                monitor?.skipCurrentChange()
                interactionGeneration += 1
                let transaction = interactionGeneration
                panel.hide()
                await Task.yield()
                guard transaction == interactionGeneration else { return }
                if !copyOnly, !isDemo, target?.pasteIfStillFocused() == true {
                    showToast("已向原应用发送粘贴")
                } else {
                    showToast(isDemo ? "演示复制成功 · 未改动系统剪贴板" : "已复制 · 按 ⌘V 粘贴")
                }
            } catch { setStatus(error.localizedDescription) }
        }
    }

    private func setStatus(_ text: String) {
        lastStatus = text
        statusMenuItem?.title = text
        statusItem?.button?.toolTip = "ClipDune · \(text)"
        panel?.setStatus(text)
    }

    private func registerShortcut(_ preset: GlobalShortcut.Preset) {
        let previous = GlobalShortcut.Preset(rawValue: UserDefaults.standard.integer(forKey: "shortcutPreset")) ?? .commandShiftV
        guard shortcut?.register(preset) == true else {
            if previous != preset { _ = shortcut?.register(previous) }
            setStatus("快捷键被占用 · 请在菜单中选择其他组合")
            return
        }
        UserDefaults.standard.set(preset.rawValue, forKey: "shortcutPreset")
        setStatus(monitor?.status ?? "已就绪")
    }

    @objc private func togglePause() {
        guard let monitor else { return }
        monitor.isPaused.toggle()
        pauseMenuItem?.title = monitor.isPaused ? "恢复记录" : "暂停记录"
        pauseMenuItem?.state = monitor.isPaused ? .on : .off
    }

    @objc private func requestClipboardAccess() {
        guard !isDemo else { return }
        monitor?.requestAccess()
        showToast("在系统设置中将 ClipDune 的剪贴板访问设为始终允许")
    }

    @objc private func requestPasteAccess() {
        guard !isDemo else { return }
        PasteDestination.requestPermission()
        showToast(PasteDestination.hasPermission ? "直接粘贴已就绪" : "请在系统设置 → 隐私与安全性中允许辅助功能访问")
    }

    @objc private func changeShortcut(_ sender: NSMenuItem) {
        guard let preset = GlobalShortcut.Preset(rawValue: sender.tag), !isDemo else { return }
        registerShortcut(preset)
        for item in sender.menu?.items ?? [] {
            item.state = item.tag == UserDefaults.standard.integer(forKey: "shortcutPreset") ? .on : .off
        }
    }

    @objc private func toggleLogin(_ sender: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
            sender.state = SMAppService.mainApp.status == .enabled ? .on : .off
        } catch { showError("无法修改登录启动设置，请将应用放入 Applications 后重试。") }
    }

    private func refreshExclusions() {
        guard let menu = excludedMenu else { return }
        menu.removeAllItems()
        add("添加应用…", action: #selector(addExclusion), to: menu)
        menu.addItem(.separator())
        for bundleID in exclusionList.sorted() {
            let item = add(bundleID, action: #selector(removeExclusion(_:)), to: menu)
            item.representedObject = bundleID
            item.state = .on
        }
    }

    @objc private func addExclusion() {
        panel?.hide()
        let picker = NSOpenPanel()
        picker.allowedContentTypes = [.applicationBundle]
        picker.directoryURL = URL(fileURLWithPath: "/Applications")
        picker.message = "仅停止未来采集；已保存的内容不会自动删除。"
        guard picker.runModal() == .OK, let url = picker.url, let bundleID = Bundle(url: url)?.bundleIdentifier else { return }
        exclusionList.insert(bundleID)
        saveExclusions()
    }

    @objc private func removeExclusion(_ sender: NSMenuItem) {
        guard let bundleID = sender.representedObject as? String else { return }
        exclusionList.remove(bundleID)
        saveExclusions()
    }

    private func saveExclusions() {
        monitor?.excludedApplications = exclusionList
        if !isDemo { UserDefaults.standard.set(exclusionList.sorted(), forKey: "excludedApplications") }
        refreshExclusions()
    }

    @objc private func clearHistory() {
        panel?.hide()
        let alert = NSAlert()
        alert.messageText = "删除所有未收藏的历史？"
        alert.informativeText = "收藏不会删除。此操作不可撤销，也不会修改系统当前剪贴板。"
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "删除历史")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        Task { @MainActor in
            do { try await store?.clearUnpinned(); showToast("未收藏历史已清理"); refresh() }
            catch { showError(error.localizedDescription) }
        }
    }

    @objc private func exportHistory() {
        panel?.hide()
        let picker = NSSavePanel()
        picker.nameFieldStringValue = "ClipDune.clipdunebackup"
        picker.message = "备份包含原始剪贴板内容，未加密。请仅保存到你信任的位置，不要直接分享。"
        guard picker.runModal() == .OK, let url = picker.url else { return }
        Task { @MainActor in
            do {
                guard let data = try await store?.exportArchive() else { return }
                try data.write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                showToast("本地备份已导出")
            } catch { showError("备份导出失败，请检查目标目录权限与空间。") }
        }
    }

    @objc private func importHistory() {
        panel?.hide()
        let picker = NSOpenPanel()
        picker.allowedContentTypes = [UTType(filenameExtension: "clipdunebackup") ?? .data]
        picker.message = "仅导入你信任的 ClipDune 备份。排除应用与敏感标记规则仍然生效；已有内容不会被清空。"
        guard picker.runModal() == .OK, let url = picker.url else { return }
        let exclusions = exclusionList
        Task { @MainActor in
            do {
                guard let store else { return }
                let count = try await store.importArchive(from: url, excludedApplications: exclusions)
                showToast("备份已处理：\(count) 项通过校验")
                refresh()
            } catch { showError(error.localizedDescription) }
        }
    }

    @objc private func revealData() { if let dataDirectory { NSWorkspace.shared.open(dataDirectory) } }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func showAbout() {
        panel?.hide()
        let alert = NSAlert()
        alert.messageText = "ClipDune · 拾贴 0.1.0"
        alert.informativeText = "独立开发的 macOS 剪贴板工具。\n\n本地保存，不联网、不上传、无账号。默认保留 30 天和最多 2,000 条普通历史；收藏不自动过期。内容预算 256 MiB，单项上限 16 MiB。\n\n密码过滤不是绝对保证；请将敏感来源加入排除列表。当前为开发预览版，尚未签名公证或通过商店审核。"
        alert.runModal()
    }

    private func showError(_ message: String) {
        panel?.hide()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "ClipDune"
        alert.informativeText = message
        alert.runModal()
    }

    private func showToast(_ message: String) {
        toastGeneration += 1
        let generation = toastGeneration
        toast?.orderOut(nil)
        let screen = panel?.panel.screen ?? NSScreen.main
        let frame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1_000, height: 800)
        let toast = NSPanel(contentRect: NSRect(x: frame.midX - 230, y: frame.minY + 28, width: 460, height: 48),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        toast.level = .floating
        toast.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .canJoinAllApplications]
        toast.isOpaque = false
        toast.backgroundColor = .clear
        toast.ignoresMouseEvents = true
        let effect = NSVisualEffectView(frame: toast.contentView!.bounds)
        effect.material = .hudWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        let label = NSTextField(labelWithString: message)
        label.frame = NSRect(x: 12, y: 15, width: 436, height: 20)
        label.alignment = .center
        label.font = .systemFont(ofSize: 12, weight: .medium)
        effect.addSubview(label)
        toast.contentView = effect
        toast.orderFrontRegardless()
        self.toast = toast
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.3) { [weak self] in
            guard let self, self.toastGeneration == generation else { return }
            self.toast?.orderOut(nil)
            self.toast = nil
        }
    }

    private func seedDemo() async throws {
        let examples: [(String, ClipKind, String)] = [
            ("设计不是堆功能。\n\n先把每一次唤出、检索与粘贴做对。", .text, "备忘录"),
            ("https://developer.apple.com/documentation/appkit", .link, "Safari"),
            ("git status --short\nmake test\nswift build -c release", .text, "终端"),
            ("本周进展\n• 全屏工作流\n• 键盘快速检索\n• 本地隐私保护", .text, "文本编辑"),
            ("部署前检查配置；部署后核对实际运行版本。", .text, "开发笔记"),
            ("ClipDune\n拾贴\n\n随手复制，随时找回。", .text, "欢迎")
        ]
        for (index, example) in examples.enumerated() {
            let content = ClipboardContent(fragments: [.init(representations: [.init(type: NSPasteboard.PasteboardType.string.rawValue, data: Data(example.0.utf8))])],
                                           text: example.0, kind: example.1, sourceName: example.2, sourceBundleID: "app.clipdune.fixture")
            if let identity = try await store?.record(content, at: Date().addingTimeInterval(Double(index) * -120)), index == 0 {
                try await store?.setPinned(true, for: identity)
            }
        }
    }

    private func runUICheck(directory: URL) async {
        await UICheck.run(panel: panel!, directory: directory, open: { [weak self] in self?.togglePanel() })
        NSApp.terminate(nil)
    }
}
