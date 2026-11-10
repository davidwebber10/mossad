import MossadCore
import SwiftUI

/// At most this many speakers have a row; a town hall's other voices are counted in one line.
private let shownSpeakers = 12

private extension MeetingAnalytics {
    var shown: [Speaker] { Array(speakers.prefix(shownSpeakers)) }

    /// A speaker's number against their usual, and the words for the range; nil with no history for it.
    func usual(_ s: Speaker, _ metric: PersonMetric) -> (reading: Reading, usually: String)? {
        guard let b = baselines.person(s.id), let context = b.context, let reading = b[metric], let usual = reading.usual else { return nil }
        return (reading, MeetingFindings.usually(metric, usual, context: context))
    }
}

/// "+4 more voices" under a table that does not show everyone.
private struct MoreVoices: View {
    let analytics: MeetingAnalytics

    var body: some View {
        let rest = analytics.speakers.dropFirst(shownSpeakers)
        if !rest.isEmpty {
            let share = rest.reduce(0) { $0 + $1.share }
            Text("+\(rest.count) more \(rest.count == 1 ? "voice" : "voices") with \(percentText(share)) of the talk")
                .font(.system(size: 11.5)).foregroundStyle(Palette.tertiary)
        }
    }
}

// MARK: Talk time

/// Who talked, for how long, and what is usual for each person; the owner against the rest; who held the floor
/// across the call.
struct TalkTimeSection: View {
    let analytics: MeetingAnalytics
    let people: MeetingPeople
    let callID: String

    var body: some View {
        let a = analytics
        VStack(alignment: .leading, spacing: 12) {
            if let finding = MeetingFindings.talk(a) {
                SpeakerFinding(speaker: finding.subject.flatMap(people.speaker(forKey:)), callID: callID, text: finding.text)
            }
            if let owner = a.owner, a.speakers.count > 1, owner.seconds > 0 {
                HStack(spacing: 12) {
                    Text("You against the rest").font(.system(size: 12)).foregroundStyle(Palette.secondary).fixedSize()
                    BalanceBar(mine: owner.seconds, theirs: a.speechSeconds - owner.seconds).frame(maxWidth: 260)
                    Text("\(MeetingFindings.span(owner.seconds)) of \(MeetingFindings.span(a.speechSeconds))")
                        .font(.system(size: 12)).foregroundStyle(Palette.secondary).monospacedDigit().lineLimit(1)
                }
            }
            rows
            MoreVoices(analytics: a)
            if !a.floor.isEmpty { FloorStrip(analytics: a, people: people) }
            if !a.baselines.ownerWith.isEmpty { OwnerWithRows(analytics: a, people: people, callID: callID) }
        }
    }

    private var rows: some View {
        let a = analytics
        let peak = max(a.speakers.map(\.seconds).max() ?? 1, 1)
        let trends = a.baselines.people.contains { $0.shareTrend.count >= MeetingAnalytics.Trends.minimumPoints }
        return VStack(spacing: 0) {
            ForEach(a.shown) { s in
                let speaker = people.speaker(forKey: s.id)
                let usual = a.usual(s, .talkShare)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 12) {
                        SpeakerCell(speaker: speaker, name: s.name, callID: callID).frame(width: 150, alignment: .leading)
                        Capsule().fill(Palette.fill)
                            .overlay(alignment: .leading) {
                                GeometryReader { g in Capsule().fill(speaker?.color ?? Palette.bar).frame(width: max(6, g.size.width * s.seconds / peak)) }
                            }
                            .frame(height: 8)
                            .accessibilityHidden(true)
                        Text(MeetingFindings.span(s.seconds)).foregroundStyle(Palette.secondary).lineLimit(1).frame(width: 82, alignment: .trailing)
                        Marked(text: percentText(s.share), reading: usual?.reading, usually: usual?.usually).frame(width: 54, alignment: .trailing)
                        if trends {
                            Sparkline(values: a.baselines.person(s.id)?.shareTrend ?? []).frame(width: 52, height: 16)
                                .help("Their talk share in the last meetings; the dot is this call")
                        }
                    }
                    if a.baselines.hasHistory, !s.isUnknown {
                        Text(usualLine(s, usual))
                            .font(.system(size: 11.5))
                            .foregroundStyle(usual?.reading.stoodOut == true ? Palette.ink : Palette.tertiary)
                            .padding(.leading, 16)
                    }
                }
                .font(.system(size: 12.5)).monospacedDigit()
                .padding(.vertical, 7)
                .hairline()
            }
        }
        .hairline(.top)
    }

    /// "Usually 30 to 40% in 1:1s with you", as the owner's example reads.
    private func usualLine(_ s: MeetingAnalytics.Speaker, _ usual: (reading: MeetingAnalytics.Reading, usually: String)?) -> String {
        guard let usual else { return "Not enough history yet" }
        return usual.usually.prefix(1).uppercased() + usual.usually.dropFirst()
    }
}

