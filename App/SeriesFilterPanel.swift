import MossadCore
import SwiftUI

/// The Recurring filter's button, as the Meetings one: three shortening lines, and the number of choices once there
/// is one. It opens the flyout beside the list.
struct SeriesFilterButton: View {
    @ObservedObject var filters: SeriesFilterModel
    @State private var hovering = false

    var body: some View {
        let count = filters.filter.active.count
        Button { filters.toggleOpen() } label: {
            HStack(spacing: 5) {
                Image(systemName: "line.3.horizontal.decrease").font(.system(size: 13, weight: .medium))
                if count > 0 {
                    Text("\(count)").font(.system(size: 11.5, weight: .semibold)).monospacedDigit()
                        .contentTransition(.numericText())
                }
            }
            .foregroundStyle(count > 0 ? Palette.accent : hovering || filters.isOpen ? Palette.ink : Palette.secondary)
            .padding(.horizontal, count > 0 ? 9 : 0)
            .frame(minWidth: 28, minHeight: 24)
            .background { Capsule().fill(count > 0 ? Palette.accentTint : hovering || filters.isOpen ? Palette.fill : .clear) }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .keyboardShortcut("f", modifiers: [.command, .option])
        .help(count == 0 ? "Filter recurring meetings (⌥⌘F)" : "\(count) \(count == 1 ? "filter" : "filters") on (⌥⌘F)")
        .accessibilityLabel("Filter recurring meetings")
        .accessibilityValue(count == 0 ? "No filters" : "\(count) \(count == 1 ? "filter" : "filters") on")
        .popover(isPresented: $filters.isOpen, arrowEdge: .trailing) {
            SeriesFilterPanel(filters: filters)
        }
        .animation(.snappy(duration: 0.2), value: count)
    }
}

/// The choices as chips over the list, then how many series are left and "Clear all". Nothing with no filter.
struct SeriesFilterChips: View {
    @ObservedObject var filters: SeriesFilterModel

    var body: some View {
        let choices = filters.filter.active
        if !choices.isEmpty {
            FlowLayout(spacing: 6) {
                ForEach(Array(choices.enumerated()), id: \.element) { i, choice in
                    if i > 0, filters.filter.peopleMode == .all, case .person = choice {
                        Text("and").font(.system(size: 11.5)).foregroundStyle(Palette.tertiary).frame(height: 22)
                    }
                    ActiveChip(text: filters.label(choice)) {
                        withAnimation(.snappy(duration: 0.2)) { filters.filter.remove(choice) }
                    } mark: {
                        switch choice {
                        case .person(let who): FilterPersonDot(who: who)
                        case .platform(let p): PlatformDot(platform: p, size: 7)
                        default: EmptyView()
                        }
                    }
                }
                HStack(spacing: 8) {
                    if filters.answered == filters.filter {
                        Text("\(filters.facets.matches.count) of \(filters.facets.total)")
                            .foregroundStyle(Palette.tertiary).monospacedDigit()
                            .accessibilityLabel("\(filters.facets.matches.count) of \(filters.facets.total) recurring meetings")
                    }
                    Button("Clear all") { withAnimation(.snappy(duration: 0.2)) { filters.clear() } }
                        .buttonStyle(.plain)
                        .fontWeight(.medium)
                        .foregroundStyle(Palette.accent)
                }
                .font(.system(size: 11.5))
                .frame(height: 22)
                .padding(.leading, 2)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Filters")
        }
    }
}

/// The flyout: who on the left, as a list to search, then when it meets and how it runs, then who comes and what it
/// is worth. Each choice says how many series it has with the other groups' choices, and applies at once.
struct SeriesFilterPanel: View {
    @ObservedObject var filters: SeriesFilterModel

    private static let peopleWidth: CGFloat = 228
    private static let columnWidth: CGFloat = 300
    private static let maxHeight: CGFloat = 560

    private var facets: SeriesFacets { filters.facets }

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            HStack(alignment: .top, spacing: 0) {
                FilterPeoplePicker(people: facets.people, chosen: filters.filter.people, mode: $filters.filter.peopleMode, noun: .series) {
                    filters.filter.toggle(.person($0))
                }
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
                .keyboardShortcut(.delete, modifiers: [.command, .option])
                .help("Remove every filter (⌥⌘⌫)")
        }
        .padding(.leading, 16).padding(.trailing, 12)
        .frame(height: 44)
    }

    /// "4 of 12 recurring meetings": the live result.
    private var countText: String {
        let total = facets.total
        let noun = total == 1 ? "recurring meeting" : "recurring meetings"
        return filters.answered.isEmpty ? "\(total) \(noun)" : "\(facets.matches.count) of \(total) \(noun)"
    }

    private func change(_ body: () -> Void) {
        withAnimation(.snappy(duration: 0.2)) { body() }
    }

    private func chip(_ choice: SeriesFilter.Active, _ text: String, count: Int, platform: Platform? = nil) -> some View {
        FilterChip(text: text, count: count, on: filters.filter.contains(choice), platform: platform, noun: .series) {
            change { filters.filter.toggle(choice) }
        }
    }

    /// When it meets next and last, how often, and how long.
    @ViewBuilder
    private var when: some View {
        FilterGroup("Next meeting", note: "from your calendar") {
            FlowLayout(spacing: 6) {
                ForEach(SeriesFilter.Next.allCases, id: \.self) { n in chip(.next(n), n.option, count: facets.next.count(n)) }
            }
        }
        FilterGroup("Last met") {
            FlowLayout(spacing: 6) {
                ForEach(SeriesFilter.LastMet.allCases, id: \.self) { l in chip(.lastMet(l), l.option, count: facets.lastMet.count(l)) }
            }
        }
        FilterGroup("Cadence") {
            FlowLayout(spacing: 6) {
                ForEach(SeriesFilter.Cadence.allCases, id: \.self) { c in chip(.cadence(c), c.option, count: facets.cadences.count(c)) }
            }
        }
        FilterGroup("Usual length", note: "minutes") {
            FlowLayout(spacing: 6) {
                ForEach(MeetingFilter.Length.allCases, id: \.self) { l in chip(.length(l), l.option, count: facets.lengths.count(l)) }
            }
        }
    }

    /// Who usually comes, what is open, what the coach thinks of it, and where it runs.
    @ViewBuilder
    private var what: some View {
        let sizes = MeetingFilter.Size.allCases.filter { ![.alone, .unknown].contains($0) || facets.sizes.exists($0) || filters.filter.sizes.contains($0) }
        FilterGroup("People in the meeting", note: "usually") {
            FlowLayout(spacing: 6) {
                ForEach(sizes, id: \.self) { s in chip(.size(s), s.option, count: facets.sizes.count(s)) }
            }
        }
        FilterGroup("Has") {
            FlowLayout(spacing: 6) { chip(.openItems, "Open items", count: facets.openItems.count(true)) }
        }
        // Without one rating there is nothing to choose between: every series is "Not rated".
        if [MeetingFilter.Value.high, .medium, .low].contains(where: facets.values.exists) || !filters.filter.values.isEmpty {
            FilterGroup("Meeting value", note: "The coach's usual rating") {
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
}
