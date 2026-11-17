import Foundation

/// What a process of Mossad is: the app in front that records and processes (`full`), a copy that only shows
/// (`inert`: a preview, Rehearsal, a second copy, a made-up registry), or a profile's background run (`worker`).
/// `Duty` and `does` are the one table of what each does.
public enum RunMode: Equatable, Sendable {
    case full, inert, worker

    public static func decide(preview: Bool, rehearsal: Bool, secondCopy: Bool, madeUpRegistry: Bool, worker: Bool = false) -> RunMode {
        if worker { return .worker }
        return preview || rehearsal || secondCopy || madeUpRegistry ? .inert : .full
    }

    public func does(_ duty: Duty) -> Bool {
        switch self {
        case .full: duty != .statusFile
        case .worker: Duty.workerDuties.contains(duty)
        case .inert: Duty.inertDuties.contains(duty)
        }
    }

    /// `does`, and on a made-up registry only what stays in the folder: a proof run never reaches a service.
    public func runs(_ duty: Duty, madeUpRegistry: Bool) -> Bool {
        does(duty) && !(madeUpRegistry && duty.leavesTheFolder)
    }
}

/// Each thing a process of Mossad may do.
public enum Duty: String, CaseIterable, Sendable {
    // What a worker does, as the window app does too.
    case recover, people, queue, inviteMatch, sync, digest, serverConfig, backup, coach, commitments, nextTime, personas, takeInMoved, statusFile
    // What only the app in front does.
    case detect, record, geminiNotes, calendarSnapshot, upcoming, hotKeys, loginItem, updater, notifications, weeklyMail, usageStats, retention, askPermission
    /// `window` is a window, a menu bar item, and a Dock icon; `sharedItems` the iCloud Keychain items for the iPhone;
    /// `upkeep` the one-time backfills, the older person briefs, and the Google directory.
    case window, sharedItems, upkeep, registry, startWorkers

    /// It reaches past the profile's folder: a provider, a store, a calendar, a server.
    public var leavesTheFolder: Bool {
        switch self {
        case .inviteMatch, .sync, .digest, .serverConfig, .backup, .coach, .commitments, .nextTime, .personas: true
        default: false
        }
    }

    static let workerDuties: Set<Duty> = [.recover, .people, .queue, .inviteMatch, .sync, .digest, .serverConfig, .backup,
                                          .coach, .commitments, .nextTime, .personas, .takeInMoved, .statusFile]
    static let inertDuties: Set<Duty> = [.upcoming, .notifications, .window]
}
