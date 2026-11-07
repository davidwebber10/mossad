import Foundation

/// What the owner reads when something fails: a short title, one calm sentence about what happens next or what to
/// do, and whether to show it at all. The raw error stays in `technical`, for the Log and the Details disclosure.
public struct FriendlyError: Equatable, Sendable {
    /// What Mossad was doing. It decides who retries (Mossad on its own, or the owner) and where a fix lives.
    public enum Context: String, Sendable, CaseIterable {
        case syncing, uploadingAudio, transcribing, identifying, summarizing, coaching, recording, sendingEmail, chatting
        case importingOrgChart, checkingUpdates, connectingServer, sharing, general

        /// Steps Mossad runs again by itself: the pipeline, sync, and the iPhone's outbox.
        public var retriesItself: Bool {
            switch self {
            case .syncing, .uploadingAudio, .transcribing, .identifying, .summarizing: true
            default: false
            }
        }

        var defaultService: String {
            switch self {
            case .transcribing: "the transcription service"
            case .identifying, .summarizing, .coaching, .chatting: "the AI service"
            case .sendingEmail: "the mail service"
            case .checkingUpdates: "the update server"
            case .syncing, .uploadingAudio, .connectingServer, .sharing: "your server"
            case .recording, .importingOrgChart, .general: "the service"
            }
        }

        /// The title when nothing more specific fits.
        var fallbackTitle: String {
            switch self {
            case .syncing: "Sync didn't finish"
            case .uploadingAudio: "The recording didn't upload"
            case .transcribing: "Transcription didn't finish"
            case .identifying: "Mossad couldn't name the speakers"
            case .summarizing: "The summary didn't finish"
            case .coaching: "The coach couldn't finish"
            case .recording: "Recording couldn't start"
            case .sendingEmail: "The email didn't send"
            case .chatting: "Mossad couldn't answer"
            case .importingOrgChart: "Mossad couldn't import the org chart"
            case .checkingUpdates: "Mossad couldn't check for updates"
            case .connectingServer: "Mossad couldn't connect to your server"
            case .sharing: "The share link didn't update"
            case .general: "That didn't work"
            }
        }
    }

    public enum Visibility: Sendable, Equatable {
        /// The app stopped its own request.
        case never
        /// A drop Mossad retries quietly: only worth a word when it happens again.
        case whenRepeated
        case always
    }

    public enum Kind: String, Sendable {
        case cancelled, offline, unreachable, timedOut, serverTrouble, busy, rateLimited
        case unauthorized, wrongSecret, missingKey, billing, rejected, tooLarge, refused, unreadable, transcriptionFailed
        case notMossad, notConnected, microphoneBusy, microphoneDenied, recordingFailed, diskFull, fileMissing, notSignedIn, iCloudFull
        case badFile, tooManySteps, other

        var isTransient: Bool {
            [.offline, .unreachable, .timedOut, .serverTrouble, .busy, .rateLimited].contains(self)
        }
    }

    public let kind: Kind
    public let context: Context
    public let title: String
    public let message: String
    /// Whether trying again as it is can work. A wrong key or a refused request needs a change first.
    public let canRetry: Bool
    public let visibility: Visibility
    /// The error as the code saw it, cleaned of markup and trimmed, for the Log and Details.
    public let technical: String

    /// Recording problems use the recording color; everything else uses the accent.
    public var isAboutRecording: Bool {
        context == .recording || [.microphoneBusy, .microphoneDenied, .recordingFailed].contains(kind)
    }

    public func shouldShow(failures: Int) -> Bool {
        switch visibility {
        case .never: false
        case .whenRepeated: failures >= 2
        case .always: true
        }
    }

    // MARK: Making one

    /// `service` names who did not answer ("your server", "iCloud") when the error itself does not say.
    /// `retries` says whether Mossad runs it again by itself, when that differs from the context's habit (a call
    /// whose attempts ran out does not).
    public init(_ error: Error, context: Context, service: String? = nil, nextAttempt: Date? = nil, retries: Bool? = nil,
                technical: String? = nil) {
        let c = Self.classify(error)
        self.init(kind: c.kind, context: context, service: c.service ?? service, said: c.said, nextAttempt: nextAttempt, retries: retries,
                  technical: technical ?? Self.clean(String(describing: error)))
    }

