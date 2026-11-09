/// Keeps values read from disk or the Keychain until their version changes, so a view's body does not read
/// them each time it draws. Not thread-safe: use it from one actor.
public final class VersionedCache<Key: Hashable, Value> {
    private var version: Int?
    private var values: [Key: Value] = [:]

    public init() {}

    public func value(_ key: Key, version: Int, load: () -> Value) -> Value {
        if version != self.version {
            values = [:]
            self.version = version
        }
        if let value = values[key] { return value }
        let value = load()
        values[key] = value
        return value
    }

    /// Reads every value again at the next ask, for a change that has no version.
    public func forget() {
        values = [:]
    }
}
