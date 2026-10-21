import CryptoKit
import Foundation

/// An S3-compatible bucket: Amazon S3, or Cloudflare R2 (path style, region "auto").
public struct S3Config: Sendable, Equatable {
    public var endpoint: URL
    public var bucket: String
    public var region: String
    public var accessKeyID: String
    public var secret: String
    public var pathStyle: Bool

    public init(endpoint: URL, bucket: String, region: String, accessKeyID: String, secret: String, pathStyle: Bool) {
        self.endpoint = endpoint
        self.bucket = bucket
        self.region = region
        self.accessKeyID = accessKeyID
        self.secret = secret
        self.pathStyle = pathStyle
    }
}

/// Signature Version 4 query signing. One signed URL per request (PUT, GET, DELETE) keeps the client small,
/// and a signed GET URL lets the player stream a recording without the secret.
public enum S3Presigner {
    public static func url(_ c: S3Config, method: String, key: String, date: Date = Date(), expires: Int = 900) -> URL {
        let host = c.pathStyle ? (c.endpoint.host ?? "") : "\(c.bucket).\(c.endpoint.host ?? "")"
        let segments = (c.pathStyle ? [c.bucket] : []) + key.split(separator: "/").map(String.init)
        let path = "/" + segments.map(encode).joined(separator: "/")
        let stamp = Self.stamp(date), day = String(stamp.prefix(8))
        let scope = "\(day)/\(c.region)/s3/aws4_request"
        let query = [
            ("X-Amz-Algorithm", "AWS4-HMAC-SHA256"),
            ("X-Amz-Credential", "\(c.accessKeyID)/\(scope)"),
            ("X-Amz-Date", stamp),
            ("X-Amz-Expires", String(expires)),
            ("X-Amz-SignedHeaders", "host"),
        ].map { "\(encode($0.0))=\(encode($0.1))" }.sorted().joined(separator: "&")
        let canonical = [method, path, query, "host:\(host)", "", "host", "UNSIGNED-PAYLOAD"].joined(separator: "\n")
        let toSign = ["AWS4-HMAC-SHA256", stamp, scope, hex(SHA256.hash(data: Data(canonical.utf8)))].joined(separator: "\n")
        var key = SymmetricKey(data: Data("AWS4\(c.secret)".utf8))
        for part in [day, c.region, "s3", "aws4_request"] { key = SymmetricKey(data: hmac(key, part)) }
        let signature = hex(hmac(key, toSign))
        let port = c.endpoint.port.map { ":\($0)" } ?? ""
        return URL(string: "\(c.endpoint.scheme ?? "https")://\(host)\(port)\(path)?\(query)&X-Amz-Signature=\(signature)")!
    }

    private static func hmac(_ key: SymmetricKey, _ text: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(text.utf8), using: key))
    }

    private static func hex<D: Sequence>(_ bytes: D) -> String where D.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// RFC 3986 unreserved characters stay; everything else is percent-encoded, as SigV4 requires.
    static func encode(_ s: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    static func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f.string(from: date)
    }
}
