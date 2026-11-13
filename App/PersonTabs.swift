import MossadCore
import SwiftUI

/// The person page's Overview: how to present to them (or the coach's older read), their numbers, and the two of
/// you together. The owner's own page has the numbers and who they meet with most.
struct PersonOverviewTab: View {
    @EnvironmentObject var controller: AppController
    let profile: VoiceProfile
    let stats: PersonStats
    let relation: PersonRelation?
    let select: (String) -> Void
    @State private var refreshing = false

    private var first: String { profile.name.split(separator: " ").first.map(String.init) ?? profile.name }
    /// By the person's id when the people store has one, so the read stays with the person through a new name.
    private var brief: PersonBrief? { controller.shownCoachProfile.note(on: profile.name, people: controller.shownCoachPeople)?.value.brief }
    /// How the person thinks: shown traits and the card, built by code. Nil for the owner and until a trait shows.
    private var read: PersonaSummary? { profile.isOwner ? nil : controller.persona(of: profile.name) }
    private var personID: String? { controller.personID(of: profile.name) }

    var body: some View {
        LabelColumnStack(spacing: Rhythm.sectionGap) {
            if !profile.isOwner, let personID {
                PersonNextTimeSection(personID: personID, name: profile.name, inColumn: true)
            }
            if !profile.isOwner {
                if read != nil || brief != nil, controller.personaCovered(personID) {
                    // A colleague must not read this on a shared screen.
                    LabelColumn(label: "The coach’s read") { PersonaCoverRow { controller.uncover(personID) } }
                } else if let read, let card = read.card {
                    PersonaCardView(card: card, first: first)
                } else {
                    coachRead
                    if let brief {
                        ForEach(brief.sections, id: \.title) { section in
                            LabelColumn(label: section.title) { prose(section.points) }
                        }
                    }
                }
            }
            LabelColumn(label: "By the numbers") {
                FigureRow(figures: [
                    (stats.totalTalk > 0 ? talkText(stats.totalTalk) : "None", profile.isOwner ? "total talk time" : "\(first) talking"),
                    (stats.averageShare.map(percent) ?? "None", "average talk share"),
                    ("\(stats.actionItems.count)", "action items"),
                    (stats.firstHeard.map { $0.formatted(.dateTime.month(.abbreviated).year()) } ?? "None", "first heard"),
                ])
            }
            if !profile.isOwner, let r = relation, r.calls > 0 {
                LabelColumn(label: "Together") {
                    FigureRow(figures: [
                        (r.usualSlot.map(slotText) ?? "None", "usual time"),
                        (r.oneOnOne?.share.map(percent) ?? "None", "your talk share one to one"),
                        (r.group?.share.map(percent) ?? "None", "your talk share in groups"),
                        ("\(r.myCommitments.filter { $0.done == nil }.count)", "open tasks for \(first)"),
                    ])
                }
                if !r.topics.isEmpty {
                    LabelColumn(label: "Topics", labelTopPadding: 4) {
                        FlowLayout(spacing: 6) {
                            ForEach(r.topics, id: \.self) { t in
                                Button { controller.showTag(t) } label: { TagChip(text: t) }
                                    .buttonStyle(.plain)
                                    .help("Meetings about \(t)")
                            }
                        }
                        .frame(maxWidth: Rhythm.measure, alignment: .leading)
                    }
                }
            }
            if !stats.oftenWith.isEmpty {
                LabelColumn(label: "Often with") { oftenWith }
            }
        }
    }

    // MARK: The coach's read