    /// From a reason saved as text, such as `CallRecord.failureReason`, old or new.
    public init(reason: String, context: Context, service: String? = nil, nextAttempt: Date? = nil, retries: Bool? = nil) {
        let c = Self.classify(text: reason)
        self.init(kind: c.kind, context: context, service: c.service ?? service, said: c.said, nextAttempt: nextAttempt, retries: retries,
                  technical: Self.clean(reason))
    }

    public init(kind: Kind, context: Context, service: String? = nil, said: String? = nil, nextAttempt: Date? = nil, retries: Bool? = nil,
                technical: String = "") {
        self.kind = kind
        self.context = context
        self.technical = technical
        let auto = retries ?? context.retriesItself
        let wording = Self.words(kind: kind, context: context, auto: auto, service: service ?? context.defaultService, said: said,
                                 nextAttempt: nextAttempt)
        title = wording.title
        message = wording.message
        canRetry = wording.canRetry
        visibility = kind == .cancelled ? .never : kind.isTransient && auto ? .whenRepeated : .always
    }

    // MARK: Wording

    private static func words(kind: Kind, context: Context, auto: Bool, service s: String, said: String?, nextAttempt: Date?)
        -> (title: String, message: String, canRetry: Bool) {
        let S = capitalized(s)
        let again = auto ? (nextAttempt.map { "Mossad tries again at \($0.formatted(date: .omitted, time: .shortened))." } ?? "Mossad tries again on its own.")
                         : "Try again in a moment."
        let later = auto ? again : "Try again in a few minutes."
        let isServer = s.lowercased() == "your server"
        // "the AI service" is a description, not a name: "the API key", not "the the AI service key".
        let named = !(s.hasPrefix("the ") || s.hasPrefix("your "))
        let key = named ? "\(s) key" : "API key"
        switch kind {
        case .cancelled: return ("Stopped", "", true)
        case .offline:
            return ("You're offline", auto ? "Mossad tries again when you're back online." : "Check your connection, then try again.", true)
        case .unreachable:
            return ("\(S) didn't answer", auto ? again : isServer ? "Check the address, and that the server is running." : "Check your connection, then try again.", true)
        case .timedOut: return ("\(S) took too long to answer", later, true)
        case .serverTrouble: return ("\(S) is having trouble", said ?? later, true)
        case .busy: return ("\(S) is busy right now", later, true)
        case .rateLimited: return ("\(S) asked Mossad to slow down", auto ? again : "Wait a minute, then try again.", true)
        case .unauthorized where isServer, .wrongSecret:
            return ("Your server didn't accept the secret",
                    context == .connectingServer ? "Copy the secret again from your Mac, then try again." : "Connect the server again in \(syncSettings).", false)
        case .unauthorized: return ("\(S) didn't accept the API key", "Check the \(key) in \(keySettings(context)).", false)
        case .missingKey: return ("Mossad needs your \(key)", "Add the key in \(keySettings(context)), then retry.", false)
        case .billing:
            return (named ? "Your \(s) account needs attention" : "Your AI account needs attention",
                    "Check the plan and credit on the account, then retry.", false)
        case .rejected: return ("\(S) couldn't take this request", said ?? "Open Details to see what it said.", false)
        case .tooLarge:
            return (context == .transcribing || context == .uploadingAudio ? "This recording is too large for \(s)" : "This is too large for \(s)",
                    context == .transcribing ? "Choose another transcription service in \(aiSettings), then retry." : said ?? "Try something smaller.", false)
        case .refused: return ("\(S) declined this request", "Try again, or choose another model in \(aiSettings).", true)
        case .unreadable:
            return (context == .syncing && !isServer || s == "the service" ? "Mossad couldn't read the data" : "\(S) sent a reply Mossad couldn't read", again, true)
        case .transcriptionFailed:
            return ("\(S) couldn't transcribe this audio", said ?? "The audio is saved. Retry, or choose another service in \(aiSettings).", true)
        case .notMossad: return ("That address isn't a Mossad server", "Check the address, then try again.", false)
        case .notConnected: return ("Your server isn't connected", "Connect it in \(syncSettings).", false)
        case .microphoneBusy: return ("Another app is using the microphone", "End the call or recording there, then try again.", true)
        case .microphoneDenied: return ("Mossad can't use the microphone", "Allow it in \(micSettings), then try again.", false)
        case .recordingFailed: return ("Recording couldn't start", "Try again in a moment. The microphone may be busy.", true)
        case .diskFull: return (isPhone ? "This iPhone is full" : "Your disk is full", "Free some space, then try again.", false)
        case .fileMissing: return ("Mossad couldn't find the file", "Choose the file again.", false)
        case .notSignedIn: return ("You're not signed in to iCloud", "Sign in to iCloud in Settings, and Mossad syncs again.", false)
        case .iCloudFull: return ("Your iCloud storage is full", "Free some iCloud storage, and Mossad syncs again.", false)
        case .badFile:
            return ("This file isn't an org chart Mossad can read",
                    "It needs the columns Last Name, First Name, Position Title, and Supervisor.", false)
        case .tooManySteps: return ("Mossad couldn't find an answer", "Try a narrower question.", true)
        case .other: return (context.fallbackTitle, auto ? again : said ?? again, true)
        }
    }

