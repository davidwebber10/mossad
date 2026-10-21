import Foundation

/// Routes URLSession requests to a test handler.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Recorded {
        var method: String
        var url: URL
        var headers: [String: String]
        var body: Data
    }

    nonisolated(unsafe) static var handler: ((Recorded) -> (Int, Data))?
    nonisolated(unsafe) static var requests: [Recorded] = []

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        requests = []
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                body.append(buffer, count: n)
            }
            stream.close()
        }
        let recorded = Recorded(method: request.httpMethod ?? "GET", url: request.url!, headers: request.allHTTPHeaderFields ?? [:], body: body)
        Self.requests.append(recorded)
        let (status, data) = Self.handler?(recorded) ?? (404, Data())
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

func json(_ object: Any) -> Data { try! JSONSerialization.data(withJSONObject: object) }
