import MossadCore
import SwiftUI

/// A place in the sidebar: a section, or a page of Coach. The pages under Meetings are sections of their own.
enum SidebarPlace: Hashable {
    case section(AppController.Section)
    case coach(CoachPage)
}

typealias SidebarNav = SidebarNavigation<SidebarPlace>

extension AppController {
    /// The sidebar's items with the pages under them, for the arrow keys and the clicks. One table, so each item
    /// with pages gets the same keys.
    static let sidebarItems: [SidebarNav.Item] = Section.topLevel.map { s in
        switch s {
        case .meetings: SidebarNav.Item(id: .section(.meetings), children: Section.underMeetings.map { .section($0) })
        case .coach: SidebarNav.Item(id: .section(.coach), children: CoachPage.allCases.map { .coach($0) }, opensFirstChild: true)
        default: SidebarNav.Item(id: .section(s))
        }
    }

    /// Where the window is, as the sidebar sees it.
    var sidebarSpot: SidebarNav.Spot {
        if section.isUnderMeetings { return SidebarNav.Spot(item: .section(.meetings), child: .section(section)) }
        if section == .coach { return SidebarNav.Spot(item: .section(.coach), child: .coach(coachPage)) }
        return SidebarNav.Spot(item: .section(section))
    }

    /// Whether the sidebar shows the pages under this item now.
    func sidebarOpen(_ item: Section) -> Bool { sidebarSpot.item == .section(item) }

    func go(to spot: SidebarNav.Spot) {
        switch spot.child ?? spot.item {
        case .section(let s): section = s
        case .coach(let page):
            coachPage = page
            section = .coach
        }
    }

    /// A click on an item, a letter typed, or the Go menu: Coach opens on its first page, as each way to it does.
    func go(to section: Section) {
        if section.isUnderMeetings { self.section = section } else { go(to: SidebarNav.open(Self.sidebarItems, item: .section(section))) }
    }
}
