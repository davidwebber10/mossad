import Foundation
import Security

/// How the iPhone learns the server: a code the Mac shows (scan it), or iCloud Keychain when both devices use it.
public enum ServerPairing {
    static let scheme = "mossad-server"

    /// "mossad-server:<base64url JSON>": what the Mac's QR code holds.
    public static func code(for c: ServerConnection) -> String {
        let data = (try? JSONEncoder().encode(c)) ?? Data()
        return "\(scheme):\(data.base64URL)"
    }

    public static func connection(fromCode text: String) -> ServerConnection? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("\(scheme):") else { return nil }
        var b = String(t.dropFirst(scheme.count + 1)).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        guard let data = Data(base64Encoded: b), let c = try? JSONDecoder().decode(ServerConnection.self, from: data),
              ServerConnection.address(from: c.address.absoluteString) != nil, !c.secret.isEmpty else { return nil }
        return c
    }

    // MARK: iCloud Keychain

    static let service = "com.dwebber.mossad.shared"
    static let account = "server"

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecAttrAccessGroup as String: SharedAIKey.accessGroup,
         kSecAttrSynchronizable as String: true,
         kSecUseDataProtectionKeychain as String: true]
    }

    /// The server the Mac shared through iCloud Keychain, if any.
    public static func shared() -> ServerConnection? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return try? JSONDecoder().decode(ServerConnection.self, from: data)
    }

    public static func share(_ c: ServerConnection) throws {
        let data = try JSONEncoder().encode(c)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let result = SecItemAdd(add as CFDictionary, nil)
            guard result == errSecSuccess else { throw KeychainError(status: result) }
        } else if status != errSecSuccess {
            throw KeychainError(status: status)
        }
    }

    public static func unshare() { SecItemDelete(query as CFDictionary) }
}

/// Where this device syncs: iCloud (the default), the owner's own server, or nowhere.
public enum SyncChoice: String, CaseIterable, Sendable {
    case icloud, server, off
}
