import Foundation
import Security
import LocalAuthentication

public enum GitHubCredential {
    private static let service = "com.github.boyce-ywr.clipdune.updates"
    private static let account = "github-release-reader"

    public static var isConfigured: Bool {
        var query = baseQuery
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess || status == errSecInteractionNotAllowed
    }

    public static func read() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else { throw CredentialError.keychain(status) }
        return value
    }

    public static func save(_ token: String) throws {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (20...512).contains(token.utf8.count), !token.contains(where: \.isWhitespace),
              token.unicodeScalars.allSatisfy({ $0.isASCII && $0.value >= 33 && $0.value <= 126 }) else { throw CredentialError.invalidToken }
        let attributes: [String: Any] = [kSecValueData as String: Data(token.utf8),
                                          kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(baseQuery.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw CredentialError.keychain(status) }
    }

    public static func remove() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CredentialError.keychain(status) }
    }

    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
}

private enum CredentialError: LocalizedError {
    case invalidToken, keychain(OSStatus)
    var errorDescription: String? {
        switch self {
        case .invalidToken: return "令牌格式无效，请重新粘贴；不会显示或记录令牌内容。"
        case .keychain(let status): return "钥匙串操作失败（\(status)），请检查系统授权。"
        }
    }
}
