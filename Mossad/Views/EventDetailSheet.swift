// Mossad/Views/EventDetailSheet.swift
import SwiftUI

struct EventDetailSheet: View {
    let event: UpcomingEvent
    let enabled: Bool
    let onToggle: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(event.title)
                        .font(.title2)
                        .fontWeight(.bold)

                    if let calendarTitle = event.calendarTitle {
                        HStack(spacing: 6) {
                            if let cgColor = event.calendarColor {
                                Circle()
                                    .fill(Color(cgColor: cgColor))
                                    .frame(width: 8, height: 8)
                            }
                            Text(calendarTitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Date & Time
                    DetailSection(icon: "clock", title: "When") {
                        Text(formattedDateRange)
                        Text(formattedDuration)
                            .foregroundStyle(.secondary)
                    }

                    // Recording toggle
                    DetailSection(icon: "mic.fill", title: "Recording") {
                        HStack {
                            Text(enabled ? "Will record when call is detected" : "Recording skipped for this event")
                                .foregroundStyle(enabled ? Color.primary : Color.orange)
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { enabled },
                                set: { _ in onToggle() }
                            ))
                            .toggleStyle(.switch)
                            .labelsHidden()
                        }
                    }

                    // Location
                    if let location = event.location, !location.isEmpty {
                        DetailSection(icon: "mappin", title: "Location") {
                            Text(location)
                                .textSelection(.enabled)
                        }
                    }

                    // Meeting link
                    if let meetingUrl = event.meetingUrl, let url = URL(string: meetingUrl) {
                        DetailSection(icon: "video.fill", title: "Meeting Link") {
                            Link(meetingUrl, destination: url)
                                .font(.callout)
                        }
                    }

                    // Organizer
                    if let organizer = event.organizer {
                        DetailSection(icon: "person.fill", title: "Organizer") {
                            Text(organizer)
                                .textSelection(.enabled)
                        }
                    }

                    // Attendees
                    if !event.attendees.isEmpty {
                        DetailSection(icon: "person.2.fill", title: "Attendees (\(event.attendees.count))") {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(event.attendees, id: \.email) { attendee in
                                    AttendeeRow(attendee: attendee)
                                }
                            }
                        }
                    }

                    // Notes
                    if let notes = event.notes, !notes.isEmpty {
                        DetailSection(icon: "note.text", title: "Notes") {
                            Text(notes)
                                .textSelection(.enabled)
                                .font(.callout)
                        }
                    }

                    // Open in Calendar
                    HStack {
                        Spacer()
                        Button {
                            openInGoogleCalendar()
                        } label: {
                            Label("Open in Google Calendar", systemImage: "calendar")
                        }
                        .buttonStyle(.bordered)
                        Spacer()
                    }
                    .padding(.top, 8)
                }
                .padding()
            }
        }
        .frame(minWidth: 480, minHeight: 400, maxHeight: 600)
    }

    private var formattedDateRange: String {
        let dateFormatter = DateFormatter()
        let calendar = Calendar.current

        if calendar.isDateInToday(event.startDate) {
            dateFormatter.dateFormat = "'Today,' h:mm a"
        } else if calendar.isDateInTomorrow(event.startDate) {
            dateFormatter.dateFormat = "'Tomorrow,' h:mm a"
        } else {
            dateFormatter.dateFormat = "EEEE, MMM d, h:mm a"
        }
        let start = dateFormatter.string(from: event.startDate)

        dateFormatter.dateFormat = "h:mm a"
        let end = dateFormatter.string(from: event.endDate)

        return "\(start) – \(end)"
    }

    private var formattedDuration: String {
        let seconds = Int(event.endDate.timeIntervalSince(event.startDate))
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        if hours > 0 {
            return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
        }
        return "\(minutes) minutes"
    }

    private func openInGoogleCalendar() {
        // Google Calendar event URL format: uses the event ID
        // EventKit IDs from Google have a format we can extract from
        // Fallback: open Google Calendar to the event's date
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        let dateStr = formatter.string(from: event.startDate)
        let urlString = "https://calendar.google.com/calendar/r/day/\(Calendar.current.component(.year, from: event.startDate))/\(Calendar.current.component(.month, from: event.startDate))/\(Calendar.current.component(.day, from: event.startDate))"
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }
}

struct DetailSection<Content: View>: View {
    let icon: String
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon)
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
            content
                .padding(.leading, 28)
        }
    }
}

struct AttendeeRow: View {
    let attendee: Attendee

    var body: some View {
        HStack(spacing: 10) {
            statusIcon
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(attendee.name)
                    .font(.callout)
                if attendee.email != attendee.name {
                    Text(attendee.email)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Text(statusLabel)
                .font(.caption)
                .foregroundStyle(statusColor)
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch attendee.status {
        case .accepted:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .declined:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
        case .tentative:
            Image(systemName: "questionmark.circle.fill")
                .foregroundStyle(.orange)
        case .pending:
            Image(systemName: "circle")
                .foregroundStyle(.secondary)
        }
    }

    private var statusLabel: String {
        switch attendee.status {
        case .accepted: return "Accepted"
        case .declined: return "Declined"
        case .tentative: return "Maybe"
        case .pending: return "No response"
        }
    }

    private var statusColor: Color {
        switch attendee.status {
        case .accepted: return .green
        case .declined: return .red
        case .tentative: return .orange
        case .pending: return .secondary
        }
    }
}
