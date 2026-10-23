import AppKit
import SwiftUI
import ClipDuneCore
import ClipDuneMac

@MainActor
final class SettingsModel: ObservableObject {
    @Published var preferences: AppPreferences
    @Published var clipboardStatus = ""
    @Published var accessibilityAllowed = false
    @Published var updateStatus = "尚未检查"
    @Published var updateBusy = false
    @Published var updateProgress: Double?
    @Published var tokenPresent = false
    @Published var tokenDraft = ""
    @Published var storageUsage: HistoryStorageUsage?
    @Published var storageBusy = false
    var onChange: ((AppPreferences, AppPreferences) -> Void)?
    var onStorageLimitChange: ((Int) -> Void)?
    var openClipboardPermission: (() -> Void)?
    var openPastePermission: (() -> Void)?
    var addExclusion: (() -> Void)?
    var exportArchive: (() -> Void)?
    var importArchive: (() -> Void)?
    var clearHistory: (() -> Void)?
    var checkUpdates: (() -> Void)?
    var cancelUpdate: (() -> Void)?
    var saveToken: ((String) -> Void)?
    var removeToken: (() -> Void)?

    init(preferences: AppPreferences) { self.preferences = preferences }

    func binding<Value>(_ keyPath: WritableKeyPath<AppPreferences, Value>) -> Binding<Value> {
        Binding(get: { self.preferences[keyPath: keyPath] }, set: { value in
            let previous = self.preferences
            self.preferences[keyPath: keyPath] = value
            self.onChange?(self.preferences, previous)
        })
    }

    func removeExclusion(_ identity: String) {
        let previous = preferences
        preferences.excludedApplications.remove(identity)
        onChange?(preferences, previous)
    }
}

@MainActor
final class SettingsWindowController: NSWindowController {
    private let tabs = NSTabViewController()
    private let model: SettingsModel

    init(model: SettingsModel) {
        self.model = model
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 590),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "ClipDune 设置"
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .preference
        tabs.tabStyle = .toolbar
        let sections: [(String, String, AnyView)] = [
            ("通用", "gearshape", AnyView(GeneralSettings(model: model))),
            ("外观", "paintbrush", AnyView(AppearanceSettings(model: model))),
            ("快捷键", "keyboard", AnyView(ShortcutSettings(model: model))),
            ("排除", "hand.raised", AnyView(ExclusionSettings(model: model))),
            ("关于与更新", "info.circle", AnyView(UpdateSettings(model: model)))
        ]
        for (title, symbol, view) in sections {
            let hosting = NSHostingController(rootView: view.frame(maxWidth: .infinity, maxHeight: .infinity))
            hosting.preferredContentSize = NSSize(width: 700, height: 590)
            let item = NSTabViewItem(viewController: hosting)
            item.label = title
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            tabs.addTabViewItem(item)
        }
        window.contentViewController = tabs
        window.setContentSize(NSSize(width: 700, height: 590))
        window.contentMinSize = NSSize(width: 700, height: 590)
        window.center()
    }

    required init?(coder: NSCoder) { nil }

    func present(updates: Bool = false) {
        if updates { tabs.selectedTabViewItemIndex = 4 }
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.contentView?.layoutSubtreeIfNeeded()
    }

    func checkPresentation(directory: URL) async {
        var screenshots = 0
        for (index, name) in ["general", "appearance", "shortcuts", "exclusions", "updates"].enumerated() {
            tabs.selectedTabViewItemIndex = index
            present()
            try? await Task.sleep(for: .milliseconds(180))
            guard let view = window?.contentView?.superview, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            if let image = bitmap.representation(using: .png, properties: [:]) {
                try? image.write(to: directory.appendingPathComponent("settings-\(name).png"))
                screenshots += 1
            }
        }
        let storageChecks = await StorageSettingsUICheck.run(model: model)
        var result: [String: Any] = storageChecks
        result["pages"] = screenshots
        result["status"] = screenshots == 5 && storageChecks.values.allSatisfy { $0 } ? "passed" : "failed"
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: directory.appendingPathComponent("settings-check.json"), options: .atomic)
        }
        window?.close()
    }
}

