import AppKit
import ClipDuneCore
import Darwin

public struct PreparedUpdate: Sendable {
    public let directory: URL
    public let application: URL
    public let manifest: ReleaseManifest
}

public enum UpdateInstaller {
    public static func prepare(directory: URL, manifest: ReleaseManifest) throws -> PreparedUpdate {
        let archive = directory.appendingPathComponent(manifest.archiveName)
        try SignedRelease.verifyArchive(archive, manifest: manifest)
        try UpdateArchive.validateEntries(at: archive)
        let unpacked = directory.appendingPathComponent("unpacked", isDirectory: true)
        try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try run("/usr/bin/ditto", ["-x", "-k", archive.path, unpacked.path])
        let application = unpacked.appendingPathComponent("ClipDune.app", isDirectory: true)
        try validateApplication(application, manifest: manifest)
        return PreparedUpdate(directory: directory, application: application, manifest: manifest)
    }

    public static func validateApplication(_ url: URL, manifest: ReleaseManifest) throws {
        let manager = FileManager.default
        let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey]
        guard let enumerator = manager.enumerator(at: url, includingPropertiesForKeys: keys),
              let infoData = try? Data(contentsOf: url.appendingPathComponent("Contents/Info.plist")),
              let info = try? PropertyListSerialization.propertyList(from: infoData, format: nil) as? [String: Any],
              info["CFBundleIdentifier"] as? String == manifest.bundleID,
              info["CFBundleExecutable"] as? String == "ClipDune",
              info["CFBundleShortVersionString"] as? String == manifest.version,
              Int(info["CFBundleVersion"] as? String ?? "") == manifest.build,
              manager.isExecutableFile(atPath: url.appendingPathComponent("Contents/MacOS/ClipDune").path) else { throw UpdateError.unsafeInstall }
        var size = 0
        for case let item as URL in enumerator {
            let values = try item.resourceValues(forKeys: Set(keys))
            guard values.isSymbolicLink != true else { throw UpdateError.unsafeInstall }
            size += values.fileSize ?? 0
            guard size <= 512 * 1024 * 1024 else { throw UpdateError.unsafeInstall }
        }
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", url.path])
    }

    public static func validateDestination(_ destination: URL) throws {
        let manager = FileManager.default
        let normalized = destination.standardizedFileURL
        let allowedParents = [URL(fileURLWithPath: "/Applications", isDirectory: true),
                              manager.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)]
        guard allowedParents.contains(normalized.deletingLastPathComponent()),
              normalized.pathExtension == "app", normalized.resolvingSymlinksInPath() == normalized,
              manager.isWritableFile(atPath: normalized.deletingLastPathComponent().path),
              manager.isWritableFile(atPath: normalized.path),
              Bundle(url: normalized)?.bundleIdentifier == "com.github.boyce-ywr.clipdune" else { throw UpdateError.unsafeInstall }
    }

    public static func swapApplication(_ incoming: URL, with destination: URL) throws {
        guard renameatx_np(AT_FDCWD, incoming.path, AT_FDCWD, destination.path, UInt32(RENAME_SWAP)) == 0 else {
            throw UpdateError.installationFailed
        }
    }

    public static func replaceAndConfirm(source: URL, target: URL, backup: URL,
                                         validate: (URL) throws -> Void,
                                         beforeReplacement: () throws -> Void,
                                         launchAndConfirm: () throws -> Void,
                                         stopNewApplication: () -> Bool,
                                         recordState: (String) throws -> Void) throws {
        let manager = FileManager.default
        var swapped = false
        do {
            try manager.copyItem(at: source, to: backup)
            try validate(backup)
            try beforeReplacement()
            try swapApplication(backup, with: target)
            swapped = true
            try recordState("awaiting_confirmation")
            try launchAndConfirm()
            try recordState("installed")
        } catch {
            if swapped {
                guard stopNewApplication() else {
                    try? recordState("rollback_requires_quit")
                    throw error
                }
                do {
                    try swapApplication(backup, with: target)
                    try recordState("rolled_back")
                } catch { try? recordState("rollback_failed") }
            } else {
                try? recordState("failed_before_replacement")
                try? manager.removeItem(at: backup)
            }
            throw error
        }
    }

    @MainActor
    public static func launchHelper(prepared: PreparedUpdate, target: URL) throws {
        try validateDestination(target)
        let sourceHelper = target.appendingPathComponent("Contents/Helpers/ClipDuneUpdateHelper")
        let helper = prepared.directory.appendingPathComponent("ClipDuneUpdateHelper")
        guard FileManager.default.isExecutableFile(atPath: sourceHelper.path) else { throw UpdateError.unsafeInstall }
        try FileManager.default.copyItem(at: sourceHelper, to: helper)
        let statusDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ClipDune/Updates")
        try FileManager.default.createDirectory(at: statusDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let statusURL = statusDirectory.appendingPathComponent("installation.json")
        let pending: [String: Any] = ["status": "pending", "build": prepared.manifest.build]
        try JSONSerialization.data(withJSONObject: pending).write(to: statusURL, options: .atomic)
        let process = Process()
        process.executableURL = helper
        process.arguments = ["--install", prepared.directory.path, target.path, String(ProcessInfo.processInfo.processIdentifier), statusURL.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let ready = prepared.directory.appendingPathComponent("helper-ready")
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, process.isRunning, !FileManager.default.fileExists(atPath: ready.path) {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        guard FileManager.default.fileExists(atPath: ready.path) else {
            if process.isRunning { process.terminate() }
            throw UpdateError.installationFailed
        }
    }

    public static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 30) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning { process.terminate(); throw UpdateError.installationFailed }
        guard process.terminationStatus == 0 else { throw UpdateError.installationFailed }
    }
}
