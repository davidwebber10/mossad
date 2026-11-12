import AppKit
import MossadCore
import SwiftUI

/// One choice in the flyout: its words and how many meetings it has. On, it takes the accent on its tint; with no
/// meeting to give it is dimmed and does nothing, unless it is on and can be turned off.
struct FilterChip: View {
    static let height: CGFloat = 24

    let text: String
    /// Nil for a chip that opens something ("Custom") rather than counting meetings.
    let count: Int?
    let on: Bool
    var platform: Platform?
    /// What the count counts, one and many.
    var noun = FilterNoun.meetings
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let empty = count == 0 && !on
        Button(action: action) {
            HStack(spacing: 6) {
                if let platform { PlatformDot(platform: platform, size: 7) }
                // The width of the heavier weight always, so turning a chip on never moves its neighbors.
                Text(text).fontWeight(.medium).hidden()
                    .overlay { Text(text).fontWeight(on ? .medium : .regular).fixedSize() }
                if let count {
                    Text("\(count)").font(.system(size: 11)).monospacedDigit()
                        .foregroundStyle(on ? Palette.accent.opacity(0.8) : Palette.secondary)
                        .contentTransition(.numericText())
                }
            }
            .lineLimit(1)
            .foregroundStyle(on ? Palette.accent : Palette.ink)
            .padding(.horizontal, 9)
            .frame(height: Self.height)
            .background(on ? Palette.accentTint : hovering ? Palette.selection : Palette.fill, in: Capsule())
            .overlay { if on { Capsule().strokeBorder(Palette.accent.opacity(0.3), lineWidth: 1) } }
            .contentShape(Capsule())
            .contentShape(.focusEffect, Capsule())
        }
        .buttonStyle(.plain)
        .disabled(empty)
        .opacity(empty ? 0.42 : 1)
        .onHover { hovering = $0 }
        .accessibilityLabel(text)
        .accessibilityValue(count.map { noun.count($0) } ?? "")
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// What a filter's counts count: meetings in the Meetings filter, recurring meetings in the Recurring one.
struct FilterNoun {
    let one: String
    let many: String

    static let meetings = FilterNoun(one: "meeting", many: "meetings")
    static let series = FilterNoun(one: "recurring meeting", many: "recurring meetings")

    func count(_ n: Int) -> String { "\(n) \(n == 1 ? one : many)" }
    /// "Meetings", "Recurring meetings".
    var title: String { many.prefix(1).uppercased() + many.dropFirst() }
}

// MARK: People

/// Who was in the meeting: a field to search, then everyone with a mark, a name, and a count, the person in the
/// most meetings first. The arrow keys move through the list from the field and Return chooses.
struct FilterPeoplePicker: View {
    /// Everyone with their counts, the one in the most first.
    let people: [MeetingFacets.Person]
    let chosen: [MeetingFilter.Who]
    @Binding var mode: MeetingFilter.PeopleMode
    var noun = FilterNoun.meetings
    let toggle: (MeetingFilter.Who) -> Void
    @State private var query = ""
    @State private var highlighted: String?
    @FocusState private var searching: Bool

    private var shown: [MeetingFacets.Person] { MeetingFacets.people(people, matching: query) }

