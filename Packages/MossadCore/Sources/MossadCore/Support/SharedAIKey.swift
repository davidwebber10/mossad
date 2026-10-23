import Foundation
import Security

/// The AI provider, model, and key, shared from the Mac to the iPhone through iCloud Keychain, so Chat and the
/// coach work on the phone without typing a key there. Only apps in the shared keychain group can read it.
public struct SharedAIKey: Codable, Equatable, Sendable {
    public var provider: String
    public var model: String
    public var key: String

    public init(provider: String, model: String, key: String) {
        self.provider = provider
        self.model = model
        self.key = key
    }

    public static let accessGroup = "35VNBDXR6B.com.dwebber.mossad.shared"
    static let service = "com.dwebber.mossad.shared"
    static let account = "ai"

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecAttrAccessGroup as String: accessGroup,
         kSecAttrSynchronizable as String: true,
         kSecUseDataProtectionKeychain as String: true]
    }

    public static func load() -> SharedAIKey? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return try? JSONDecoder().decode(SharedAIKey.self, from: data)
    }

    public func save() throws {
        let data = try JSONEncoder().encode(self)
        let status = SecItemUpdate(Self.query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = Self.query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let result = SecItemAdd(add as CFDictionary, nil)
            guard result == errSecSuccess else { throw KeychainError(status: result) }
        } else if status != errSecSuccess {
            throw KeychainError(status: status)
        }
    }

    public static func delete() {
        SecItemDelete(query as CFDictionary)
    }
}
