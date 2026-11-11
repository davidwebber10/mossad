import Foundation

/// Why a Google request failed, in the words the Google step shows. Read from Google's own error codes, never from
/// its free text, so a reply never reaches the screen or the log.
public enum GoogleError: Error, Equatable, Sendable, CustomStringConvertible {
    /// No client ID and secret saved yet.
    case noClient
    /// Never signed in, or signed out.
    case notConnected
    /// The owner pressed Cancel on Google's page.
    case denied
    /// The page that came back was not from this sign-in.
    case stateMismatch
    /// The client ID or the secret is wrong, or the client was deleted.
    case invalidClient
    /// The client is not of the type "Desktop app", so the loopback address is refused.
    case redirectMismatch
    /// The sign-in ran out or was revoked: sign in again.
    case expired
    /// An Internal app used with an account outside the organization, or a Workspace admin blocks the app.
    case orgBlocked
    /// The API is not turned on in the project.
    case apiDisabled(GoogleAPI?)
    /// The sign-in did not give this part: the owner unticked it on Google's page.
    case scopeMissing(GoogleScope?)
    /// The account cannot see this item, or the directory is closed to it.
    case forbidden
    case notFound
    case rateLimited
    /// No answer within the time.
    case timedOut
    /// No network.
    case offline
    case unexpectedAnswer
    case http(Int)

    public var description: String {
        switch self {
        case .noClient: "noClient"
        case .notConnected: "notConnected"
        case .denied: "denied"
        case .stateMismatch: "stateMismatch"
        case .invalidClient: "invalidClient"
        case .redirectMismatch: "redirectMismatch"
        case .expired: "expired"
        case .orgBlocked: "orgBlocked"
        case .apiDisabled(let api): "apiDisabled(\(api?.rawValue ?? "?"))"
        case .scopeMissing(let s): "scopeMissing(\(s?.rawValue ?? "?"))"
        case .forbidden: "forbidden"
        case .notFound: "notFound"
        case .rateLimited: "rateLimited"
        case .timedOut: "timedOut"
        case .offline: "offline"
        case .unexpectedAnswer: "unexpectedAnswer"
        case .http(let code): "http(\(code))"
        }
    }

