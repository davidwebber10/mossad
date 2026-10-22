import CryptoKit
import Foundation

public enum MailProvider: String, CaseIterable, Sendable, Identifiable {
    case resend, postmark, sendgrid, mailgun, brevo, ses

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .resend: "Resend"
        case .postmark: "Postmark"
        case .sendgrid: "SendGrid"
        case .mailgun: "Mailgun"
        case .brevo: "Brevo"
        case .ses: "Amazon SES"
        }
    }
    public var key: APIKey {
        switch self {
        case .resend: .resend
        case .postmark: .postmark
        case .sendgrid: .sendgrid
        case .mailgun: .mailgun
        case .brevo: .brevo
        case .ses: .sesSecret
        }
    }
}

/// The settings a mailer needs besides its key. Every mailer sends to exactly one address.
public struct MailSettings: Sendable, Equatable {
    public var from: String
    /// Mailgun's sending domain.
    public var domain = ""
    /// Mailgun and SendGrid: the EU host instead of the US one.
    public var europe = false
    /// Amazon SES.
    public var region = "us-east-1"
    public var accessKeyID = ""

    public init(from: String, domain: String = "", europe: Bool = false, region: String = "us-east-1", accessKeyID: String = "") {
        self.from = from
        self.domain = domain
        self.europe = europe
        self.region = region
        self.accessKeyID = accessKeyID
    }

    public func mailer(_ provider: MailProvider, secret: String, session: URLSession = .shared) -> any Mailing {
        switch provider {
        case .resend: ResendMailer(apiKey: secret, from: from, session: session)
        case .postmark: HTTPMailer.postmark(token: secret, from: from, session: session)
        case .sendgrid: HTTPMailer.sendGrid(key: secret, from: from, europe: europe, session: session)
        case .mailgun: HTTPMailer.mailgun(key: secret, domain: domain, from: from, europe: europe, session: session)
        case .brevo: HTTPMailer.brevo(key: secret, from: from, session: session)
        case .ses: HTTPMailer.ses(accessKeyID: accessKeyID, secret: secret, region: region, from: from, session: session)
        }
    }
}

/// A mailer that is one HTTP request: each provider differs only in how it builds that request.
public struct HTTPMailer: Mailing {
    let name: String
    let session: URLSession
    let build: @Sendable (_ to: String, _ subject: String, _ html: String, _ text: String) throws -> URLRequest

    func request(to: String, subject: String, html: String, text: String) throws -> URLRequest {
        try build(to, subject, html, text)
    }