    var body: some View {
        let people = shown
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                // Not the People page's count, which has only the meetings where the person spoke.
                HStack(spacing: 6) {
                    Text("People").textRole(.label).foregroundStyle(Palette.secondary)
                    Text("spoke or invited").font(.system(size: 11)).foregroundStyle(Palette.tertiary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 4)
                if chosen.count > 1 { modePicker.transition(.opacity) }
            }
            .frame(height: 20)
            .padding(EdgeInsets(top: 12, leading: 16, bottom: 8, trailing: 12))
            field.padding(.horizontal, 12)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(people) { p in
                            PersonRow(person: p, on: chosen.contains(p.who), highlighted: highlighted == p.id, noun: noun) { choose(p.who) }
                                .id(p.id)
                        }
                    }
                    .padding(.horizontal, 8).padding(.top, 8).padding(.bottom, 10)
                }
                .onChange(of: highlighted) { _, id in if let id { proxy.scrollTo(id) } }
            }
            .overlay(alignment: .top) {
                if people.isEmpty {
                    Text(query.isEmpty ? "No named people yet" : "No one matches “\(query)”")
                        .foregroundStyle(Palette.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16).padding(.top, 28)
                }
            }
        }
        .onChange(of: query) { _, _ in highlighted = nil }
        .onAppear {
            // After the flyout's own first responder is set, so typing goes to the search at once.
            DispatchQueue.main.async { searching = true }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("People")
    }

    private func choose(_ who: MeetingFilter.Who) {
        withAnimation(.snappy(duration: 0.2)) { toggle(who) }
    }

    private var field: some View {
        HStack(spacing: 6) {
            IconImage(.search, size: 13).foregroundStyle(Palette.tertiaryMark)
            TextField("Search people", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .focused($searching)
                .onKeyPress(.downArrow) { move(1) }
                .onKeyPress(.upArrow) { move(-1) }
                // Escape first clears the text; with no text it closes the flyout.
                .onKeyPress(.escape) {
                    guard !query.isEmpty else { return .ignored }
                    query = ""
                    return .handled
                }
                .onSubmit {
                    if let who = MeetingFacets.choiceOnReturn(people, query: query, highlighted: highlighted, chosen: chosen) { choose(who) }
                }
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Palette.tertiaryMark) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear the search")
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(Palette.fill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func move(_ by: Int) -> KeyPress.Result {
        let ids = shown.map(\.id)
        guard !ids.isEmpty else { return .ignored }
        let index = highlighted.flatMap { ids.firstIndex(of: $0) }.map { min(max($0 + by, 0), ids.count - 1) } ?? (by > 0 ? 0 : ids.count - 1)
        highlighted = ids[index]
        return .handled
    }

    /// "Any" finds the meetings with one of the chosen people; "All" the meetings with every one of them.
    private var modePicker: some View {
        HStack(spacing: 0) {
            ForEach([(MeetingFilter.PeopleMode.any, "Any"), (.all, "All")], id: \.1) { choice, word in
                let on = mode == choice
                Button { withAnimation(.snappy(duration: 0.2)) { mode = choice } } label: {
                    Text(word)
                        .font(.system(size: 11, weight: on ? .semibold : .regular))
                        .foregroundStyle(on ? Palette.ink : Palette.secondary)
                        .padding(.horizontal, 8)
                        .frame(height: 16)
                        .background { if on { Capsule().fill(Palette.segmentOn).shadow(color: .black.opacity(0.12), radius: 1, y: 1) } }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
                .help("\(noun.title) with \(choice == .any ? "any" : "all") of these people")
            }
        }
        .padding(2)
        .background(Palette.fill, in: Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Match")
    }
}

private struct PersonRow: View {
    let person: MeetingFacets.Person
    let on: Bool
    let highlighted: Bool
    let noun: FilterNoun
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let empty = person.count == 0 && !on
        Button(action: action) {
            HStack(spacing: 8) {
                PersonMark(name: person.who.name, size: 20)
                Text(person.who.name).lineLimit(1).truncationMode(.tail)
                    .fontWeight(on ? .medium : .regular)
                Spacer(minLength: 6)
                Text("\(person.count)").font(.system(size: 11)).monospacedDigit().foregroundStyle(Palette.secondary)
                    .contentTransition(.numericText())
                IconImage(.checkSmall, size: 12).foregroundStyle(Palette.accent).opacity(on ? 1 : 0)
            }
            .font(.system(size: 12.5))
            .foregroundStyle(Palette.ink)
            .padding(.leading, 8).padding(.trailing, 8)
            .frame(height: 30)
            .background(on ? Palette.accentTint : highlighted || hovering ? Palette.fill : .clear,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        // The arrow keys and Return work the list from the search field, so Tab goes on to the groups.
        .focusable(false)
        .disabled(empty)
        .opacity(empty ? 0.42 : 1)
        .onHover { hovering = $0 }
        .accessibilityLabel(person.who.name)
        .accessibilityValue(noun.count(person.count))
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

// MARK: Date

/// The seven days as one bar in the calendar's order; any number of them can be on.
struct FilterWeekdays: View {
    let chosen: Set<Int>
    let counts: MeetingTally<Int>
    let toggle: (Int) -> Void
    @Environment(\.calendar) private var calendar

    var body: some View {
        let days = MeetingFilter.weekdayOrder(calendar)
        HStack(spacing: 2) {
            ForEach(days, id: \.self) { day in
                let on = chosen.contains(day), n = counts.count(day), empty = n == 0 && !on
                Button { toggle(day) } label: {
                    Text(calendar.shortWeekdaySymbols[day - 1])
                        .font(.system(size: 11.5, weight: on ? .medium : .regular))
                        .foregroundStyle(on ? Palette.accent : Palette.ink)
                        .frame(maxWidth: .infinity)
                        .frame(height: 20)
                        .background { if on { Capsule().fill(Palette.accentTint).overlay { Capsule().strokeBorder(Palette.accent.opacity(0.3), lineWidth: 1) } } }
                        .contentShape(Capsule())
                        .contentShape(.focusEffect, Capsule())
                }
                .buttonStyle(.plain)
                .disabled(empty)
                .opacity(empty ? 0.42 : 1)
                .help("\(calendar.weekdaySymbols[day - 1]): \(n) \(n == 1 ? "meeting" : "meetings")")
                .accessibilityLabel(calendar.weekdaySymbols[day - 1])
                .accessibilityValue("\(n) \(n == 1 ? "meeting" : "meetings")")
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Palette.fill, in: Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Days of the week")
    }
}

/// The two days of a custom range, each a date to type or step through on the chips' fill.
struct FilterDateRange: View {
    let from: Date
    let to: Date
    let setFrom: (Date) -> Void
    let setTo: (Date) -> Void

    var body: some View {
        HStack(spacing: 6) {
            field("From", Binding(get: { min(from, to) }, set: setFrom))
            Text("to").foregroundStyle(Palette.secondary)
            field("To", Binding(get: { max(from, to) }, set: setTo))
        }
    }

    private func field(_ label: String, _ date: Binding<Date>) -> some View {
        PlainDateField(date: date)
            .fixedSize()
            .padding(.horizontal, 8)
            .frame(height: FilterChip.height)
            .background(Palette.fill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .accessibilityLabel(label)
    }
}

/// AppKit's date field with no bezel of its own, so it sits on the design's fill. Days after today cannot be chosen:
/// no meeting was recorded then.
private struct PlainDateField: NSViewRepresentable {
    @Binding var date: Date

    func makeNSView(context: Context) -> NSDatePicker {
        let picker = NSDatePicker()
        picker.datePickerStyle = .textField
        picker.datePickerElements = .yearMonthDay
        picker.isBezeled = false
        picker.isBordered = false
        picker.drawsBackground = false
        picker.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        picker.target = context.coordinator
        picker.action = #selector(Coordinator.changed(_:))
        return picker
    }

    func updateNSView(_ picker: NSDatePicker, context: Context) {
        context.coordinator.date = $date
        picker.maxDate = Date()
        if picker.dateValue != date { picker.dateValue = date }
    }

    func makeCoordinator() -> Coordinator { Coordinator(date: $date) }

    @MainActor
    final class Coordinator: NSObject {
        var date: Binding<Date>
        init(date: Binding<Date>) { self.date = date }
        @objc func changed(_ sender: NSDatePicker) { date.wrappedValue = sender.dateValue }
    }
}

// MARK: Length

/// A custom length: two thumbs on one track, 0 to 2 hours in steps of 5 minutes. The upper thumb at the end
/// means "or more". The arrow keys move a thumb that has the focus.
struct FilterMinuteSlider: View {
    let range: MeetingFilter.MinuteRange
    let set: (MeetingFilter.MinuteRange) -> Void
    /// The thumb a drag moves, from its start to its end: two thumbs at one place go by the drag's direction.
    @State private var grabbed: MeetingFilter.MinuteRange.Thumb?

    private static let top = MeetingFilter.MinuteRange.top
    private static let step = MeetingFilter.MinuteRange.step
    private static let thumb: CGFloat = 16
    /// As the system's sliders: white, and a light gray in dark mode, so the thumb reads on the flyout's glass.
    private static let knob = Color(light: 0xFFFFFF, dark: 0xD6D1C9)

    private var upper: Int { range.upper }
    private var lower: Int { range.lower }

    var body: some View {
        HStack(spacing: 12) {
            GeometryReader { geometry in
                let span = max(1, geometry.size.width - Self.thumb)
                let low = CGFloat(lower) / CGFloat(Self.top) * span, high = CGFloat(upper) / CGFloat(Self.top) * span
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.fill).frame(height: 4).padding(.horizontal, Self.thumb / 2)
                    Capsule().fill(Palette.accentFill).frame(width: max(0, high - low), height: 4).offset(x: low + Self.thumb / 2)
                    thumb("Shortest", .lower, value: lower, at: low, span: span)
                    thumb("Longest", .upper, value: upper, at: high, span: span)
                }
                .frame(height: Self.thumb)
                .coordinateSpace(.named("minutes"))
            }
            .frame(height: Self.thumb)
            Text(range.label)
                .font(.system(size: 12)).monospacedDigit()
                .foregroundStyle(Palette.secondary)
                .frame(width: 96, alignment: .trailing)
        }
        .padding(.top, 2)
    }

    private func thumb(_ label: String, _ which: MeetingFilter.MinuteRange.Thumb, value: Int, at x: CGFloat, span: CGFloat) -> some View {
        let move = { (minutes: Int) in set(range.moving(which, to: minutes)) }
        return Circle()
            .fill(Self.knob)
            .overlay { Circle().strokeBorder(.black.opacity(0.08), lineWidth: 0.5) }
            .shadow(color: .black.opacity(0.22), radius: 1.5, y: 1)
            .frame(width: Self.thumb, height: Self.thumb)
            .contentShape(Circle().inset(by: -4))
            .offset(x: x)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("minutes"))
                    .onChanged { drag in
                        let minutes = MeetingFilter.MinuteRange.snap(minutes: Double(drag.location.x - Self.thumb / 2) / Double(span) * Double(Self.top))
                        let moving = grabbed ?? range.grab(which, toward: minutes)
                        if grabbed == nil, minutes != value { grabbed = moving }
                        set(range.moving(moving, to: minutes))
                    }
                    .onEnded { _ in grabbed = nil }
            )
            .focusable()
            .onKeyPress(.leftArrow) { move(value - Self.step); return .handled }
            .onKeyPress(.rightArrow) { move(value + Self.step); return .handled }
            .accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityValue(value >= Self.top && label == "Longest" ? "No limit" : "\(value) minutes")
            .accessibilityAdjustableAction { direction in
                move(direction == .increment ? value + Self.step : value - Self.step)
            }
    }
}
