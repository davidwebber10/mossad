// Mossad/Views/UpcomingEventsView.swift
import SwiftUI
import MossadShared

struct UpcomingEventsView: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedEvent: UpcomingEvent?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if appState.upcomingEvents.isEmpty {
                ContentUnavailableView(
                    "No Upcoming Meetings",
                    systemImage: "calendar",
                    description: Text("No meetings found in the next 30 days, or calendar access hasn't been granted.")
                )
            } else {
                List {
                    ForEach(groupedByDay, id: \.key) { label, events in
                        Section(label) {
                            ForEach(events) { event in
                                EventRow(
                                    event: event,
                                    enabled: appState.isEventEnabled(event.id)
                                ) {
                                    appState.toggleEventRecording(event.id)
                                }
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    selectedEvent = event
                                }
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .sheet(item: $selectedEvent) { event in
            EventDetailSheet(
                event: event,
                enabled: appState.isEventEnabled(event.id)
            ) {
                appState.toggleEventRecording(event.id)
            }
        }
        .navigationTitle("Upcoming")
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    appState.refreshUpcomingEvents()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh calendar")
            }
        }
    }

    private var groupedByDay: [(key: String, value: [UpcomingEvent])] {
        let calendar = Calendar.current
        let now = Date()
        var groups: [(key: String, date: Date, value: [UpcomingEvent])] = []
        var seen: [String: Int] = [:]

        for event in appState.upcomingEvents {
            let label: String
            let groupDate: Date

            if calendar.isDateInToday(event.startDate) {
                label = "Today"
                groupDate = calendar.startOfDay(for: now)
            } else if calendar.isDateInTomorrow(event.startDate) {
                label = "Tomorrow"
                groupDate = calendar.startOfDay(for: now.addingTimeInterval(86400))
            } else {
                let formatter = DateFormatter()
                formatter.dateFormat = "EEEE, MMM d"
                label = formatter.string(from: event.startDate)
                groupDate = calendar.startOfDay(for: event.startDate)
            }

            if let idx = seen[label] {
                groups[idx].value.append(event)
            } else {
                seen[label] = groups.count
                groups.append((key: label, date: groupDate, value: [event]))
            }
        }

        return groups
            .sorted { $0.date < $1.date }
            .map { (key: $0.key, value: $0.value) }
    }
}

struct EventRow: View {
    let event: UpcomingEvent
    let enabled: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onToggle) {
                Image(systemName: enabled ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(enabled ? .green : .secondary)
            }
            .buttonStyle(.plain)
            .help(enabled ? "Recording enabled — click to skip" : "Recording disabled — click to enable")

            VStack(alignment: .leading, spacing: 3) {
                Text(event.title)
                    .font(.body)
                    .fontWeight(.medium)
                    .strikethrough(!enabled, color: .secondary)
                    .foregroundStyle(enabled ? .primary : .secondary)

                HStack(spacing: 6) {
                    Label {
                        Text("\(event.startDate, style: .time) – \(event.endDate, style: .time)")
                    } icon: {
                        Image(systemName: "clock")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    if let url = event.meetingUrl {
                        Label {
                            Text(platformName(from: url))
                        } icon: {
                            Image(systemName: platformIcon(from: url))
                        }
                        .font(.caption)
                        .foregroundStyle(.blue)
                    }
                }
            }

            Spacer()

            if !enabled {
                Text("Skipped")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(.orange.opacity(0.15))
                    )
            }
        }
        .padding(.vertical, 4)
    }

    private func platformName(from url: String) -> String {
        if url.contains("zoom.us") { return "Zoom" }
        if url.contains("meet.google.com") { return "Meet" }
        if url.contains("teams.microsoft.com") { return "Teams" }
        return "Meeting"
    }

    private func platformIcon(from url: String) -> String {
        if url.contains("zoom.us") { return "video.fill" }
        if url.contains("meet.google.com") { return "person.3.fill" }
        if url.contains("teams.microsoft.com") { return "person.2.fill" }
        return "link"
    }
}
