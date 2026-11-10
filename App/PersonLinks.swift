import MossadCore
import SwiftUI

/// Which saved person each name on a meeting page stands for. The names of the meeting itself (its speakers,
/// invited people, action item owners, and presenters) are worked out one time, when the page's people are.
struct PersonLinks: Equatable {
    /// What the links were made from. Two sets with one stamp are the same, so a page that draws four times a
    /// second does not hand every name a new environment.
    private let stamp: String
    private let directory: PersonDirectory
    private let context: [String]
    /// Nil inside means "looked up, nobody".
    private let known: [String: String?]

    init(stamp: String = "", directory: PersonDirectory = PersonDirectory(), context: [String] = [], names: [String] = []) {
        self.stamp = stamp
        self.directory = directory
        self.context = context
        var known: [String: String?] = [:]
        for name in names where known[name] == nil { known[name] = .some(directory.person(for: name, among: context)) }
        self.known = known
    }

    static func == (a: PersonLinks, b: PersonLinks) -> Bool { a.stamp == b.stamp }

    /// The saved person for a name or an email as written on the page; nil when it stands for nobody Mossad knows.
    func person(for name: String) -> String? {
        if let hit = known[name] { return hit }
        return directory.person(for: name, among: context)
    }
}

private struct PersonLinksKey: EnvironmentKey {
    static let defaultValue = PersonLinks()
}

extension EnvironmentValues {
    /// The open meeting's names and their people, for `PersonName` anywhere on the page.
    var personLinks: PersonLinks {
        get { self[PersonLinksKey.self] }
        set { self[PersonLinksKey.self] = newValue }
    }
}

/// A person's name on a meeting page. It opens their profile when the name stands for a saved person; any other
/// name stays plain text. The font and the color come from the caller.
struct PersonName: View {
    @EnvironmentObject private var controller: AppController
    @Environment(\.personLinks) private var links
    let name: String
    /// What to show when it is not the name itself: "Sam C.", "You".
    var shown: String?

    init(_ name: String, shown: String? = nil) {
        self.name = name
        self.shown = shown
    }

    var body: some View {
        if let person = links.person(for: name) {
            Button { controller.openPerson(person) } label: { Text(shown ?? name) }
                .buttonStyle(PersonLinkStyle())
                .help("Open \(person)\u{2019}s profile")
                .accessibilityLabel("Open \(person)\u{2019}s profile")
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
                .buttonStyle(PersonLinkStyle())
                .help("Name this voice")
                .accessibilityLabel("Name \(speaker.name)")
                .popover(isPresented: $naming, arrowEdge: .bottom) {
                    SpeakerNamingPopover(speaker: speaker, callID: callID, isPresented: $naming)
                }
        } else {
            PersonName(speaker.name, shown: shown)
        }
    }
}

/// A name that is a link: plain until the pointer is on it, then underlined, with the link pointer.
struct PersonLinkStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        LinkLabel(configuration: configuration)
    }

    private struct LinkLabel: View {
        let configuration: Configuration
        @State private var hovered = false

        var body: some View {
            configuration.label
                .underline(hovered)
                .opacity(configuration.isPressed ? 0.6 : 1)
                .contentShape(Rectangle())
                .onHover { hovered = $0 }
                .pointerStyle(.link)
        }
    }
}
