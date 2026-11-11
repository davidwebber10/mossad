import MossadCore
import SwiftUI

/// The filter's flyout, all of it in view at once: who on the left, as a list to search, then when and how large,
/// then what it was about. Each choice says how many meetings it has with the other groups' choices, and applies
/// at once: there is no Apply, the list behind the flyout is the preview.
struct MeetingFilterPanel: View {
    @EnvironmentObject var filters: MeetingFilterModel
    @Environment(\.calendar) private var calendar
    @State private var allTags = false
    @State private var allKinds = false

    private static let peopleWidth: CGFloat = 228
    private static let columnWidth: CGFloat = 334
    /// A long list of topics opened with "more" scrolls inside its column from here.
    private static let maxHeight: CGFloat = 560
    private static let tagsShown = 9
    private static let kindsShown = 6

    private var facets: MeetingFacets { filters.facets }

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            HStack(alignment: .top, spacing: 0) {
                // As tall as the groups beside it; the list scrolls inside.
                FilterPeoplePicker()
                    .frame(width: Self.peopleWidth)
                    .frame(idealHeight: 380, maxHeight: .infinity)
                Hairline(axis: .vertical)
                column { when }
                Hairline(axis: .vertical)
                column { what }
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxHeight: Self.maxHeight)
        }
        .frame(width: Self.peopleWidth + 2 + Self.columnWidth * 2)
        .font(.system(size: 12))
        .foregroundStyle(Palette.ink)
        .background {
            // The same shortcut closes it, since the button behind does not get keys while the flyout has them.
            Button("Close") { filters.isOpen = false }.keyboardShortcut("f", modifiers: [.command, .option])
                .focusable(false).opacity(0).accessibilityHidden(true)
        }
    }

    private func column<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) { content() }
                .padding(EdgeInsets(top: 14, leading: 16, bottom: 18, trailing: 16))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(width: Self.columnWidth)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Filters").font(.system(size: 13, weight: .semibold))
            Text(countText)
                .foregroundStyle(Palette.secondary).monospacedDigit()
                .contentTransition(.numericText())
                .animation(.snappy(duration: 0.2), value: countText)
            Spacer(minLength: 12)
            Button("Clear all") { change { filters.clear() } }
                .buttonStyle(.sheetText)
                .disabled(filters.filter.isEmpty)
                // Not Command-Delete alone: in the people search that deletes the typed line.
                .keyboardShortcut(.delete, modifiers: [.command, .option])
                .help("Remove every filter (⌥⌘⌫)")
        }
        .padding(.leading, 16).padding(.trailing, 12)
        .frame(height: 44)
    }

    /// "12 of 86 meetings": the live result.
    private var countText: String {
        let total = facets.total
        let noun = total == 1 ? "meeting" : "meetings"
        return filters.answered.isEmpty ? "\(total) \(noun)" : "\(facets.matches.count) of \(total) \(noun)"
    }

    private func change(_ body: () -> Void) {
        withAnimation(.snappy(duration: 0.2)) { body() }
    }

    private func toggle(_ choice: MeetingFilter.Active) {
        change { filters.filter.toggle(choice) }
    }

    private func chip(_ choice: MeetingFilter.Active, _ text: String, count: Int, platform: Platform? = nil) -> some View {
        FilterChip(text: text, count: count, on: filters.filter.contains(choice), platform: platform) { toggle(choice) }
    }

    // MARK: Groups

    /// When it was, how long it ran, how many people, and what came out of it.
    @ViewBuilder
    private var when: some View {
        FilterGroup("Date") {
            FlowLayout(spacing: 6) {
                ForEach(MeetingFilter.Period.presets, id: \.self) { p in
                    chip(.period(p), p.label(calendar: calendar), count: facets.periods.count(p))
                }
                FilterChip(text: "Custom", count: nil, on: filters.filter.period?.isCustom == true) {
                    change { filters.filter.toggleCustomPeriod(now: Date(), calendar: calendar) }
                }
            }
            if case .custom(let from, let to) = filters.filter.period {
                FilterDateRange(from: from, to: to, setFrom: { filters.filter.setRange(from: $0) }, setTo: { filters.filter.setRange(to: $0) })
                    .transition(.opacity)
            }
            FilterWeekdays(chosen: filters.filter.weekdays, counts: facets.weekdays) { toggle(.weekday($0)) }
                .padding(.top, 2)
        }
        FilterGroup("Length", note: "minutes") {
            FlowLayout(spacing: 6) {
                ForEach(MeetingFilter.Length.allCases, id: \.self) { l in
                    chip(.length(l), l.option, count: facets.lengths.count(l))
                }
                FilterChip(text: "Custom", count: nil, on: filters.filter.customLength != nil) {
                    change { filters.filter.toggleCustomLength() }
                }
            }
            if let range = filters.filter.customLength {
                FilterMinuteSlider(range: range) { filters.filter.customLength = $0 }
                    .transition(.opacity)
            }
        }
        // "Just me" and "Not known" only where a meeting has them.
        let sizes = MeetingFilter.Size.allCases.filter { ![.alone, .unknown].contains($0) || facets.sizes.exists($0) || filters.filter.sizes.contains($0) }
        FilterGroup("People in the meeting") {
            FlowLayout(spacing: 6) {
                ForEach(sizes, id: \.self) { s in chip(.size(s), s.option, count: facets.sizes.count(s)) }
            }
        }
        let flags = MeetingFilter.Flag.allCases.filter { $0 != .screens || facets.flags.exists(.screens) || filters.filter.flags.contains(.screens) }
        FilterGroup("Has") {
            FlowLayout(spacing: 6) {
                ForEach(flags, id: \.self) { f in chip(.flag(f), f.option, count: facets.flags.count(f)) }
            }
        }
    }

    /// What it was about, what kind it was, what it was worth, and where it ran.
    @ViewBuilder
    private var what: some View {
        if !facets.tags.isEmpty {
            FilterGroup("Topic") {
                FlowLayout(spacing: 6) {
                    ForEach(shown(facets.tags, limit: Self.tagsShown, all: allTags, chosen: filters.filter.tags)) { t in
                        chip(.tag(t.name), t.name, count: t.count)
                    }
                    if facets.tags.count > Self.tagsShown {
                        MoreChip(more: facets.tags.count - Self.tagsShown, open: allTags) { change { allTags.toggle() } }
                    }
                }
            }
        }
        if !facets.kinds.isEmpty {
            FilterGroup("Kind") {
                FlowLayout(spacing: 6) {
                    ForEach(shown(facets.kinds, limit: Self.kindsShown, all: allKinds, chosen: filters.filter.kinds)) { k in
                        chip(.kind(k.name), k.name, count: k.count)
                    }
                    if facets.kinds.count > Self.kindsShown {
                        MoreChip(more: facets.kinds.count - Self.kindsShown, open: allKinds) { change { allKinds.toggle() } }
                    }
                }
            }
        }
        // Without one rating there is nothing to choose between: every meeting is "Not rated".
        if [MeetingFilter.Value.high, .medium, .low].contains(where: facets.values.exists) || !filters.filter.values.isEmpty {
            FilterGroup("Meeting value", note: "The coach's rating") {
                FlowLayout(spacing: 6) {
                    ForEach(MeetingFilter.Value.allCases, id: \.self) { v in chip(.value(v), v.option, count: facets.values.count(v)) }
                }
            }
        }
        let platforms = Platform.allCases.filter { facets.platforms.exists($0) || filters.filter.platforms.contains($0) }
        if platforms.count > 1 || !filters.filter.platforms.isEmpty {
            FilterGroup("Platform") {
                FlowLayout(spacing: 6) {
                    ForEach(platforms, id: \.self) { p in chip(.platform(p), p.filterName, count: facets.platforms.count(p), platform: p) }
                }
            }
        }
    }

    /// The first few, and any chosen one further down, so a choice never hides behind "more".
    private func shown(_ list: [MeetingFacets.Named], limit: Int, all: Bool, chosen: [String]) -> [MeetingFacets.Named] {
        guard !all, list.count > limit else { return list }
        let keys = Set(chosen.map { $0.lowercased() })
        return Array(list.prefix(limit)) + list.dropFirst(limit).filter { keys.contains($0.id) }
    }
}

/// A group of choices under its small label.
private struct FilterGroup<Content: View>: View {
    let title: String
    var note: String?
    @ViewBuilder let content: Content

    init(_ title: String, note: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.note = note
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text(title).textRole(.label).foregroundStyle(Palette.secondary)
                if let note { Text(note).font(.system(size: 11)).foregroundStyle(Palette.tertiary) }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

/// "9 more" at the end of a long group, and "Fewer" once it is open.
private struct MoreChip: View {
    let more: Int
    let open: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(open ? "Fewer" : "\(more) more")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Palette.accent)
                .padding(.horizontal, 6)
                .frame(height: FilterChip.height)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
