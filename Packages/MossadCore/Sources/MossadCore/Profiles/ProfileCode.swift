import Foundation

/// The profile code: one profile of the Mac for the iPhone, where iCloud Keychain is off. It holds the profile's id,
/// name, color, and how it syncs; for a server also the address and the secret, so it is shown only for a minute.
/// The old `mossad-server:` code still pairs the first profile.
public struct ProfileCode: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public static let scheme = "mossad-profile"
    public static let currentVersion = 1

    public var version: Int
    public var id: String
    public var name: String
    public var color: ProfileColor
    /// "icloud" or "server".
    public var sync: String
    /// Only with "server".
    public var address: URL?
    /// Only with "server".
    public var secret: String?

    /// The Mac's active profile with its own sync and server. Nil for no sync, and for a server with no connection.
    public static func make(profile: Profile, sync: SyncChoice, server: ServerConnection?) -> ProfileCode? {
        switch sync {
        case .off: return nil
        case .icloud:
            return ProfileCode(version: currentVersion, id: profile.id, name: profile.name, color: profile.color, sync: SyncChoice.icloud.rawValue)
        case .server:
            guard let server else { return nil }
            return ProfileCode(version: currentVersion, id: profile.id, name: profile.name, color: profile.color, sync: SyncChoice.server.rawValue,
                               address: server.address, secret: server.secret)
        }
    }

    /// "mossad-profile:<base64url JSON>".
    public var text: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return "\(Self.scheme):\(((try? encoder.encode(self)) ?? Data()).base64URL)"
    }

    public var connection: ServerConnection? {
        guard sync == SyncChoice.server.rawValue, let address, let secret else { return nil }
        return ServerConnection(address: address, secret: secret)
    }

    public var holdsSecret: Bool { secret != nil }

    /// What goes in the profile's settings on the phone. Never the secret: that goes to the Keychain.
    public var settings: [String: String] {
        var out = ["syncWith": sync]
        if let address, sync == SyncChoice.server.rawValue { out["serverAddress"] = address.absoluteString }
        return out
    }

    /// Never the secret, in a log line or a debugger.
    public var description: String { "ProfileCode(\(id))" }
    public var debugDescription: String { description }

    public enum Parsed: Equatable, Sendable {
        case profile(ProfileCode), server(ServerConnection), newer, damaged, notMossad

        public var problem: String? {
            switch self {
            case .newer: "This code is from a newer Mossad. Update Mossad on this iPhone, then scan it again."
            case .damaged: "That code could not be read. Show the code on your Mac again."
            case .notMossad: "That code isn't from Mossad. Show the code on your Mac again."
            case .profile, .server: nil
            }
        }
    }

    private struct Versioned: Decodable { var version: Int }

    /// Either scheme. The version is read before anything else, so a newer code is refused in its own words.
    public static func parse(_ text: String) -> Parsed {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix(ServerPairing.scheme + ":") {
            return ServerPairing.connection(fromCode: t).map(Parsed.server) ?? .damaged
        }
        guard t.hasPrefix(scheme + ":") else { return .notMossad }
        var b = String(t.dropFirst(scheme.count + 1)).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        guard let data = Data(base64Encoded: b), let versioned = try? JSONDecoder().decode(Versioned.self, from: data) else { return .damaged }
        guard versioned.version <= currentVersion else { return .newer }
        guard var code = try? JSONDecoder().decode(ProfileCode.self, from: data),
              code.id == Profile.defaultID || ProfileRegistry.isID(code.id) else { return .damaged }
        let name = code.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return .damaged }
        code.name = String(name.prefix(ProfileRules.nameLimit))
        switch code.sync {
        case SyncChoice.icloud.rawValue:
            code.address = nil
            code.secret = nil
        case SyncChoice.server.rawValue:
            guard let address = code.address, let checked = ServerConnection.address(from: address.absoluteString),
                  let secret = code.secret, !secret.isEmpty else { return .damaged }
            code.address = checked
        default:
            return .damaged
        }
        return .profile(code)
    }

    /// Starts with either scheme and a colon.
    public static func isCode(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.hasPrefix(scheme + ":") || t.hasPrefix(ServerPairing.scheme + ":")
    }

    /// The Mac's pairing card: today's server code for the first profile, so an old phone still pairs; a profile
    /// code for another, so the first profile of a phone never gets another profile's server.
    public static func pairingText(profile: Profile, connection: ServerConnection) -> String {
        guard !profile.isDefault, let code = make(profile: profile, sync: .server, server: connection) else {
            return ServerPairing.code(for: connection)
        }
        return code.text
    }
}
