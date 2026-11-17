import Foundation

/// What the first request to the owner's server returned. A company network can stand between the Mac and a
/// correct address: its gateway answers with its own page or its own certificate. That is "blocked", which needs
/// another network, not another address. Only those signs say "blocked": anything unknown stays as before. A page
/// or a redirect proves a block only where the address already worked (`setupError`).
public enum BlockSign: String, Equatable, Sendable {
    case certificate, page, redirect
}

public enum HelloAnswer: Equatable, Sendable {
    case mossad
    /// Surely not the owner's server, and the look of a gateway: a page where JSON should be, a certificate the
    /// system does not trust, or a redirect to another host.
    case blocked(BlockSign)
    /// No answer at all: offline, a timeout, no such host.
    case noAnswer
    /// A server that answered, but not as Mossad.
    case notMossad

    public init(status: Int?, contentType: String?, body: Data, error: URLError.Code?, host: String, finalHost: String?) {
        if let error {
            self = [.serverCertificateUntrusted, .serverCertificateHasUnknownRoot].contains(error) ? .blocked(.certificate) : .noAnswer
            return
        }
        if let finalHost, Self.bare(finalHost) != Self.bare(host) {
            self = .blocked(.redirect)
            return
        }
        if status == 200, Self.isMossad(body) {
            self = .mossad
            return
        }
        if status == 200 || status == 403, Self.isPage(contentType: contentType, body: body) {
            self = .blocked(.page)
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
        // XML is what a storage host (S3, R2, CloudFront) refuses with: a server that is not Mossad, not a gateway.
        return start.hasPrefix("<") && !start.hasPrefix("<?xml")
    }

    /// The host without case and without a leading "www.": a redirect to the www form, or from http to https, is the
    /// same server.
    private static func bare(_ host: String) -> String {
        let h = host.lowercased()
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }

    /// The error the setup sheet shows for an address that is not yet known to be a Mossad server. A page or a
    /// redirect there is also what a wrong address gives, so only a certificate says "blocked", or any sign from the
    /// host of the server that is already connected (that address worked before). Every other answer from a server
    /// is "not a Mossad server"; no answer keeps its own words.
    public static func setupError(_ error: Error, typedHost: String?, connectedHost: String?) -> Error {
        if case ServerError.networkBlocked(_, let sign) = error {
            let known = typedHost.map(bare) != nil && typedHost.map(bare) == connectedHost.map(bare)
            return sign == .certificate || known ? error : ServerError.notMossad
        }
        return error is ServerError ? ServerError.notMossad : error
    }
}