    /// One short line.
    public var title: String {
        switch self {
        case .noClient: "Add your Google app first"
        case .notConnected: "Mossad is not connected to Google"
        case .denied: "You cancelled the sign-in"
        case .stateMismatch: "The sign-in did not come back to Mossad"
        case .invalidClient: "Google does not know this client"
        case .redirectMismatch: "The client is not a desktop app"
        case .expired: "The Google sign-in ran out"
        case .orgBlocked: "Your organization blocks this app"
        case .apiDisabled(let api): "\(api?.name ?? "An API") is off"
        case .scopeMissing(let scope): "Google did not give \(scope.map { "\"\($0.title)\"" } ?? "this permission")"
        case .forbidden: "Google refused the read"
        case .notFound: "Google did not find it"
        case .rateLimited: "Google asks Mossad to wait"
        case .timedOut: "Google did not answer in time"
        case .offline: "Mossad cannot reach Google"
        case .unexpectedAnswer: "Google sent an answer Mossad cannot read"
        case .http(let code): "Google answered with an error (\(code))"
        }
    }

    /// What to do, in one or two calm sentences.
    public var advice: String {
        switch self {
        case .noClient: "Paste the client ID and the client secret from step 5, then press Check."
        case .notConnected: "Press Check to sign in."
        case .denied: "Press Check again and choose Allow. If Google said that the app is in testing, add your account as a test user on the Audience page (step 3)."
        case .stateMismatch: "Close the browser tab and press Check again."
        case .invalidClient: "Copy the client ID and the client secret again from the Credentials page. Make sure that both come from the same client."
        case .redirectMismatch: "Make a new OAuth client of the type \"Desktop app\" (step 5) and paste its ID and secret."
        case .expired: "Press Check to sign in again. Mossad keeps working with your Mac's calendars meanwhile."
        case .orgBlocked: "With an Internal app, sign in with an account of your organization. Otherwise ask your Google Workspace admin to allow the app."
        case .apiDisabled(let api): "Open the \(api?.name ?? "API") page (step 2) and press Enable. Google can take a few minutes to start it."
        case .scopeMissing: "Press Check again and leave each box ticked on Google's page, or turn this part off here."
        case .forbidden: "Your account cannot read this. For the directory, your Workspace admin must share it with users."
        case .notFound: "The item is gone or not shared with this account."
        case .rateLimited: "Mossad tries again later by itself."
        case .timedOut: "Check the network and press Check again."
        case .offline: "Check the network and press Check again."
        case .unexpectedAnswer: "Press Check again. If it continues, look in the Log."
        case .http: "Press Check again later. If it continues, look in the Log."
        }
    }

    /// A short text for the log: the code only, never the reply.
    public var logText: String { description }

    /// Whether a later try can work without the owner.
    public var isTransient: Bool {
        switch self {
        case .rateLimited, .timedOut, .offline: true
        case .http(let code): code >= 500
        default: false
        }
    }

    /// The error of a failed request, from the status and Google's error codes.
    public static func from(status: Int, body: Data, scope: GoogleScope? = nil) -> GoogleError {
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        // The OAuth endpoints: {"error": "invalid_grant", "error_description": "..."}.
        if let code = json["error"] as? String, let known = oauth(code) { return known }
        // The APIs: {"error": {"code": 403, "status": "PERMISSION_DENIED", "errors": [{"reason": ...}], "details": [...]}}.
        let error = json["error"] as? [String: Any] ?? [:]
        let reasons = ((error["errors"] as? [[String: Any]]) ?? []).compactMap { $0["reason"] as? String }
            + ((error["details"] as? [[String: Any]]) ?? []).compactMap { $0["reason"] as? String }
        let apiStatus = error["status"] as? String
        if reasons.contains(where: { ["accessNotConfigured", "SERVICE_DISABLED"].contains($0) }) {
            let details = (error["details"] as? [[String: Any]]) ?? []
            let service = details.compactMap { ($0["metadata"] as? [String: Any])?["service"] as? String }.first
            return .apiDisabled(GoogleAPI.allCases.first { $0.host == service } ?? scope?.api)
        }
        if reasons.contains(where: { ["insufficientPermissions", "ACCESS_TOKEN_SCOPE_INSUFFICIENT"].contains($0) }) { return .scopeMissing(scope) }
        if reasons.contains(where: { ["rateLimitExceeded", "userRateLimitExceeded", "RATE_LIMIT_EXCEEDED"].contains($0) }) { return .rateLimited }
        switch status {
        case 401: return .expired
        case 403: return apiStatus == "RESOURCE_EXHAUSTED" ? .rateLimited : .forbidden
        case 404: return .notFound
        case 429: return .rateLimited
        case 400 where json["error"] as? String == "invalid_request": return .invalidClient
        default: return .http(status)
        }
    }

    /// An OAuth error code, from the token endpoint or from the browser's return. Nil for a code not known here.
    public static func oauth(_ code: String) -> GoogleError? {
        switch code {
        case "invalid_client", "unauthorized_client", "deleted_client": .invalidClient
        case "invalid_grant": .expired
        case "redirect_uri_mismatch": .redirectMismatch
        case "access_denied": .denied
        case "admin_policy_enforced", "org_internal": .orgBlocked
        default: nil
        }
    }

    /// A network error as one of these.
    public static func from(_ error: Error) -> GoogleError {
        if let g = error as? GoogleError { return g }
        let code = (error as? URLError)?.code
        switch code {
        case .timedOut?: return .timedOut
        case .notConnectedToInternet?, .networkConnectionLost?, .cannotFindHost?, .cannotConnectToHost?, .dnsLookupFailed?: return .offline
        default: return .unexpectedAnswer
        }
    }
}
