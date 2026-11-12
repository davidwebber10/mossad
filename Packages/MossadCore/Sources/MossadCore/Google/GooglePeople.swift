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

/// One person as the directory or the owner's contacts give them. Only what Mossad keeps: the addresses are the key.
public struct GoogleProfile: Codable, Equatable, Sendable {
    public enum Source: String, Codable, Sendable { case directory, contacts }

    /// Lowercase.
    public var emails: [String]
    public var name: String?
    public var jobTitle: String?
    public var department: String?
    /// The person's own photo; nil for Google's default picture.
    public var photoURL: URL?
    public var source: Source

    public init(emails: [String], name: String?, jobTitle: String? = nil, department: String? = nil, photoURL: URL? = nil, source: Source) {
        self.emails = emails.map(EmailIdentity.normalized).filter { $0.contains("@") }
        self.name = name?.trimmingCharacters(in: .whitespacesAndNewlines).nonBlank
        self.jobTitle = jobTitle?.trimmingCharacters(in: .whitespacesAndNewlines).nonBlank
        self.department = department?.trimmingCharacters(in: .whitespacesAndNewlines).nonBlank
        self.photoURL = photoURL
        self.source = source
    }
}

extension GooglePeopleAPI {
    public struct Page: Equatable, Sendable {
        public var profiles: [GoogleProfile]
        public var nextPageToken: String?
    }

    private struct Answer: Decodable {
        struct Meta: Decodable { var primary: Bool? }
        struct Name: Decodable {
            var displayName: String?
            var metadata: Meta?
        }
        struct Email: Decodable { var value: String? }
        struct Org: Decodable {
            var title: String?
            var department: String?
            var metadata: Meta?
        }
        struct Photo: Decodable {
            var url: String?
            var `default`: Bool?
            var metadata: Meta?
        }
        struct Entry: Decodable {
            var names: [Name]?
            var emailAddresses: [Email]?
            var organizations: [Org]?
            var photos: [Photo]?
        }

        var people: [Entry]?
        var connections: [Entry]?
        var nextPageToken: String?
    }

    public static func page(_ data: Data, source: GoogleProfile.Source) throws -> Page {
        guard let a = try? JSONDecoder().decode(Answer.self, from: data) else { throw GoogleError.unexpectedAnswer }
        let entries = (a.people ?? []) + (a.connections ?? [])
        let profiles = entries.compactMap { e -> GoogleProfile? in
            let name = (e.names?.first { $0.metadata?.primary == true } ?? e.names?.first)?.displayName
            let org = e.organizations?.first { $0.metadata?.primary == true } ?? e.organizations?.first
            let photo = (e.photos ?? []).first { $0.default != true && $0.url != nil }
            let p = GoogleProfile(emails: (e.emailAddresses ?? []).compactMap(\.value), name: name, jobTitle: org?.title, department: org?.department,
                                  photoURL: photo?.url.flatMap(URL.init(string:)), source: source)
            return p.emails.isEmpty ? nil : p
        }
        return Page(profiles: profiles, nextPageToken: a.nextPageToken)
    }

    /// At most this many pages of 1,000 for one read.
    static let maxPages = 20

    /// Each part that the sign-in gives and the owner has on, read to its end. A part that failed or stopped at the
    /// page limit is not in the answer: its old copy stays, and nothing is made from a part of a list.
    public static func fetch(session: GoogleSession) async -> [GoogleProfile.Source: [GoogleProfile]] {
        var out: [GoogleProfile.Source: [GoogleProfile]] = [:]
        for (scope, source) in [(GoogleScope.directory, GoogleProfile.Source.directory), (.contacts, .contacts)] where session.has(scope) {
            var token: String?, all: [GoogleProfile] = [], done = false
            do {
                for _ in 0..<maxPages {
                    let url = source == .directory ? directoryURL(pageToken: token) : contactsURL(pageToken: token)
                    let p = try page(try await session.get(url, scope: scope), source: source)
                    all += p.profiles
                    token = p.nextPageToken
                    if token == nil { done = true; break }
                }
                if done { out[source] = all } else { Log.error("Google People: the \(source.rawValue) read stopped at \(maxPages) pages") }
            } catch {
                Log.error("Google People: the \(source.rawValue) read failed (\(GoogleError.from(error).logText))")
            }
        }
        return out
    }
}

/// The profiles of the last read, on this Mac only (`People/google-directory.json`): it never syncs. It names an
/// invitee whom the calendar gave only as an address.
public struct GoogleDirectoryCache: Codable, Equatable, Sendable {
    public var profiles: [GoogleProfile]
    public var read: Date

    /// Keeps only what the cache is for: the addresses and the name of each profile.
    public init(profiles: [GoogleProfile], read: Date) {
        self.profiles = profiles.map { GoogleProfile(emails: $0.emails, name: $0.name, source: $0.source) }
        self.read = read
    }

    /// The new read for each part that was read; the old copy for a part that was not.
    public func replacing(_ fresh: [GoogleProfile.Source: [GoogleProfile]], read: Date) -> GoogleDirectoryCache {
        let kept = profiles.filter { fresh[$0.source] == nil }
        return GoogleDirectoryCache(profiles: kept + fresh.values.flatMap { $0 }, read: read)
    }

    public static func remove(_ paths: Paths) { try? FileManager.default.removeItem(at: url(paths)) }

    public static func url(_ paths: Paths) -> URL { paths.people.appendingPathComponent("google-directory.json") }

    public static func load(_ paths: Paths) -> GoogleDirectoryCache? {
        guard let data = try? Data(contentsOf: url(paths)) else { return nil }
        return try? JSONDecoder.callRecord.decode(GoogleDirectoryCache.self, from: data)
    }

    public func save(_ paths: Paths) throws {
        try FileManager.default.createDirectory(at: paths.people, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(self).write(to: Self.url(paths), options: .atomic)
    }

    /// The name for each address that one profile has; an address in two profiles with two names has none.
    public var names: [String: String] {
        var out: [String: String?] = [:]
        for p in DirectoryMerge.ordered(profiles) {
            guard let name = p.name else { continue }
            for e in p.emails {
                if let known = out[e] { if known != name && p.source == .directory { out[e] = .some(nil) } } else { out[e] = name }
            }
        }
        return out.compactMapValues { $0 }
    }
}
