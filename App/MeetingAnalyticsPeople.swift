import MossadCore
import SwiftUI

/// At most this many speakers have a row; a town hall's other voices are counted in one line.
private let shownSpeakers = 12

private extension MeetingAnalytics {
    var shown: [Speaker] { Array(speakers.prefix(shownSpeakers)) }

    /// A speaker's number against their history; nil with no history for it. `usually` is the range in words
    /// ("usually 30 to 40% in 1:1s with you"). `tip` is the tooltip: for a count, the rate of this call first,
    /// because the range is per hour and the cell shows a count.
    func usual(_ s: Speaker, _ metric: PersonMetric) -> (reading: Reading, usually: String, tip: String)? {
        guard let b = baselines.person(s.id), let context = b.context, let reading = b[metric], let usual = reading.usual else { return nil }
        let usually = MeetingFindings.usually(metric, usual, context: context)
        let perHour: Set<PersonMetric> = [.questionsPerHour, .cutInsPerHour, .cutOffsPerHour]
        let rate = perHour.contains(metric) ? "\(MeetingFindings.value(metric, reading.value)) an hour in this call; " : ""
        return (reading, usually, "\(sentenceCase(rate + usually)) (\(MeetingFindings.basis(usual)))")
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
        let trends = a.baselines.people.contains { !$0.shareTrend.isEmpty }
        // The lines under the names show only when at least one person has a range for their share.
        let ranges = a.baselines.people.contains { $0[.talkShare]?.usual != nil }
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
                        Marked(text: percentText(s.share), reading: usual?.reading, tip: usual?.tip).frame(width: 54, alignment: .trailing)
                        if trends {
                            Sparkline(values: a.baselines.person(s.id)?.shareTrend ?? [], minimumSpan: 0.2).frame(width: 52, height: 16)
                                .help("Their talk share in the earlier meetings; the dot is this call")
                        }
                    }
                    if ranges, !s.isUnknown, let line = usualLine(s, usual?.usually) {
                        Text(line)
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

    /// "Usually 30 to 40% in 1:1s with you", as the owner's example reads; with fewer than five meetings, "30 to
    /// 40% in 1:1s with you, in 3 meetings so far". No line when the person's history is of meetings of other
    /// sizes, which say nothing about a share.
    private func usualLine(_ s: MeetingAnalytics.Speaker, _ usually: String?) -> String? {
        if let usually { return sentenceCase(usually) }
        return analytics.baselines.person(s.id)?.context == nil ? "Not enough history yet" : nil
    }
}

/// The owner's share of this call next to their share in earlier meetings with each other person.
private struct OwnerWithRows: View {
    let analytics: MeetingAnalytics
    let people: MeetingPeople
    let callID: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Your share of this meeting, against meetings of this size with each person").font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.secondary)
                .padding(.bottom, 6)
            ForEach(analytics.baselines.ownerWith) { w in
                if let usual = w.reading.usual {
                    HStack(spacing: 12) {
                        SpeakerCell(speaker: people.speaker(forKey: w.id), name: analytics.speaker(w.id)?.name ?? "", callID: callID)
                            .frame(width: 150, alignment: .leading)
                        let usually = MeetingFindings.usually(.talkShare, usual, context: w.context)
                        Marked(text: percentText(w.reading.value), reading: w.reading, tip: "\(sentenceCase(usually)) (\(MeetingFindings.basis(usual)))")
                            .frame(width: 60, alignment: .leading)
                        Text(usually)
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

/// Turns per person, the pause before answers, silence, and the cut-ins between the owner and the others.
///
/// Who talked over whom can only be seen between the owner's microphone and the call (see `MeetingAnalytics.Flow`).
/// So the table says "Cut in on you" and "You cut in", the owner's row holds the totals, and a call on one track
/// has no such columns at all. A cell that cannot be measured shows a dash, never 0.
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
            // A narrow window drops the turns, the average turn, and the pause before answers before a name would squeeze.
            ViewThatFits(in: .horizontal) {
                table(columns(full: true))
                table(columns(full: false))
            }
            MoreVoices(analytics: a)
            if a.baselines.hasFirmHistory { MarkKey() }
            if let flow = a.flow {
                Text(flow.crossTalkMeasured
                     ? "Cut-ins and talking at once are measured between your microphone and the call. People in the call who talk over each other are not measured."
                     : "Cut-ins and talking at once are not measured in this call: every voice is on one audio track.")
                    .font(.system(size: 11.5)).foregroundStyle(Palette.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                FlowFigures(flow: flow, long: long)
                if flow.crossTalkMeasured, !flow.interruptions.isEmpty { CutIns(flow: flow, people: people, callID: callID, long: long) }
            }
        }
    }

    private func table(_ columns: [SpeakerTable.Column]) -> some View {
        SpeakerTable(speakers: analytics.shown, people: people, callID: callID, columns: columns)
            .frame(minWidth: SpeakerTable.width(columns))
    }

    private func columns(full: Bool) -> [SpeakerTable.Column] {
        let a = analytics
        var out: [SpeakerTable.Column] = []
        if full {
            out.append(SpeakerTable.Column("Turns", width: 44) { s in Text("\(s.turns)").foregroundStyle(Palette.secondary) })
            out.append(SpeakerTable.Column("Typical turn", width: 84) { s in
                let u = a.usual(s, .averageTurn)
                Marked(text: MeetingFindings.span(s.averageTurn), reading: u?.reading, tip: u?.tip)
            })
        }
        out.append(SpeakerTable.Column("Longest turn", width: 132) { s in
            if let turn = s.longestTurn {
                let u = a.usual(s, .longestTurn)
                HStack(spacing: 6) {
                    Marked(text: MeetingFindings.span(turn.seconds), reading: u?.reading, tip: u?.tip)
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
                    Marked(text: MeetingFindings.pause(gap), reading: u?.reading, tip: u?.tip)
                } else {
                    NoValue()
                }
            })
        }
        guard a.flow?.crossTalkMeasured == true else { return out }
        // With the owner in the call, both columns are about the owner and one other person; the owner's row is the total.
        let owned = a.owner != nil
        out.append(SpeakerTable.Column(owned ? "Cut in on you" : "Cut in", width: 88) { s in
            cutIns(s, onOwner: true, owned: owned)
        })
        out.append(SpeakerTable.Column(owned ? "You cut in" : "Was cut off", width: 72) { s in
            cutIns(s, onOwner: false, owned: owned)
        })
        return out
    }

    /// A count of cut-ins for one row. With the owner in the call: in a person's row, how often they cut in on the
    /// owner (`onOwner`) or the owner on them; in the owner's row, the totals. A voice on the owner's own
    /// microphone that is not the owner has nothing to show here.
    @ViewBuilder
    private func cutIns(_ s: MeetingAnalytics.Speaker, onOwner: Bool, owned: Bool) -> some View {
        let made = owned && s.isOwner ? !onOwner : onOwner
        let count = made ? s.interruptionsMade : s.interruptionsReceived
        if let count, !owned || s.isOwner || !s.id.hasPrefix("me:") {
            let u = analytics.usual(s, made ? .cutInsPerHour : .cutOffsPerHour)
            Marked(text: "\(count)", reading: u?.reading, tip: u?.tip)
        } else {
            NoValue().help("Not measured: this voice is on your microphone")
        }
    }
}

/// The pause before answers and silence, and, where it can be measured, how often the owner and someone in the
/// call talked at once.
private struct FlowFigures: View {
    let flow: MeetingAnalytics.Flow
    let long: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            if flow.crossTalkMeasured {
                SmallFigure(value: "\(flow.overlapCount)",
                            label: flow.overlapCount == 0 ? "times you and someone in the call talked at once"
                                : "times you and someone in the call talked at once, \(MeetingFindings.span(flow.overlapSeconds)) in all")
            }
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
        .help("Talking at once is one second or more of two voices together. Silence is every pause of 3 seconds or more between the first word and the last.")
    }
}

/// "Sam Carter cut in on Dana Lee 3×", with the moments to play. Always the owner's microphone and the call.
private struct CutIns: View {
    let flow: MeetingAnalytics.Flow
    let people: MeetingPeople
    let callID: String
    let long: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Cut-ins between you and others").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.secondary)
                .padding(.bottom, 6)
            ForEach(flow.interruptions.prefix(6)) { cut in
                HStack(spacing: 8) {
                    name(cut.by)
                    Text("cut in on").foregroundStyle(Palette.secondary)
                    name(cut.of)
                    Text("\(cut.count)×").foregroundStyle(Palette.secondary)
                    Spacer(minLength: 8)
                    ForEach(Array(cut.moments.prefix(4).enumerated()), id: \.offset) { _, at in PlayAt(at: at, long: long).font(.system(size: 11.5)) }
                }
                .font(.system(size: 12.5)).monospacedDigit()
                .lineLimit(1)
                .padding(.vertical, 6)
                .hairline(.top)
            }
        }
        .help("Someone cut in when they began at least a second after the other person, said three words or more, talked along for a second or more, and kept talking for 3 seconds or more after the other person stopped.")
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
                Marked(text: "\(Int(pace.rounded()))", reading: u?.reading, tip: u?.tip)
            } else {
                NoValue().help("Too little speech to measure a pace")
            }
        })
        out.append(SpeakerTable.Column("Fillers a minute", width: 104) { s in
            if let fillers = s.fillersPerMinute {
                let u = a.usual(s, .fillersPerMinute)
                Marked(text: String(format: "%.1f", fillers), reading: u?.reading, tip: u?.tip)
            } else {
                NoValue()
            }
        })
        out.append(SpeakerTable.Column("Questions", width: 76) { s in
            let u = a.usual(s, .questionsPerHour)
            Marked(text: "\(s.questions)", reading: u?.reading, tip: u?.tip)
        })
        return out
    }
}
