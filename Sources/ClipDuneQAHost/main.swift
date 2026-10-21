import AppKit

@MainActor
final class HostDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow?
    private var textView: NSTextView?
    private let directory: URL
    private var focusObserver: NSObjectProtocol?

    init(directory: URL) { self.directory = directory }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        guard session?["CGSSessionScreenIsLocked"] as? Bool != true else {
            writeState("blocked_screen_locked")
            NSApp.terminate(nil)
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 160, y: 160, width: 900, height: 600),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "ClipDune QA · 隔离全屏输入窗口"
        window.collectionBehavior = [.fullScreenPrimary]
        window.delegate = self
        let text = NSTextView(frame: window.contentView!.bounds)
        text.autoresizingMask = [.width, .height]
        text.font = .monospacedSystemFont(ofSize: 20, weight: .regular)
        text.backgroundColor = NSColor(calibratedRed: 0.07, green: 0.1, blue: 0.12, alpha: 1)
        text.textColor = .white
        text.textContainerInset = NSSize(width: 32, height: 32)
        text.string = "ClipDune · 隔离全屏测试\n\n这不是实际终端，不执行命令，不读取系统剪贴板。\n\n$ 等待剪贴板面板唤出…"
        window.contentView = text
        self.window = window
        textView = text
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeFirstResponder(text)
        focusObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("app.clipdune.qa.focus.\(directory.lastPathComponent)"), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    Task { @MainActor in
                        for _ in 0..<20 {
                            if self.window?.isKeyWindow == true { break }
                            try? await Task.sleep(for: .milliseconds(25))
                        }
                        let state = ["keyWindow": self.window?.isKeyWindow == true,
                                     "inputFocused": self.window?.firstResponder === self.textView]
                        if let data = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]) {
                            try? data.write(to: self.directory.appendingPathComponent("host-focus.json"), options: .atomic)
                        }
                    }
                }
            }
        if CommandLine.arguments.contains("--windowed") { writeState("windowed_ready") }
        else { window.toggleFullScreen(nil) }
    }

    func windowDidEnterFullScreen(_ notification: Notification) { writeState("full_screen_ready") }
    func windowDidFailToEnterFullScreen(_ window: NSWindow) { writeState("failed_full_screen") }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func writeState(_ status: String) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let payload: [String: Any] = ["status": status, "pid": ProcessInfo.processInfo.processIdentifier,
                                      "window": window?.windowNumber ?? 0]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: directory.appendingPathComponent("host.json"), options: .atomic)
        }
    }
}

MainActor.assumeIsolated {
    let application = NSApplication.shared
    application.setActivationPolicy(.regular)
    let directory = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "/tmp/clipdune-qa", isDirectory: true)
    let delegate = HostDelegate(directory: directory)
    application.delegate = delegate
    application.run()
}
