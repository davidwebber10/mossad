import EventKit
import Foundation

public struct MatchedEvent {
    public let title: String
    public let attendees: [String]
    public let organizer: String?
    public let calendarEventId: String
    public let meetingUrl: String?
}

public final class CalendarMatcher {
    private let eventStore = EKEventStore()
    public init() {}

    public func requestAccess() async -> Bool {
        if #available(macOS 14.0, *) {
            do { return try await eventStore.requestFullAccessToEvents() } catch { return false }
        } else {
            return await withCheckedContinuation { continuation in
                eventStore.requestAccess(to: .event) { granted, _ in
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    public func findMatchingEvent(platform: MeetingPlatform, detectedURL: String?, at date: Date = Date()) -> MatchedEvent? {
        let windowStart = date.addingTimeInterval(-600)
        let windowEnd = date.addingTimeInterval(600)
        let predicate = eventStore.predicateForEvents(withStart: windowStart, end: windowEnd, calendars: nil)
        let events = eventStore.events(matching: predicate)

        if let detectedURL = detectedURL {
            for event in events {
                let eventURLs = Self.extractMeetingURLs(from: event)
                if Self.urlMatches(detected: detectedURL, eventURLs: eventURLs) {
                    return matchedEvent(from: event)
                }
            }
        }

        let closest = events.sorted { abs($0.startDate.timeIntervalSince(date)) < abs($1.startDate.timeIntervalSince(date)) }.first
        if let closest = closest { return matchedEvent(from: closest) }
        return nil
    }

    private func matchedEvent(from event: EKEvent) -> MatchedEvent {
        let attendees = event.attendees?.compactMap { participant -> String? in
            let url = participant.url
            return url.absoluteString.replacingOccurrences(of: "mailto:", with: "")
        } ?? []
        let organizer = event.organizer.map { $0.url.absoluteString.replacingOccurrences(of: "mailto:", with: "") }
        let urls = Self.extractMeetingURLs(from: event)
        return MatchedEvent(title: event.title ?? "Untitled Meeting", attendees: attendees, organizer: organizer, calendarEventId: event.eventIdentifier, meetingUrl: urls.first)
    }

    static func extractMeetingURLs(from event: EKEvent) -> [String] {
        var allText = ""
        if let notes = event.notes { allText += notes + " " }
        if let location = event.location { allText += location + " " }
        if let url = event.url { allText += url.absoluteString }
        return extractMeetingURLs(from: allText)
    }

    public static func extractMeetingURLs(from text: String) -> [String] {
        let patterns = [
            #"https://meet\.google\.com/[a-z]+-[a-z]+-[a-z]+"#,
            #"https://zoom\.us/j/\d+[^\s]*"#,
            #"https://teams\.microsoft\.com/[^\s]+"#,
        ]
        var urls: [String] = []
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
                let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
                for match in matches {
                    if let range = Range(match.range, in: text) { urls.append(String(text[range])) }
                }
            }
        }
        return urls
    }

    public static func urlMatches(detected: String, eventURLs: [String]) -> Bool {
        for eventURL in eventURLs {
            if detected.contains("zoom.us/j/") && eventURL.contains("zoom.us/j/") {
                let detectedId = detected.components(separatedBy: "/j/").last?.components(separatedBy: "?").first
                let eventId = eventURL.components(separatedBy: "/j/").last?.components(separatedBy: "?").first
                if detectedId != nil && detectedId == eventId { return true }
            }
            if detected.contains("meet.google.com/") && eventURL.contains("meet.google.com/") {
                let detectedCode = detected.components(separatedBy: "meet.google.com/").last?.components(separatedBy: "?").first
                let eventCode = eventURL.components(separatedBy: "meet.google.com/").last?.components(separatedBy: "?").first
                if detectedCode != nil && detectedCode == eventCode { return true }
            }
            if detected.contains("teams.microsoft.com") && eventURL.contains("teams.microsoft.com") { return true }
        }
        return false
    }
}
