import Foundation

public struct AppPreferences: Equatable, Sendable {
    public enum Appearance: String, CaseIterable, Sendable { case system, light, dark }
    public var maximumItems: Int = 5_000
    public static let storageOptionsMiB = [64, 128, 256, 512, 1_024, 2_048]
    public var maximumStorageMiB: Int = 256
    public var maximumStorageBytes: Int { maximumStorageMiB * 1024 * 1024 }
    public var retentionDays: Int = 30
    public var startsAtLogin = false
    public var showsMenuBarIcon = true
    public var alwaysPastePlainText = false
    public var pastesDirectly = true
    public var appearance: Appearance = .system
    public var compactCards = false
    public var shortcutPreset = 0
    public var automaticallyChecksUpdates = true
    public var updateProxy = "http://127.0.0.1:7897"
    public var excludedApplications: Set<String> = CapturePolicy.defaultExcludedApplications

    public init(defaults: UserDefaults) {
        if defaults.object(forKey: "maximumItems") != nil { maximumItems = min(50_000, max(100, defaults.integer(forKey: "maximumItems"))) }
        if Self.storageOptionsMiB.contains(defaults.integer(forKey: "maximumStorageMiB")) {
            maximumStorageMiB = defaults.integer(forKey: "maximumStorageMiB")
        }
        if defaults.object(forKey: "retentionDays") != nil { retentionDays = min(365, max(1, defaults.integer(forKey: "retentionDays"))) }
        startsAtLogin = defaults.bool(forKey: "startsAtLogin")
        if defaults.object(forKey: "showsMenuBarIcon") != nil { showsMenuBarIcon = defaults.bool(forKey: "showsMenuBarIcon") }
        alwaysPastePlainText = defaults.bool(forKey: "alwaysPastePlainText")
        if defaults.object(forKey: "pastesDirectly") != nil { pastesDirectly = defaults.bool(forKey: "pastesDirectly") }
        appearance = Appearance(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .system
        compactCards = defaults.bool(forKey: "compactCards")
        shortcutPreset = min(2, max(0, defaults.integer(forKey: "shortcutPreset")))
        if defaults.object(forKey: "automaticallyChecksUpdates") != nil { automaticallyChecksUpdates = defaults.bool(forKey: "automaticallyChecksUpdates") }
        if let proxy = defaults.string(forKey: "updateProxy") { updateProxy = proxy }
        if let applications = defaults.stringArray(forKey: "excludedApplications") { excludedApplications = Set(applications) }
    }

    public func save(to defaults: UserDefaults) {
        defaults.set(maximumItems, forKey: "maximumItems")
        defaults.set(maximumStorageMiB, forKey: "maximumStorageMiB")
        defaults.set(retentionDays, forKey: "retentionDays")
        defaults.set(startsAtLogin, forKey: "startsAtLogin")
        defaults.set(showsMenuBarIcon, forKey: "showsMenuBarIcon")
        defaults.set(alwaysPastePlainText, forKey: "alwaysPastePlainText")
        defaults.set(pastesDirectly, forKey: "pastesDirectly")
        defaults.set(appearance.rawValue, forKey: "appearance")
        defaults.set(compactCards, forKey: "compactCards")
        defaults.set(shortcutPreset, forKey: "shortcutPreset")
        defaults.set(automaticallyChecksUpdates, forKey: "automaticallyChecksUpdates")
        defaults.set(updateProxy, forKey: "updateProxy")
        defaults.set(excludedApplications.sorted(), forKey: "excludedApplications")
    }

    public func usesPlainText(shiftHeld: Bool) -> Bool { alwaysPastePlainText != shiftHeld }
}

public enum PasteReadiness: Equatable, Sendable {
    case ready, waitingForFocus, targetChanged, unavailable
}

public enum PasteFocusPolicy {
    public static func evaluate(expectedPID: Int32, currentPID: Int32?, focusedElementMatches: Bool?,
                                targetWindowMatches: Bool?, hasPermission: Bool, targetTerminated: Bool,
                                allowsWindowFallback: Bool = true, windowServerMatches: Bool? = nil) -> PasteReadiness {
        guard hasPermission, !targetTerminated else { return .unavailable }
        guard currentPID == expectedPID else { return .targetChanged }
        if targetWindowMatches == false || windowServerMatches == false { return .targetChanged }
        if focusedElementMatches == true { return .ready }
        if focusedElementMatches == false { return .targetChanged }
        if allowsWindowFallback && (targetWindowMatches == true || windowServerMatches == true) { return .ready }
        return .waitingForFocus
    }
}

public struct PasteFocusRecovery {
    private var readySince: TimeInterval?
    private var windowFallback = false

    public init() { }

    public mutating func observe(_ readiness: PasteReadiness, usingWindowFallback: Bool, at time: TimeInterval) -> PasteReadiness {
        guard readiness == .ready else {
            readySince = nil
            return readiness
        }
        if readySince == nil || windowFallback != usingWindowFallback {
            readySince = time
            windowFallback = usingWindowFallback
        }
        let delay = usingWindowFallback ? 0.1 : 0.025
        return time - (readySince ?? time) >= delay ? .ready : .waitingForFocus
    }
}
