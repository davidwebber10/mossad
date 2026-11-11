import Foundation

/// People API, read-only: the company directory and the owner's own contacts. Pure: the address of a request and
/// the reading of an answer.
public enum GooglePeopleAPI {
    static let fields = "names,emailAddresses,organizations,photos"

    public static func directoryURL(pageSize: Int = 1000, pageToken: String? = nil) -> URL {
        var c = URLComponents(string: "https://people.googleapis.com/v1/people:listDirectoryPeople")!
        c.queryItems = [
            URLQueryItem(name: "readMask", value: fields),
            URLQueryItem(name: "sources", value: "DIRECTORY_SOURCE_TYPE_DOMAIN_PROFILE"),
            URLQueryItem(name: "pageSize", value: String(pageSize)),
        ] + (pageToken.map { [URLQueryItem(name: "pageToken", value: $0)] } ?? [])
        return c.url!
    }

    public static func contactsURL(pageSize: Int = 1000, pageToken: String? = nil) -> URL {
        var c = URLComponents(string: "https://people.googleapis.com/v1/people/me/connections")!
        c.queryItems = [
            URLQueryItem(name: "personFields", value: fields),
            URLQueryItem(name: "pageSize", value: String(pageSize)),
        ] + (pageToken.map { [URLQueryItem(name: "pageToken", value: $0)] } ?? [])
        return c.url!
    }
}
