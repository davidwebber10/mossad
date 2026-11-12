import Foundation
import MossadCore

/// Where the window is, as one `NavigationPlace`, and the way back to one (`NavigationModel`).
extension AppController {
    /// The saved tab of the pages that have tabs, as their AppStorage holds it.
    private static let tabKeys: [Section: (key: String, first: String)] = [
        .meetings: ("detailTab", MeetingDetailView.Tab.summary.rawValue),
        .people: ("personTab", PersonProfileView.Tab.overview.rawValue),
        .recurring: ("recurringTab", RecurringPage.Tab.nextTime.rawValue),
    ]

    /// Search text, or nil when there is none worth keeping.
    private static func text(_ s: String?) -> String? {
        guard let s, !s.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return s
    }

    var currentPlace: NavigationPlace {
        let part = navigation.part(section)
        var place = NavigationPlace(section: section.rawValue, page: part?.page, item: part?.item, search: Self.text(part?.search))
        switch section {
        case .meetings:
            // List mode keeps its selection here; Calendar mode reports the meeting it opened full-pane.
            if part?.page == nil { place.item = selectedMeetingID }
            place.search = Self.text(meetingQuery)
            place.filter = meetingFilter.filter.isEmpty ? nil : meetingFilter.filter
            if let moment = lastMoment, moment.callID == place.item { place.time = moment.at }
        case .recurring:
            place.item = part?.item ?? series.selected
        case .people:
            // By the person's id where the name is a saved person, so a merge or a rename still finds them.
            if let name = part?.item { place.item = series.people.id(for: name) ?? name }
        case .coach:
            place.page = coachPage.rawValue
        case .settings:
            place.page = UserDefaults.standard.string(forKey: "settingsPage") ?? SettingsPage.general.rawValue
        default:
            break
        }
        if place.item != nil, let tab = Self.tabKeys[section] {
            place.tab = UserDefaults.standard.string(forKey: tab.key) ?? tab.first
        }
        return place
    }

    /// The place as it is now, or nil when its item is gone: a deleted meeting, a series that ended, a person who
    /// was deleted. A merged person comes back as the one who took them in.
    func resolve(_ place: NavigationPlace) -> NavigationPlace? {
        guard let section = Section(rawValue: place.section) else { return nil }
        guard let item = place.item else { return place }
        switch section {
        case .meetings:
            return meetings.contains(where: { $0.id == item }) || calendarUpcoming.contains(where: { $0.id == item }) ? place : nil
        case .recurring:
            return series.series(item) == nil && !series.all.isEmpty ? nil : place
        case .people:
            guard series.people.knows(item) else { return place }
            guard let person = series.people.person(item) else { return nil }
            var now = place
            now.item = person.id.rawValue
            return now
        default:
            return place
        }
    }

    /// Shows a place again. Each value is set as it is, with no jump marked, so nothing here is a new step.
    func apply(_ place: NavigationPlace) {
        guard let target = Section(rawValue: place.section) else { return }
        if let tab = Self.tabKeys[target], let value = place.tab { UserDefaults.standard.set(value, forKey: tab.key) }
        switch target {
        case .meetings:
            if meetingQuery != (place.search ?? "") { meetingQuery = place.search ?? "" }
            let filter = place.filter ?? MeetingFilter()
            if meetingFilter.filter != filter { meetingFilter.filter = filter }
            if place.page == nil, let id = place.item { selectedMeetingID = id }
            if let id = place.item, let at = place.time {
                lastMoment = (id, at)
                seekRequest = SeekRequest(callID: id, at: at, play: false)
            }
        case .recurring:
            if let id = place.item { series.selected = id }
        case .people:
            if let item = place.item {
                personToOpen = series.people.name(of: item) ?? item
                personRequests += 1
            }
        case .coach:
            if let page = place.page.flatMap(CoachPage.init(rawValue:)) { coachPage = page }
        case .settings:
            if let page = place.page { UserDefaults.standard.set(page, forKey: "settingsPage") }
        default:
            break
        }
        if section != target { section = target }
    }

    /// A place's name in the Back and Forward menus: the meeting, the person, or the series, with the tab.
    func title(of place: NavigationPlace) -> String {
        guard let section = Section(rawValue: place.section) else { return place.section }
        var name: String?
        switch section {
        case .meetings:
            name = place.item.flatMap { id in meetings.first { $0.id == id }?.title ?? calendarUpcoming.first { $0.id == id }?.title }
        case .recurring:
            name = series.series(place.item)?.title
        case .people:
            name = place.item.map { series.people.name(of: $0) ?? $0 }
        case .coach:
            name = place.page.flatMap(CoachPage.init(rawValue:)).map { "Coach › \($0.title)" }
        case .settings:
            name = place.page.flatMap(SettingsPage.init(rawValue:)).map { "Settings › \($0.title)" }
        default:
            break
        }
        let base = name ?? section.rawValue
        if let tab = place.tab, place.item != nil, tab != Self.tabKeys[section]?.first { return "\(base) · \(tab)" }
        if let search = place.search { return "\(base) · “\(search)”" }
        return base
    }

    /// The findings deck takes the swipe: the Coach's Findings page, and a meeting's Coach tab.
    var showsFindingsDeck: Bool {
        (section == .coach && coachPage == .findings)
            || (section == .meetings && UserDefaults.standard.string(forKey: "detailTab") == MeetingDetailView.Tab.coach.rawValue)
    }
}
