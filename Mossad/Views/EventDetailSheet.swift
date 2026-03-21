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
                    if let meetingUrl = event.meetingUrl {
                        DetailSection(icon: "video.fill", title: "Meeting Link") {
                            Text(meetingUrl)
                                .foregroundStyle(.blue)
                                .textSelection(.enabled)
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
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(event.attendees, id: \.self) { attendee in
                                    Text(attendee)
                                        .textSelection(.enabled)
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
                            openInCalendar()
                        } label: {
                            Label("Open in Calendar", systemImage: "calendar")
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

    private func openInCalendar() {
        // calshow: opens Calendar.app to the event's date
        let timestamp = event.startDate.timeIntervalSinceReferenceDate
        if let url = URL(string: "ical://show?date=\(timestamp)") {
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