    private var coachRead: some View {
        LabelColumn(label: "The coach’s read") {
            VStack(alignment: .leading, spacing: Rhythm.pairGap) {
                if let brief {
                    Text(brief.headline)
                        .font(.system(size: Rhythm.leadSize, weight: .medium)).lineSpacing(Rhythm.secondaryLineGap)
                        .foregroundStyle(Palette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    HStack(spacing: Space.s) {
                        Text("From \(brief.calls) \(brief.calls == 1 ? "call" : "calls") · updated \(brief.updated.formatted(.relative(presentation: .named)))")
                        refreshButton
                    }
                    .font(.system(size: Rhythm.secondarySize)).foregroundStyle(Palette.tertiary)
                } else {
                    Text(stats.meetings.count >= 2
                         ? "The coach has not read the calls with \(first) yet."
                         : "After two calls with \(first), the coach writes how to work with them: their goals, how to get through to them, and how they communicate.")
                        .font(.system(size: Rhythm.bodySize)).lineSpacing(Rhythm.secondaryLineGap)
                        .foregroundStyle(Palette.secondary)
                        .frame(maxWidth: Rhythm.measure, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                    if stats.meetings.count >= 2 { refreshButton.font(.system(size: Rhythm.secondarySize)) }
                }
            }
        }
    }

    @ViewBuilder
    private var refreshButton: some View {
        if stats.meetings.count >= 2 {
            if refreshing {
                Text("Reading…").foregroundStyle(Palette.tertiary)
            } else {
                Button(brief == nil ? "Read the calls now" : "Read again") {
                    refreshing = true
                    Task {
                        await controller.writePersonBriefs([profile.name])
                        refreshing = false
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(Palette.accent)
                .help("Read the calls with \(first) again")
            }
        }
    }

    /// The section's points as one paragraph; a point from a call ends in a quiet link that opens it.
    private func prose(_ points: [PersonBrief.Point]) -> some View {
        var text = AttributedString()
        for (i, point) in points.enumerated() {
            if i > 0 { text += AttributedString(" ") }
            text += AttributedString(point.text)
            if let id = point.callID, let url = URL(string: "mossad://call/\(id)") {
                var link = AttributedString(" ↗")
                link.link = url
                link.foregroundColor = Palette.tertiary
                text += link
            }
        }
        return Text(text)
            .font(.system(size: Rhythm.bodySize)).lineSpacing(Rhythm.secondaryLineGap)
            .foregroundStyle(Palette.ink)
            .tint(Palette.tertiary)
            .frame(maxWidth: Rhythm.measure, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    /// "Dana Lee 5 · Sam Park 4": names in ink as buttons, the counts quiet.
    private var oftenWith: some View {
        FlowLayout(spacing: 0) {
            ForEach(Array(stats.oftenWith.prefix(8).enumerated()), id: \.element.name) { i, co in
                HStack(spacing: 0) {
                    if i > 0 { Text(" · ").foregroundStyle(Palette.secondary) }
                    Button(co.name) { select(co.name) }.buttonStyle(.plain).foregroundStyle(Palette.ink)
                    Text(" \(co.meetings)").foregroundStyle(Palette.secondary).monospacedDigit()
                }
            }
        }
        .readingText()
        .frame(maxWidth: Rhythm.measure, alignment: .leading)
    }

    private func slotText(_ s: PersonRelation.Slot) -> String {
        let day = Calendar.current.shortWeekdaySymbols[s.weekday - 1]
        let time = Calendar.current.date(bySettingHour: s.hour, minute: 0, second: 0, of: Date()).map { $0.formatted(.dateTime.hour()) } ?? "\(s.hour)"
        return "\(day) \(time)"
    }
}

/// What the coach knows about the person: what the owner confirmed, how they think with each trait's confidence,
/// and what the owner blocked for good, with Undo.
struct PersonKnowledgeTab: View {
    @EnvironmentObject var controller: AppController
    let profile: VoiceProfile
    let calls: Int

    private var first: String { profile.name.split(separator: " ").first.map(String.init) ?? profile.name }
    private var personID: String? { controller.personID(of: profile.name) }
    private var read: PersonaSummary? { controller.persona(of: profile.name) }
    private var keepsRead: Bool { controller.keepsRead(profile.name) }

    /// What the owner confirmed about this person on a card, by the person's id; by the label of the coach's note
    /// when the people store is off.
    private var confirmed: [CoachFact] {
        let coach = controller.shownCoachProfile, saved = controller.personaPeople
        let byID = saved.id(of: profile.name).map { coach.learnings(about: $0, people: saved) } ?? []
        return byID.isEmpty ? coach.learnings(named: profile.name) : byID
    }

    /// "Never again" on a card about this person.
    private var blocked: [FindingAnswer] {
        guard let personID else { return [] }
        let saved = controller.personaPeople
        return controller.shownCoachProfile.neverAgain.filter { a in a.person.map { saved.canonical($0) == personID || $0 == personID } ?? false }
    }

    var body: some View {
        LabelColumnStack(spacing: Rhythm.sectionGap) {
            if controller.personaCovered(personID), read != nil {
                LabelColumn(label: "How they think") { PersonaCoverRow { controller.uncover(personID) } }
            } else if confirmed.isEmpty, read?.traits.isEmpty ?? true, blocked.isEmpty {
                EmptyState(symbol: "brain", title: "Nothing known yet",
                           message: keepsRead ? PersonaCard.needsMore(first: first, calls: calls) : "You keep no read on \(first). The coach learns nothing about them.",
                           action: keepsRead || personID == nil || !controller.personasOn ? nil : ("Keep a read", { controller.setKeepsRead(profile.name, true) }))
                    .frame(maxWidth: .infinity).padding(.top, Space.xl)
            } else {
                if !confirmed.isEmpty {
                    LabelColumn(label: "You confirmed") {
                        VStack(alignment: .leading, spacing: Rhythm.itemGap) {
                            ForEach(confirmed) { fact in
                                Label { Text(fact.text).fixedSize(horizontal: false, vertical: true) } icon: {
                                    Image(systemName: "checkmark").font(.system(size: Rhythm.noteSize, weight: .semibold)).foregroundStyle(Palette.okText)
                                }
                                .font(.system(size: Rhythm.bodySize)).foregroundStyle(Palette.ink)
                            }
                        }
                    }
                }
                if let read, !read.traits.isEmpty {
                    PersonaTraitsView(read: read, date: { id in controller.meetings.first { $0.id == id }?.start })
                } else if keepsRead {
                    LabelColumn(label: "How they think") {
                        Text(PersonaCard.needsMore(first: first, calls: calls))
                            .font(.system(size: Rhythm.bodySize)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if !blocked.isEmpty {
                    LabelColumn(label: "Never again") {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(blocked) { a in
                                HStack(alignment: .firstTextBaseline, spacing: Space.m) {
                                    Text(a.text).font(.system(size: Rhythm.bodySize)).foregroundStyle(Palette.ink)
                                        .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                                    Button("Undo") { controller.allowFindingAgain(a.id) }
                                        .buttonStyle(SettingsTextButtonStyle(color: Palette.accent, weight: .semibold))
                                        .accessibilityLabel("Undo never again: \(a.text)")
                                }
                                .padding(.vertical, 6)
                            }
                        }
                        .frame(maxWidth: Rhythm.measure, alignment: .leading)
                    }
                }
            }
            LabelColumn(label: "") {
                Button("All the coach knows") { controller.open(coach: .knowledge) }
                    .buttonStyle(SettingsTextButtonStyle(color: Palette.accent))
            }
        }
    }
}

/// The voice samples Mossad keeps for the person, where each came from, and the promise that they stay on this Mac.
struct PersonVoiceTab: View {
    @EnvironmentObject var controller: AppController
    let profile: VoiceProfile
    let deleteAll: () -> Void

    private var first: String { profile.name.split(separator: " ").first.map(String.init) ?? profile.name }

    /// The samples with where they came from, newest first; nil when the samples' file is not there.
    private var samples: [VoiceSample]? {
        controller.voiceSamples(of: profile)?.sorted { ($0.recorded ?? $0.learned) > ($1.recorded ?? $1.learned) }
    }

    var body: some View {
        LabelColumnStack(spacing: Rhythm.sectionGap) {
            let list = samples
            if profile.embeddings.isEmpty, list?.isEmpty ?? true {
                EmptyState(symbol: "waveform", title: "No voice sample yet",
                           message: "Name \(first)’s voice in a meeting and Mossad recognizes it in later calls.")
                    .frame(maxWidth: .infinity).padding(.top, Space.xl)
            } else {
                LabelColumn(label: "Voice samples") {
                    VStack(alignment: .leading, spacing: Rhythm.itemGap) {
                        Text("\(profile.embeddings.count) \(profile.embeddings.count == 1 ? "sample" : "samples"). Mossad recognizes \(profile.isOwner ? "you" : first) by voice in later calls.")
                            .font(.system(size: Rhythm.bodySize)).foregroundStyle(Palette.ink)
                        if let list, !list.isEmpty { rows(list) }
                    }
                }
            }
            LabelColumn(label: "Privacy") {
                VStack(alignment: .leading, spacing: Space.s) {
                    HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                        IconImage(.lock, size: 12)
                        Text("Voice fingerprints are biometric data. They stay on this Mac in the Voices folder and are never uploaded.")
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Button("Delete every person’s saved voices…", action: deleteAll)
                        .buttonStyle(.plain).fontWeight(.medium).foregroundStyle(Palette.recording)
                }
                .font(.system(size: Rhythm.bodySize)).foregroundStyle(Palette.secondary)
                .frame(maxWidth: Rhythm.measure, alignment: .leading)
            }
        }
    }

    private func rows(_ list: [VoiceSample]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 0) {
            ForEach(Array(list.enumerated()), id: \.element.id) { i, s in
                let call = s.callID.flatMap { id in controller.meetings.first { $0.id == id } }
                GridRow {
                    Text((s.recorded ?? s.learned).formatted(.dateTime.month(.abbreviated).day().year()))
                        .foregroundStyle(Palette.secondary).monospacedDigit()
                    Group {
                        if let call {
                            Button(call.title) { controller.openMeeting(call.id) }.buttonStyle(.plain).foregroundStyle(Palette.ink).lineLimit(1)
                        } else {
                            Text(s.callID == nil ? "No call kept" : "A deleted meeting").foregroundStyle(Palette.tertiary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text(s.origin.words).foregroundStyle(Palette.secondary).lineLimit(1).fixedSize()
                    Text([s.seconds.map { "\(Int($0.rounded())) s" }, VoiceSample.qualityWord(s.quality)].compactMap { $0 }.joined(separator: " · "))
                        .foregroundStyle(Palette.secondary).monospacedDigit()
                        .help("The length of speech in the sample, and how clear it is")
                }
                .padding(.vertical, 6)
                if i < list.count - 1 { GridRow { Hairline().gridCellColumns(4) } }
            }
        }
        .font(.system(size: Rhythm.bodySize))
        .frame(maxWidth: Rhythm.measure, alignment: .leading)
    }
}
