import Foundation

/// The domains of the owner's company, as the owner listed them in Settings > General: one person can have an
/// address on each ("sam@acme.test" and "sam@acmeinc.test"). An address on a listed domain whose name before the @
/// is the same as a person's on another listed domain is that person, when exactly one person has that name.
public struct CompanyDomains: Sendable, Hashable {
    public let domains: [String]

    public static let none = CompanyDomains([])

    public init(_ list: [String]) {
        var seen: Set<String> = []
        domains = list.compactMap(Self.domain).filter { seen.insert($0).inserted }
    }

    /// What the owner typed: domains apart by commas, semicolons, spaces, or new lines. A word with no dot is left out.
    public static func parse(_ text: String) -> CompanyDomains {
        CompanyDomains(text.split(whereSeparator: { ",; \n\t".contains($0) }).map(String.init))
    }

    public var text: String { domains.joined(separator: ", ") }
    public var isEmpty: Bool { domains.isEmpty }

    /// Whether an address is on a listed domain.
    public func contains(_ address: String) -> Bool {
        Self.split(address).map { domains.contains($0.domain) } ?? false
    }

    /// "Sam.Carter@ACME.test" gives "sam.carter" and "acme.test".
    public static func split(_ address: String) -> (local: String, domain: String)? {
        let a = EmailIdentity.normalized(address)
        guard let at = a.lastIndex(of: "@") else { return nil }
        let local = String(a[..<at]), domain = String(a[a.index(after: at)...])
        guard !local.isEmpty, domain.contains(".") else { return nil }
        return (local, domain)
    }

    private static func domain(_ raw: String) -> String? {
        var d = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let at = d.lastIndex(of: "@") { d = String(d[d.index(after: at)...]) }
        guard d.contains("."), !d.hasPrefix("."), !d.hasSuffix("."), d.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }) else { return nil }
        return d
    }

    // MARK: Suggestions

    /// Mail services for anyone, and calendar rooms: never a company's own domain.
    static let publicDomains: Set<String> = ["gmail.com", "googlemail.com", "outlook.com", "hotmail.com", "live.com", "msn.com", "yahoo.com",
                                             "icloud.com", "me.com", "mac.com", "aol.com", "proton.me", "protonmail.com", "gmx.com"]

    /// The owner's own domains first, then the domains in the most invites (two at least), at most `limit`. Only a
    /// suggestion: nothing applies until the owner saves.
    public static func suggestions(ownerEmails: [String], invites: [[String]], limit: Int = 5) -> [String] {
        var out: [String] = []
        for e in ownerEmails { if let d = split(e)?.domain, !out.contains(d), !publicDomains.contains(d) { out.append(d) } }
        var counts: [String: Int] = [:]
        for invite in invites {
            for d in Set(invite.compactMap { split($0)?.domain }) where !publicDomains.contains(d) && !d.hasSuffix("calendar.google.com") {
                counts[d, default: 0] += 1
            }
        }
        let ranked = counts.filter { $0.value >= 2 && !out.contains($0.key) }.sorted { ($1.value, $0.key) < ($0.value, $1.key) }.map(\.key)
        return Array((out + ranked).prefix(limit))
    }

    // MARK: The saved list

    private static let lock = NSLock()
    nonisolated(unsafe) private static var saved = CompanyDomains.none

    /// The list the owner saved, for the resolvers that the app builds anywhere. The app sets it at launch and on save.
    public static var current: CompanyDomains {
        get { lock.withLock { saved } }
        set { lock.withLock { saved = newValue } }
    }
}
