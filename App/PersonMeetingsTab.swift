import MossadCore
import SwiftUI

/// Every meeting with the person, newest first: where they spoke, or where the invite names them on a sure match.
/// A search over the titles, and a click opens the meeting.
struct PersonMeetingsTab: View {
    @EnvironmentObject var controller: AppController
    /// Nil while it is made.
    let meetings: PersonMeetings?
    /// The first name; nil on the owner's own page.
    let first: String?
    let top: CGFloat
    @State private var query = ""

    var body: some View {
        let rows = meetings?.matching(query) ?? []
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let meetings, !meetings.rows.isEmpty {
                    HStack(spacing: Space.m) {
                        Text(summary(meetings)).font(.system(size: Rhythm.bodySize)).foregroundStyle(Palette.secondary)
                        Spacer(minLength: Space.m)
                        SearchField(prompt: "Search these meetings", query: $query).frame(maxWidth: 260)
                    }
                    .padding(.bottom, Space.m)
                    if rows.isEmpty {
                        Text("No meeting matches “\(query)”.").font(.system(size: Rhythm.bodySize)).foregroundStyle(Palette.secondary).padding(.top, Space.m)
                    }
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                            PersonMeetingRow(row: row, onlyInvited: first.map { "\($0) was invited" }) { controller.openMeeting(row.id) }
                            if i < rows.count - 1 { Hairline() }
                        }
                    }
                } else if meetings == nil {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.top, Space.xl)
                } else {
                    EmptyState(symbol: "calendar", title: "No meetings yet",
                               message: first.map { "Meetings where \($0) speaks, or where the invite names \($0), show here." }
                                   ?? "The meetings you speak in show here.")
                        .frame(maxWidth: .infinity).padding(.top, Space.xl)
                }
            }
            .detailColumn(top: top)
        }
        .onAppear {
            // Development hook for screenshots: MOSSAD_PERSON_SEARCH=<words> fills the search.
            if CommandLine.arguments.contains("--ui-preview"), let q = ProcessInfo.processInfo.environment["MOSSAD_PERSON_SEARCH"] { query = q }
        }
    }

    /// "14 meetings · 3 only invited · 2 from Gemini notes"
    private func summary(_ m: PersonMeetings) -> String {
        var parts = [meetingsText(m.rows.count)]
        if m.together.invitedOnly > 0 { parts.append("\(m.together.invitedOnly) only invited") }
        let notes = m.rows.filter(\.notesOnly).count
        if notes > 0 { parts.append("\(notes) from Gemini notes") }
        return parts.joined(separator: " · ")
    }
}

/// The date, the title with its marks, the platform, and the length.
private struct PersonMeetingRow: View {
    let row: PersonMeetings.Row
    /// "Sam was invited", on a row where they did not speak; nil on the owner's page.
    let onlyInvited: String?
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: Space.m) {
                Text(day).frame(width: 92, alignment: .leading).foregroundStyle(Palette.secondary)
                HStack(spacing: Space.s) {
                    Text(row.title).font(.system(size: Rhythm.bodySize, weight: .medium)).foregroundStyle(Palette.ink).lineLimit(1)
                    if row.notesOnly { SourceMark(text: "Gemini notes") }
                    if row.part == .invited, let onlyInvited {
                        Text("Invited").font(.system(size: Rhythm.noteSize, weight: .semibold)).foregroundStyle(Palette.secondary)
                            .padding(.horizontal, 6).frame(height: 16)
                            .overlay(Capsule().strokeBorder(Palette.bar, lineWidth: 1))
                            .fixedSize()
                            .help(onlyInvited + ", and did not speak, or not by a voice Mossad knows")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: Space.s) {
                    PlatformDot(platform: row.platform)
                    Text(row.platform.shortName)
                }
                .frame(width: 90, alignment: .leading)
                .foregroundStyle(Palette.secondary)
                Text(durationLabel(row.seconds)).frame(width: 64, alignment: .trailing).foregroundStyle(Palette.secondary)
            }
            .font(.system(size: Rhythm.secondarySize)).monospacedDigit()
            .padding(.vertical, 9).padding(.horizontal, Space.s)
            .background(hovering ? Palette.fill.opacity(0.5) : .clear, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the meeting")
    }

    /// "Today", "Oct 9", or "Oct 9, 2025" in another year.
    private var day: String {
        let cal = Calendar.current
        if cal.isDateInToday(row.start) || cal.isDateInYesterday(row.start) { return dayWord(row.start) }
        return cal.isDate(row.start, equalTo: Date(), toGranularity: .year)
            ? row.start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
            : row.start.formatted(.dateTime.month(.abbreviated).day().year())
    }
}

/// A small rounded search field for a list inside a page.
private struct SearchField: View {
    let prompt: String
    @Binding var query: String

    var body: some View {
        HStack(spacing: Space.s) {
            Image(systemName: "magnifyingglass").font(.system(size: Rhythm.noteSize)).foregroundStyle(Palette.tertiary).accessibilityHidden(true)
            TextField(prompt, text: $query).textFieldStyle(.plain).font(.system(size: Rhythm.bodySize))
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Palette.tertiary) }
                    .buttonStyle(.plain).accessibilityLabel("Clear the search")
            }
        }
        .padding(.horizontal, 9).frame(height: 26)
        .background(Palette.fill, in: Capsule())
    }
}
