import Foundation

/// A marker line of the transcript with an id of its own: a string, so it never equals a turn's number id, and made
/// from its place, so two markers at one second never share it.
public struct PlacedMarker: Equatable, Sendable, Identifiable {
    public let id: String
    public let marker: TranscriptMarker
}

/// Where each marker line goes: before the first turn that starts at or after it, else after the last turn.
public enum TranscriptMarkerRows {
    public static func place(_ markers: [TranscriptMarker], blocks: [TranscriptBlock]) -> (before: [Int: [PlacedMarker]], after: [PlacedMarker]) {
        let sorted = markers.enumerated().sorted { ($0.element.offset, $0.offset) < ($1.element.offset, $1.offset) }.map(\.element)
        var before: [Int: [PlacedMarker]] = [:]
        var previousEnd: TimeInterval = -1
        var rest = sorted[...]
        for block in blocks {
            var here: [PlacedMarker] = []
            while let m = rest.first, m.offset <= block.start {
                rest = rest.dropFirst()
                // A marker inside the turn before shows no line, as before.
                if m.offset > previousEnd { here.append(PlacedMarker(id: "marker-\(block.id)-\(here.count)", marker: m)) }
            }
            if !here.isEmpty { before[block.id] = here }
            previousEnd = block.end
        }
        let after = rest.filter { $0.offset > previousEnd }.enumerated().map { PlacedMarker(id: "marker-end-\($0.offset)", marker: $0.element) }
        return (before, after)
    }
}
