import MossadCore
import SwiftUI

/// The band at the top of a person's page, as a meeting's: the photo or initials, the name, the job and the team,
/// every address, the actions, and the numbers of the two of you. The tabs sit on its lower edge.
struct PersonHeader: View {
    @EnvironmentObject var controller: AppController
    let profile: VoiceProfile
    let stats: PersonStats
    let org: OrgChart.Match?
    let chart: OrgChart?
    let others: [VoiceProfile]
    /// Nil while it is made.
    let together: PersonMeetings.Together?
    let rename: () -> Void
    let merge: (VoiceProfile) -> Void
    let delete: () -> Void
    let changed: () -> Void

    @State private var adding = false

    private var first: String { profile.name.split(separator: " ").first.map(String.init) ?? profile.name }
    private var personID: String? { controller.personID(of: profile.name) }
    private var keepsRead: Bool { controller.keepsRead(profile.name) }
    /// The job, the team, and the photo from Google's directory, when it has this person.
    private var directory: DirectoryDetails? { saved?.directory }
    private var saved: Person? { controller.savedPerson(of: profile) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: Space.l) {
                avatar
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                        Text(profile.name)
                            .font(.system(size: Detail.titleSize, weight: .semibold)).tracking(Detail.titleSize * -0.02)
                            .foregroundStyle(Palette.ink)
                            .lineLimit(1)
                            .textSelection(.enabled)
                            .accessibilityAddTraits(.isHeader)
                        if profile.isOwner {
                            Text("You").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.secondary)
                                .padding(.horizontal, 7).frame(height: 18)
                                .background(Palette.fill, in: Capsule())
                        }
                    }
                    if let role = roleLine {
                        Text(role).font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.ink).lineLimit(1)
                    }
                    emails
                }
                Spacer(minLength: Space.m)
                actions
            }
            figures.padding(.top, 26)
        }
        .frame(maxWidth: Detail.columnMax, alignment: .leading)
        .padding(.horizontal, Detail.gutter)
        .padding(.top, Detail.bandPadding)
        .padding(.bottom, Detail.bandPadding + 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.band)
        .hairline(.bottom)
    }

    // MARK: Who

    @ViewBuilder
    private var avatar: some View {
        if let photo = directory?.photoURL {
            // The directory's photo, from Google; the initials while it loads or when it cannot.
            AsyncImage(url: photo) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                PersonMark(name: profile.name, size: 56, isOwner: profile.isOwner)
            }
            .frame(width: 56, height: 56)
            .clipShape(Circle())
            .accessibilityHidden(true)
        } else {
            PersonMark(name: profile.name, size: 56, isOwner: profile.isOwner)
        }
    }

    /// "VP, Planning · reports to Sam Park", from the org chart; else "Staff Engineer · Platform" from the directory.
    private var roleLine: String? {
        guard let org else {
            let parts = [directory?.jobTitle, directory?.department].compactMap { $0 }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }
        var parts: [String] = []
        if !org.person.title.isEmpty { parts.append(org.person.title) }
        if let manager = chart?.manager(of: org.person.id) { parts.append("reports to \(manager.fullName)") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The addresses Google's directory gave that the owner did not: shown, and they come again at each read.
    private var directoryEmails: [String] {
        guard let person = saved else { return [] }
        let mine = Set(profile.emails.map { $0.lowercased() })
        return person.emails.filter { $0.state == .seen && $0.source == .googleDirectory && !mine.contains($0.address) }.map(\.address)
    }

    /// Every address, then "Add email". A right click on an address copies or removes it.
    private var emails: some View {
        FlowLayout(spacing: Space.s) {
            ForEach(profile.emails, id: \.self) { email in
                Text(email)
                    .font(.system(size: 12.5)).foregroundStyle(Palette.secondary)
                    .textSelection(.enabled)
                    .contextMenu {
                        Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(email, forType: .string) }
                        Button("Remove \(email)", role: .destructive) { remove(email) }
                        Button("Not \(first)’s address") { reject(email) }
                            .help("Mossad never gives this address to \(first) again, also not by the company domains")
                    }
            }
            ForEach(directoryEmails, id: \.self) { email in
                Text(email).font(.system(size: 12.5)).foregroundStyle(Palette.tertiary)
                    .textSelection(.enabled)
                    .help("From Google's directory")
                    .contextMenu {
                        Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(email, forType: .string) }
                        Button("Not \(first)’s address") { reject(email) }
                    }
            }
            Button { adding = true } label: {
                Label(profile.emails.isEmpty ? "Add email" : "Add", systemImage: "plus")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Palette.accent)
            .help("Add an address of \(first)")
            .popover(isPresented: $adding, arrowEdge: .bottom) {
                AddEmailPopover(profile: profile, others: others, merge: merge, done: { adding = false; changed() })
            }
        }
        .frame(maxWidth: Detail.titleMax, alignment: .leading)
    }

    /// "Not their address": gone from the person, and saved as not theirs, so no rule and no directory read gives
    /// it back.
    private func reject(_ email: String) {
        do {
            if profile.emails.contains(where: { $0.caseInsensitiveCompare(email) == .orderedSame }) { try controller.library.removeEmail(email, for: profile.name) }
            if let store = controller.library.identity?.people, let id = store.id(forVoiceName: profile.name, isOwner: profile.isOwner) {
                try store.rejectEmail(email, for: id)
            }
        } catch { Log.error("Saving an address as not the person's failed: \(error)") }
        changed()
    }

    private func remove(_ email: String) {
        do { try controller.library.removeEmail(email, for: profile.name) } catch { Log.error("Removing an address failed: \(error)") }
        changed()
    }

    private var actions: some View {
        Menu {
            Button(action: rename) { Label { Text("Edit name and email…") } icon: { Icon.pencil.image } }
            Button("Add email…", systemImage: "plus") { adding = true }
            if !profile.emails.isEmpty {
                Menu("Remove email") {
                    ForEach(profile.emails, id: \.self) { email in Button(email) { remove(email) } }
                }
            }
            if !(profile.emails + directoryEmails).isEmpty {
                Menu("Not \(first)’s address") {
                    ForEach(profile.emails + directoryEmails, id: \.self) { email in Button(email) { reject(email) } }
                }
            }
            Menu {
                ForEach(others, id: \.name) { target in Button(target.name) { merge(target) } }
            } label: {
                Label { Text("Merge into") } icon: { Icon.merge.image }
            }
            .disabled(profile.isOwner || others.isEmpty)
            if !profile.isOwner, personID != nil, controller.personasOn {
                Toggle("Keep a read on \(first)", isOn: Binding(get: { keepsRead }, set: { controller.setKeepsRead(profile.name, $0) }))
            }
            Divider()
            Button("Delete…", systemImage: "trash", role: .destructive, action: delete).disabled(profile.isOwner)
        } label: {
            IconImage(.more, size: 15).accessibilityLabel("Actions for \(profile.name)")
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
        .fixedSize()
    }

    // MARK: Numbers

    /// Meetings, last met, how often, and time together. Only a meeting they spoke in with the owner there proves
    /// that the two met; the count says how many were only an invite.
    private var figures: some View {
        let t = together
        let owner = profile.isOwner
        let count: (String, String) = (t.map { "\($0.meetings)" } ?? "–", t.map { Self.countLabel($0, owner: owner) } ?? "meetings")
        let last: (String, String) = (t.map { $0.lastMet.map(shortDay) ?? ($0.meetings > 0 ? "Not known" : "Not yet") } ?? "–",
                                      owner ? "last meeting" : "last met")
        let often: (String, String) = {
            guard let t else { return ("–", "how often") }
            if let c = t.cadence { return (c.word, "\(t.recent) in the last 90 days") }
            return ("\(t.recent)", t.recent == 1 ? "meeting in the last 90 days" : "meetings in the last 90 days")
        }()
        let time: (String, String) = (t.map { $0.seconds > 0 ? talkText($0.seconds) : "None" } ?? "–", owner ? "in meetings" : "time together")
        return FigureRow(figures: [count, last, often, time], ruled: false, maxWidth: Detail.titleMax)
    }

    /// "meetings together" only when each one proves it; else what they are: "meetings · 2 only invited · 1 from notes".
    static func countLabel(_ t: PersonMeetings.Together, owner: Bool) -> String {
        let word = t.meetings == 1 ? "meeting" : "meetings"
        if owner { return word }
        if t.met == t.meetings, t.meetings > 0 { return word + " together" }
        var parts = [word]
        if t.invitedOnly > 0 { parts.append("\(t.invitedOnly) only invited") }
        let notes = t.meetings - t.met - t.invitedOnly
        if notes > 0 { parts.append("\(notes) from notes") }
        return parts.joined(separator: " · ")
    }
}

