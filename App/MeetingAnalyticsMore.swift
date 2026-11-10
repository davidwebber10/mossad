import MossadCore
import SwiftUI

/// A small heading inside a group, as "Rated low more than once" on the Analytics page.
private struct Subheading: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.secondary)
    }
}

/// A title and a value on one line, as the cost table's rows.
private struct ValueRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 6) {
            Text(title).foregroundStyle(Palette.secondary)
            Spacer(minLength: 12)
            Text(value).foregroundStyle(Palette.ink).monospacedDigit()
        }
        .font(.system(size: 12.5))
        .accessibilityElement(children: .combine)
    }
}

// MARK: Participation

/// The invited people against the voices: who spoke, who did not, and who spoke with no invite.
struct ParticipationSection: View {
    let participation: MeetingAnalytics.Participation
    let analytics: MeetingAnalytics
    let people: MeetingPeople
    let callID: String

    var body: some View {
        let p = participation
        VStack(alignment: .leading, spacing: 12) {
            Finding(MeetingFindings.participation(p))
            SplitBar(parts: [(fraction(p.spoke.count, p.invited.count), Palette.accentFill), (fraction(p.unheard.count, p.invited.count), Palette.bar)])
                .frame(maxWidth: 420)
            if !p.spoke.isEmpty { list("Spoke", p.spoke) }
            if !p.unheard.isEmpty {
                // With unnamed voices in the call, a person with no voice is not known to be silent.
                list(p.unnamedVoices == 0 ? "Did not speak" : "No voice with their name", p.unheard)
            }
            if !p.uninvited.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Subheading("Spoke with no invite")
                    FlowLayout(spacing: 14) {
                        ForEach(p.uninvited, id: \.self) { id in
                            SpeakerCell(speaker: people.speaker(forKey: id), name: people.name(forKey: id), callID: callID)
                        }
                    }
                    .font(.system(size: 12.5))
                }
            }
        }
    }

    private func list(_ title: String, _ attendees: [MeetingAnalytics.Participation.Attendee]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Subheading("\(title) · \(attendees.count)")
            FlowLayout(spacing: 14) {
                ForEach(attendees) { a in
                    HStack(spacing: 8) {
                        if let speaker = a.speaker.flatMap(people.speaker(forKey:)) {
                            Circle().fill(speaker.color).frame(width: 8, height: 8)
                        } else {
                            Circle().strokeBorder(Palette.ring, lineWidth: 1.5).frame(width: 8, height: 8)
                        }
                        PersonName(a.email ?? a.label, shown: a.label).fontWeight(.medium).lineLimit(1)
                    }
                }
            }
            .font(.system(size: 12.5))
        }
    }
}

// MARK: Outcomes

/// Decisions, action items by owner, and the owner's tasks that came from this call.
struct MeetingOutcomesSection: View {
    @EnvironmentObject var controller: AppController
    let outcomes: MeetingAnalytics.Outcomes
    let analytics: MeetingAnalytics
    let people: MeetingPeople
    let callID: String

    var body: some View {
        let o = outcomes
        VStack(alignment: .leading, spacing: 12) {
            Finding(MeetingFindings.outcomes(o))
            if !o.owners.isEmpty { owners }
            if !o.tasks.isEmpty { tasks }
        }
    }

    private var owners: some View {
        let peak = max(outcomes.owners.map(\.tasks.count).max() ?? 1, 1)
        return VStack(spacing: 0) {
            ForEach(outcomes.owners) { owner in
                HStack(spacing: 12) {
                    Group {
                        if let name = owner.name {
                            HStack(spacing: 8) {
                                if let speaker = owner.speaker.flatMap(people.speaker(forKey:)) {
                                    Circle().fill(speaker.color).frame(width: 8, height: 8)
                                } else {
                                    Circle().strokeBorder(Palette.ring, lineWidth: 1.5).frame(width: 8, height: 8)
                                }
                                PersonName(name).fontWeight(.medium).lineLimit(1)
                            }
                        } else {
                            Text("No owner").foregroundStyle(Palette.secondary).padding(.leading, 16)
                        }
                    }
                    .frame(width: 150, alignment: .leading)
                    Capsule().fill(Palette.fill)
                        .overlay(alignment: .leading) {
                            GeometryReader { g in Capsule().fill(Palette.bar).frame(width: max(8, g.size.width * CGFloat(owner.tasks.count) / CGFloat(peak))) }
                        }
                        .frame(height: 8)
                        .frame(maxWidth: 260)
                        .accessibilityHidden(true)
                    Text("\(owner.tasks.count) \(owner.tasks.count == 1 ? "item" : "items")").foregroundStyle(Palette.secondary)
                        .frame(width: 60, alignment: .trailing)
                    Spacer(minLength: 0)
                }
                .font(.system(size: 12.5)).monospacedDigit()
                .padding(.vertical, 6)
                .hairline()
                .help(owner.tasks.joined(separator: "\n"))
            }
        }
        .hairline(.top)
    }

