// Mossad/AppState.swift
import EventKit
import Foundation
import MossadShared
import SwiftUI

public enum AttendeeStatus: String {
    case accepted
    case declined
    case tentative
    case pending
}

public struct Attendee {
    public let name: String
    public let email: String
    public let status: AttendeeStatus
}

public struct UpcomingEvent: Identifiable {
    public let id: String
    public let title: String
    public let startDate: Date
    public let endDate: Date
    public let meetingUrl: String?
    public let isAllDay: Bool
    public let location: String?
    public let notes: String?
    public let organizer: String?
    public let attendees: [Attendee]
    public let calendarTitle: String?
    public let calendarColor: CGColor?
}

@MainActor
public final class AppState: NSObject, ObservableObject {
    @Published var recordingState: RecordingState = .idle
    @Published var currentMeetingTitle: String?
    @Published var currentPlatform: String?
    @Published var elapsedSeconds: Int = 0
    @Published var speakerCount: Int = 0
    @Published var currentConversationId: String?
    @Published var showSpeakerLabeling = false
    @Published var lastEndedConversationId: String?
    @Published var lastEndedCalendarAttendees: [String] = []
    @Published var upcomingEvents: [UpcomingEvent] = []
    @Published var disabledEventIds: Set<String> = []
    @Published var autoSkippedEventIds: Set<String> = []

    private let eventStore = EKEventStore()
    private var refreshTimer: Timer?
    private var coordinator: SessionCoordinator?
    let store: ConversationStore

