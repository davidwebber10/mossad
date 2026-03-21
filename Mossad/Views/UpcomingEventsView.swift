// Mossad/Views/UpcomingEventsView.swift
import SwiftUI
import MossadShared

struct UpcomingEventsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if appState.upcomingEvents.isEmpty {
                ContentUnavailableView(
                    "No Upcoming Meetings",
                    systemImage: "calendar",
                    description: Text("No meetings scheduled for the rest of today, or calendar access hasn't been granted.")
                )
            } else {
                List {
                    ForEach(groupedByTime, id: \.key) { label, events in
                        Section(label) {
                            ForEach(events) { event in
                                EventRow(
                                    event: event,
                                    enabled: appState.isEventEnabled(event.id)
                                ) {
                                    appState.toggleEventRecording(event.id)
                                }
                            }
                        }
                    }
                }
                .listStyle(.inset)
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

    private var groupedByTime: [(key: String, value: [UpcomingEvent])] {
        let calendar = Calendar.current
        let now = Date()
        var groups: [String: [UpcomingEvent]] = [:]

        for event in appState.upcomingEvents {
            let label: String
            if event.startDate <= now && event.endDate >= now {
                label = "Now"
            } else if calendar.isDate(event.startDate, equalTo: now, toGranularity: .hour) {
                label = "This Hour"
            } else {
                let hour = calendar.component(.hour, from: event.startDate)
                let formatter = DateFormatter()
                formatter.dateFormat = "h a"
                label = formatter.string(from: event.startDate)
            }
            groups[label, default: []].append(event)
        }

        // Sort: "Now" first, then by time
        let order = ["Now", "This Hour"]
        return groups.sorted { a, b in
            let aIdx = order.firstIndex(of: a.key) ?? Int.max
            let bIdx = order.firstIndex(of: b.key) ?? Int.max
            if aIdx != bIdx { return aIdx < bIdx }
            let aTime = a.value.first?.startDate ?? .distantFuture
            let bTime = b.value.first?.startDate ?? .distantFuture
            return aTime < bTime
        }
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
