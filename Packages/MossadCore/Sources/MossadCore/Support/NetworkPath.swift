import Foundation
import Network

/// What the system says about the network now. A constrained path is one the owner marked to save data (Low Data
/// Mode on a hotspot or a metered network): optional traffic, such as the live transcript's audio streams, stays off it.
public final class NetworkPath: @unchecked Sendable {
    public static let shared = NetworkPath()

    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var constrained = false
    private var expensive = false

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.lock.withLock {
                self.constrained = path.isConstrained
                self.expensive = path.isExpensive
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.dwebber.mossad.network-path", qos: .utility))
    }

    public var isConstrained: Bool { lock.withLock { constrained } }
    public var isExpensive: Bool { lock.withLock { expensive } }
}
