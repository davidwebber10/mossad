import Foundation

/// A browser tab. Outside the macOS-only probes because the meeting rules, which the iPhone app also builds, read it.
public struct BrowserTab: Equatable, Sendable {
    public var url: String
    public var title: String
    /// The selected tab of its window.
    public var isActive: Bool

    public init(url: String, title: String, isActive: Bool = false) {
        self.url = url
        self.title = title
        self.isActive = isActive
    }
}
