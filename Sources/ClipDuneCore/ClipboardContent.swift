import CryptoKit
import Foundation

public struct ClipboardRepresentation: Codable, Equatable, Sendable {
    public let type: String
    public let data: Data

    public init(type: String, data: Data) {
        self.type = type
        self.data = data
    }
}

public struct ClipboardFragment: Codable, Equatable, Sendable {
    public let representations: [ClipboardRepresentation]

    public init(representations: [ClipboardRepresentation]) {
        self.representations = representations
    }
}

public enum ClipKind: String, Codable, Sendable, CaseIterable {
    case text, richText, html, image, link, files, color, other

    public var title: String {
        switch self {
        case .text: return "文本"
        case .richText: return "富文本"
        case .html: return "HTML"
        case .image: return "图片"
        case .link: return "链接"
        case .files: return "文件"
        case .color: return "颜色"
        case .other: return "其他"
        }
    }

    public var legacyKind: ClipKind {
        switch self {
        case .html: return .richText
        case .color, .other: return .text
        default: return self
        }
    }
}

public struct ClipboardContent: Codable, Equatable, Sendable {
    public let fragments: [ClipboardFragment]
    public let text: String
    public let kind: ClipKind
    public let sourceName: String
    public let sourceBundleID: String
    public let thumbnail: Data?

    public init(fragments: [ClipboardFragment], text: String, kind: ClipKind,
                sourceName: String, sourceBundleID: String, thumbnail: Data? = nil) {
        self.fragments = fragments
        self.text = text
        self.kind = kind
        self.sourceName = sourceName
        self.sourceBundleID = sourceBundleID
        self.thumbnail = thumbnail
    }

    public var byteCount: Int {
        fragments.reduce(thumbnail?.count ?? 0) { total, fragment in
            total + fragment.representations.reduce(0) { $0 + $1.data.count }
        }
    }

    public var contentByteCount: Int {
        fragments.reduce(0) { total, fragment in
            if kind == .image {
                let imageTypes = ["public.png", "public.tiff", "public.jpeg", "com.compuserve.gif", "public.heic"]
                let preferred = imageTypes.lazy.compactMap { type in fragment.representations.first { $0.type == type } }.first ??
                    fragment.representations.first(where: { !["public.utf8-plain-text", "public.rtf", "public.html", "public.url", "public.file-url"].contains($0.type) })
                return total + (preferred?.data.count ?? 0)
            }
            return total + fragment.representations.reduce(0) { $0 + $1.data.count }
        }
    }

    public var objectCount: Int {
        if kind == .files { return fragments.filter { $0.representations.contains { $0.type == "public.file-url" } }.count }
        return fragments.count
    }

    private enum CodingKeys: String, CodingKey {
        case fragments, text, kind, contentKind, sourceName, sourceBundleID, thumbnail
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        fragments = try values.decode([ClipboardFragment].self, forKey: .fragments)
        text = try values.decode(String.self, forKey: .text)
        let stored = try values.decode(ClipKind.self, forKey: .kind)
        let types = Set(fragments.flatMap(\.representations).map(\.type))
        kind = try values.decodeIfPresent(ClipKind.self, forKey: .contentKind) ??
            (stored == .richText && types.contains("public.html") && !types.contains("public.rtf") ? .html : stored)
        sourceName = try values.decode(String.self, forKey: .sourceName)
        sourceBundleID = try values.decode(String.self, forKey: .sourceBundleID)
        thumbnail = try values.decodeIfPresent(Data.self, forKey: .thumbnail)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(fragments, forKey: .fragments)
        try values.encode(text, forKey: .text)
        try values.encode(kind.legacyKind, forKey: .kind)
        try values.encode(kind, forKey: .contentKind)
        try values.encode(sourceName, forKey: .sourceName)
        try values.encode(sourceBundleID, forKey: .sourceBundleID)
        try values.encodeIfPresent(thumbnail, forKey: .thumbnail)
    }