    private static var isPhone: Bool {
        #if os(iOS)
        true
        #else
        false
        #endif
    }

    private static var aiSettings: String { isPhone ? "Mossad on your Mac, in Settings › AI" : "Settings › AI" }
    private static var syncSettings: String { isPhone ? "Settings" : "Settings › Sync & Server" }
    private static var micSettings: String { isPhone ? "Settings › Privacy & Security › Microphone" : "System Settings › Privacy & Security › Microphone" }
    private static func keySettings(_ context: Context) -> String {
        context == .sendingEmail ? (isPhone ? "Mossad on your Mac, in Settings › Coach" : "Settings › Coach") : aiSettings
    }

    /// "your server" opens a sentence as "Your server"; "iCloud" stays as it is.
    static func capitalized(_ s: String) -> String {
        guard let first = s.first, first.isLowercase else { return s }
        if s.dropFirst().first?.isUppercase == true { return s }
        return first.uppercased() + s.dropFirst()
    }

    // MARK: Reading errors

    private struct Classified {
        var kind: Kind
        var service: String?
        var said: String?
    }

    private static func classify(_ error: Error) -> Classified {
        switch error {
        case is CancellationError: return .init(kind: .cancelled)
        case let e as MissingAPIKey: return .init(kind: .missingKey, service: e.service)
        case TranscriptionError.http(let code, let body): return http(code, body, service: "AssemblyAI")
        case TranscriptionError.failed(let message): return .init(kind: .transcriptionFailed, service: "AssemblyAI", said: humane(message))
        case ProviderError.http(let p, let code, let body): return http(code, body, service: p)
        case ProviderError.failed(let p, let message): return failed(message, service: p)
        case SummaryError.http(let code, let body): return http(code, body, service: "Anthropic")
        case SummaryError.refused: return .init(kind: .refused, service: "Anthropic")
        case SummaryError.malformed: return .init(kind: .unreadable, service: "the AI service")
        case MailError.http(let code, let body): return http(code, body, service: "Resend")
        case ChatError.tooManySteps: return .init(kind: .tooManySteps)
        case ServerError.notMossad: return .init(kind: .notMossad)
        case ServerError.wrongSecret: return .init(kind: .wrongSecret, service: "your server")
        case ServerError.http(let code, let message):
            if code == 0 { return .init(kind: .other, said: humane(message)) }
            if code == 200 { return .init(kind: .unreadable, service: "your server") }
            return http(code, message, service: "your server")
        case OrgChart.ParseError.missingColumns: return .init(kind: .badFile)
        case is DecodingError, is EncodingError: return .init(kind: .unreadable)
        case let e as URLError: return url(e.code.rawValue)
        default: break
        }
        #if os(macOS)
        if error is CaptureError { return .init(kind: .recordingFailed) }
        #endif
        let ns = error as NSError
        let top = classify(ns: ns)
        // A wrapper's own code is often generic ("the operation failed"); the error inside says what happened.
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError, let inner = classify(ns: underlying),
           top == nil || top?.kind == .recordingFailed || top?.kind == .unreachable {
            return inner
        }
        if let top { return top }
        if let described = (error as? LocalizedError)?.errorDescription, let said = humane(described) {
            return .init(kind: .other, said: said)
        }
        return .init(kind: .other)
    }