/// The owner's share of this call next to their share in earlier meetings with each other person.
private struct OwnerWithRows: View {
    let analytics: MeetingAnalytics
    let people: MeetingPeople
    let callID: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Your share next to each person").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.secondary)
                .padding(.bottom, 6)
            ForEach(analytics.baselines.ownerWith) { w in
                if let usual = w.reading.usual {
                    HStack(spacing: 12) {
                        SpeakerCell(speaker: people.speaker(forKey: w.id), name: analytics.speaker(w.id)?.name ?? "", callID: callID)
                            .frame(width: 150, alignment: .leading)
                        Marked(text: percentText(w.reading.value), reading: w.reading, usually: "usually \(MeetingFindings.range(.talkShare, usual)) \(w.context.label)")
                            .frame(width: 60, alignment: .leading)
                        Text("usually \(MeetingFindings.range(.talkShare, usual)) \(w.context.label)")
                            .foregroundStyle(w.reading.stoodOut ? Palette.ink : Palette.tertiary).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 12.5)).monospacedDigit()
                    .padding(.vertical, 6)
                    .hairline(.top)
                }
            }
        }
        .padding(.top, 4)
    }
}

/// One strip for the whole call, colored by who talked most in each stretch. Click to play from there.
private struct FloorStrip: View {
    @Environment(\.momentPlayer) private var player
    let analytics: MeetingAnalytics
    let people: MeetingPeople

    var body: some View {
        let a = analytics
        VStack(alignment: .leading, spacing: 4) {
            Text("Who held the floor").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.secondary)
            GeometryReader { g in
                Canvas { context, size in
                    context.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 3), with: .color(Palette.fill))
                    for block in a.floor {
                        let x = size.width * block.start / a.duration, w = size.width * (block.end - block.start) / a.duration
                        let bar = CGRect(x: x, y: 1.5, width: max(w - 1, 1), height: size.height - 3)
                        context.fill(Path(roundedRect: bar, cornerRadius: 1.5), with: .color(people.color(forKey: block.speaker)))
                    }
                }
                .contentShape(Rectangle())
                .gesture(SpatialTapGesture().onEnded { tap in
                    player?.play(min(max(0, tap.location.x / max(g.size.width, 1)), 1) * a.duration)
                })
            }
            .frame(height: 14)
            .help(player == nil ? "Who talked most in each stretch of the call" : "Who talked most in each stretch of the call. Click to play from there.")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Who held the floor across the call")
            HStack {
                Text(clock(0))
                Spacer()
                Text(a.duration >= 3600 ? longClock(a.duration) : clock(a.duration))
            }
            .font(.system(size: 10.5)).monospacedDigit().foregroundStyle(Palette.tertiary)
            .accessibilityHidden(true)
        }
        .padding(.top, 4)
    }
}

// MARK: Conversation flow

/// Turns per person, who cut in on whom, pauses before answers, and silence.
struct FlowSection: View {
    let analytics: MeetingAnalytics
    let people: MeetingPeople
    let callID: String
    let long: Bool

    var body: some View {
        let a = analytics
        VStack(alignment: .leading, spacing: 12) {
            if let finding = MeetingFindings.flow(a) {
                SpeakerFinding(speaker: finding.subject.flatMap(people.speaker(forKey:)), callID: callID, text: finding.text)
            }
            // A narrow window drops the average turn and the pause before answers before a name would squeeze.
            ViewThatFits(in: .horizontal) {
                table(columns(full: true))
                table(columns(full: false))
            }
            MoreVoices(analytics: a)
            if a.baselines.hasHistory { MarkKey() }
            if let flow = a.flow {
                FlowFigures(flow: flow, long: long)
                if !flow.interruptions.isEmpty { CutIns(flow: flow, people: people, callID: callID, long: long) }
            }
        }
    }

    private func table(_ columns: [SpeakerTable.Column]) -> some View {
        SpeakerTable(speakers: analytics.shown, people: people, callID: callID, columns: columns)
            .frame(minWidth: SpeakerTable.width(columns))
    }

    private func columns(full: Bool) -> [SpeakerTable.Column] {
        let a = analytics
        var out = [SpeakerTable.Column("Turns", width: 44) { s in Text("\(s.turns)").foregroundStyle(Palette.secondary) }]
        if full {
            out.append(SpeakerTable.Column("Average turn", width: 84) { s in
                let u = a.usual(s, .averageTurn)
                Marked(text: MeetingFindings.span(s.averageTurn), reading: u?.reading, usually: u?.usually)
            })
        }
        out.append(SpeakerTable.Column("Longest turn", width: 132) { s in
            if let turn = s.longestTurn {
                let u = a.usual(s, .longestTurn)
                HStack(spacing: 6) {
                    Marked(text: MeetingFindings.span(turn.seconds), reading: u?.reading, usually: u?.usually)
                    PlayAt(at: turn.start, long: long).font(.system(size: 11.5))
                }
            } else {
                NoValue()
            }
        })
        if full {
            out.append(SpeakerTable.Column("Answers after", width: 84) { s in
                if let gap = s.medianResponse {
                    let u = a.usual(s, .responseGap)
                    Marked(text: MeetingFindings.pause(gap), reading: u?.reading, usually: u?.usually)
                } else {
                    NoValue()
                }
            })
        }
        out.append(SpeakerTable.Column("Cut in", width: 50) { s in
            let u = a.usual(s, .cutInsPerHour)
            Marked(text: "\(s.interruptionsMade)", reading: u?.reading, usually: u?.usually)
        })
        out.append(SpeakerTable.Column("Was cut off", width: 68) { s in
            let u = a.usual(s, .cutOffsPerHour)
            Marked(text: "\(s.interruptionsReceived)", reading: u?.reading, usually: u?.usually)
        })
        return out
    }
}

