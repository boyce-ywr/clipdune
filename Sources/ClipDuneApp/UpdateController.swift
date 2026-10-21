import AppKit
import ClipDuneCore
import ClipDuneMac

@MainActor
final class UpdateController {
    private let model: SettingsModel
    private let defaults: UserDefaults
    private var operation: Task<Void, Never>?
    private var handedToHelper = false
    private let isDemo: Bool
    private var automaticTimer: Timer?

    init(model: SettingsModel, defaults: UserDefaults = .standard, isDemo: Bool) {
        self.model = model
        self.defaults = defaults
        self.isDemo = isDemo
        model.checkUpdates = { [weak self] in self?.check(manual: true) }
        model.cancelUpdate = { [weak self] in self?.cancel() }
        model.saveToken = { [weak self] token in self?.saveToken(token) }
        model.removeToken = { [weak self] in self?.removeToken() }
        if !isDemo { model.tokenPresent = GitHubCredential.isConfigured }
        if !isDemo { restoreInstallationStatus() }
        if !isDemo {
            automaticTimer = Timer.scheduledTimer(withTimeInterval: 3_600, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkAutomaticallyIfDue() }
            }
        }
    }

    func checkAutomaticallyIfDue() {
        guard !isDemo, model.preferences.automaticallyChecksUpdates, model.tokenPresent,
              Date().timeIntervalSince1970 - defaults.double(forKey: "lastUpdateCheck") >= 86_400 else { return }
        check(manual: false)
    }

    func cancel() { operation?.cancel() }

    private func check(manual: Bool) {
        guard operation == nil else { return }
        guard !isDemo else { model.updateStatus = "演示模式不会联网或读取钥匙串。"; return }
        model.updateBusy = true
        model.updateProgress = nil
        model.updateStatus = "正在检查 GitHub Release…"
        operation = Task { @MainActor [self] in
            defer { operation = nil; model.updateBusy = false; model.updateProgress = nil }
            do {
                guard let token = try GitHubCredential.read() else { throw UpdateError.noAuthorization }
                let key = try trustedPublicKey()
                let proxyURL = try GitHubUpdatePolicy.proxyURL(model.preferences.updateProxy)
                let release = try await GitHubReleaseClient.latest(token: token, proxyURL: proxyURL)
                let data = try await GitHubReleaseClient.manifest(release.asset(named: "clipdune-update.json"), token: token, proxyURL: proxyURL)
                let manifest = try SignedRelease.verify(data, publicKey: key)
                guard release.tag_name == "v\(manifest.version)" else { throw UpdateError.invalidManifest }
                let system = ProcessInfo.processInfo.operatingSystemVersion
                #if arch(arm64)
                let architecture = "arm64"
                #else
                let architecture = "x86_64"
                #endif
                try manifest.checkCompatibility(systemVersion: "\(system.majorVersion).\(system.minorVersion).\(system.patchVersion)", architecture: architecture)
                defaults.set(Date().timeIntervalSince1970, forKey: "lastUpdateCheck")
                let currentBuild = Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0") ?? 0
                guard currentBuild > 0, Bundle.main.bundleURL.pathExtension == "app" else {
                    model.updateStatus = "发现版本 \(manifest.version)。开发入口不替换自身，请安装完整应用后在线升级。"
                    return
                }
                guard manifest.build > currentBuild else { model.updateStatus = "当前已是最新版本（\(manifest.version)）。"; return }
                if !manual, defaults.integer(forKey: "skippedUpdateBuild") == manifest.build { return }
                model.updateStatus = "发现新版本 \(manifest.version)"
                try Task.checkCancellation()
                let choice = askToDownload(manifest)
                if choice == .alertThirdButtonReturn { defaults.set(manifest.build, forKey: "skippedUpdateBuild"); return }
                guard choice == .alertFirstButtonReturn else { return }
                try UpdateInstaller.validateDestination(Bundle.main.bundleURL)
                let asset = try release.asset(named: manifest.archiveName)
                guard asset.size == manifest.archiveBytes else { throw UpdateError.invalidDownload }
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("clipdune-update-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                defer { if !handedToHelper { try? FileManager.default.removeItem(at: directory) } }
                try data.write(to: directory.appendingPathComponent("clipdune-update.json"), options: .atomic)
                try key.base64EncodedString().write(to: directory.appendingPathComponent("public-key.txt"), atomically: true, encoding: .utf8)
                model.updateStatus = "正在下载 \(manifest.version)…"
                model.updateProgress = 0
                try await GitHubReleaseClient.archive(asset, token: token, destination: directory.appendingPathComponent(manifest.archiveName), proxyURL: proxyURL) { [weak self] value in
                    Task { @MainActor in
                        guard let self, self.model.updateBusy else { return }
                        self.model.updateProgress = value
                    }
                }
                try Task.checkCancellation()
                model.updateStatus = "正在验证签名与安装包…"
                let prepared = try await Task.detached { try UpdateInstaller.prepare(directory: directory, manifest: manifest) }.value
                try Task.checkCancellation()
                let install = NSAlert()
                install.messageText = "安装 \(manifest.version) 并重新启动？"
                install.informativeText = "签名和内容校验已通过。升级仅替换应用，保留历史与设置；旧应用会暂存为备份。"
                install.addButton(withTitle: "安装并重启")
                install.addButton(withTitle: "稍后")
                guard install.runModal() == .alertFirstButtonReturn else { model.updateStatus = "安装已取消；下次检查可重新下载。"; return }
                try UpdateInstaller.launchHelper(prepared: prepared, target: Bundle.main.bundleURL)
                handedToHelper = true
                NSApp.terminate(nil)
            } catch {
                model.updateStatus = error is CancellationError ? "更新已取消。" : error.localizedDescription
            }
        }
    }

    private func askToDownload(_ manifest: ReleaseManifest) -> NSApplication.ModalResponse {
        let alert = NSAlert()
        alert.messageText = "ClipDune \(manifest.version) 可用"
        alert.informativeText = String(manifest.notes.prefix(3_000)) + "\n\n下载约 \(manifest.archiveBytes / 1024 / 1024) MiB。安装前会再次确认。"
        alert.addButton(withTitle: "下载更新")
        alert.addButton(withTitle: "稍后提醒")
        alert.addButton(withTitle: "跳过此版本")
        return alert.runModal()
    }

    private func trustedPublicKey() throws -> Data {
        guard let url = Bundle.main.url(forResource: "UpdatePublicKey", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8),
              let data = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)), data.count == 32 else {
            throw UpdateError.invalidSignature
        }
        return data
    }

    private func restoreInstallationStatus() {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ClipDune/Updates/installation.json")
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = object["status"] as? String else { return }
        switch status {
        case "installed": model.updateStatus = "上次更新已完成，旧版本备份保留在应用目录。"
        case "rolled_back": model.updateStatus = "上次更新未能正常启动，已恢复旧版本。请检查系统安全提示后重试。"
        case "rollback_requires_quit", "rollback_failed": model.updateStatus = "上次更新需要手动处理。旧版本备份仍在应用目录；详情见数据目录 Updates/installation.json。"
        case "failed_before_replacement": model.updateStatus = "上次更新失败，原应用未替换。"
        default: model.updateStatus = "上次更新尚未确认完成，请检查数据目录 Updates/installation.json。"
        }
    }

    private func saveToken(_ token: String) {
        guard !isDemo else { model.tokenDraft = ""; return }
        defer { model.tokenDraft = "" }
        do { try GitHubCredential.save(token); model.tokenPresent = true; model.updateStatus = "授权已保存，可以检查更新。" }
        catch { model.updateStatus = error.localizedDescription }
    }

    private func removeToken() {
        guard !isDemo else { return }
        cancel()
        do { try GitHubCredential.remove(); model.tokenPresent = false; model.updateStatus = "授权已移除，自动检查不会再访问私有仓库。" }
        catch { model.updateStatus = error.localizedDescription }
    }

    func stop() { automaticTimer?.invalidate(); automaticTimer = nil; cancel() }
}
