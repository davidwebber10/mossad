import Foundation

/// What the first request to the owner's server returned. A company network can stand between the Mac and a
/// correct address: its gateway answers with its own page or its own certificate. That is "blocked", which needs
/// another network, not another address. Only those signs say "blocked": anything unknown stays as before.
public enum HelloAnswer: Equatable, Sendable {
    case mossad
    /// Surely not the owner's server, and the look of a gateway: a page where JSON should be, a certificate the
    /// system does not trust, or a redirect to another host.
    case blocked
    /// No answer at all: offline, a timeout, no such host.
    case noAnswer
    /// A server that answered, but not as Mossad.
    case notMossad

    public init(status: Int?, contentType: String?, body: Data, error: URLError.Code?, host: String, finalHost: String?) {
        if let error {
            self = [.serverCertificateUntrusted, .serverCertificateHasUnknownRoot].contains(error) ? .blocked : .noAnswer
            return
        }
        if let finalHost, finalHost.lowercased() != host.lowercased() {
            self = .blocked
            return
        }
        if status == 200, Self.isMossad(body) {
            self = .mossad
            return
        }
        if status == 200 || status == 403, Self.isPage(contentType: contentType, body: body) {
            self = .blocked
            return
        }
        self = .notMossad
    }

    static func isMossad(_ body: Data) -> Bool {
        (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["mossad"] as? Bool == true
    }

    private static func isPage(contentType: String?, body: Data) -> Bool {
        if contentType?.lowercased().contains("text/html") == true { return true }
        let start = String(decoding: body.prefix(64), as: UTF8.self).drop { $0.isWhitespace || $0 == "\u{FEFF}" }
        return start.hasPrefix("<")
    }
}