    private static func classify(ns: NSError) -> Classified? {
        switch ns.domain {
        case NSURLErrorDomain: return url(ns.code)
        case "CKErrorDomain":
            switch ns.code {
            case 3, 4: return .init(kind: .offline)
            case 6, 15: return .init(kind: .serverTrouble, service: "iCloud")
            case 7, 23: return .init(kind: .rateLimited, service: "iCloud")
            case 9: return .init(kind: .notSignedIn)
            case 20: return .init(kind: .cancelled)
            case 25: return .init(kind: .iCloudFull)
            default: return nil
            }
        case NSOSStatusErrorDomain, "com.apple.coreaudio.avfaudio", "AVFoundationErrorDomain":
            return osStatus(ns.code)
        case NSCocoaErrorDomain:
            switch ns.code {
            case NSFileNoSuchFileError, NSFileReadNoSuchFileError: return .init(kind: .fileMissing)
            case NSFileWriteOutOfSpaceError: return .init(kind: .diskFull)
            case NSPropertyListReadCorruptError, NSCoderReadCorruptError, NSCoderValueNotFoundError: return .init(kind: .unreadable)
            case NSUserCancelledError: return .init(kind: .cancelled)
            default: return nil
            }
        case NSPOSIXErrorDomain:
            switch ns.code {
            case Int(ENOSPC): return .init(kind: .diskFull)
            case Int(ECANCELED): return .init(kind: .cancelled)
            case Int(ETIMEDOUT): return .init(kind: .timedOut)
            case Int(ENETDOWN), Int(ENETUNREACH): return .init(kind: .offline)
            default: return nil
            }
        default: return nil
        }
    }

    private static func url(_ code: Int) -> Classified {
        switch URLError.Code(rawValue: code) {
        case .cancelled: .init(kind: .cancelled)
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff, .callIsActive:
            .init(kind: .offline)
        case .timedOut: .init(kind: .timedOut)
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .secureConnectionFailed, .serverCertificateUntrusted,
             .serverCertificateHasBadDate, .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot, .cannotLoadFromNetwork:
            .init(kind: .unreachable)
        case .badServerResponse, .cannotParseResponse, .cannotDecodeContentData, .cannotDecodeRawData, .zeroByteResource:
            .init(kind: .unreadable)
        case .userAuthenticationRequired: .init(kind: .unauthorized)
        case .fileDoesNotExist, .noPermissionsToReadFile: .init(kind: .fileMissing)
        default: .init(kind: .unreachable)
        }
    }

    /// AVAudioSession and Core Audio codes are four-character codes; the common ones mean the mic is taken.
    private static func osStatus(_ code: Int) -> Classified {
        switch code {
        case 561_017_449, 560_030_580, 1_936_290_409, 561_145_187: .init(kind: .microphoneBusy)  // !pri, !act, siri, !rec
        case Int(ENOSPC): .init(kind: .diskFull)
        default: .init(kind: .recordingFailed)
        }
    }

    private static func http(_ code: Int, _ body: String, service: String) -> Classified {
        let said = providerMessage(body)
        let lower = body.lowercased()
        if lower.contains("credit balance") || lower.contains("insufficient_quota") || lower.contains("billing") || code == 402 {
            return .init(kind: .billing, service: service, said: said)
        }
        let kind: Kind = switch code {
        case 401, 403: .unauthorized
        case 408: .timedOut
        case 413: .tooLarge
        case 429: .rateLimited
        case 529: .busy
        case 500...599: .serverTrouble
        default: .rejected
        }
        // A server's own words help on a refusal; on an outage they are only a status line.
        return .init(kind: kind, service: service, said: kind == .rejected || kind == .tooLarge ? said : nil)
    }

    private static func failed(_ message: String, service: String) -> Classified {
        let lower = message.lowercased()
        if lower.contains("limit") || lower.contains("too large") { return .init(kind: .tooLarge, service: service) }
        if lower.contains("cut off") || lower.contains("not json") || lower.contains("no message") { return .init(kind: .unreadable, service: service) }
        return .init(kind: .other, service: service, said: humane(message))
    }

