import Foundation
import CryptoKit
import ClipDuneCore
import ClipDuneMac

final class UpdateTests {
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent("clipdune-update-test-\(UUID().uuidString)")

    init() throws { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
    deinit { try? FileManager.default.removeItem(at: directory) }

    private func manifest(data: Data = Data("fixture".utf8), build: Int = 2) -> ReleaseManifest {
        .init(version: "0.2.0", build: build, minimumSystemVersion: "14.0", architectures: ["arm64"],
              archiveName: "ClipDune-0.2.0-macOS.zip", archiveBytes: Int64(data.count),
              sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), notes: "测试版本")
    }

    func signatureRejectsTamperingAndWrongKey() throws {
        let key = Curve25519.Signing.PrivateKey()
        let original = manifest()
        let signed = try JSONEncoder().encode(SignedRelease(manifest: original, privateKey: key))
        expectEqual(try SignedRelease.verify(signed, publicKey: key.publicKey.rawRepresentation), original)
        let wrong = Curve25519.Signing.PrivateKey()
        do { _ = try SignedRelease.verify(signed, publicKey: wrong.publicKey.rawRepresentation); fail("wrong key accepted") }
        catch UpdateError.invalidSignature { }
        var json = try requireValue(JSONSerialization.jsonObject(with: signed) as? [String: Any])
        json["payload"] = Data("tampered".utf8).base64EncodedString()
        do { _ = try SignedRelease.verify(JSONSerialization.data(withJSONObject: json), publicKey: key.publicKey.rawRepresentation); fail("tampered data accepted") }
        catch UpdateError.invalidSignature { }
        do { _ = try SignedRelease.verify(Data(repeating: 0, count: 129 * 1024), publicKey: key.publicKey.rawRepresentation); fail("oversize accepted") }
        catch UpdateError.invalidSignature { }
    }

    func archiveHashAndLengthAreVerified() throws {
        let bytes = Data("fixture".utf8)
        let archive = directory.appendingPathComponent("archive.zip")
        try bytes.write(to: archive)
        try SignedRelease.verifyArchive(archive, manifest: manifest(data: bytes))
        try Data("fixturE".utf8).write(to: archive)
        do { try SignedRelease.verifyArchive(archive, manifest: manifest(data: bytes)); fail("hash mismatch accepted") }
        catch UpdateError.invalidDownload { }
        try Data("fixture oversized".utf8).write(to: archive)
        do { try SignedRelease.verifyArchive(archive, manifest: manifest(data: bytes)); fail("size mismatch accepted") }
        catch UpdateError.invalidDownload { }
    }

    func architectureAndSystemCompatibility() throws {
        try manifest().checkCompatibility(systemVersion: "14.0", architecture: "arm64")
        try manifest().checkCompatibility(systemVersion: "27.0.1", architecture: "arm64")
        do { try manifest().checkCompatibility(systemVersion: "13.9", architecture: "arm64"); fail("old system accepted") }
        catch UpdateError.incompatible { }
        do { try manifest().checkCompatibility(systemVersion: "27.0", architecture: "x86_64"); fail("wrong architecture accepted") }
        catch UpdateError.incompatible { }
        expectNil(ReleaseManifest.versionParts("1.0-beta"))
        expectNil(ReleaseManifest.versionParts("../x"))
    }

    func redirectPolicyDoesNotLeakAuthorization() throws {
        expectEqual(try GitHubUpdatePolicy.proxyURL("http://127.0.0.1:7897")?.port, 7897)
        expectNil(try GitHubUpdatePolicy.proxyURL(""))
        for proxy in ["http://user:secret@localhost:7897", "https://localhost:7897", "http://localhost:7897/path"] {
            do { _ = try GitHubUpdatePolicy.proxyURL(proxy); fail("unsafe proxy accepted") }
            catch UpdateError.network { }
        }
        expectTrue(GitHubUpdatePolicy.allowsAuthorization(URL(string: "https://api.github.com/repos/boyce-ywr/clipdune/releases/assets/1")!))
        expectFalse(GitHubUpdatePolicy.allowsAuthorization(URL(string: "https://release-assets.githubusercontent.com/file")!))
        expectTrue(GitHubUpdatePolicy.allows(URL(string: "https://release-assets.githubusercontent.com/file")!))
        for value in ["http://api.github.com/repos/boyce-ywr/clipdune/releases", "https://api.github.com.evil.example/file",
                      "https://evil.example/file", "https://user@api.github.com/file", "https://api.github.com:444/file"] {
            expectFalse(GitHubUpdatePolicy.allows(URL(string: value)!))
        }
        expectFalse(GitHubUpdatePolicy.allowsAuthorization(URL(string: "https://api.github.com/repos/other/repo/releases")!))
    }

