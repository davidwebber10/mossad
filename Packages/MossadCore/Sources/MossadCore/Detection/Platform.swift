import Foundation

public enum Platform: String, Codable, Sendable, CaseIterable {
    case zoom, meet, teams
    /// A meeting in a room, started by hand: the mic only, no call app.
    case inPerson
    /// A call recording that the owner shared to the iPhone app: one track with every voice.
    case phoneCall
    /// A platform of a newer build. The meeting still reads.
    case unknown

    /// The platforms a person can choose; `unknown` is none of them.
    public static let allCases: [Platform] = [.zoom, .meet, .teams, .inPerson, .phoneCall]

    /// A text this build does not know is `unknown`, so a meeting from a newer build is never left out.
    public init(from decoder: Decoder) throws {
        self = Platform(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }

    public var displayName: String {
        switch self {
        case .zoom: "Zoom"
        case .meet: "Google Meet"
        case .teams: "Microsoft Teams"
        case .inPerson: "In person"
        case .phoneCall: "Phone call"
        case .unknown: "Not known"
        }
    }

    /// One track holds every voice: a room recording or a phone call.
    public var isOneTrack: Bool { self == .inPerson || self == .phoneCall }

    /// The name of the mic track in the progress lines.
    public var micTrackName: String {
        switch self {
        case .inPerson: "the room audio"
        case .phoneCall: "the call recording"
        default: "your mic"
        }
    }

    /// The title of a meeting with no title.
    public var untitled: String {
        switch self {
        case .phoneCall: "Phone call"
        case .unknown: "Call"
        default: "\(displayName) call"
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
    /// A browser that can hold a call but whose tabs Mossad cannot read (Firefox, for example).
    case unreadableBrowser(String)
}