    /// Reads the reasons Mossad saves as text: `Pipeline.failureReason`'s short forms and error descriptions.
    private static func classify(text: String) -> Classified {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = t.lowercased()
        if lower == "cancelled" || lower == "canceled" || lower.contains("error -999") { return .init(kind: .cancelled) }
        if let m = t.firstMatch(of: /^(?<service>[A-Za-z][\w .]*?) (?:HTTP|error) (?<code>\d{3})(?::\s*(?<body>[\s\S]*))?$/), let code = Int(m.code) {
            let service = m.service == "Claude" ? "Anthropic" : String(m.service)
            return http(code, m.body.map(String.init) ?? "", service: service)
        }
        if let m = t.firstMatch(of: /^(?<service>.+) key missing$/) { return .init(kind: .missingKey, service: String(m.service)) }
        if lower == "invalid api key" { return .init(kind: .unauthorized) }
        if let m = t.firstMatch(of: /NSURLErrorDomain error (?<code>-?\d+)/), let code = Int(m.code) { return url(code) }
        if let m = t.firstMatch(of: /OSStatus error (?<code>-?\d+)/), let code = Int(m.code) { return osStatus(code) }
        if lower.contains("no network connection") || lower.contains("appears to be offline") || lower.contains("connection was lost") {
            return .init(kind: .offline)
        }
        if lower.contains("timed out") { return .init(kind: .timedOut) }
        if lower == "network error" || lower.contains("could not connect to the server") || lower.contains("hostname could not be found") {
            return .init(kind: .unreachable)
        }
        if let m = t.firstMatch(of: /^AssemblyAI (?:transcription failed: (?<said>.*)|could not transcribe the audio)$/) {
            return .init(kind: .transcriptionFailed, service: "AssemblyAI", said: m.said.flatMap { humane(String($0)) })
        }
        if lower.contains("refused") { return .init(kind: .refused) }
        if lower.contains("not the expected json") { return .init(kind: .unreadable) }
        if lower == "unexpected error" { return .init(kind: .other) }
        return .init(kind: .other, said: humane(t))
    }

    // MARK: Cleaning text

    /// A provider's own explanation from a JSON error body, when it reads like a sentence.
    public static func providerMessage(_ body: String) -> String? {
        if let data = body.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let error = object["error"] as? [String: Any]
            let detail = object["detail"] as? [String: Any]
            let candidates: [Any?] = [error?["message"], object["message"], object["error"], object["err_msg"], detail?["message"],
                                      object["detail"], object["error_description"], ((object["errors"] as? [[String: Any]])?.first)?["message"]]
            for case let text as String in candidates { if let h = humane(text) { return h } }
            return nil
        }
        // A body cut off at 500 bytes is not valid JSON any more; its message usually comes first.
        if let m = body.firstMatch(of: /"(?:message|err_msg|error)"\s*:\s*"(?<text>[^"]+)"/) { return humane(String(m.text)) }
        return humane(body)
    }

    /// The text as one plain sentence, or nil when it reads like code: markup, braces, ids, or status codes.
    static func humane(_ raw: String) -> String? {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["Error: ", "error: "] where t.hasPrefix(prefix) { t = String(t.dropFirst(prefix.count)) }
        guard (8...180).contains(t.count), t.split(separator: " ").count >= 3 else { return nil }
        if t.contains(where: { "{}<>[]\\|=".contains($0) }) { return nil }
        if t.range(of: #"\d{3,}|https?:|_[a-z]|[a-z]_|\.\w+\(|NSURL|OSStatus|Domain|couldn’t be completed|couldn't be completed"#,
                   options: .regularExpression) != nil { return nil }
        t = t.replacingOccurrences(of: "!", with: ".")
        t = capitalized(t)
        if let last = t.last, !".?".contains(last) { t += "." }
        return t
    }

    /// For Details and the Log: markup removed, whitespace collapsed, at most 600 characters.
    public static func clean(_ raw: String) -> String {
        var t = raw.replacingOccurrences(of: #"<(script|style)[\s\S]*?</\1>"#, with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        return t.count > 600 ? String(t.prefix(600)) + "…" : t
    }
}

extension FriendlyError.Context {
    public init(step: ProcessingStep) {
        switch step {
        case .transcribing: self = .transcribing
        case .identifying: self = .identifying
        case .summarizing, .writing: self = .summarizing
        }
    }
}

extension CallRecord {
    /// Why the last attempt failed, in the owner's words: Mossad still retrying while the call is in progress,
    /// the owner's turn once it has stopped.
    public var friendlyFailure: FriendlyError? {
        guard let reason = failureReason else { return nil }
        let stopped = status == .failed
        let step = ProcessingStep(status: status) ?? failedStep.flatMap { ProcessingStep(status: $0) }
        return FriendlyError(reason: reason, context: step.map(FriendlyError.Context.init(step:)) ?? .general,
                             nextAttempt: stopped ? nil : nextAttempt, retries: !stopped)
    }
}
