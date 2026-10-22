import Foundation

public enum Platform: String, Codable, Sendable, CaseIterable {
    case zoom, meet, teams
    /// A meeting in a room, started by hand: the mic only, no call app.
    case inPerson

    public var displayName: String {
        switch self {
        case .zoom: "Zoom"
        case .meet: "Google Meet"
        case .teams: "Microsoft Teams"
        case .inPerson: "In person"
        }
    }

    /// The call apps detection looks for; an in-person meeting is never detected.
    public static let callApps: [Platform] = [.zoom, .meet, .teams]
}

/// What kind of app a Core Audio process belongs to.
public enum AppKind: Equatable, Sendable {
    case zoomApp
    case teamsApp
    /// A browser, identified by its main bundle ID (helpers map to their browser).
    case browser(String)
}
