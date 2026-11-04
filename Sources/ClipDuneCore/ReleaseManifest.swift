import CryptoKit
import Foundation

public enum UpdateError: LocalizedError {
    case invalidManifest, invalidSignature, incompatible, noAuthorization, noRelease, missingAsset
    case invalidDownload, untrustedRedirect, network(Int), unsafeInstall, installationFailed, cancelled

    public var errorDescription: String? {
        switch self {
        case .invalidManifest: return "更新清单格式无效。"
        case .invalidSignature: return "更新签名验证失败，已拒绝安装。"
        case .incompatible: return "此版本不适用于当前系统或芯片架构。"
        case .noAuthorization: return "GitHub 拒绝了请求授权（401），请检查发布工具使用的凭据。"
        case .noRelease: return "没有可见的正式 Release。"
        case .missingAsset: return "Release 缺少匹配的更新清单或安装包。"
        case .invalidDownload: return "安装包大小或 SHA-256 校验不一致，已拒绝安装。"
        case .untrustedRedirect: return "更新请求被重定向到不可信地址，已停止下载。"
        case .network(let status): return "GitHub 请求失败（\(status)），请检查网络、代理，或稍后重试（GitHub 对未登录请求有每小时次数限制）。"
        case .unsafeInstall: return "此应用位置无法安全自动更新，请先将完整应用放入可写的 Applications 目录。"
        case .installationFailed: return "更新安装失败，已尝试恢复旧版本；请查看更新状态，不要删除备份。"
        case .cancelled: return "更新已取消。"
        }
    }
}

public struct ReleaseManifest: Codable, Equatable, Sendable {
    public let schema: Int
    public let bundleID: String
    public let version: String
    public let build: Int
    public let minimumSystemVersion: String
    public let architectures: [String]
    public let archiveName: String
    public let archiveBytes: Int64
    public let sha256: String
    public let notes: String

    public init(version: String, build: Int, minimumSystemVersion: String, architectures: [String],
                archiveName: String, archiveBytes: Int64, sha256: String, notes: String) {
        schema = 1
        bundleID = "com.github.boyce-ywr.clipdune"
        self.version = version
        self.build = build
        self.minimumSystemVersion = minimumSystemVersion
        self.architectures = architectures
        self.archiveName = archiveName
        self.archiveBytes = archiveBytes
        self.sha256 = sha256
        self.notes = notes
    }

    public func validate() throws {
        guard schema == 1, bundleID == "com.github.boyce-ywr.clipdune", build > 0,
              Self.versionParts(version) != nil, Self.versionParts(minimumSystemVersion) != nil,
              !architectures.isEmpty, Set(architectures).isSubset(of: ["arm64", "x86_64"]),
              archiveName == "ClipDune-\(version)-macOS.zip", archiveBytes > 0, archiveBytes <= 256 * 1024 * 1024,
              sha256.count == 64, sha256.allSatisfy({ "0123456789abcdef".contains($0) }),
              notes.utf8.count <= 32_768 else { throw UpdateError.invalidManifest }
    }

    public func checkCompatibility(systemVersion: String, architecture: String) throws {
        guard architectures.contains(architecture), let required = Self.versionParts(minimumSystemVersion),
              let current = Self.versionParts(systemVersion), !current.lexicographicallyPrecedes(required) else { throw UpdateError.incompatible }
    }

    public static func versionParts(_ value: String) -> [Int]? {
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        guard (2...3).contains(components.count), value.utf8.count <= 32,
              components.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) && Int($0) != nil }) else { return nil }
        let numbers = components.compactMap { Int($0) }
        return numbers + Array(repeating: 0, count: 3 - numbers.count)
    }
}

public struct SignedRelease: Codable, Sendable {
    public let payload: String
    public let signature: String

    public init(manifest: ReleaseManifest, privateKey: Curve25519.Signing.PrivateKey) throws {
        try manifest.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(manifest)
        payload = bytes.base64EncodedString()
        signature = try privateKey.signature(for: bytes).base64EncodedString()
    }

    public static func verify(_ data: Data, publicKey: Data) throws -> ReleaseManifest {
        guard data.count <= 128 * 1024,
              let envelope = try? JSONDecoder().decode(Self.self, from: data),
              let payload = Data(base64Encoded: envelope.payload), payload.count <= 64 * 1024,
              let signature = Data(base64Encoded: envelope.signature),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey),
              key.isValidSignature(signature, for: payload) else { throw UpdateError.invalidSignature }
        guard let manifest = try? JSONDecoder().decode(ReleaseManifest.self, from: payload) else { throw UpdateError.invalidManifest }
        try manifest.validate()
        return manifest
    }

    public static func verifyArchive(_ url: URL, manifest: ReleaseManifest) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        var bytes: Int64 = 0
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            bytes += Int64(chunk.count)
            guard bytes <= manifest.archiveBytes else { throw UpdateError.invalidDownload }
            digest.update(data: chunk)
        }
        let hash = digest.finalize().map { String(format: "%02x", $0) }.joined()
        guard bytes == manifest.archiveBytes, hash == manifest.sha256 else { throw UpdateError.invalidDownload }
    }
}

public enum GitHubUpdatePolicy {
    public static let repository = "boyce-ywr/clipdune"
    public static let apiRoot = URL(string: "https://api.github.com/repos/\(repository)")!

    public static func allows(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443 else { return false }
        return ["api.github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com"].contains(url.host?.lowercased() ?? "")
    }

    public static func allowsAuthorization(_ url: URL) -> Bool {
        allows(url) && url.host?.lowercased() == "api.github.com" && url.path.hasPrefix("/repos/\(repository)/")
    }

    public static func proxyURL(_ value: String) throws -> URL? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return nil }
        guard let url = URL(string: value), url.scheme == "http", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/", let port = url.port, (1...65_535).contains(port) else {
            throw UpdateError.network(NSURLErrorBadURL)
        }
        return url
    }
}
