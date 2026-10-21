import Foundation
import Security

public enum APIKey: String, CaseIterable, Sendable {
    case assemblyai
    case anthropic

    /// The Doppler secret name each key is imported from.
    var dopplerName: String {
        switch self {
        case .assemblyai: "ASSEMBLYAI"
        case .anthropic: "ANTHROPIC_API_KEY_POLYWOOD_ANALYTICS"
        }
    }
}

/// Generic-password storage for API keys.
public struct Keychain: Sendable {
    public let service: String

    public init(service: String = "com.dwebber.mossad") {
        self.service = service
    }

    private func query(_ key: APIKey) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: key.rawValue]
    }

    public func set(_ value: String, for key: APIKey) throws {
        let data = Data(value.utf8)
        let status = SecItemUpdate(query(key) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query(key)
            add[kSecValueData as String] = data
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
        } else if status != errSecSuccess {
            throw KeychainError(status: status)
        }
    }

    public func get(_ key: APIKey) -> String? {
        var q = query(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func delete(_ key: APIKey) {
        SecItemDelete(query(key) as CFDictionary)
    }
}

public struct KeychainError: Error, CustomStringConvertible {
    public let status: OSStatus
    public var description: String { "Keychain error \(status)" }
}

/// Copies keys from Doppler-provided environment variables into the Keychain.
/// Returns the keys that were stored.
@discardableResult
public func importKeys(from env: [String: String], into keychain: Keychain) -> [APIKey] {
    APIKey.allCases.compactMap { key in
        guard let value = env[key.dopplerName], !value.isEmpty else { return nil }
        do {
            try keychain.set(value, for: key)
            return key
        } catch {
            Log.error("Could not store \(key.rawValue): \(error)")
            return nil
        }
    }
}
