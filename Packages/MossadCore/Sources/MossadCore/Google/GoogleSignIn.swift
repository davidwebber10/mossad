import Foundation
import Network

/// Waits on 127.0.0.1 for the one page that Google's consent screen sends back, as Google asks of desktop apps.
/// Only this Mac can reach it, and it closes after the first answer.
final class LoopbackReceiver: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "mossad.google.loopback")
    private var waiting: CheckedContinuation<GoogleCallback, Error>?
    /// A callback that came before anyone waited for it.
    private var early: GoogleCallback?
    private var done = false
    /// The sign-in's own state: an answer with another one is not this sign-in's, and the wait goes on.
    private let expected: String?
    /// The start answered once; the listener's later states change nothing.
    private var started = false

    init(state: String? = nil) throws {
        expected = state
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        parameters.acceptLocalOnly = true
        listener = try NWListener(using: parameters)
    }

    /// Starts listening and gives the address to send Google.
    func start() async throws -> URL {
        let port: UInt16 = try await withCheckedThrowingContinuation { c in
            listener.stateUpdateHandler = { [weak self, listener] state in
                guard let self, !self.started else { return }
                switch state {
                case .ready:
                    self.started = true
                    c.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error):
                    self.started = true
                    c.resume(throwing: error)
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] in self?.accept($0) }
            listener.start(queue: queue)
        }
        return URL(string: "http://127.0.0.1:\(port)")!
    }

    /// The first callback the browser brings, or an error after `timeout`.
    func callback(timeout: Duration) async throws -> GoogleCallback {
        // A Cancel in the app ends the wait at once.
        try await withTaskCancellationHandler {
            try await wait(timeout: timeout)
        } onCancel: {
            self.stop()
        }
    }

    private func wait(timeout: Duration) async throws -> GoogleCallback {
        try await withThrowingTaskGroup(of: GoogleCallback.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { c in
                    self.queue.async {
                        if let early = self.early {
                            self.early = nil
                            c.resume(returning: early)
                        } else if self.done { c.resume(throwing: CancellationError()) } else { self.waiting = c }
                    }
                }
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw GoogleError.timedOut
            }
            defer { group.cancelAll(); stop() }
            return try await group.next()!
        }
    }

    func stop() {
        queue.async {
            self.done = true
            self.listener.cancel()
            self.waiting?.resume(throwing: CancellationError())
            self.waiting = nil
        }
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            guard let self else { return connection.cancel() }
            let text = String(decoding: data ?? Data(), as: UTF8.self)
            let line = text.components(separatedBy: "\r\n").first ?? ""
            let callback = GoogleCallback.parse(requestLine: line)
            let body = Self.page(callback)
            let response = "HTTP/1.1 \(callback == nil ? "404 Not Found" : "200 OK")\r\nContent-Type: text/html; charset=utf-8\r\n"
                + "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            guard let callback else { return }
            if let expected = self.expected, callback.state != expected { return }
            guard let waiting = self.waiting else {
                if self.early == nil { self.early = callback }
                return
            }
            self.waiting = nil
            waiting.resume(returning: callback)
        }
    }

    /// The page the browser shows after Google: no script, no other site.
    static func page(_ callback: GoogleCallback?) -> String {
        let text = switch callback {
        case .code?: "Mossad is connected to Google. You can close this tab."
        case .error?: "The sign-in did not finish. You can close this tab and go back to Mossad."
        case nil: "Not found."
        }
        return "<!doctype html><meta charset=utf-8><title>Mossad</title><body style=\"font: 15px -apple-system; margin: 15vh auto; max-width: 28em; text-align: center\"><p>\(text)</p>"
    }
}

/// One sign-in: the consent page in the owner's own browser, the code back to the loopback address, and the trade
/// for tokens. The client and the tokens go to the Keychain only.
public enum GoogleSignIn {
    /// The owner has this long on Google's page.
    static let timeout: Duration = .seconds(300)

    public static func run(client: GoogleClient, scopes: Set<GoogleScope>, session: GoogleSession, transport: GoogleTransport = URLSessionTransport(),
                           loginHint: String? = nil, open: @escaping @Sendable (URL) async -> Void) async throws -> GoogleTokens {
        guard !client.id.isEmpty, !client.secret.isEmpty else { throw GoogleError.noClient }
        let pkce = PKCE.make(), state = PKCE.state()
        let receiver = try LoopbackReceiver(state: state)
        let redirect = try await receiver.start()
        await open(GoogleOAuth.authorizationURL(client: client, redirect: redirect, scopes: scopes, pkce: pkce, state: state, loginHint: loginHint))
        let answer: GoogleCallback
        do { answer = try await receiver.callback(timeout: timeout) } catch {
            receiver.stop()
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            throw GoogleError.from(error)
        }
        let code: String
        switch answer {
        case .error(let reason, _):
            throw GoogleError.oauth(reason) ?? .http(400)
        case .code(let c, let back):
            guard back == state else { throw GoogleError.stateMismatch }
            code = c
        }
        let data: Data, status: Int
        do { (data, status) = try await transport.send(GoogleOAuth.codeRequest(code: code, client: client, redirect: redirect, pkce: pkce)) } catch {
            throw GoogleError.from(error)
        }
        guard status == 200 else { throw GoogleError.from(status: status, body: data) }
        let tokens = try GoogleOAuth.tokens(from: data, now: Date())
        try await session.signedIn(tokens)
        return tokens
    }
}
