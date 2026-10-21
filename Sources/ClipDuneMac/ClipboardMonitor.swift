import AppKit
import ClipDuneCore

@MainActor
public final class ClipboardMonitor {
    public var onCapture: ((ClipboardContent) -> Void)?
    public var onStatus: ((String) -> Void)?
    public var excludedApplications: Set<String> = CapturePolicy.defaultExcludedApplications
    public var isPaused = false {
        didSet {
            lastChangeCount = pasteboard.changeCount
            report(isPaused ? "记录已暂停" : "正在本地记录")
        }
    }
    private let pasteboard: NSPasteboard
    private var timer: Timer?
    private var lastChangeCount: Int
    private var lastStatus = ""
    public var status: String { lastStatus }

    public init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
        lastChangeCount = pasteboard.changeCount
    }

    public func start() {
        guard timer == nil else { return }
        timer = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer!, forMode: .common)
        poll()
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    public func requestAccess() {
        _ = pasteboard.string(forType: .string)
        lastChangeCount = pasteboard.changeCount
        poll()
    }

    public func skipCurrentChange() { lastChangeCount = pasteboard.changeCount }

    private func poll() {
        guard !isPaused else {
            lastChangeCount = pasteboard.changeCount
            report("记录已暂停")
            return
        }
        if #available(macOS 15.4, *), pasteboard.name == .general {
            guard pasteboard.accessBehavior == .alwaysAllow else {
                lastChangeCount = pasteboard.changeCount
                report(pasteboard.accessBehavior == .alwaysDeny ? "剪贴板访问被拒绝 · 请在系统设置中允许" : "等待剪贴板授权 · 在菜单中启用记录")
                return
            }
        }
        report("正在本地记录")
        guard lastChangeCount != pasteboard.changeCount else { return }
        let expectedChange = pasteboard.changeCount
        lastChangeCount = expectedChange
        let application = NSWorkspace.shared.frontmostApplication
        do {
            let content = try PasteboardCodec.read(pasteboard, sourceName: application?.localizedName ?? "未知应用",
                                                   sourceBundleID: application?.bundleIdentifier ?? "",
                                                   excludedApplications: excludedApplications)
            guard pasteboard.changeCount == expectedChange, let content else { return }
            onCapture?(content)
        } catch {
            report("此项未记录：格式无效或超过 16 MiB")
        }
    }

    private func report(_ status: String) {
        guard status != lastStatus else { return }
        lastStatus = status
        onStatus?(status)
    }
}
