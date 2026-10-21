import Foundation
import CryptoKit
import ClipDuneCore
import ClipDuneMac

func option(_ name: String) throws -> String {
    guard let index = CommandLine.arguments.firstIndex(of: name), CommandLine.arguments.indices.contains(index + 1) else { throw UpdateError.invalidManifest }
    return CommandLine.arguments[index + 1]
}

func hashFile(_ url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var digest = SHA256()
    while let bytes = try handle.read(upToCount: 1024 * 1024), !bytes.isEmpty { digest.update(data: bytes) }
    return digest.finalize().map { String(format: "%02x", $0) }.joined()
}

do {
    switch CommandLine.arguments.dropFirst().first {
    case "keygen":
        let privateURL = URL(fileURLWithPath: try option("--private-key"))
        let publicURL = URL(fileURLWithPath: try option("--public-key"))
        let manager = FileManager.default
        try manager.createDirectory(at: privateURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let key: Curve25519.Signing.PrivateKey
        if manager.fileExists(atPath: privateURL.path) {
            key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(contentsOf: privateURL))
        } else {
            key = Curve25519.Signing.PrivateKey()
            guard manager.createFile(atPath: privateURL.path, contents: key.rawRepresentation, attributes: [.posixPermissions: 0o600]) else { throw UpdateError.unsafeInstall }
        }
        if manager.fileExists(atPath: publicURL.path) {
            let existing = try String(contentsOf: publicURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            guard existing == key.publicKey.rawRepresentation.base64EncodedString() else { throw UpdateError.invalidSignature }
        } else {
            try (key.publicKey.rawRepresentation.base64EncodedString() + "\n").write(to: publicURL, atomically: true, encoding: .utf8)
        }
        print("签名密钥已就绪；只将公钥写入工程，私钥未输出。")
    case "sign":
        let archive = URL(fileURLWithPath: try option("--archive"))
        let application = URL(fileURLWithPath: try option("--app"))
        let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(contentsOf: URL(fileURLWithPath: try option("--private-key"))))
        let publicText = try String(contentsOf: application.appendingPathComponent("Contents/Resources/UpdatePublicKey.txt"), encoding: .utf8)
        guard Data(base64Encoded: publicText.trimmingCharacters(in: .whitespacesAndNewlines)) == privateKey.publicKey.rawRepresentation else {
            throw UpdateError.invalidSignature
        }
        guard let bundle = Bundle(url: application),
              let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              let build = Int(bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""),
              let minimum = bundle.object(forInfoDictionaryKey: "LSMinimumSystemVersion") as? String,
              let bytes = try FileManager.default.attributesOfItem(atPath: archive.path)[.size] as? NSNumber else { throw UpdateError.invalidManifest }
        let notes = try String(contentsOf: URL(fileURLWithPath: try option("--notes")), encoding: .utf8)
        let architectures = try option("--architectures").split(separator: ",").map(String.init)
        let manifest = ReleaseManifest(version: version, build: build, minimumSystemVersion: minimum,
                                       architectures: architectures, archiveName: archive.lastPathComponent,
                                       archiveBytes: bytes.int64Value, sha256: try hashFile(archive), notes: notes)
        try UpdateInstaller.validateApplication(application, manifest: manifest)
        try UpdateArchive.validateEntries(at: archive)
        let signed = try SignedRelease(manifest: manifest, privateKey: privateKey)
        let data = try JSONEncoder().encode(signed)
        _ = try SignedRelease.verify(data, publicKey: privateKey.publicKey.rawRepresentation)
        try SignedRelease.verifyArchive(archive, manifest: manifest)
        try data.write(to: URL(fileURLWithPath: try option("--output")), options: .atomic)
        print("已签名并验证版本 \(version)，构建 \(build)。")
    case "verify":
        let text = try String(contentsOf: URL(fileURLWithPath: try option("--public-key")), encoding: .utf8)
        guard let key = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw UpdateError.invalidSignature }
        let manifest = try SignedRelease.verify(Data(contentsOf: URL(fileURLWithPath: try option("--manifest"))), publicKey: key)
        let archive = URL(fileURLWithPath: try option("--archive"))
        try SignedRelease.verifyArchive(archive, manifest: manifest)
        try UpdateArchive.validateEntries(at: archive)
        print("PASS 签名、SHA-256、大小与 ZIP 路径校验：\(manifest.version)")
    case "check-feed":
        let tokenData = FileHandle.standardInput.readDataToEndOfFile()
        guard tokenData.count <= 1024, let token = String(data: tokenData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else { throw UpdateError.noAuthorization }
        let publicText = try String(contentsOf: URL(fileURLWithPath: try option("--public-key")), encoding: .utf8)
        guard let publicKey = Data(base64Encoded: publicText.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw UpdateError.invalidSignature }
        let directory = URL(fileURLWithPath: try option("--output"), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let semaphore = DispatchSemaphore(value: 0)
        let releaseID = (try? option("--release-id")).flatMap(Int64.init)
        Task.detached {
            do {
                let release: GitHubRelease
                if let releaseID { release = try await GitHubReleaseClient.releaseForPublishing(id: releaseID, token: token) }
                else { release = try await GitHubReleaseClient.latest(token: token) }
                let data = try await GitHubReleaseClient.manifest(release.asset(named: "clipdune-update.json"), token: token)
                let manifest = try SignedRelease.verify(data, publicKey: publicKey)
                guard release.tag_name == "v\(manifest.version)" else { throw UpdateError.invalidManifest }
                let asset = try release.asset(named: manifest.archiveName)
                guard asset.size == manifest.archiveBytes else { throw UpdateError.invalidDownload }
                try data.write(to: directory.appendingPathComponent("clipdune-update.json"), options: .atomic)
                try await GitHubReleaseClient.archive(asset, token: token, destination: directory.appendingPathComponent(manifest.archiveName)) { _ in }
                let prepared = try UpdateInstaller.prepare(directory: directory, manifest: manifest)
                print("PASS 私有仓库 Release API、真实资产下载、签名、ZIP 与应用校验：\(prepared.manifest.version)")
                semaphore.signal()
            } catch {
                print("更新下载验证失败：\(error.localizedDescription)")
                exit(1)
            }
        }
        guard semaphore.wait(timeout: .now() + 180) == .success else { throw UpdateError.network(NSURLErrorTimedOut) }
    default:
        print("ClipDuneReleaseTool keygen | sign | verify | check-feed")
        exit(2)
    }
} catch {
    print("发布工具失败：\(error.localizedDescription)")
    exit(1)
}