    public func send(to: String, subject: String, html: String, text: String) async throws {
        let (data, response) = try await session.data(for: request(to: to, subject: subject, html: html, text: text))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw ProviderError.http(name, status, data.snippet) }
    }

    private static func json(_ url: String, headers: [String: String], body: [String: Any]) throws -> URLRequest {
        var r = URLRequest(url: URL(string: url)!)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        r.httpBody = try JSONSerialization.data(withJSONObject: body)
        return r
    }

    static func postmark(token: String, from: String, session: URLSession) -> HTTPMailer {
        HTTPMailer(name: "Postmark", session: session) { to, subject, html, text in
            try json("https://api.postmarkapp.com/email", headers: ["X-Postmark-Server-Token": token],
                     body: ["From": from, "To": to, "Subject": subject, "HtmlBody": html, "TextBody": text, "MessageStream": "outbound"])
        }
    }

    static func sendGrid(key: String, from: String, europe: Bool, session: URLSession) -> HTTPMailer {
        HTTPMailer(name: "SendGrid", session: session) { to, subject, html, text in
            try json("https://\(europe ? "api.eu.sendgrid.com" : "api.sendgrid.com")/v3/mail/send", headers: ["Authorization": "Bearer \(key)"],
                     body: ["personalizations": [["to": [["email": to]]]], "from": ["email": from], "subject": subject,
                            "content": [["type": "text/plain", "value": text], ["type": "text/html", "value": html]]])
        }
    }

    static func mailgun(key: String, domain: String, from: String, europe: Bool, session: URLSession) -> HTTPMailer {
        HTTPMailer(name: "Mailgun", session: session) { to, subject, html, text in
            var r = URLRequest(url: URL(string: "https://\(europe ? "api.eu.mailgun.net" : "api.mailgun.net")/v3/\(domain)/messages")!)
            r.httpMethod = "POST"
            r.setValue("Basic \(Data("api:\(key)".utf8).base64EncodedString())", forHTTPHeaderField: "Authorization")
            r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            var form = URLComponents()
            form.queryItems = [("from", from), ("to", to), ("subject", subject), ("text", text), ("html", html)].map { URLQueryItem(name: $0.0, value: $0.1) }
            // A "+" in a form body means a space, so it must be encoded too.
            r.httpBody = Data((form.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
            return r
        }
    }

    static func brevo(key: String, from: String, session: URLSession) -> HTTPMailer {
        HTTPMailer(name: "Brevo", session: session) { to, subject, html, text in
            try json("https://api.brevo.com/v3/smtp/email", headers: ["api-key": key],
                     body: ["sender": ["email": from], "to": [["email": to]], "subject": subject, "htmlContent": html, "textContent": text])
        }
    }

    static func ses(accessKeyID: String, secret: String, region: String, from: String, session: URLSession) -> HTTPMailer {
        HTTPMailer(name: "Amazon SES", session: session) { to, subject, html, text in
            var r = try json("https://email.\(region).amazonaws.com/v2/email/outbound-emails", headers: [:], body: [
                "FromEmailAddress": from, "Destination": ["ToAddresses": [to]],
                "Content": ["Simple": ["Subject": ["Data": subject, "Charset": "UTF-8"],
                                       "Body": ["Html": ["Data": html, "Charset": "UTF-8"], "Text": ["Data": text, "Charset": "UTF-8"]]]],
            ])
            r.setValue(nil, forHTTPHeaderField: "Accept")
            SigV4.sign(&r, service: "ses", region: region, accessKeyID: accessKeyID, secret: secret)
            return r
        }
    }
}

/// AWS Signature Version 4 in the Authorization header, for JSON APIs such as SES.
enum SigV4 {
    static func sign(_ r: inout URLRequest, service: String, region: String, accessKeyID: String, secret: String, date: Date = Date()) {
        let stamp = S3Presigner.stamp(date), day = String(stamp.prefix(8))
        let host = r.url?.host ?? ""
        r.setValue(stamp, forHTTPHeaderField: "X-Amz-Date")
        var headers = ["host": host, "x-amz-date": stamp]
        if let type = r.value(forHTTPHeaderField: "Content-Type") { headers["content-type"] = type }
        let names = headers.keys.sorted()
        let payload = hex(SHA256.hash(data: r.httpBody ?? Data()))
        let path = r.url.map { $0.path.isEmpty ? "/" : $0.path.split(separator: "/", omittingEmptySubsequences: false).map { S3Presigner.encode(String($0)) }.joined(separator: "/") } ?? "/"
        let query = r.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems }?
            .map { "\(S3Presigner.encode($0.name))=\(S3Presigner.encode($0.value ?? ""))" }.sorted().joined(separator: "&") ?? ""
        let canonical = [r.httpMethod ?? "GET", path, query, names.map { "\($0):\(headers[$0]!.trimmingCharacters(in: .whitespaces))" }.joined(separator: "\n") + "\n",
                         names.joined(separator: ";"), payload].joined(separator: "\n")
        let scope = "\(day)/\(region)/\(service)/aws4_request"
        let toSign = ["AWS4-HMAC-SHA256", stamp, scope, hex(SHA256.hash(data: Data(canonical.utf8)))].joined(separator: "\n")
        var key = SymmetricKey(data: Data("AWS4\(secret)".utf8))
        for part in [day, region, service, "aws4_request"] { key = SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(for: Data(part.utf8), using: key))) }
        let signature = hex(HMAC<SHA256>.authenticationCode(for: Data(toSign.utf8), using: key))
        r.setValue("AWS4-HMAC-SHA256 Credential=\(accessKeyID)/\(scope), SignedHeaders=\(names.joined(separator: ";")), Signature=\(signature)",
                   forHTTPHeaderField: "Authorization")
    }

    private static func hex<D: Sequence>(_ bytes: D) -> String where D.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}