private struct GeneralSettings: View {
    @ObservedObject var model: SettingsModel
    var body: some View {
        Form {
            Section {
                Picker("历史记录上限", selection: model.binding(\.maximumItems)) {
                    ForEach([500, 1_000, 2_000, 5_000, 10_000, 50_000], id: \.self) { Text($0.formatted()).tag($0) }
                }
                Picker("普通历史保留天数", selection: model.binding(\.retentionDays)) {
                    ForEach([7, 30, 90, 365], id: \.self) { Text("\($0) 天").tag($0) }
                }
                Picker("总存储容量上限", selection: Binding(get: { model.preferences.maximumStorageMiB }, set: { model.onStorageLimitChange?($0) })) {
                    ForEach(AppPreferences.storageOptionsMiB, id: \.self) { value in
                        Text(value >= 1_024 ? "\(value / 1_024) GiB" : "\(value) MiB").tag(value)
                    }
                }.disabled(model.storageBusy)
                if let usage = model.storageUsage {
                    Text("已用 \(ByteCountFormatter.string(fromByteCount: Int64(usage.totalBytes), countStyle: .binary)) · 收藏占用 \(ByteCountFormatter.string(fromByteCount: Int64(usage.pinnedBytes), countStyle: .binary))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("登录时启动", isOn: model.binding(\.startsAtLogin))
                Toggle("在菜单栏中显示图标", isOn: model.binding(\.showsMenuBarIcon))
            } footer: { Text("普通历史按最近使用时间保留和清理；收藏计入容量但不自动删除。降低容量前会确认。容量统计原始内容与缩略图，不含数据库开销；完整备份另限 384 MiB。") }
            Section("粘贴") {
                Toggle("始终以纯文本粘贴", isOn: model.binding(\.alwaysPastePlainText))
                Text("粘贴时按住 Shift，可对本次粘贴切换格式。")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("直接粘贴到当前应用", isOn: model.binding(\.pastesDirectly))
                Text("双击条目或按 Return，粘贴到唤出前的光标位置。关闭时仅复制。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("权限") {
                LabeledContent("剪贴板") { Text(model.clipboardStatus).lineLimit(2) }
                Button("打开剪贴板访问设置…") { model.openClipboardPermission?() }
                LabeledContent("直接粘贴", value: model.accessibilityAllowed ? "辅助功能已允许" : "需要辅助功能权限")
                Button("打开辅助功能设置…") { model.openPastePermission?() }
            }
        }.formStyle(.grouped).toggleStyle(.switch)
    }
}

private struct AppearanceSettings: View {
    @ObservedObject var model: SettingsModel
    var body: some View {
        Form {
            Section("主题") {
                Picker("外观", selection: model.binding(\.appearance)) {
                    Text("跟随系统").tag(AppPreferences.Appearance.system)
                    Text("浅色").tag(AppPreferences.Appearance.light)
                    Text("深色").tag(AppPreferences.Appearance.dark)
                }.pickerStyle(.segmented)
                Toggle("紧凑卡片", isOn: model.binding(\.compactCards))
                Text("调整卡片宽度，在同一屏幕显示更多历史。设置立即生效。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped).toggleStyle(.switch)
    }
}

private struct ShortcutSettings: View {
    @ObservedObject var model: SettingsModel
    var body: some View {
        Form {
            Section("唤出面板") {
                Picker("全局快捷键", selection: model.binding(\.shortcutPreset)) {
                    Text("⌘⇧V").tag(0)
                    Text("⌃⌥Space").tag(1)
                    Text("⌃⇧V").tag(2)
                }
                Text("遇到冲突会保留原快捷键并提示，不静默失效。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("面板内") {
                LabeledContent("搜索", value: "直接打字，自动聚焦")
                LabeledContent("选择条目", value: "↑ / ↓")
                LabeledContent("粘贴 / 仅复制", value: "Return / Option-Return")
                LabeledContent("快捷粘贴", value: "⌘1–9")
                LabeledContent("收藏 / 预览", value: "⌘P / ⌘Y")
                LabeledContent("设置 / 关闭", value: "⌘, / Esc")
            }
        }.formStyle(.grouped)
    }
}

private struct ExclusionSettings: View {
    @ObservedObject var model: SettingsModel
    var body: some View {
        Form {
            Section {
                ForEach(model.preferences.excludedApplications.sorted(), id: \.self) { identity in
                    HStack {
                        Text(identity).textSelection(.enabled).lineLimit(1)
                        Spacer()
                        Button("移除") { model.removeExclusion(identity) }
                    }
                }
                Button("添加应用…") { model.addExclusion?() }
            } header: { Text("不记录这些应用") }
              footer: { Text("只影响未来采集，不自动删除历史。敏感标记过滤始终开启，但不能识别所有密码或密钥。") }
            Section("数据管理") {
                HStack {
                    Button("导出备份…") { model.exportArchive?() }
                    Button("导入备份…") { model.importArchive?() }
                    Button("清理未收藏历史…") { model.clearHistory?() }
                }
                Text("备份包含原始内容且未加密，只应保存到可信位置。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }
}

private struct UpdateSettings: View {
    @ObservedObject var model: SettingsModel
    var body: some View {
        Form {
            Section {
                LabeledContent("ClipDune · 拾贴", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版")
                Text("本地优先的剪贴板工具。剪贴板内容不会上传；联网仅用于你启用的版本更新。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("GitHub Release 在线升级") {
                Text("boyce-ywr/clipdune · 私有仓库")
                Toggle("自动检查更新（每天一次）", isOn: model.binding(\.automaticallyChecksUpdates))
                TextField("HTTP 代理", text: model.binding(\.updateProxy))
                Text("当前默认 127.0.0.1:7897；留空使用系统网络设置。仅更新请求使用此代理。")
                    .font(.caption).foregroundStyle(.secondary)
                Text(model.updateStatus).textSelection(.enabled)
                if let progress = model.updateProgress { ProgressView(value: progress) }
                HStack {
                    Button("检查更新…") { model.checkUpdates?() }.disabled(model.updateBusy)
                    if model.updateBusy { Button("取消") { model.cancelUpdate?() } }
                }
            }
            Section("私有仓库授权") {
                LabeledContent("令牌状态", value: model.tokenPresent ? "已存入 macOS 钥匙串" : "未配置")
                SecureField("GitHub 细粒度访问令牌", text: $model.tokenDraft)
                HStack {
                    Button("保存到钥匙串") { model.saveToken?(model.tokenDraft) }
                        .disabled(model.tokenDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("移除授权") { model.removeToken?() }.disabled(!model.tokenPresent)
                }
                Text("只需此仓库的 Contents: Read 权限。令牌不写入配置文件或更新包；应用不会读取 gh 的登录凭据。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("在 GitHub 创建令牌…") {
                    NSWorkspace.shared.open(URL(string: "https://github.com/settings/personal-access-tokens/new")!)
                }
            }
        }.formStyle(.grouped).toggleStyle(.switch)
    }
}
