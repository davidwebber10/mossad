import Foundation

/// The MCP server of one profile: its name in an AI app and the commands the owner copies. The first profile keeps
/// today's `mossad` and `--mcp`, so an AI app set up before a second profile keeps working.
public struct MCPCommand: Equatable, Sendable {
    public let serverName: String
    public let arguments: [String]

    public init(profile: Profile, among profiles: [Profile]) {
        guard !profile.isDefault else {
            serverName = "mossad"
            arguments = ["--mcp"]
            return
        }
        let own = Self.word(profile)
        let shared = profiles.contains { !$0.isDefault && $0.id != profile.id && Self.word($0) == own }
        serverName = "mossad-" + (shared ? "\(own)-\(profile.id)" : own)
        arguments = ["--mcp", "--profile", profile.id]
    }

    /// The name's ASCII letters and digits in lower case, accents removed; the id when none is left.
    private static func word(_ profile: Profile) -> String {
        let folded = profile.name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        let kept = String(folded.lowercased().unicodeScalars.filter { ("a"..."z").contains($0) || ("0"..."9").contains($0) }.map(Character.init))
        return kept.isEmpty ? profile.id : kept
    }

    public func claudeCode(binary: String) -> String {
        "claude mcp add --scope user \(serverName) -- \"\(binary)\" " + arguments.joined(separator: " ")
    }

    public func desktop(binary: String) -> String {
        "\"\(serverName)\": { \"command\": \"\(binary)\", \"args\": [\(arguments.map { "\"\($0)\"" }.joined(separator: ", "))] }"
    }
}
