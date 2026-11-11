import MossadCore
import SwiftUI

/// The Meetings filter's button: three shortening lines, and the number of choices in the accent once there is
/// one. It opens the flyout. In the list's title row it is a quiet mark; in the toolbar (Calendar mode has no
/// list) it is a glass capsule like its neighbors.
struct MeetingFilterButton: View {
    enum Place { case title, toolbar }

    @EnvironmentObject var filters: MeetingFilterModel
    var place = Place.title
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
            .frame(minWidth: place == .toolbar ? Chrome.controlHeight : 28, minHeight: place == .toolbar ? Chrome.controlHeight : 24)
            .background { ground(active: count > 0) }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .keyboardShortcut("f", modifiers: [.command, .option])
        .help(count == 0 ? "Filter meetings (⌥⌘F)" : "\(count) \(count == 1 ? "filter" : "filters") on (⌥⌘F)")
        .accessibilityLabel("Filter meetings")
        .accessibilityValue(count == 0 ? "No filters" : "\(count) \(count == 1 ? "filter" : "filters") on")
        // Beside the list in its title row, so the list it filters stays in view; below the toolbar in Calendar mode.
        .popover(isPresented: $filters.isOpen, arrowEdge: place == .title ? .trailing : .bottom) {
            MeetingFilterPanel().environmentObject(filters)
        }
        .animation(.snappy(duration: 0.2), value: count)
    }

    @ViewBuilder
    private func ground(active: Bool) -> some View {
        switch place {
        case .title:
            Capsule().fill(active ? Palette.accentTint : hovering || filters.isOpen ? Palette.fill : .clear)
        case .toolbar:
            Color.clear.chromeGlass(in: Capsule())
                .overlay { if active { Capsule().fill(Palette.accentTint) } }
        }
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
                    ActiveChip(choice: choice, text: filters.label(choice, calendar: calendar)) {
                        withAnimation(.snappy(duration: 0.2)) { filters.filter.remove(choice) }
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
private struct ActiveChip: View {
    let choice: MeetingFilter.Active
    let text: String
    let remove: () -> Void
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

    @ViewBuilder
    private var mark: some View {
        switch choice {
        case .person(let who): Circle().fill(PersonMark.color(for: who.name)).frame(width: 7, height: 7)
        case .platform(let p): PlatformDot(platform: p, size: 7)
        case .tag: Text("#").foregroundStyle(Palette.tertiary)
        default: EmptyView()
        }
    }
}

extension MeetingFilterModel {
    /// A chip's words; a person by the name they have now.
    func label(_ choice: MeetingFilter.Active, calendar: Calendar) -> String {
        if case .person(let who) = choice, let now = facets.people.first(where: { $0.who == who }) { return now.who.name }
        return choice.label(calendar: calendar)
    }
}
