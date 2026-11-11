import Foundation

/// Every bookmark of all meetings, for the Bookmarks page under Meetings: one group per meeting, the newest meeting
/// first, its bookmarks in the order of the call.
public enum BookmarkIndex {
    /// The line that was said at a bookmark, so a bookmark with no note still says what it marked.
    public struct Said: Sendable, Equatable, Hashable {
        public let speaker: String
        public let text: String
    }

    public struct Entry: Sendable, Equatable, Hashable, Identifiable {
        public let callID: String
        /// Seconds into the recording.
        public let offset: TimeInterval
        /// The owner's own words; nil when there are none.
        public let note: String?
        /// The time of day of the bookmark.
        public let time: Date
        public let said: Said?
        public var id: String { "\(callID)#\(Int((offset * 1000).rounded()))" }
    }

    public struct Group: Sendable, Equatable, Hashable, Identifiable {
        public let callID: String
        public let title: String
        public let start: Date
        public let bookmarks: [Entry]
        public var id: String { callID }
    }

    /// A line counts for a bookmark made up to this many seconds after it ended: the owner hears it, then marks it.
    static let afterLine: TimeInterval = 15

    /// A query of words keeps the bookmarks whose note, said line, or meeting title holds every word, without
    /// regard to case or accents.
    public static func groups(_ records: [CallRecord], query: String = "") -> [Group] {
        let terms = MomentSearch.terms(query)
        return records.sorted { $0.start > $1.start }.compactMap { r in
            let marks = r.markers.filter(\.isBookmark).sorted { $0.offset < $1.offset }
            guard !marks.isEmpty else { return nil }
            let names = MarkdownWriter.displayNames(r)
            let lines = Transcript.interleaved(r.utterances)
            let title = r.title
            let entries = marks.map { m in
                Entry(callID: r.id, offset: m.offset, note: m.note?.trimmingCharacters(in: .whitespacesAndNewlines).nonBlank,
                      time: r.date(atOffset: m.offset), said: said(at: m.offset, in: lines, names: names))
            }
            let kept = terms.isEmpty ? entries : entries.filter { e in
                MomentSearch.matches(terms, [title, e.note ?? "", e.said?.text ?? "", e.said?.speaker ?? ""])
            }
            return kept.isEmpty ? nil : Group(callID: r.id, title: title, start: r.start, bookmarks: kept)
        }
    }

    public static func count(_ groups: [Group]) -> Int { groups.reduce(0) { $0 + $1.bookmarks.count } }

    /// The line that runs at the moment, else the last one that ended a short time before it.
    static func said(at offset: TimeInterval, in lines: [Utterance], names: [String: String]) -> Said? {
        let line = lines.last { $0.start <= offset && $0.end >= offset }
            ?? lines.last { $0.end < offset && offset - $0.end <= afterLine }
        guard let line, let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines).nonBlank else { return nil }
        return Said(speaker: names[line.speakerKey] ?? line.speakerKey, text: text)
    }
}

/// Every kept screen of all meetings, for the Screens page under Meetings: one group per meeting, the newest meeting
/// first, its screens in the order of the call.
public enum ScreenIndex {
    public struct Group: Sendable, Equatable, Identifiable {
        public let callID: String
        public let title: String
        public let start: Date
        public let screens: [SharedScreen]
        /// The time of day of each screen, by file name.
        public let times: [String: Date]
        public var id: String { callID }
    }

    /// A query keeps the screens whose recognized text (or presenter) holds every word, with the same words as the
    /// filter of a meeting's Screens tab.
    public static func groups(_ records: [CallRecord], query: String = "") -> [Group] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return records.sorted { $0.start > $1.start }.compactMap { r in
            let deleted = Set(r.deletedScreens ?? [])
            var screens = (r.screens ?? []).filter { !deleted.contains($0.file) }.sorted { $0.offset < $1.offset }
            if !q.isEmpty {
                screens = screens.filter { ScreenText.contains([$0.text, $0.presenter ?? ""].joined(separator: "\n"), query: q) }
            }
            return screens.isEmpty ? nil : Group(callID: r.id, title: r.title, start: r.start, screens: screens,
                                                 times: Dictionary(screens.map { ($0.file, r.date(of: $0)) }, uniquingKeysWith: { a, _ in a }))
        }
    }

    public static func count(_ groups: [Group]) -> Int { groups.reduce(0) { $0 + $1.screens.count } }
}

/// Words of a query for the pages under Meetings: folded for case and accents, each one required.
enum MomentSearch {
    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    static func terms(_ query: String) -> [String] {
        fold(query).split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    static func matches(_ terms: [String], _ fields: [String]) -> Bool {
        let text = fold(fields.joined(separator: "\n"))
        return terms.allSatisfy(text.contains)
    }
}
