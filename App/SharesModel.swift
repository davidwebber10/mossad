import Foundation
import MossadCore

/// What the Shares page knows from the server: every share with its numbers, and one share's days. The links
/// themselves are the controller's; this only adds what the server counts.
@MainActor
final class SharesModel: ObservableObject {
    enum Server: Equatable {
        case unknown
        case ok
        /// The Worker is from before the views and the PIN.
        case old
        /// The Worker is new, and its database was not updated.
        case needsMigration
        case unreachable(String)
    }

    @Published private(set) var remote: [ServerShare]?
    @Published private(set) var server = Server.unknown
    @Published private(set) var details: [String: ShareDetail] = [:]
    /// Made-up links for a picture of the page; nil in the real app.
    @Published private(set) var sampleLinks: [MeetingLink]?
    private var loading = false

    func load(_ controller: AppController) async {
        if let sample = ShareSample.kind {
            sampleLinks = sample == "empty" ? [] : ShareSample.links
            remote = sample == "sample" ? ShareSample.remote : nil
            server = sample == "old" ? .old : .ok
            if sample == "sample" { details = ShareSample.details }
            return
        }
        guard !loading, !ServerSample.isOn, let c = controller.serverConnection else { return }
        loading = true
        defer { loading = false }
        do {
            // The server says in its hello what it can do. It is asked again until it is current, so an update
            // of the server shows here without a new launch.
            if server != .ok, let hello = try? await ServerClient(c).hello(), hello.authorized, hello.shares != controller.serverShares {
                controller.serverShares = hello.shares
            }
            let list = try await ServerClient(c).shares()
            // An older server lists views and questions and nothing else; its rows still help.
            remote = list.shares
            server = list.needsMigration ? .needsMigration : (controller.serverHasShareNumbers ? .ok : .old)
        } catch {
            if remote == nil { server = .unreachable(FriendlyError(error, context: .sharing, service: "your server").message) }
        }
    }

    func loadDetail(_ id: String, _ controller: AppController) async {
        guard ShareSample.kind == nil, server == .ok, !ServerSample.isOn, let c = controller.serverConnection else { return }
        if let detail = try? await ServerClient(c).shareDetail(shareID: id) { details[id] = detail }
    }
}

/// Development hook for screenshots: `MOSSAD_SHARES=sample` in a preview shows made-up shares with their numbers,
/// `=old` the same links on a server from before the views, and `=empty` a server with no shares. Nothing is saved
/// and no call goes out.
enum ShareSample {
    static let kind: String? = CommandLine.arguments.contains("--ui-preview") ? ProcessInfo.processInfo.environment["MOSSAD_SHARES"] : nil

    private static let day: TimeInterval = 86_400
    private static let now = Date()

    private static func link(_ n: Int, _ title: String, created: Double, expires: Double?, days: Int?, pin: String? = nil, recording: Bool = false) -> MeetingLink {
        var l = MeetingLink(token: String(repeating: "\(n)", count: 43), callID: "sample-\(n)", title: title,
                            options: ShareOptions(summary: true, transcript: true, recording: recording, chat: false, days: days),
                            created: now.addingTimeInterval(created * day), expires: expires.map { now.addingTimeInterval($0 * day) })
        l.pin = pin
        return l
    }

    static let links: [MeetingLink] = [
        link(1, "Spring catalog launch review", created: -11, expires: 3.1, days: 14, pin: "4821", recording: true),
        link(2, "Dealer preview dry run", created: -2, expires: 5.0 / 24, days: 7),
        link(3, "Vendor contract terms", created: -6, expires: 24, days: 30, pin: "0739"),
        link(4, "First quarter budget review", created: -19, expires: nil, days: nil),
        link(5, "Holiday coverage plan", created: -40, expires: -10, days: 30),
    ]

    private static func share(_ l: MeetingLink, views: Int, viewers: Int, first: Double?, last: Double?, pin: Bool = false, locked: Bool = false, wrong: Int = 0,
                              gone: Bool = false) -> ServerShare {
        ServerShare(id: l.id, title: l.title, created: l.created, expires: l.expires, views: views, questions: 0, viewers: viewers,
                    firstView: first.map { now.addingTimeInterval($0 * day) }, lastView: last.map { now.addingTimeInterval($0 * day) },
                    pin: pin, pinLocked: locked, wrongPins: wrong, gone: gone)
    }

    static let remote: [ServerShare] = [
        share(links[0], views: 23, viewers: 7, first: -10.8, last: -2.0 / 24, pin: true, wrong: 2),
        share(links[1], views: 0, viewers: 0, first: nil, last: nil),
        share(links[2], views: 3, viewers: 2, first: -5, last: -4, pin: true, locked: true, wrong: 30),
        share(links[3], views: 41, viewers: 12, first: -18.5, last: -1.2),
        share(links[4], views: 6, viewers: 4, first: -39, last: -31, gone: true),
    ]

    static let details: [String: ShareDetail] = {
        var cal = Calendar.current
        cal.timeZone = .current
        let style = Date.ISO8601FormatStyle(timeZone: .current).year().month().day()
        let counts = [6, 5, 0, 2, 1, 0, 0, 3, 2, 1, 2, 1]
        let people = [3, 1, 0, 1, 0, 0, 0, 1, 1, 0, 0, 0]
        let days = counts.enumerated().compactMap { i, n -> ShareDetail.Day? in
            n == 0 ? nil : ShareDetail.Day(day: now.addingTimeInterval(Double(i - 11) * day).formatted(style), views: n, viewers: people[i])
        }
        return [links[0].id: ShareDetail(share: remote[0], days: days,
                                        countries: [.init(name: "US", count: 5), .init(name: "CA", count: 1), .init(name: "DE", count: 1)],
                                        devices: [.init(name: "computer", count: 4), .init(name: "phone", count: 2), .init(name: "other", count: 1)])]
    }()
}
