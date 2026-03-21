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
                            FlowLayout(spacing: 6) {
                                ForEach(event.attendees, id: \.self) { attendee in
                                    PersonPill(text: attendee)
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

struct PersonPill: View {
    let text: String

    private var name: String {
        // Extract name from "Name <email>" format
        if let angleBracket = text.firstIndex(of: "<") {
            let n = text[text.startIndex..<angleBracket].trimmingCharacters(in: .whitespaces)
            return n.isEmpty ? email : n
        }
        return text
    }

    private var email: String {
        if let start = text.firstIndex(of: "<"),
           let end = text.firstIndex(of: ">") {
            return String(text[text.index(after: start)..<end])
        }
        return text
    }

    private var initials: String {
        let parts = name.split(separator: " ")
        if parts.count >= 2 {
            return "\(parts[0].prefix(1))\(parts[1].prefix(1))".uppercased()
        }
        return String(name.prefix(2)).uppercased()
    }

    var body: some View {
        HStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(Color(hue: Double(abs(name.hashValue) % 360) / 360.0, saturation: 0.4, brightness: 0.7))
                    .frame(width: 24, height: 24)
                Text(initials)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
            }
            Text(name)
                .font(.caption)
                .lineLimit(1)
        }
        .padding(.trailing, 8)
        .padding(.vertical, 4)
        .padding(.leading, 4)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.primary.opacity(0.06))
        )
        .help(email)
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = layout(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y), proposal: .unspecified)
        }
    }

    private func layout(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxX: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            maxX = max(maxX, x)
        }

        return (CGSize(width: maxX, height: y + rowHeight), positions)
    }
}
