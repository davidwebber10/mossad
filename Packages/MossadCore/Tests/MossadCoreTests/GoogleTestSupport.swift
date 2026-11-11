import Foundation
@testable import MossadCore

/// The Keychain of a test: a dictionary.
final class MemorySecrets: GoogleSecrets, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [APIKey: String] = [:]

    func get(_ key: APIKey) -> String? { lock.withLock { values[key] } }
    func set(_ value: String, for key: APIKey) throws { lock.withLock { values[key] = value } }
    func delete(_ key: APIKey) { _ = lock.withLock { values.removeValue(forKey: key) } }
}

/// Answers each request from the test's table; no request leaves the test.
final class StubTransport: GoogleTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var answer: (URLRequest) -> (Int, Data)
    private(set) var requests: [URLRequest] = []

    init(_ answer: @escaping (URLRequest) -> (Int, Data)) { self.answer = answer }

    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let reply = lock.withLock {
            requests.append(request)
            return answer(request)
        }
        return (reply.1, reply.0)
    }

    var sent: [URLRequest] { lock.withLock { requests } }

    static func json(_ object: Any) -> Data { try! JSONSerialization.data(withJSONObject: object) }
}

extension URLRequest {
    var form: [String: String] {
        let text = String(decoding: httpBody ?? Data(), as: UTF8.self)
        var out: [String: String] = [:]
        for pair in text.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            out[kv[0]] = kv.count > 1 ? kv[1].removingPercentEncoding : ""
        }
        return out
    }

    func query(_ name: String) -> String? {
        URLComponents(url: url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
    }
}

/// A made-up client: not a real one.
let testClient = GoogleClient(id: "123-example.apps.googleusercontent.com", secret: "made-up-secret")
