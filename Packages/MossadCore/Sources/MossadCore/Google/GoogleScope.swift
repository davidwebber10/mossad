import Foundation

/// The read-only parts of Google that Mossad can ask for. The owner turns each one on or off in the Google step;
/// nothing else is ever asked for (no Gmail, no Drive).
public enum GoogleScope: String, CaseIterable, Codable, Sendable, Identifiable {
    /// Calendar events: the invites, their people and answers, the meeting link, and the attached notes.
    case calendar
    /// Google Docs: the "Notes by Gemini" document attached to an event.
    case docs
    /// The company directory: names, job titles, departments, and photos.
    case directory
    /// The owner's own contacts: names and photos.
    case contacts

    public var id: String { rawValue }

    /// The scope as Google names it.
    public var url: String {
        switch self {
        case .calendar: "https://www.googleapis.com/auth/calendar.events.readonly"
        case .docs: "https://www.googleapis.com/auth/documents.readonly"
        case .directory: "https://www.googleapis.com/auth/directory.readonly"
        case .contacts: "https://www.googleapis.com/auth/contacts.readonly"
        }
    }

    public var title: String {
        switch self {
        case .calendar: "Calendar events"
        case .docs: "Gemini notes"
        case .directory: "Company directory"
        case .contacts: "Your contacts"
        }
    }

    public var detail: String {
        switch self {
        case .calendar: "Reads your events: who is invited, who said yes, the meeting link, and the attached notes."
        case .docs: "Reads the \"Notes by Gemini\" document attached to an event, for meetings you did not record."
        case .directory: "Fills names, job titles, departments, and photos of people in your company."
        case .contacts: "Fills names and photos of people in your own contacts."
        }
    }

    /// The API to turn on in Google Cloud for this scope.
    public var api: GoogleAPI {
        switch self {
        case .calendar: .calendar
        case .docs: .docs
        case .directory, .contacts: .people
        }
    }

    /// The scopes that Google says a token has, from its space-separated list.
    public static func granted(_ list: String) -> Set<GoogleScope> {
        let urls = Set(list.split(separator: " ").map(String.init))
        return Set(allCases.filter { urls.contains($0.url) })
    }
}

/// An API to turn on in the owner's Google Cloud project.
public enum GoogleAPI: String, CaseIterable, Sendable {
    case calendar, docs, people

    public var name: String {
        switch self {
        case .calendar: "Google Calendar API"
        case .docs: "Google Docs API"
        case .people: "People API"
        }
    }

    /// The API's page in the console's library, where Enable is.
    public var library: URL {
        let id = switch self {
        case .calendar: "calendar-json.googleapis.com"
        case .docs: "docs.googleapis.com"
        case .people: "people.googleapis.com"
        }
        return URL(string: "https://console.cloud.google.com/apis/library/\(id)")!
    }

    /// The host the API answers on, to say which one a "not enabled" error is about.
    var host: String {
        switch self {
        case .calendar: "calendar-json.googleapis.com"
        case .docs: "docs.googleapis.com"
        case .people: "people.googleapis.com"
        }
    }
}