    override init() {
        let dbManager = try! DatabaseManager()
        self.store = ConversationStore(dbQueue: dbManager.dbQueue)
        // Load disabled events from UserDefaults
        let savedDisabled = UserDefaults.standard.stringArray(forKey: "disabledEventIds") ?? []
        self.disabledEventIds = Set(savedDisabled)
        super.init()

        // Start the session coordinator in-process
        do {
            coordinator = try SessionCoordinator()
            coordinator?.delegate = self
            coordinator?.startMonitoring()
            print("[Mossad] SessionCoordinator started, monitoring for calls...")
        } catch {
            print("[Mossad] Failed to start SessionCoordinator: \(error)")
        }

        refreshUpcomingEvents()
        // Refresh every 5 minutes as a fallback
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshUpcomingEvents()
            }
        }
        // Refresh immediately when calendar changes
        NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: eventStore,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshUpcomingEvents()
            }
        }
    }

    func refreshUpcomingEvents() {
        let now = Date()
        let endOfSearch = now.addingTimeInterval(60 * 60 * 24 * 30) // 30 days out

        let selectedCalendarId = UserDefaults.standard.string(forKey: "calendarId")
        let calendars: [EKCalendar]?
        if let selectedCalendarId, selectedCalendarId != "all",
           let cal = eventStore.calendar(withIdentifier: selectedCalendarId) {
            calendars = [cal]
        } else {
            calendars = nil
        }

        let predicate = eventStore.predicateForEvents(withStart: now, end: endOfSearch, calendars: calendars)
        let events = eventStore.events(matching: predicate)

        upcomingEvents = events
            .filter { !$0.isAllDay }
            .sorted { $0.startDate < $1.startDate }
            .prefix(50)
            .map { event in
                // Extract meeting URL from notes/location
                var meetingUrl: String? = nil
                let text = [event.notes, event.location].compactMap { $0 }.joined(separator: " ")
                let patterns = [
                    #"https://meet\.google\.com/[a-z]+-[a-z]+-[a-z]+"#,
                    #"https://zoom\.us/j/\d+[^\s]*"#,
                    #"https://teams\.microsoft\.com/[^\s]+"#,
                ]
                for pattern in patterns {
                    if let regex = try? NSRegularExpression(pattern: pattern),
                       let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                       let range = Range(match.range, in: text) {
                        meetingUrl = String(text[range])
                        break
                    }
                }

                let attendees: [Attendee] = event.attendees?.map { participant in
                    let email = participant.url.absoluteString.replacingOccurrences(of: "mailto:", with: "")
                    let name = participant.name ?? email
                    let status: AttendeeStatus
                    switch participant.participantStatus {
                    case .accepted: status = .accepted
                    case .declined: status = .declined
                    case .tentative: status = .tentative
                    default: status = .pending
                    }
                    return Attendee(name: name, email: email, status: status)
                } ?? []

                let organizer = event.organizer.map { org -> String in
                    let email = org.url.absoluteString.replacingOccurrences(of: "mailto:", with: "")
                    if let name = org.name, !name.isEmpty {
                        return "\(name) <\(email)>"
                    }
                    return email
                }

                return UpcomingEvent(
                    id: event.eventIdentifier,
                    title: event.title ?? "Untitled",
                    startDate: event.startDate,
                    endDate: event.endDate,
                    meetingUrl: meetingUrl,
                    isAllDay: event.isAllDay,
                    location: event.location,
                    notes: event.notes,
                    organizer: organizer,
                    attendees: attendees,
                    calendarTitle: event.calendar.title,
                    calendarColor: event.calendar.cgColor
                )
            }

        // Re-evaluate auto-skip on every refresh
        let skipPatterns = UserDefaults.standard.stringArray(forKey: "skipPatterns") ?? []
        let manuallyToggled = Set(UserDefaults.standard.stringArray(forKey: "manuallyToggledEventIds") ?? [])

        // Remove previously auto-skipped events that no longer match
        for eventId in autoSkippedEventIds {
            if !manuallyToggled.contains(eventId) {
                disabledEventIds.remove(eventId)
            }
        }

        // Re-evaluate which events should be auto-skipped
        var newAutoSkipped = Set<String>()
        for event in upcomingEvents {
            if manuallyToggled.contains(event.id) { continue }
            let titleLower = event.title.lowercased()
            let shouldSkip = skipPatterns.contains { titleLower.contains($0.lowercased()) }
            if shouldSkip {
                disabledEventIds.insert(event.id)
                newAutoSkipped.insert(event.id)
            }
        }
        autoSkippedEventIds = newAutoSkipped
        UserDefaults.standard.set(Array(disabledEventIds), forKey: "disabledEventIds")
    }

    func toggleEventRecording(_ eventId: String) {
        if disabledEventIds.contains(eventId) {
            disabledEventIds.remove(eventId)
            autoSkippedEventIds.remove(eventId)
        } else {
            disabledEventIds.insert(eventId)
        }
        UserDefaults.standard.set(Array(disabledEventIds), forKey: "disabledEventIds")
        // Track that this event was manually toggled so auto-skip doesn't override
        var toggled = UserDefaults.standard.stringArray(forKey: "manuallyToggledEventIds") ?? []
        if !toggled.contains(eventId) {
            toggled.append(eventId)
            UserDefaults.standard.set(toggled, forKey: "manuallyToggledEventIds")
        }
    }

    func isAutoSkipped(_ eventId: String) -> Bool {
        autoSkippedEventIds.contains(eventId)
    }

    func isEventEnabled(_ eventId: String) -> Bool {
        !disabledEventIds.contains(eventId)
    }

    func pauseRecording() {
        coordinator?.pauseRecording()
    }

    func resumeRecording() {
        coordinator?.resumeRecording()
    }

    var elapsedFormatted: String {
        let minutes = elapsedSeconds / 60
        let seconds = elapsedSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    func handleStateChange(_ snapshot: ServiceSnapshot) {
        print("[Mossad] State changed: \(snapshot.recordingState.rawValue) - \(snapshot.currentMeetingTitle ?? "no meeting")")
        let wasRecording = self.recordingState == .recording
        let nowIdle = snapshot.recordingState == .idle || snapshot.recordingState == .detecting

        self.recordingState = snapshot.recordingState
        self.currentMeetingTitle = snapshot.currentMeetingTitle
        self.currentPlatform = snapshot.currentPlatform
        self.elapsedSeconds = snapshot.elapsedSeconds ?? 0
        self.speakerCount = snapshot.speakerCount ?? 0

        if wasRecording && nowIdle, let convId = self.currentConversationId {
            let speakers = (try? self.store.fetchSpeakers(conversationId: convId)) ?? []
            let unlabeled = speakers.filter { !$0.isMe && $0.name.hasPrefix("Speaker ") }
            if !unlabeled.isEmpty {
                self.lastEndedConversationId = convId
                self.showSpeakerLabeling = true
            }
        }

        self.currentConversationId = snapshot.currentConversationId
    }
}

extension AppState: SessionCoordinatorDelegate {
    nonisolated public func coordinator(_ coordinator: SessionCoordinator, didChangeState snapshot: ServiceSnapshot) {
        Task { @MainActor in
            self.handleStateChange(snapshot)
        }
    }

    nonisolated public func coordinator(_ coordinator: SessionCoordinator, didReceiveUtterance utteranceData: Data) {
        // Could use for live transcript display
    }
}