/// Overlaps, the pause before answers, and silence, as the Analytics page's small figures.
private struct FlowFigures: View {
    let flow: MeetingAnalytics.Flow
    let long: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            SmallFigure(value: "\(flow.overlapCount)",
                        label: flow.overlapCount == 0 ? "times two people talked at once" : "times two people talked at once, \(MeetingFindings.span(flow.overlapSeconds)) in all")
            SmallFigure(value: flow.medianResponse.map(MeetingFindings.pause) ?? "–", label: "before an answer, at the median")
            SmallFigure(value: MeetingFindings.span(flow.silenceSeconds), label: "of silence, \(percentText(flow.silenceShare)) of the call")
            if let longest = flow.longestSilence {
                VStack(alignment: .leading, spacing: 2) {
                    SmallFigure(value: MeetingFindings.span(longest.seconds), label: "the longest silence")
                    PlayAt(at: longest.start, long: long, icon: true).font(.system(size: 11.5, weight: .semibold))
                }
            }
        }
        .padding(.top, 12)
        .hairline(.top)
        .help("An overlap is one second or more of two people talking at once. Silence is every pause of 3 seconds or more between the first word and the last.")
    }
}

/// "Sam Carter cut in on Dana Lee 3×", with the moments to play.
private struct CutIns: View {
    let flow: MeetingAnalytics.Flow
    let people: MeetingPeople
    let callID: String
    let long: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Who cut in on whom").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.secondary)
                .padding(.bottom, 6)
            ForEach(flow.interruptions.prefix(6)) { cut in
                HStack(spacing: 8) {
                    name(cut.by)
                    Text("cut in on").foregroundStyle(Palette.secondary)
                    name(cut.of)
                    Text("\(cut.count)×").foregroundStyle(Palette.secondary)
                    Spacer(minLength: 8)
                    ForEach(cut.moments.prefix(4), id: \.self) { at in PlayAt(at: at, long: long).font(.system(size: 11.5)) }
                }
                .font(.system(size: 12.5)).monospacedDigit()
                .lineLimit(1)
                .padding(.vertical, 6)
                .hairline(.top)
            }
        }
        .help("Someone cut in when they began at least a second after the other person, said three words or more, talked along for a second or more, and kept talking after the other person stopped.")
    }

    private func name(_ id: String) -> some View {
        SpeakerCell(speaker: people.speaker(forKey: id), name: people.name(forKey: id), callID: callID)
    }
}

// MARK: Delivery

/// Pace, filler words, and questions per person, by the coach's rules.
struct DeliverySection: View {
    let analytics: MeetingAnalytics
    let people: MeetingPeople
    let callID: String

    var body: some View {
        let a = analytics
        VStack(alignment: .leading, spacing: 12) {
            if let finding = MeetingFindings.delivery(a) {
                SpeakerFinding(speaker: finding.subject.flatMap(people.speaker(forKey:)), callID: callID, text: finding.text)
            }
            ViewThatFits(in: .horizontal) {
                table(columns(full: true))
                table(columns(full: false))
            }
            MoreVoices(analytics: a)
        }
    }

    private func table(_ columns: [SpeakerTable.Column]) -> some View {
        SpeakerTable(speakers: analytics.shown, people: people, callID: callID, columns: columns)
            .frame(minWidth: SpeakerTable.width(columns))
    }

    private func columns(full: Bool) -> [SpeakerTable.Column] {
        let a = analytics
        var out: [SpeakerTable.Column] = []
        if full { out.append(SpeakerTable.Column("Words", width: 60) { s in Text(s.words.formatted()).foregroundStyle(Palette.secondary) }) }
        out.append(SpeakerTable.Column("Words a minute", width: 104) { s in
            if let pace = s.wordsPerMinute {
                let u = a.usual(s, .wordsPerMinute)
                Marked(text: "\(Int(pace.rounded()))", reading: u?.reading, usually: u?.usually)
            } else {
                NoValue().help("Too little speech to measure a pace")
            }
        })
        out.append(SpeakerTable.Column("Fillers a minute", width: 104) { s in
            if let fillers = s.fillersPerMinute {
                let u = a.usual(s, .fillersPerMinute)
                Marked(text: String(format: "%.1f", fillers), reading: u?.reading, usually: u?.usually)
            } else {
                NoValue()
            }
        })
        out.append(SpeakerTable.Column("Questions", width: 76) { s in
            let u = a.usual(s, .questionsPerHour)
            Marked(text: "\(s.questions)", reading: u?.reading, usually: u?.usually)
        })
        return out
    }
}
