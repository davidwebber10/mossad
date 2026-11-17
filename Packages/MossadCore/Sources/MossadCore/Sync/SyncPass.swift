import Foundation

/// One sync pass, as the window app's `syncNow` ran it off the main thread: the main store (push, pull without the
/// meetings, the shared records, the server's config, the phone's recording notices), then the server's copy while
/// iCloud syncs, then whether the digest arrived. The same calls in the same order, with the same log lines. It
/// touches no view; the caller reads the result.
public enum SyncPass {
    public struct Inputs: Sendable {
        public var main: CloudSync?
        public var mirror: CloudSync?
        public var serverIsMain: Bool
        public var place: String
        public var connection: ServerConnection?
        public var owner: String
        public var personasInMCP: Bool
        public var personas: SyncedPersonas?
        public var calling: Bool
        public var callStarted: @Sendable () -> Bool
        /// A digest a part of which did not arrive, sent again as it is (`DigestPlan.step` said resend).
        public var keptDigest: [SharedPayload]?
        /// Makes the digest; nil: no digest in this pass. Asked at most once.
        public var makeDigest: (@Sendable () -> [SharedPayload]?)?

        public init(main: CloudSync?, mirror: CloudSync?, serverIsMain: Bool, place: String, connection: ServerConnection?, owner: String,
                    personasInMCP: Bool, personas: SyncedPersonas?, calling: Bool, callStarted: @escaping @Sendable () -> Bool,
                    keptDigest: [SharedPayload]?, makeDigest: (@Sendable () -> [SharedPayload]?)?) {
            self.main = main
            self.mirror = mirror
            self.serverIsMain = serverIsMain
            self.place = place
            self.connection = connection
            self.owner = owner
            self.personasInMCP = personasInMCP
            self.personas = personas
            self.calling = calling
            self.callStarted = callStarted
            self.keptDigest = keptDigest
            self.makeDigest = makeDigest
        }
    }

    public struct Result: Sendable {
        public var received = 0
        public var failure: FriendlyError?
        public var waiting: [PendingRecording] = []
        public var digest: [SharedPayload]?
        public var digestArrived = false
    }

    public static func run(_ inputs: Inputs) async -> Result {
        var result = Result()
        let place = inputs.place, connection = inputs.connection, owner = inputs.owner, personasHere = inputs.personasInMCP
        let callStarted = inputs.callStarted
        var digest: [SharedPayload]? = inputs.keptDigest
        var digestMade = inputs.keptDigest != nil
        // From the app's own rules; a month is made again only when its meetings changed, and a call stops it.
        func makeDigest() -> [SharedPayload]? {
            guard let make = inputs.makeDigest, !digestMade else { return digest }
            digestMade = true
            digest = make()
            return digest
        }
        if let cloud = inputs.main {
            do {
                let changed = try await cloud.push()
                result.received = try await cloud.pull(includeMeetings: false)
                let shared = try await cloud.pushShared(people: true, personas: inputs.personas, stop: callStarted,
                                                        digest: inputs.serverIsMain ? makeDigest() : nil)
                if changed + shared > 0 { Log.info("Sync: \(changed + shared) changes sent to \(place)") }
                // The server's tools read what time the Mac last sent everything: never the age of one record.
                if inputs.serverIsMain, let connection {
                    try? await ServerClient(connection).putConfig(owner: owner, personasInMCP: personasHere, syncedAt: Date())
                }
                if result.received > 0 { Log.info("Sync: \(result.received) changes from your other devices") }
            } catch {
                result.failure = FriendlyError(error, context: .syncing, service: place)
                Log.error("Sync with \(place) failed: \(error)")
            }
            result.waiting = (try? await cloud.recordingNotices()) ?? []
        }
        if let mirror = inputs.mirror {
            do {
                let copied = try await mirror.push()
                if copied > 0 { Log.info("Server: \(copied) meetings copied for ChatGPT and share links") }
                // What the server's MCP reads besides the meetings, one way, by the same allowed-field lists:
                // never during a call, when the disk and the network belong to the recording.
                if !inputs.calling {
                    let shared = try await mirror.pushShared(people: true, personas: inputs.personas, mirror: true, stop: callStarted, digest: makeDigest())
                    if shared > 0 { Log.info("Server: \(shared) people, tasks, points, coach, and chat records copied") }
                    if !callStarted(), let connection {
                        try? await ServerClient(connection).putConfig(owner: owner, personasInMCP: personasHere, syncedAt: Date())
                    }
                }
            } catch {
                Log.error("Copying meetings to your server failed: \(error)")
            }
        }
        // The digest counts as sent only when every part arrived; else the same copy goes again at the next sync,
        // not made again, while nothing it stands on changed.
        let server = inputs.serverIsMain ? inputs.main : inputs.mirror
        if let digest, let server { result.digestArrived = (try? await server.holds(digest)) == true }
        result.digest = digest
        return result
    }
}
