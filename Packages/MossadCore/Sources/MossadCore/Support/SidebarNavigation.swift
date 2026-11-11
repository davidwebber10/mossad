import Foundation

/// The arrow keys of a sidebar whose items can have pages under them. The rows that show are the items and the
/// pages of the item that is open. An item whose click opens its first page is not a row of its own while it is
/// open: it would be the same place as its first page, and the arrow would stop on it for nothing.
public enum SidebarNavigation<ID: Hashable> {
    public struct Item {
        public let id: ID
        public let children: [ID]
        /// True when a click on the item opens its first page (Coach); false when the item is a page itself (Meetings).
        public let opensFirstChild: Bool

        public init(id: ID, children: [ID] = [], opensFirstChild: Bool = false) {
            self.id = id
            self.children = children
            self.opensFirstChild = opensFirstChild && !children.isEmpty
        }
    }

    /// Where the owner is: an item, and the page under it when one is open.
    public struct Spot: Equatable {
        public let item: ID
        public let child: ID?

        public init(item: ID, child: ID? = nil) {
            self.item = item
            self.child = child
        }
    }

    /// The rows that show while `spot` is open, from the top.
    public static func rows(_ items: [Item], at spot: Spot) -> [Spot] {
        items.flatMap { item -> [Spot] in
            let own = Spot(item: item.id)
            guard item.id == spot.item, !item.children.isEmpty else { return [own] }
            let pages = item.children.map { Spot(item: item.id, child: $0) }
            return item.opensFirstChild ? pages : [own] + pages
        }
    }

    /// What a click on an item (or a jump to it) opens.
    public static func open(_ items: [Item], item id: ID) -> Spot {
        guard let item = items.first(where: { $0.id == id }), item.opensFirstChild else { return Spot(item: id) }
        return Spot(item: id, child: item.children.first)
    }

    /// The row `by` rows from `spot`, held at the ends. Nil when `spot` is not in the sidebar.
    public static func step(_ items: [Item], from spot: Spot, by: Int) -> Spot? {
        guard let item = items.first(where: { $0.id == spot.item }) else { return nil }
        let rows = rows(items, at: spot)
        // A page that is not a row (it went away) moves from its item, or from the item's first page.
        guard let i = rows.firstIndex(of: spot) ?? rows.firstIndex(of: Spot(item: item.id))
                ?? rows.firstIndex(where: { $0.item == item.id }) else { return nil }
        let target = rows[min(max(i + by, 0), rows.count - 1)]
        return target.child == nil ? open(items, item: target.item) : target
    }

    public static func first(_ items: [Item], at spot: Spot) -> Spot? {
        rows(items, at: spot).first.map { $0.child == nil ? open(items, item: $0.item) : $0 }
    }

    public static func last(_ items: [Item], at spot: Spot) -> Spot? {
        rows(items, at: spot).last.map { $0.child == nil ? open(items, item: $0.item) : $0 }
    }
}