    func zipEntriesRejectTraversalAndSymlinks() throws {
        expectTrue(UpdateArchive.isSafeEntry("ClipDune.app/Contents/Info.plist"))
        for value in ["/tmp/ClipDune.app/x", "ClipDune.app/../escape", "ClipDune.app/Contents/../../escape",
                      "Other.app/file", "ClipDune.app/Contents\\escape", "ClipDune.app/Contents/\0"] {
            expectFalse(UpdateArchive.isSafeEntry(value))
        }
        let app = directory.appendingPathComponent("ClipDune.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try Data("safe".utf8).write(to: app.appendingPathComponent("file"))
        let archive = directory.appendingPathComponent("safe.zip")
        try UpdateInstaller.run("/usr/bin/ditto", ["-c", "-k", "--norsrc", "--keepParent", app.path, archive.path])
        try UpdateArchive.validateEntries(at: archive)
        try FileManager.default.createSymbolicLink(atPath: app.appendingPathComponent("link").path, withDestinationPath: "/tmp")
        let unsafe = directory.appendingPathComponent("unsafe.zip")
        try UpdateInstaller.run("/usr/bin/ditto", ["-c", "-k", "--norsrc", "--keepParent", app.path, unsafe.path])
        do { try UpdateArchive.validateEntries(at: unsafe); fail("symlink archive accepted") }
        catch UpdateError.invalidDownload { }
    }

    func atomicSwapAndRollbackPreserveBothVersions() throws {
        let target = directory.appendingPathComponent("ClipDune.app")
        let incoming = directory.appendingPathComponent("incoming.app")
        for item in [target, incoming] { try FileManager.default.createDirectory(at: item, withIntermediateDirectories: false) }
        try Data("old".utf8).write(to: target.appendingPathComponent("version"))
        try Data("new".utf8).write(to: incoming.appendingPathComponent("version"))
        let unrelated = directory.appendingPathComponent("history")
        try Data("keep data".utf8).write(to: unrelated)
        try UpdateInstaller.swapApplication(incoming, with: target)
        expectEqual(try String(contentsOf: target.appendingPathComponent("version"), encoding: .utf8), "new")
        expectEqual(try String(contentsOf: incoming.appendingPathComponent("version"), encoding: .utf8), "old")
        try UpdateInstaller.swapApplication(incoming, with: target)
        expectEqual(try String(contentsOf: target.appendingPathComponent("version"), encoding: .utf8), "old")
        expectEqual(try String(contentsOf: unrelated, encoding: .utf8), "keep data")
        do { try UpdateInstaller.validateDestination(target); fail("temporary destination accepted") }
        catch UpdateError.unsafeInstall { }
    }

    func failedRelaunchRollsBackThroughProductionTransaction() throws {
        let target = directory.appendingPathComponent("ClipDune.app")
        let source = directory.appendingPathComponent("new.app")
        let backup = directory.appendingPathComponent("backup.app")
        for item in [target, source] { try FileManager.default.createDirectory(at: item, withIntermediateDirectories: false) }
        try Data("old".utf8).write(to: target.appendingPathComponent("version"))
        try Data("new".utf8).write(to: source.appendingPathComponent("version"))
        var states: [String] = []
        do {
            try UpdateInstaller.replaceAndConfirm(source: source, target: target, backup: backup,
                validate: { expectEqual(try String(contentsOf: $0.appendingPathComponent("version"), encoding: .utf8), "new") },
                beforeReplacement: {}, launchAndConfirm: {
                    expectEqual(try String(contentsOf: target.appendingPathComponent("version"), encoding: .utf8), "new")
                    throw UpdateError.installationFailed
                }, stopNewApplication: { true }, recordState: { states.append($0) })
            fail("Expected failed launch")
        } catch UpdateError.installationFailed { }
        expectEqual(try String(contentsOf: target.appendingPathComponent("version"), encoding: .utf8), "old")
        expectEqual(states, ["awaiting_confirmation", "rolled_back"])
    }

    func successfulTransactionPreservesOldApplicationAsBackup() throws {
        let target = directory.appendingPathComponent("ClipDune.app")
        let source = directory.appendingPathComponent("new.app")
        let backup = directory.appendingPathComponent("backup.app")
        for item in [target, source] { try FileManager.default.createDirectory(at: item, withIntermediateDirectories: false) }
        try Data("old".utf8).write(to: target.appendingPathComponent("version"))
        try Data("new".utf8).write(to: source.appendingPathComponent("version"))
        var states: [String] = []
        try UpdateInstaller.replaceAndConfirm(source: source, target: target, backup: backup,
            validate: { _ in }, beforeReplacement: {}, launchAndConfirm: {},
            stopNewApplication: { fail("Unexpected rollback"); return true }, recordState: { states.append($0) })
        expectEqual(states, ["awaiting_confirmation", "installed"])
        expectEqual(try String(contentsOf: target.appendingPathComponent("version"), encoding: .utf8), "new")
        expectEqual(try String(contentsOf: backup.appendingPathComponent("version"), encoding: .utf8), "old")
    }

    func preferencesRoundTripAndPasteOverride() throws {
        let name = "app.clipdune.preferences.test.\(UUID().uuidString)"
        let defaults = try requireValue(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        var preferences = AppPreferences(defaults: defaults)
        expectTrue(preferences.pastesDirectly)
        expectFalse(preferences.usesPlainText(shiftHeld: false))
        expectTrue(preferences.usesPlainText(shiftHeld: true))
        preferences.alwaysPastePlainText = true
        preferences.maximumItems = 10_000
        preferences.appearance = .dark
        preferences.showsMenuBarIcon = false
        preferences.save(to: defaults)
        expectEqual(AppPreferences(defaults: defaults), preferences)
        expectTrue(preferences.usesPlainText(shiftHeld: false))
        expectFalse(preferences.usesPlainText(shiftHeld: true))
    }

    func destinationPolicyRejectsWrongApplicationsAndWindows() {
        expectEqual(PasteFocusPolicy.evaluate(expectedPID: 100, currentPID: 100, focusedElementMatches: true, targetWindowMatches: true, hasPermission: true, targetTerminated: false), .ready)
        expectEqual(PasteFocusPolicy.evaluate(expectedPID: 100, currentPID: 100, focusedElementMatches: nil, targetWindowMatches: true, hasPermission: true, targetTerminated: false), .waitingForFocus)
        expectEqual(PasteFocusPolicy.evaluate(expectedPID: 100, currentPID: 200, focusedElementMatches: true, targetWindowMatches: true, hasPermission: true, targetTerminated: false), .targetChanged)
        expectEqual(PasteFocusPolicy.evaluate(expectedPID: 100, currentPID: 100, focusedElementMatches: true, targetWindowMatches: false, hasPermission: true, targetTerminated: false), .targetChanged)
        expectEqual(PasteFocusPolicy.evaluate(expectedPID: 100, currentPID: 100, focusedElementMatches: true, targetWindowMatches: true, hasPermission: false, targetTerminated: false), .unavailable)
    }

    func permissionURLsTargetCorrectPanes() {
        expectTrue(SystemSettings.url(for: .clipboard).absoluteString.hasSuffix("?Privacy_Pasteboard"))
        expectTrue(SystemSettings.url(for: .accessibility).absoluteString.hasSuffix("?Privacy_Accessibility"))
    }

    func releaseMetadataRequiresUniqueAssets() throws {
        let bytes = Data("{\"tag_name\":\"v0.2.0\",\"draft\":false,\"prerelease\":false,\"assets\":[{\"id\":1,\"name\":\"clipdune-update.json\",\"size\":100}]}".utf8)
        let release = try JSONDecoder().decode(GitHubRelease.self, from: bytes)
        expectEqual(try release.asset(named: "clipdune-update.json").id, 1)
        do { _ = try release.asset(named: "missing.zip"); fail("missing asset accepted") }
        catch UpdateError.missingAsset { }
    }
}