    public var fingerprint: String {
        var digest = SHA256()
        for fragment in fragments {
            digest.update(data: Data("fragment\u{0}".utf8))
            for representation in fragment.representations.sorted(by: { $0.type < $1.type }) {
                digest.update(data: Data("\(representation.type.utf8.count):\(representation.type):\(representation.data.count):".utf8))
                digest.update(data: representation.data)
            }
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public func validate(maximumBytes: Int) throws {
        guard !fragments.isEmpty, fragments.count <= 100,
              fragments.allSatisfy({ !$0.representations.isEmpty && $0.representations.count <= 32 }),
              fragments.allSatisfy({ Set($0.representations.map(\.type)).count == $0.representations.count }),
              fragments.allSatisfy({ $0.representations.allSatisfy { CapturePolicy.canStoreRepresentation($0.type) } }),
              byteCount <= maximumBytes,
              text.utf8.count <= maximumBytes,
              sourceName.utf8.count <= 1024, sourceBundleID.utf8.count <= 1024 else {
            throw HistoryError.invalidContent
        }
    }
}

public struct ClipSummary: Identifiable, Sendable {
    public let id: String
    public let text: String
    public let kind: ClipKind
    public let sourceName: String
    public let copiedAt: Date
    public let isPinned: Bool
    public let thumbnail: Data?
    public let userTitle: String
    public let sourceBundleID: String
    public let contentBytes: Int
    public let fragmentCount: Int

    public var sizeLabel: String {
        switch kind {
        case .text, .richText, .html, .link: return "\(text.count) 个字符"
        case .files: return "\(fragmentCount) 个文件引用"
        case .color: return "\(fragmentCount) 个颜色"
        case .image, .other:
            return ByteCountFormatter.string(fromByteCount: Int64(contentBytes), countStyle: .file)
        }
    }
}

public struct HistoryLimits: Sendable {
    public var maximumItems: Int
    public var maximumBytes: Int
    public var maximumItemBytes: Int
    public var retentionDays: Int

    public init(maximumItems: Int = 2_000, maximumBytes: Int = 256 * 1024 * 1024,
                maximumItemBytes: Int = 16 * 1024 * 1024, retentionDays: Int = 30) {
        self.maximumItems = maximumItems
        self.maximumBytes = maximumBytes
        self.maximumItemBytes = maximumItemBytes
        self.retentionDays = retentionDays
    }
}

public enum HistoryError: LocalizedError {
    case database(String), invalidContent, unsupportedVersion, capacityReached, invalidTitle

    public var errorDescription: String? {
        switch self {
        case .database: return "本地数据库操作失败，请检查存储空间与文件权限。"
        case .invalidContent: return "内容格式无效或超过单项大小限制。"
        case .unsupportedVersion: return "数据版本高于当前应用支持的版本，请先升级应用。"
        case .capacityReached: return "收藏内容已占满存储预算，请先删除不需要的收藏。"
        case .invalidTitle: return "名称最多 120 个字符，不能包含换行或控制字符。"
        }
    }
}

public enum CapturePolicy {
    public static let supportedTypes: Set<String> = [
        "public.utf8-plain-text", "public.rtf", "public.html", "public.png",
        "public.tiff", "public.file-url", "public.url", "com.adobe.pdf",
        "com.apple.cocoa.pasteboard.color", "public.jpeg", "com.compuserve.gif", "public.heic"
    ]

    public static func canStoreRepresentation(_ type: String) -> Bool {
        guard !confidentialTypes.contains(type), !type.hasPrefix("org.nspasteboard."),
              !type.hasPrefix("com.apple.pasteboard."), !type.lowercased().contains("filepromise"),
              type.utf8.count <= 255, !type.isEmpty else { return false }
        if supportedTypes.contains(type) { return true }
        return type.contains(".") && type.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || ".-_".unicodeScalars.contains($0)
        }
    }

    public static let confidentialTypes: Set<String> = [
        "org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType",
        "org.nspasteboard.AutoGeneratedType", "com.agilebits.onepassword"
    ]

    public static let defaultExcludedApplications: Set<String> = [
        "com.1password.1password", "com.agilebits.onepassword7",
        "com.bitwarden.desktop", "com.apple.Passwords", "org.keepassxc.keepassxc"
    ]

    public static func allows(types: Set<String>, sourceBundleID: String,
                              excludedApplications: Set<String>, paused: Bool) -> Bool {
        !paused && confidentialTypes.isDisjoint(with: types) &&
        !excludedApplications.contains(sourceBundleID)
    }
}
