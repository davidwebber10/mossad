import MossadCore
import SwiftUI

/// The Meetings filter's button: three shortening lines, and the number of choices in the accent once there is
/// one. It opens the flyout. It is a quiet mark beside the list's search glass, in the list's title row or, in
/// Calendar mode, at the start of the toolbar row.
struct MeetingFilterButton: View {
    @EnvironmentObject var filters: MeetingFilterModel
    /// Where the flyout opens: beside the list, or below the toolbar row in Calendar mode, over the calendar.
    var edge = Edge.trailing
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
        .help(count == 0 ? "Filter meetings (⌥⌘F)" : "\(count) \(count == 1 ? "filter" : "filters") on (⌥⌘F)")
        .accessibilityLabel("Filter meetings")
        .accessibilityValue(count == 0 ? "No filters" : "\(count) \(count == 1 ? "filter" : "filters") on")
        // Beside the list in its title row, so the list it filters stays in view; below the toolbar in Calendar mode.
        .popover(isPresented: $filters.isOpen, arrowEdge: edge) {
            MeetingFilterPanel().environmentObject(filters)
        }
        .animation(.snappy(duration: 0.2), value: count)
    }
}

/// The filter's choices as chips, each of which goes with a click, then how many meetings are left and "Clear
/// all". Nothing at all with no filter. It stands where the filtered meetings are: at the top of the list, and
/// under the toolbar in Calendar mode.
struct MeetingFilterChips: View {
    @EnvironmentObject var filters: MeetingFilterModel
    @Environment(\.calendar) private var calendar

    var body: some View {
        let choices = filters.filter.active
        if !choices.isEmpty {
            FlowLayout(spacing: 6) {
                ForEach(Array(choices.enumerated()), id: \.element) { i, choice in
                    // With "All", "and" between the people says what the chips alone do not.
                    if i > 0, filters.filter.peopleMode == .all, case .person = choice {
                        Text("and").font(.system(size: 11.5)).foregroundStyle(Palette.tertiary).frame(height: 22)
                    }
                    ActiveChip(text: filters.label(choice, calendar: calendar)) {
                        withAnimation(.snappy(duration: 0.2)) { filters.filter.remove(choice) }
                    } mark: {
                        switch choice {
                        case .person(let who): FilterPersonDot(who: who)
                        case .platform(let p): PlatformDot(platform: p, size: 7)
                        case .tag: Text("#").foregroundStyle(Palette.tertiary)
                        default: EmptyView()
                        }
                    }
                }
                HStack(spacing: 8) {
                    // The answer for these chips; a moment of the older number would be a wrong one.
                    if filters.answered == filters.filter {
                        Text("\(filters.facets.matches.count) of \(filters.facets.total)")
                            .foregroundStyle(Palette.tertiary).monospacedDigit()
                            .accessibilityLabel("\(filters.facets.matches.count) of \(filters.facets.total) meetings")
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

/// One choice: its mark (a person's hue, a platform's dot), its words, and a small cross. The whole chip removes it.
struct ActiveChip<Mark: View>: View {
    let text: String
    let remove: () -> Void
    @ViewBuilder let mark: Mark
    @State private var hovering = false

    var body: some View {
        Button(action: remove) {
            HStack(spacing: 5) {
                mark
                Text(text).lineLimit(1).truncationMode(.tail)
                Image(systemName: "xmark").font(.system(size: 7.5, weight: .bold))
                    .foregroundStyle(hovering ? Palette.ink : Palette.tertiaryMark)
            }
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(Palette.ink)
            .padding(.leading, 8).padding(.trailing, 7)
            .frame(height: 22)
            .frame(maxWidth: 200)
            .background(hovering ? Palette.selection : Palette.fill, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Remove this filter")
        .accessibilityLabel("\(text), remove filter")
    }
}

/// A person's hue on a chip.
struct FilterPersonDot: View {
    let who: MeetingFilter.Who

    var body: some View { Circle().fill(PersonMark.color(for: who.name)).frame(width: 7, height: 7) }
}

extension MeetingFilterModel {
    /// A chip's words; a person by the name they have now.
    func label(_ choice: MeetingFilter.Active, calendar: Calendar) -> String {
        if case .person(let who) = choice, let now = facets.people.first(where: { $0.who == who }) { return now.who.name }
        return choice.label(calendar: calendar)
    }
}