    /// The owner's own tasks from this call, which the Tasks page keeps.
    private var tasks: some View {
        let done = outcomes.tasks.filter(\.done).count, all = outcomes.tasks.count
        return HStack(spacing: 8) {
            Text("\(all) of your tasks \(all == 1 ? "comes" : "come") from this call; \(done == all ? (all == 1 ? "it is done" : "all are done") : "\(done) done")")
                .font(.system(size: 12.5)).foregroundStyle(Palette.secondary)
            Button("Open in Tasks") {
                controller.taskToOpen = outcomes.tasks.first { !$0.done }?.id ?? outcomes.tasks.first?.id
                controller.open(.commitments)
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Palette.accent)
        }
    }
}

// MARK: Coach

/// The coach's rating of the meeting's worth and its scores, from the review of this call.
struct MeetingCoachSection: View {
    let coach: MeetingAnalytics.Coach
    let open: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Finding(MeetingFindings.coach(coach) ?? "The coach reviewed this call")
                Spacer(minLength: 12)
                Button("Open the review", action: open)
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.accent)
            }
            if let value = coach.value {
                Text(value.reason).font(.system(size: 12.5)).foregroundStyle(Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let card = coach.scorecard {
                VStack(spacing: 0) {
                    row("Overall", card.score)
                    ForEach(card.dimensions, id: \.self) { d in row(d.name, d.score) }
                }
                .hairline(.top)
            }
        }
    }

    private func row(_ title: String, _ score: Int) -> some View {
        HStack(spacing: 12) {
            Text(title).foregroundStyle(Palette.secondary).frame(width: 150, alignment: .leading)
            HStack(spacing: 3) {
                ForEach(1...5, id: \.self) { i in
                    Capsule().fill(i <= score ? (title == "Overall" ? Palette.accentFill : Palette.bar) : Palette.fill).frame(width: 26, height: 6)
                }
            }
            .accessibilityHidden(true)
            Text("\(score) of 5").foregroundStyle(Palette.ink)
            Spacer(minLength: 0)
        }
        .font(.system(size: 12.5)).monospacedDigit()
        .padding(.vertical, 6)
        .hairline()
        .accessibilityElement(children: .combine)
    }
}

// MARK: Screens

/// Who shared a screen, how many screens, and for how long.
struct MeetingScreensSection: View {
    let screens: MeetingAnalytics.Screens
    let long: Bool

    var body: some View {
        let finding = MeetingFindings.screens(screens)
        VStack(alignment: .leading, spacing: 12) {
            Group {
                if let subject = finding.subject {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        PersonName(subject).lineLimit(1).fixedSize()
                        Text(finding.text)
                    }
                } else {
                    Text(finding.text)
                }
            }
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(Palette.ink)
            .accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) {
                ForEach(screens.presenters) { p in
                    HStack(spacing: 12) {
                        Group {
                            if let name = p.name { PersonName(name).fontWeight(.medium) } else { Text("No name shown").foregroundStyle(Palette.secondary) }
                        }
                        .lineLimit(1)
                        .frame(minWidth: 130, maxWidth: .infinity, alignment: .leading)
                        Text("\(p.screens) \(p.screens == 1 ? "screen" : "screens")").frame(width: 84, alignment: .trailing)
                        Text("\(p.sessions) \(p.sessions == 1 ? "time" : "times")").foregroundStyle(Palette.secondary).frame(width: 64, alignment: .trailing)
                        Text(p.seconds >= 1 ? MeetingFindings.span(p.seconds) : "–").foregroundStyle(Palette.secondary).frame(width: 84, alignment: .trailing)
                        PlayAt(at: p.first, long: long).font(.system(size: 11.5)).frame(width: 56, alignment: .trailing)
                    }
                    .font(.system(size: 12.5)).monospacedDigit()
                    .padding(.vertical, 6)
                    .hairline()
                }
            }
            .hairline(.top)
            .help("The time runs from the first kept picture of a share to the last. A slide that never changed adds none.")
        }
    }
}

// MARK: Cost

/// What this call cost in API calls, by purpose, as the Analytics page's cost table.
struct MeetingCostSection: View {
    let cost: MeetingAnalytics.Cost

    private static let purposes: [UsageEvent.Purpose: String] = [
        .transcription: "Transcription", .live: "Live transcript", .summary: "Summary", .coach: "Coach review",
        .weeklyEmail: "Weekly email", .question: "Questions",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Finding("\(money(cost.total)) for this call")
            Text("Transcription \(money(cost.transcription)) · AI \(money(cost.ai))")
                .font(.system(size: 12)).foregroundStyle(Palette.secondary).padding(.top, 2)
            VStack(alignment: .leading, spacing: 5) {
                ForEach(cost.lines) { line in ValueRow(title: Self.purposes[line.purpose] ?? line.purpose.rawValue, value: money(line.dollars)) }
            }
            .padding(.top, 10)
            .hairline(.top)
            .padding(.top, 12)
            .frame(maxWidth: 320)
            if cost.estimated {
                Text("Estimated from the call's length and transcript size: this call is from before Mossad logged usage.")
                    .font(.system(size: 11.5)).foregroundStyle(Palette.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
            }
        }
    }
}