/// One more address for a person. An address is one person's only: one that someone else has is never moved;
/// the owner can merge the two instead.
private struct AddEmailPopover: View {
    @EnvironmentObject var controller: AppController
    let profile: VoiceProfile
    let others: [VoiceProfile]
    let merge: (VoiceProfile) -> Void
    let done: () -> Void
    @State private var text = ""
    @State private var problem: EmailAddResult?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Add an address of \(profile.name)").font(.system(size: 13, weight: .semibold))
            TextField("Email", text: $text, prompt: Text("name@example.com"))
                .textFieldStyle(.roundedBorder)
                .onSubmit(add)
                .onChange(of: text) { _, _ in problem = nil }
            switch problem {
            case .belongsTo(let other):
                Text("\(other) has this address. An address is one person’s only.")
                    .font(.system(size: 12)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
                if let target = others.first(where: { $0.name == other }), !profile.isOwner {
                    Button("Merge \(profile.name) into \(other)") {
                        merge(target)
                        done()
                    }
                    .help("They are one person: one page with every address and every voice sample")
                }
            case .notAnAddress:
                Text("That is not an email address.").font(.system(size: 12)).foregroundStyle(Palette.secondary)
            case .alreadyTheirs:
                Text("\(profile.name) has this address already.").font(.system(size: 12)).foregroundStyle(Palette.secondary)
            default:
                Text("Mossad finds \(profile.name) in invites by each address.").font(.system(size: 11)).foregroundStyle(Palette.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", action: done).keyboardShortcut(.cancelAction)
                Button("Add", action: add)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 320)
    }

    private func add() {
        do {
            let result = try controller.library.addEmail(text, for: profile.name)
            if result == .added {
                controller.relinkEmails()
                done()
            } else {
                problem = result
            }
        } catch {
            Log.error("Adding an address failed: \(error)")
        }
    }
}
