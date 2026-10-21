import AppKit

public enum SystemSettings {
    public enum Pane: String {
        case clipboard = "Privacy_Pasteboard"
        case accessibility = "Privacy_Accessibility"
    }

    public static func url(for pane: Pane) -> URL {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane.rawValue)")!
    }

    @MainActor
    @discardableResult
    public static func open(_ pane: Pane) -> Bool {
        if NSWorkspace.shared.open(url(for: pane)) { return true }
        if NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension")!) { return true }
        return NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
    }
}
