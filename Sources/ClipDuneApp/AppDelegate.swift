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
    private var preferences = AppPreferences(defaults: .standard)
    private var settingsModel: SettingsModel?
    private var settingsWindow: SettingsWindowController?
    private var preferencesTask: Task<Void, Never>?
    private var lastPreferencesVersion = 0
    private var updater: UpdateController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--ui-check"), arguments.indices.contains(index + 1) {
            qaDirectory = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        }
        isDemo = arguments.contains("--demo") || qaDirectory != nil
        if isDemo { preferences = AppPreferences(defaults: UserDefaults(suiteName: "app.clipdune.demo.\(UUID().uuidString)")!) }
        exclusionList = preferences.excludedApplications
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
            store = try HistoryStore(directory: dataDirectory!, limits: .init(maximumItems: preferences.maximumItems,
                                                                            maximumBytes: preferences.maximumStorageBytes,
                                                                            retentionDays: preferences.retentionDays))
        } catch {
            showError(error.localizedDescription)
            NSApp.terminate(nil)
            return
        }
        configureMainMenu()
        let controller = ClipboardPanelController()
        panel = controller
        controller.onSettings = { [weak self] in self?.showSettings() }
        controller.applyAppearance(preferences.appearance, compactCards: preferences.compactCards)
        controller.onSearch = { [weak self] query, pinned in self?.search(query, pinned: pinned, reset: true) }
        controller.onChoose = { [weak self] summary, plain, copyOnly in self?.choose(summary, plain: plain, copyOnly: copyOnly) }
        controller.onRename = { [weak self] summary in self?.rename(summary) }
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
        configureSettings()
        if let settingsModel { updater = UpdateController(model: settingsModel, isDemo: isDemo) }
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
                        self.setStatus(self.monitor?.status ?? "正在本地记录")
                        self.refresh()
                    } catch { self.setStatus(error.localizedDescription) }
                }
            }
            monitor = observer
            observer.start()
            shortcut = GlobalShortcut { [weak self] in self?.togglePanel() }
            let preset = GlobalShortcut.Preset(rawValue: UserDefaults.standard.integer(forKey: "shortcutPreset")) ?? .commandShiftV
            registerShortcut(preset)
            statusItem?.isVisible = preferences.showsMenuBarIcon
        }
        Task { @MainActor in
            do {
                try await store?.pruneExpired()
                if !isDemo { acknowledgeUpdateIfRequested(); updater?.checkAutomaticallyIfDue() }
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
        updater?.stop()
        monitor?.stop()
        shortcut?.unregister()
        panel?.hide()
        if isDemo { pasteboard?.releaseGlobally() }
        if let temporaryDirectory { try? FileManager.default.removeItem(at: temporaryDirectory) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        settingsModel?.accessibilityAllowed = PasteDestination.hasPermission
        settingsModel?.clipboardStatus = monitor?.status ?? lastStatus
    }

    private func configureMainMenu() {
        let menu = NSMenu()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "退出 ClipDune", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let settingsItem = NSMenuItem(title: "设置…", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.insertItem(settingsItem, at: 0)
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
        add("设置…", action: #selector(showSettings), to: menu)
        add("检查更新…", action: #selector(showUpdateSettings), to: menu)
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
        let filter = panel?.searchFilter ?? HistoryFilter()
        Task { @MainActor in
            guard let store else { return }
            do {
                let results = try await store.search(query, pinnedOnly: pinned, filter: filter)
                guard generation == searchGeneration else { return }
                panel?.update(results, resetSelection: reset)
            } catch { setStatus(error.localizedDescription) }
        }
    }

    private func rename(_ summary: ClipSummary) {
        guard let panel, panel.isVisible, panel.panel.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = "重命名粘贴项"
        alert.informativeText = "最多 120 个字符。名称可用于搜索，历史与收藏同步显示；不会修改原内容。清空名称可恢复默认显示。"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        let field = NSTextField(string: summary.userTitle)
        field.placeholderString = "例如：每周汇报模板"
        field.identifier = NSUserInterfaceItemIdentifier("clipdune.rename.title")
        field.frame = NSRect(x: 0, y: 0, width: 340, height: 26)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: panel.panel) { [weak self] response in
            guard let self else { return }
            guard response == .alertFirstButtonReturn else { self.panel?.focusSearch(); return }
            let title = field.stringValue
            Task { @MainActor in
                do {
                    try await self.store?.rename(summary.id, title: title)
                    self.refresh()
                    self.panel?.focusSearch()
                } catch { self.showError(error.localizedDescription) }
            }
        }
    }

    private func refresh() {
        if settingsWindow?.window?.isVisible == true { refreshStorageUsage() }
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
                guard PasteboardCodec.write(content, to: pasteboard, plainText: preferences.usesPlainText(shiftHeld: plain)) else {
                    setStatus("未能写入剪贴板，内容仍保留在历史中")
                    return
                }
                monitor?.skipCurrentChange()
                let usedAt = Date()
                interactionGeneration += 1
                let transaction = interactionGeneration
                panel.hide()
                do { try await store?.recordUse(of: summary.id, at: usedAt) }
                catch { setStatus("内容已复制，但最近使用时间保存失败。") }
                await Task.yield()
                guard transaction == interactionGeneration else { return }
                if copyOnly || !preferences.pastesDirectly || isDemo {
                    showToast(isDemo ? "演示复制成功 · 未改动系统剪贴板" : "已复制 · 按 ⌘V 粘贴")
                    return
                }
                guard PasteDestination.hasPermission else {
                    requestPasteAccess()
                    showToast("已复制 · 已打开辅助功能设置，授权后再次双击即可直接粘贴")
                    return
                }
                let result = await target?.pasteWhenReady { [weak self] in self?.interactionGeneration != transaction }
                switch result {
                case .sent:
                    do { try await store?.recordUse(of: summary.id) }
                    catch { setStatus("粘贴已发送，但最近使用时间保存失败。") }
                    showToast("已向原应用发送粘贴")
                case .cancelled: break
                case .permissionRequired: requestPasteAccess()
                default: showToast(result?.fallbackMessage ?? "未记录到原目标应用 · 已复制，可按 ⌘V 粘贴")
                }
            } catch { setStatus(error.localizedDescription) }
        }
    }

    private func setStatus(_ text: String) {
        lastStatus = text
        statusMenuItem?.title = text
        statusItem?.button?.toolTip = "ClipDune · \(text)"
        panel?.setStatus(text)
        settingsModel?.clipboardStatus = text
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
        panel?.hide()
        monitor?.requestAccess()
        SystemSettings.open(.clipboard)
        showToast("在系统设置中将 ClipDune 的剪贴板访问设为始终允许")
    }

    @objc private func requestPasteAccess() {
        guard !isDemo else { return }
        panel?.hide()
        PasteDestination.requestPermission()
        settingsModel?.accessibilityAllowed = PasteDestination.hasPermission
        showToast(PasteDestination.hasPermission ? "直接粘贴已就绪" : "请在系统设置 → 隐私与安全性中允许辅助功能访问")
    }

    @objc private func changeShortcut(_ sender: NSMenuItem) {
        guard let preset = GlobalShortcut.Preset(rawValue: sender.tag), !isDemo else { return }
        var updated = preferences
        updated.shortcutPreset = preset.rawValue
        applyPreferences(updated, previous: preferences)
        for item in sender.menu?.items ?? [] {
            item.state = item.tag == UserDefaults.standard.integer(forKey: "shortcutPreset") ? .on : .off
        }
    }

    @objc private func toggleLogin(_ sender: NSMenuItem) {
        var updated = preferences
        updated.startsAtLogin = SMAppService.mainApp.status != .enabled
        applyPreferences(updated, previous: preferences)
        sender.state = preferences.startsAtLogin ? .on : .off
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
        preferences.excludedApplications = exclusionList
        settingsModel?.preferences = preferences
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
            } catch { showError(error.localizedDescription) }
        }
    }

    @objc private func importHistory() {
        panel?.hide()
        let picker = NSOpenPanel()
        picker.allowedContentTypes = [UTType(filenameExtension: "clipdunebackup") ?? .data]
        picker.message = "仅导入你信任的 ClipDune 备份（最大 384 MiB）。排除与敏感标记规则仍生效；合并后按最近使用清理超限普通历史，收藏不会自动删除。"
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
        showUpdateSettings()
    }

    private func configureSettings() {
        let model = SettingsModel(preferences: preferences)
        settingsModel = model
        model.onChange = { [weak self] current, previous in self?.applyPreferences(current, previous: previous) }
        model.openClipboardPermission = { [weak self] in self?.requestClipboardAccess() }
        model.openPastePermission = { [weak self] in self?.requestPasteAccess() }
        model.addExclusion = { [weak self] in self?.addExclusion() }
        model.exportArchive = { [weak self] in self?.exportHistory() }
        model.importArchive = { [weak self] in self?.importHistory() }
        model.clearHistory = { [weak self] in self?.clearHistory() }
        model.onStorageLimitChange = { [weak self] in self?.changeStorageLimit(to: $0) }
    }

    private func refreshStorageUsage() {
        Task { @MainActor in
            settingsModel?.storageUsage = try? await store?.storageUsage()
        }
    }

    private func changeStorageLimit(to maximumMiB: Int) {
        guard let model = settingsModel, let store, !model.storageBusy,
              AppPreferences.storageOptionsMiB.contains(maximumMiB), maximumMiB != preferences.maximumStorageMiB else { return }
        model.storageBusy = true
        Task { @MainActor in
            defer { model.storageBusy = false }
            do {
                let usage = try await store.storageUsage()
                let maximumBytes = maximumMiB * 1024 * 1024
                if maximumMiB < preferences.maximumStorageMiB {
                    let alert = NSAlert()
                    alert.messageText = "将存储容量上限降至 \(maximumMiB) MiB？"
                    alert.informativeText = "当前已用 \(ByteCountFormatter.string(fromByteCount: Int64(usage.totalBytes), countStyle: .binary))。超限时会先删除最久未使用的普通历史，且无法撤销；收藏不会自动删除。若收藏超过新上限，将保留原设置和全部内容。"
                    alert.addButton(withTitle: "取消")
                    alert.addButton(withTitle: "降低上限")
                    guard alert.runModal() == .alertSecondButtonReturn else { return }
                }
                try await store.setMaximumBytes(maximumBytes)
                preferences.maximumStorageMiB = maximumMiB
                model.preferences.maximumStorageMiB = maximumMiB
                if !isDemo { preferences.save(to: .standard) }
                model.storageUsage = try? await store.storageUsage()
                setStatus(monitor?.status ?? lastStatus)
                refresh()
            } catch { showError(error.localizedDescription) }
        }
    }

    @objc private func showSettings() {
        interactionGeneration += 1
        panel?.hide()
        guard let model = settingsModel else { return }
        if !isDemo {
            preferences.startsAtLogin = SMAppService.mainApp.status == .enabled
            model.preferences = preferences
        }
        model.accessibilityAllowed = PasteDestination.hasPermission
        model.clipboardStatus = monitor?.status ?? lastStatus
        refreshStorageUsage()
        if settingsWindow == nil { settingsWindow = SettingsWindowController(model: model) }
        settingsWindow?.present()
    }

    @objc private func showUpdateSettings() {
        showSettings()
        settingsWindow?.present(updates: true)
        settingsModel?.checkUpdates?()
    }

    private func applyPreferences(_ proposed: AppPreferences, previous: AppPreferences) {
        var updated = proposed
        if !isDemo, updated.shortcutPreset != previous.shortcutPreset {
            guard let preset = GlobalShortcut.Preset(rawValue: updated.shortcutPreset), shortcut?.register(preset) == true else {
                if let old = GlobalShortcut.Preset(rawValue: previous.shortcutPreset) { _ = shortcut?.register(old) }
                settingsModel?.preferences = previous
                showError("这个快捷键已被占用，已保留原快捷键。")
                return
            }
        }
        if !isDemo, updated.startsAtLogin != previous.startsAtLogin {
            do {
                if updated.startsAtLogin { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
                updated.startsAtLogin = SMAppService.mainApp.status == .enabled
                if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            } catch {
                updated.startsAtLogin = previous.startsAtLogin
                showError("无法修改登录启动，请将完整应用放入 Applications 后重试。")
            }
        }
        preferences = updated
        exclusionList = updated.excludedApplications
        monitor?.excludedApplications = exclusionList
        refreshExclusions()
        panel?.applyAppearance(updated.appearance, compactCards: updated.compactCards)
        if !isDemo { statusItem?.isVisible = updated.showsMenuBarIcon; updated.save(to: .standard) }
        settingsModel?.preferences = updated
        if updated.automaticallyChecksUpdates, !previous.automaticallyChecksUpdates { updater?.checkAutomaticallyIfDue() }
        if updated.pastesDirectly, !previous.pastesDirectly, !PasteDestination.hasPermission { requestPasteAccess() }
        if updated.maximumItems != previous.maximumItems || updated.retentionDays != previous.retentionDays {
            lastPreferencesVersion += 1
            let version = lastPreferencesVersion
            preferencesTask?.cancel()
            preferencesTask = Task { @MainActor in
                do {
                    try await store?.setRetention(maximumItems: updated.maximumItems, retentionDays: updated.retentionDays)
                    if version == lastPreferencesVersion { refresh() }
                } catch {
                    guard version == lastPreferencesVersion else { return }
                    preferences.maximumItems = previous.maximumItems
                    preferences.retentionDays = previous.retentionDays
                    settingsModel?.preferences = preferences
                    if !isDemo { preferences.save(to: .standard) }
                    showError(error.localizedDescription)
                }
            }
        }
    }

    private func acknowledgeUpdateIfRequested() {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--updated-confirmation"), arguments.indices.contains(index + 1),
              let dataDirectory,
              let statusData = try? Data(contentsOf: dataDirectory.appendingPathComponent("Updates/installation.json")),
              let status = try? JSONSerialization.jsonObject(with: statusData) as? [String: Any],
              let build = Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""),
              status["status"] as? String == "awaiting_confirmation", status["build"] as? Int == build,
              status["receipt"] as? String == arguments[index + 1] else { return }
        let receipt = URL(fileURLWithPath: arguments[index + 1]).standardizedFileURL
        guard receipt.deletingLastPathComponent() == dataDirectory.appendingPathComponent("Updates"),
              receipt.lastPathComponent.hasPrefix("confirmation-") else { return }
        if let data = try? JSONSerialization.data(withJSONObject: ["status": "ready", "build": build]) {
            try? data.write(to: receipt, options: .atomic)
        }
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
            let bundleIDs = ["com.apple.Notes", "com.apple.Safari", "com.apple.Terminal", "com.apple.TextEdit", "com.apple.Terminal", "app.clipdune.fixture"]
            let content = ClipboardContent(fragments: [.init(representations: [.init(type: NSPasteboard.PasteboardType.string.rawValue, data: Data(example.0.utf8))])],
                                           text: example.0, kind: example.1, sourceName: example.2, sourceBundleID: bundleIDs[index])
            if let identity = try await store?.record(content, at: Date().addingTimeInterval(Double(index) * -120)), index == 0 {
                try await store?.setPinned(true, for: identity)
            }
        }
        let color = ClipboardContent(fragments: [.init(representations: [.init(type: "public.utf8-plain-text", data: Data("#37B5AA".utf8))])],
                                     text: "#37B5AA", kind: .color, sourceName: "调色板", sourceBundleID: "com.apple.Preview")
        try await store?.record(color, at: Date().addingTimeInterval(-60))
        let markup = "<h1>产品发布检查</h1><p>签名、下载、启动与回滚分别验证。</p>"
        let html = ClipboardContent(fragments: [.init(representations: [
            .init(type: "public.html", data: Data(markup.utf8)),
            .init(type: "public.utf8-plain-text", data: Data("产品发布检查\n签名、下载、启动与回滚分别验证。".utf8))
        ])], text: "产品发布检查\n签名、下载、启动与回滚分别验证。", kind: .html, sourceName: "Safari", sourceBundleID: "com.apple.Safari")
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        try await store?.record(html, at: yesterday)
        if qaDirectory != nil {
            for index in 1...48 {
                let text = "横向滚动测试记录 \(index)"
                let entry = ClipboardContent(fragments: [.init(representations: [.init(type: "public.utf8-plain-text", data: Data(text.utf8))])],
                                             text: text, kind: .text, sourceName: "测试宿主", sourceBundleID: "app.clipdune.fixture")
                try await store?.record(entry, at: Date().addingTimeInterval(-Double(3_600 + index)))
            }
        }
        if let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 240, pixelsHigh: 144, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
           let context = NSGraphicsContext(bitmapImageRep: bitmap) {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            NSColor(srgbRed: 0.06, green: 0.2, blue: 0.24, alpha: 1).setFill()
            NSBezierPath(rect: NSRect(x: 0, y: 0, width: 240, height: 144)).fill()
            NSColor.systemTeal.setFill()
            NSBezierPath(roundedRect: NSRect(x: 26, y: 30, width: 80, height: 90), xRadius: 12, yRadius: 12).fill()
            NSColor.white.setFill()
            NSBezierPath(roundedRect: NSRect(x: 72, y: 24, width: 80, height: 90), xRadius: 12, yRadius: 12).fill()
            ("ClipDune" as NSString).draw(at: NSPoint(x: 154, y: 58), withAttributes: [.font: NSFont.systemFont(ofSize: 15, weight: .semibold), .foregroundColor: NSColor.white])
            NSGraphicsContext.restoreGraphicsState()
            if let png = bitmap.representation(using: .png, properties: [:]) {
                let image = ClipboardContent(fragments: [.init(representations: [.init(type: "public.png", data: png)])],
                                             text: "", kind: .image, sourceName: "预览", sourceBundleID: "com.apple.Preview", thumbnail: png)
                try await store?.record(image, at: Date().addingTimeInterval(-180))
            }
        }
    }

    private func runUICheck(directory: URL) async {
        await UICheck.run(panel: panel!, directory: directory, open: { [weak self] in self?.togglePanel() })
        if let settingsModel {
            settingsModel.storageUsage = try? await store?.storageUsage()
            let settings = SettingsWindowController(model: settingsModel)
            await settings.checkPresentation(directory: directory)
        }
        NSApp.terminate(nil)
    }
}
