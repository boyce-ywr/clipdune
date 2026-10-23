import AppKit

@MainActor
enum StorageSettingsUICheck {
    static func run(model: SettingsModel) async -> [String: Bool] {
        let original = model.preferences.maximumStorageMiB
        model.onStorageLimitChange?(512)
        await waitForChange(model)
        var results = ["capacityIncreaseApplies": model.preferences.maximumStorageMiB == 512 && !model.storageBusy,
                       "capacityUsageVisible": model.storageUsage != nil]
        for accept in [false, true] {
            var promptSeen = false
            let timer = Timer(timeInterval: 0.05, repeats: true) { _ in
                MainActor.assumeIsolated {
                    guard let modal = NSApp.modalWindow, let root = modal.contentView else { return }
                    let views = descendants(root)
                    guard views.compactMap({ $0 as? NSTextField }).contains(where: { $0.stringValue.hasPrefix("将存储容量上限降至") }),
                          let button = views.compactMap({ $0 as? NSButton }).first(where: { $0.title == (accept ? "降低上限" : "取消") }) else { return }
                    promptSeen = true
                    button.performClick(nil)
                }
            }
            RunLoop.main.add(timer, forMode: .modalPanel)
            model.onStorageLimitChange?(original)
            await waitForChange(model)
            timer.invalidate()
            results[accept ? "capacityReductionConfirmed" : "capacityReductionCancelled"] = promptSeen && !model.storageBusy && model.preferences.maximumStorageMiB == (accept ? original : 512)
        }
        return results
    }

    private static func waitForChange(_ model: SettingsModel) async {
        for _ in 0..<100 {
            if !model.storageBusy { return }
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    private static func descendants(_ view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap(descendants) }
}
