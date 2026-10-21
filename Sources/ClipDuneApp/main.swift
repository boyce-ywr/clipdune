import AppKit

MainActor.assumeIsolated {
    let application = NSApplication.shared
    if let index = CommandLine.arguments.firstIndex(of: "--render-icon"), CommandLine.arguments.indices.contains(index + 1) {
        do { try IconRenderer.write(to: URL(fileURLWithPath: CommandLine.arguments[index + 1])); exit(0) }
        catch { exit(1) }
    }
    application.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    application.delegate = delegate
    application.run()
}
