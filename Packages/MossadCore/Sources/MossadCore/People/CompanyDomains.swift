import Foundation

/// The domains of the owner's company, as the owner listed them in Settings > General: one person can have an
/// address on each ("sam@acme.test" and "sam@acmeinc.test"). An address on a listed domain whose name before the @
/// is the same as a person's on another listed domain is that person, when exactly one person has that name.
public struct CompanyDomains: Sendable, Hashable {
    public let domains: [String]

    public static let none = CompanyDomains([])

    public init(_ list: [String]) {
        var seen: Set<String> = []
        // A mail service for anyone is never one company's: two people there share nothing.
        domains = list.compactMap(Self.domain).filter { !Self.publicDomains.contains($0) && seen.insert($0).inserted }
    }

    /// What the owner typed: domains apart by commas, semicolons, spaces, or new lines. A word with no dot is left out.
    public static func parse(_ text: String) -> CompanyDomains {
        CompanyDomains(text.split(whereSeparator: { ",; \n\t".contains($0) }).map(String.init))
    }

    public var text: String { domains.joined(separator: ", ") }

    /// The public mail domains in what the owner typed, which the list leaves out.
    public static func refused(in text: String) -> [String] {
        var seen: Set<String> = []
        return text.split(whereSeparator: { ",; \n\t".contains($0) }).compactMap { domain(String($0)) }
            .filter { publicDomains.contains($0) && seen.insert($0).inserted }
    }

    /// Words before the @ that name a role, a team, or a machine, never one person.
    static let roles: Set<String> = ["info", "sales", "team", "admin", "noreply", "no-reply", "donotreply", "do-not-reply", "support", "help",
                                     "hello", "contact", "office", "hr", "jobs", "careers", "billing", "accounts", "accounting", "finance",
                                     "marketing", "press", "media", "security", "it", "ops", "operations", "service", "customerservice",
                                     "orders", "invoices", "postmaster", "webmaster", "root", "mail", "notifications", "calendar", "reception"]

    /// Whether the name before the @ is a role's.
    public static func isRole(_ local: String) -> Bool { roles.contains(local.lowercased()) }
    public var isEmpty: Bool { domains.isEmpty }

    /// Whether an address is on a listed domain.
    public func contains(_ address: String) -> Bool {
        Self.split(address).map { domains.contains($0.domain) } ?? false
    }

    /// "Sam.Carter@ACME.test" gives "sam.carter" and "acme.test".
    public static func split(_ address: String) -> (local: String, domain: String)? {
        let a = EmailIdentity.normalized(address)
        guard a.filter({ $0 == "@" }).count == 1, !a.contains(where: \.isWhitespace), let at = a.lastIndex(of: "@") else { return nil }
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

    /// The owner's own domains first, then the other domains of the people who have an address on one of them (a
    /// second address the owner typed, or one from the directory), the most people first. Never a domain that is
    /// only in invites: a vendor in many invites is another company. Only a suggestion: nothing applies until the
    /// owner saves.
    public static func suggestions(ownerEmails: [String], people: [[String]], limit: Int = 5) -> [String] {
        var out: [String] = []
        for e in ownerEmails { if let d = split(e)?.domain, !out.contains(d), !publicDomains.contains(d) { out.append(d) } }
        let own = Set(out)
        var counts: [String: Int] = [:]
        for addresses in people {
            let ds = Set(addresses.compactMap { split($0)?.domain })
            guard !ds.isDisjoint(with: own) else { continue }
            for d in ds where !own.contains(d) && !publicDomains.contains(d) { counts[d, default: 0] += 1 }
        }
        let ranked = counts.sorted { ($1.value, $0.key) < ($0.value, $1.key) }.map(\.key)
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

    /// Where the Mac keeps the list.
    public static let defaultsKey = "companyDomains"

    /// Reads the saved list at the start of a process, before any resolver is made: the app, `--mcp`, and the
    /// command-line steps all use it.
    public static func loadSaved(_ defaults: UserDefaults = .standard) {
        current = parse(defaults.string(forKey: defaultsKey) ?? "")
    }
}
