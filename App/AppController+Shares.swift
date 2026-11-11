import AppKit
import MossadCore

/// Share links: one meeting on the owner's server behind a private link, with an optional PIN.
extension AppController {
    /// Whether the server counts views and takes a PIN (the share calls of version 2).
    var serverHasShareNumbers: Bool { ServerSample.isOn || serverShares >= ServerClient.Hello.currentShares }

    /// The server answered, and it is older than this app: Settings and the Shares page then say "Update your server".
    var serverNeedsUpdate: Bool { serverConnection != nil && !ServerSample.isOn && serverCheck == .passed && !serverHasShareNumbers }

    /// What an owner runs to update the server, as server/README.md has it.
    static let serverUpdateSteps = """
    git pull
    cd server
    npm install
    npx wrangler d1 migrations apply mossad --remote
    npx wrangler deploy
    """

    /// How long a stopped link can still be brought back.
    static let stopUndoSeconds: TimeInterval = 8

    /// Makes or updates the link for a meeting with these options and this PIN (nil for none), and returns it.
    /// Nothing is kept on this Mac until the server has the meeting and, when asked for, the PIN.
    /// `fromNow` counts the days from today also when the choice of days is the one the link had.
    func share(_ record: CallRecord, options: ShareOptions, pin: String?, existing: MeetingLink?, fromNow: Bool = false) async throws -> MeetingLink {
        guard let c = serverConnection else { throw ServerError.wrongSecret }
        let now = Date()
        var link = existing ?? MeetingLink(token: MeetingLink.newToken(), callID: record.id, title: record.title, options: options, created: now)
        link.expires = MeetingLink.expiry(days: options.days, existing: fromNow ? nil : existing, now: now)
        link.options = options
        link.title = record.title
        link.stopping = nil
        link.stopAfter = nil
        let model = aiProvider == .anthropic ? aiProvider.resolvedModel(aiModel) : nil
        let meeting = SharedMeeting(MeetingView(record), owner: ownerName, options: options, expires: link.expires, model: model)
        let audio = options.recording ? try await recordingFile(record) : nil
        let client = ServerClient(c)
        try await client.putShare(link, meeting: meeting, audio: audio)
        if pin != existing?.pin {
            do {
                if let pin { try await client.setPIN(shareID: link.id, pin: pin) } else { try await client.removePIN(shareID: link.id) }
                link.pin = pin
            } catch {
                // A new link must not stay open without the PIN that its owner asked for.
                if existing == nil { try? await client.deleteShare(link) } else { keep(link) }
                throw error
            }
        }
        keep(link)
        return link
    }

    /// Sets a new PIN on a link, or removes it with nil. The server keeps a hash; this Mac keeps the PIN for its owner.
    func setPIN(_ link: MeetingLink, pin: String?) async throws {
        guard let c = serverConnection else { throw ServerError.wrongSecret }
        if let pin { try await ServerClient(c).setPIN(shareID: link.id, pin: pin) } else { try await ServerClient(c).removePIN(shareID: link.id) }
        var changed = link
        changed.pin = pin
        keep(changed)
    }

    /// Changes when a link stops working: so many days from now, or never. A link that works is changed on the
    /// server alone. An expired one has no copy there any more, so the meeting is sent again.
    func setExpiry(_ link: MeetingLink, days: Int?, live: Bool) async throws {
        guard let c = serverConnection else { throw ServerError.wrongSecret }
        var options = link.options
        options.days = days
        if live, serverHasShareNumbers {
            let expires = days.map { Date().addingTimeInterval(Double($0) * 86_400) }
            do {
                try await ServerClient(c).setExpiry(shareID: link.id, expires: expires)
                var changed = link
                changed.options = options
                changed.expires = expires
                keep(changed)
                return
            } catch ServerError.http(410, _) {
                // The copy went between the list and this call: send it again, below.
            }
        }
        guard let record = meetings.first(where: { $0.id == link.callID }) else {
            throw ServerError.http(410, "The meeting of this link is not on this Mac any more, so it cannot be shared again.")
        }
        _ = try await share(record, options: options, pin: link.pin, existing: link, fromNow: true)
    }

    func stopSharing(_ link: MeetingLink) async throws {
        if let c = serverConnection { try await ServerClient(c).deleteShare(link) }
        shareBook.remove(link.token)
        saveShares()
        if stoppedShare?.token == link.token { stoppedShare = nil }
    }

    /// Stops a link with time to undo. The mark is saved at once, so the link also stops when the app quits before
    /// the time is over: the next launch tells the server.
    func stopSharingSoon(_ link: MeetingLink) {
        shareBook.markStopping(token: link.token, after: Date().addingTimeInterval(Self.stopUndoSeconds))
        saveShares()
        stoppedShare = link
        Task {
            try? await Task.sleep(for: .seconds(Self.stopUndoSeconds + 0.2))
            if stoppedShare?.token == link.token { stoppedShare = nil }
            retryShareStops()
        }
    }

    func undoStop(_ link: MeetingLink) {
        shareBook.undoStop(token: link.token)
        saveShares()
        if stoppedShare?.token == link.token { stoppedShare = nil }
    }

    /// A share that another Mac made: this Mac has no link to mark, so the server is told at once.
    func stopSharing(shareID: String) async throws {
        guard let c = serverConnection else { throw ServerError.wrongSecret }
        try await ServerClient(c).deleteShare(shareID: shareID)
    }

    /// Stops every link of a meeting that is gone (deleted, or merged into another), so its page does not stay
    /// public with no meeting left to stop it from. A link the server could not be told about is kept, marked, and
    /// tried again after each sync.
    func stopSharing(callID: String) {
        guard shareBook.links.contains(where: { $0.callID == callID }) else { return }
        shareBook.markStopping(callID: callID)
        saveShares()
        retryShareStops()
    }

    func retryShareStops() {
        let links = shareBook.dueStops()
        // Without a server connection the link cannot be stopped; it stays marked until there is one. Dropping it
        // here would leave the public page with no trace of it on this Mac.
        guard !links.isEmpty, !stoppingShares, serverConnection != nil else { return }
        stoppingShares = true
        Task {
            for link in links {
                do {
                    try await stopSharing(link)
                    Log.info("Stopped a share link")
                } catch {
                    Log.error("A share link could not be stopped yet; it is tried again after the next sync: \(error)")
                }
            }
            stoppingShares = false
        }
    }

    func shareURL(_ link: MeetingLink) -> URL? { serverConnection.map { link.url(on: $0.address) } }

    /// Opens a link in the browser with the owner's mark, so the owner's own visits are not counted as views.
    func openShare(_ link: MeetingLink) {
        guard let c = serverConnection else { return }
        NSWorkspace.shared.open(OwnerMark.url(link.url(on: c.address), secret: c.secret))
    }

    private func keep(_ link: MeetingLink) {
        shareBook.put(link)
        saveShares()
    }

    private func saveShares() {
        do { try shareBook.save(to: paths.shares) } catch { Log.error("Saving share links failed: \(error)") }
    }
}
