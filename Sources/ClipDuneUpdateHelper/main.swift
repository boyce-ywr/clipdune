import AppKit
import ClipDuneCore
import ClipDuneMac
import Darwin

func writeStatus(_ status: String, to url: URL, build: Int, backup: URL? = nil, receipt: URL? = nil) throws {
    var object: [String: Any] = ["status": status, "build": build]
    if let backup { object["backup"] = backup.path }
    if let receipt { object["receipt"] = receipt.path }
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
}

func install(arguments: [String]) throws {
    guard arguments.count == 6, arguments[1] == "--install", let parentPID = Int32(arguments[4]), parentPID > 1 else { throw UpdateError.unsafeInstall }
    let manager = FileManager.default
    let stage = URL(fileURLWithPath: arguments[2], isDirectory: true).standardizedFileURL
    let target = URL(fileURLWithPath: arguments[3], isDirectory: true).standardizedFileURL
    let status = URL(fileURLWithPath: arguments[5]).standardizedFileURL
    let expectedStatus = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ClipDune/Updates/installation.json")
    guard stage.lastPathComponent.hasPrefix("clipdune-update-"), stage.resolvingSymlinksInPath().deletingLastPathComponent() == manager.temporaryDirectory.resolvingSymlinksInPath(),
          status == expectedStatus else { throw UpdateError.unsafeInstall }
    try UpdateInstaller.validateDestination(target)
    guard let parent = NSRunningApplication(processIdentifier: parentPID), parent.bundleURL?.standardizedFileURL == target,
          let keyText = try? String(contentsOf: target.appendingPathComponent("Contents/Resources/UpdatePublicKey.txt"), encoding: .utf8),
          let key = Data(base64Encoded: keyText.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw UpdateError.unsafeInstall }
    let signedData = try Data(contentsOf: stage.appendingPathComponent("clipdune-update.json"))
    let manifest = try SignedRelease.verify(signedData, publicKey: key)
    let installedBuild = Int(Bundle(url: target)?.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0") ?? 0
    guard manifest.build > installedBuild else { throw UpdateError.unsafeInstall }
    try SignedRelease.verifyArchive(stage.appendingPathComponent(manifest.archiveName), manifest: manifest)
    let unpacked = stage.appendingPathComponent("unpacked/ClipDune.app")
    try UpdateInstaller.validateApplication(unpacked, manifest: manifest)
    try Data().write(to: stage.appendingPathComponent("helper-ready"), options: .atomic)
    let deadline = Date().addingTimeInterval(30)
    while kill(parentPID, 0) == 0, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
    guard kill(parentPID, 0) != 0 else { throw UpdateError.installationFailed }
    let backup = target.deletingLastPathComponent().appendingPathComponent(".ClipDune-backup-\(UUID().uuidString).app")
    let receipt = status.deletingLastPathComponent().appendingPathComponent("confirmation-\(UUID().uuidString).json")
    try UpdateInstaller.replaceAndConfirm(source: unpacked, target: target, backup: backup, validate: {
        try UpdateInstaller.validateApplication($0, manifest: manifest)
    }, beforeReplacement: {
        try writeStatus("prepared", to: status, build: manifest.build, backup: backup, receipt: receipt)
    }, launchAndConfirm: {
        try UpdateInstaller.run("/usr/bin/open", ["-n", target.path, "--args", "--updated-confirmation", receipt.path])
        let healthDeadline = Date().addingTimeInterval(45)
        while Date() < healthDeadline {
            if let data = try? Data(contentsOf: receipt),
               let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               result["build"] as? Int == manifest.build, result["status"] as? String == "ready" {
                try? manager.removeItem(at: receipt)
                return
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw UpdateError.installationFailed
    }, stopNewApplication: {
        let running = NSWorkspace.shared.runningApplications.filter { $0.bundleURL?.standardizedFileURL == target }
        for application in running { _ = application.terminate() }
        let exitDeadline = Date().addingTimeInterval(5)
        while running.contains(where: { !$0.isTerminated }), Date() < exitDeadline { Thread.sleep(forTimeInterval: 0.1) }
        return running.allSatisfy(\.isTerminated)
    }, recordState: { phase in
        try writeStatus(phase, to: status, build: manifest.build, backup: backup,
                        receipt: phase == "awaiting_confirmation" ? receipt : nil)
        if phase == "rolled_back" { try? UpdateInstaller.run("/usr/bin/open", [target.path]) }
    })
    try? manager.removeItem(at: stage)
}

do { try install(arguments: CommandLine.arguments) }
catch { exit(1) }
