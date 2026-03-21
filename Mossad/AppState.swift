// Mossad/AppState.swift
import EventKit
import Foundation
import MossadShared
import SwiftUI

public struct UpcomingEvent: Identifiable {
    public let id: String
    public let title: String
    public let startDate: Date
    public let endDate: Date
    public let meetingUrl: String?
    public let isAllDay: Bool
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

    private var xpcConnection: NSXPCConnection?
    private var service: MossadServiceProtocol?
    private let eventStore = EKEventStore()
    private var refreshTimer: Timer?
    let store: ConversationStore

    override init() {
        let dbManager = try! DatabaseManager()
        self.store = ConversationStore(dbQueue: dbManager.dbQueue)
        // Load disabled events from UserDefaults
        let savedDisabled = UserDefaults.standard.stringArray(forKey: "disabledEventIds") ?? []
        self.disabledEventIds = Set(savedDisabled)
        super.init()
        setupXPCConnection()
        refreshUpcomingEvents()
        // Refresh every 5 minutes
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
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
            .prefix(10)
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

                return UpcomingEvent(
                    id: event.eventIdentifier,
                    title: event.title ?? "Untitled",
                    startDate: event.startDate,
                    endDate: event.endDate,
                    meetingUrl: meetingUrl,
                    isAllDay: event.isAllDay
                )
            }
    }

    func toggleEventRecording(_ eventId: String) {
        if disabledEventIds.contains(eventId) {
            disabledEventIds.remove(eventId)
        } else {
            disabledEventIds.insert(eventId)
        }
        UserDefaults.standard.set(Array(disabledEventIds), forKey: "disabledEventIds")
    }

    func isEventEnabled(_ eventId: String) -> Bool {
        !disabledEventIds.contains(eventId)
    }

    private func setupXPCConnection() {
        let connection = NSXPCConnection(serviceName: "com.mossad.MossadService")
        connection.remoteObjectInterface = NSXPCInterface(with: MossadServiceProtocol.self)
        connection.exportedInterface = NSXPCInterface(with: MossadAppProtocol.self)
        connection.exportedObject = self
        connection.resume()

        self.xpcConnection = connection
        self.service = connection.remoteObjectProxyWithErrorHandler { error in
            print("XPC error: \(error)")
        } as? MossadServiceProtocol

        // Start monitoring immediately
        service?.startMonitoring()
    }

    func pauseRecording() {
        service?.pauseRecording()
    }

    func resumeRecording() {
        service?.resumeRecording()
    }

    func stopMonitoring() {
        service?.stopMonitoring()
    }

    var elapsedFormatted: String {
        let minutes = elapsedSeconds / 60
        let seconds = elapsedSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

extension AppState: MossadAppProtocol {
    nonisolated public func stateDidChange(_ stateData: Data) {
        guard let snapshot = ServiceSnapshot.decoded(from: stateData) else { return }
        Task { @MainActor in
            // Detect recording → idle/detecting transition
            let wasRecording = self.recordingState == .recording
            let nowIdle = snapshot.recordingState == .idle || snapshot.recordingState == .detecting

            self.recordingState = snapshot.recordingState
            self.currentMeetingTitle = snapshot.currentMeetingTitle
            self.currentPlatform = snapshot.currentPlatform
            self.elapsedSeconds = snapshot.elapsedSeconds ?? 0
            self.speakerCount = snapshot.speakerCount ?? 0

            // If call just ended, check for unlabeled speakers and show labeling sheet
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

    nonisolated public func utteranceReceived(_ utteranceData: Data) {
        // Could use this for live transcript display
    }
}
