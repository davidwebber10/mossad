import Foundation

public enum Platform: String, Codable, Sendable, CaseIterable {
    case zoom, meet, teams

    public var displayName: String {
        switch self {
        case .zoom: "Zoom"
        case .meet: "Google Meet"
        case .teams: "Microsoft Teams"
        }
    }
}

/// What kind of app a Core Audio process belongs to.
public enum AppKind: Equatable, Sendable {
    case zoomApp
    case teamsApp
    /// A browser, identified by its main bundle ID (helpers map to their browser).
    case browser(String)
}
