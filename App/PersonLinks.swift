import MossadCore
import SwiftUI

/// Which saved person each name on a meeting page opens. Only a sure match is a link (`PersonDirectory.link`):
/// the person's email, or the whole name of one saved person. The names of the meeting itself (its speakers,
/// invited people, action item owners, and presenters) are worked out one time, when the page's people are.
struct PersonLinks: Equatable {
    /// What the links were made from. Two sets with one stamp are the same, so a page that draws four times a
    /// second does not hand every name a new environment.
    private let stamp: String
    private let directory: PersonDirectory
    /// The meeting's speakers and invited people, saved or not: a second "Sam" among them makes "Sam" unsure.
    private let meeting: [String]
    /// Nil inside means "looked up, nobody".
    private let known: [String: String?]

    init(stamp: String = "", directory: PersonDirectory = PersonDirectory(), meeting: [String] = [], names: [String] = []) {
        self.stamp = stamp
        self.directory = directory
        self.meeting = meeting
        var known: [String: String?] = [:]
        for name in names where known[name] == nil { known[name] = .some(directory.link(for: name, in: meeting)) }
        self.known = known
    }

    static func == (a: PersonLinks, b: PersonLinks) -> Bool { a.stamp == b.stamp }

    /// The saved person that a name or an email on the page opens; nil when the match is not sure.
    func person(for name: String) -> String? {
        if let hit = known[name] { return hit }
        return directory.link(for: name, in: meeting)
    }
}

/// Opens a person's profile. A class, so the environment holds one reference that never changes: a closure there
/// would look new on each draw of the page, and every name would draw again on each tick of the playback.
@MainActor
final class PersonOpener {
    private let open: (String) -> Void

    init(_ open: @escaping (String) -> Void) { self.open = open }

    func callAsFunction(_ person: String) { open(person) }
}

private struct PersonLinksKey: EnvironmentKey {
    static let defaultValue = PersonLinks()
}

private struct PersonOpenerKey: EnvironmentKey {
    static let defaultValue: PersonOpener? = nil
}

extension EnvironmentValues {
    /// The open meeting's names and their people, for `PersonName` anywhere on the page.
    var personLinks: PersonLinks {
        get { self[PersonLinksKey.self] }
        set { self[PersonLinksKey.self] = newValue }
    }

    /// How a name opens its person. Nil outside a meeting page: names are then plain text.
    var personOpener: PersonOpener? {
        get { self[PersonOpenerKey.self] }
        set { self[PersonOpenerKey.self] = newValue }
    }
}

/// A person's name on a meeting page. It opens their profile when the name is a sure match for a saved person; any
/// other name stays plain text. The font and the color come from the caller.
struct PersonName: View {
    @Environment(\.personLinks) private var links
    @Environment(\.personOpener) private var opener
    let name: String
    /// What to show when it is not the name itself: "Sam C.", "You".
    var shown: String?
    /// The person, when the caller already looked it up (nil inside: nobody). Without it the name is looked up here.
    var person: String??

    init(_ name: String, shown: String? = nil, person: String?? = nil) {
        self.name = name
        self.shown = shown
        self.person = person
    }

    var body: some View {
        if let opener, let target = person ?? links.person(for: name) {
            // VoiceOver reads what is on the page ("Sam", "You"), then where the link goes.
            Button { opener(target) } label: { Text(shown ?? name) }
                .buttonStyle(PersonLinkStyle())
                .help("Open \(target)\u{2019}s profile")
                .accessibilityHint("Opens \(target)\u{2019}s profile")
                .accessibilityAddTraits(.isLink)
                .accessibilityRemoveTraits(.isButton)
        } else {
            Text(shown ?? name)
        }
    }
}

/// A speaker of the open meeting: a link to their profile, or, for a voice with no name, the way to name it.
struct SpeakerName: View {
    let speaker: MeetingPeople.Speaker
    let callID: String
    /// False while the meeting cannot take names (it is still processing).
    var editable = true
    var shown: String?
    @State private var naming = false

    var body: some View {
        if speaker.isUnknown, editable {
            Button { naming = true } label: { Text(shown ?? speaker.name).foregroundStyle(Palette.accent) }
                .buttonStyle(.plain)
                .help("Name this voice")
                .accessibilityLabel("Name \(speaker.name)")
                .popover(isPresented: $naming, arrowEdge: .bottom) {
                    SpeakerNamingPopover(speaker: speaker, callID: callID, isPresented: $naming)
                }
        } else {
            // The same lookup as the lanes and the transcript: the speaker's own.
            PersonName(speaker.name, shown: shown, person: .some(speaker.person))
        }
    }
}

/// A name that is a link: a quiet dotted line under it at all times, so it reads as a link without the pointer,
/// and a solid line with the link pointer when the pointer is on it.
struct PersonLinkStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        LinkLabel(configuration: configuration)
    }

    private struct LinkLabel: View {
        let configuration: Configuration
        @State private var hovered = false

        var body: some View {
            configuration.label
                .underline(true, pattern: hovered ? .solid : .dot, color: hovered ? nil : Palette.tertiaryMark)
                .opacity(configuration.isPressed ? 0.6 : 1)
                .contentShape(Rectangle())
                .onHover { hovered = $0 }
                .pointerStyle(.link)
        }
    }
}
