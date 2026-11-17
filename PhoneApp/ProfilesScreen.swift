import MossadCore
import SwiftUI

/// Settings › Profile: the profiles this iPhone knows, the switch, "Add a profile", and the recordings of a profile
/// that left the Mac. Every rule is `PhoneProfileBook`'s, `PhoneProfileSwitch`'s, and `ProfileCode`'s.
struct ProfilesScreen: View {
    let close: () -> Void
    @Environment(PhoneProfiles.self) private var profiles
    @State private var scanning = false
    @State private var applying = false
    @State private var added: String?
    @State private var addProblem: FriendlyError?
    @State private var deleting: (uploader: ProfileUploader, id: String, sent: Bool)?
    /// Which profiles have a server, read off the main actor: each read is a Keychain read.
    @State private var servers: [String: Bool] = [:]

    var body: some View {
        let book = profiles.book
        List {
            Section {
                ForEach(book.listed) { profile in
                    row(profile, active: profile.id == profiles.shownProfile.id)
                }
            } footer: {
                if let problem = profiles.problem { Text(problem).foregroundStyle(Palette.recording) }
            }
            .listRowBackground(Palette.fill)

            Section {
                Button("Add a profile") { scanning = true }
                    .foregroundStyle(Palette.accent)
                    .disabled(applying)
            } footer: {
                if applying {
                    Text("Checking the code…").foregroundStyle(Palette.secondary)
                } else if let added {
                    Text(added).foregroundStyle(Palette.secondary)
                } else if let addProblem {
                    Text(addProblem.message).foregroundStyle(Palette.recording)
                }
            }
            .listRowBackground(Palette.fill)

            // A profile the Mac dropped, and one the owner removed here, each under its own words.
            let leaving = profiles.leavingWithRecordings
            gone(leaving.filter { !$0.profile.removedHere }, title: PhoneProfileWords.leavingTitle, footer: PhoneProfileWords.leavingFooter)
            gone(leaving.filter { $0.profile.removedHere }, title: PhoneProfileWords.removedTitle, footer: PhoneProfileWords.removedFooter)
        }
        .phonePage()
        .navigationTitle("Profile")
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $scanning) {
            CodeScanner { code in
                scanning = false
                take(code)
            }
            .ignoresSafeArea()
            .overlay(alignment: .topTrailing) {
                Button("Cancel") { scanning = false }.buttonStyle(.borderedProminent).padding()
            }
        }
        .onAppear { if !profiles.switchHeld { profiles.problem = nil } }
        .task(id: book.listed.map(\.id)) {
            for p in book.listed { if let u = profiles.uploader(for: p) { servers[p.id] = await u.hasServer() } }
        }
        .confirmationDialog("Delete this recording?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let deleting {
                    deleting.uploader.remove(deleting.id, active: active(of: deleting.uploader))
                    Task { await profiles.cleanUp() }
                }
                deleting = nil
            }
        } message: {
            Text(PhoneProfileWords.deleteMessage(sent: deleting?.sent ?? false))
        }
    }

    private func row(_ profile: PhoneProfile, active: Bool) -> some View {
        let uploader = profiles.uploader(for: profile)
        let count = uploader?.outbox.entries.count ?? 0
        let troubled = uploader.map { u in u.outbox.entries.contains { u.syncStatus.uploads[$0.id] != nil } } ?? false
        let line: (String, Color)? = if uploader == nil {
            (PhoneProfileWords.cannotOpen, Palette.recording)
        } else if let note = PhoneProfileWords.note(for: profile, hasServer: servers[profile.id] ?? true) {
            (note, Palette.secondary)
        } else if count > 0 {
            (PhoneProfileWords.waiting(count), troubled ? Palette.recording : Palette.secondary)
        } else {
            nil
        }
        return Button {
            Task {
                await profiles.switchTo(profile.id)
                if profiles.store.context.id == profile.id, !active { close() }
            }
        } label: {
            HStack(spacing: Space.m) {
                ProfileDot(color: profile.color, size: 10)
                VStack(alignment: .leading, spacing: Rhythm.pairGap) {
                    Text(profile.name).textRole(.headline).foregroundStyle(Palette.ink)
                    if let line { Text(line.0).textRole(.secondary).foregroundStyle(line.1).fixedSize(horizontal: false, vertical: true) }
                }
                Spacer(minLength: Space.s)
                if active { Image(systemName: "checkmark").foregroundStyle(Palette.accent).accessibilityHidden(true) }
            }
            .padding(.vertical, 4)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(PhoneProfileWords.label(profile.name))
        .accessibilityValue(line?.0 ?? "")
        .accessibilityAddTraits(active ? .isSelected : [])
        .swipeActions {
            if profile.source == .code, !active {
                Button("Remove from this iPhone", role: .destructive) { profiles.remove(profile.id) }
            }
        }
    }

    private func leftRecording(_ entry: Outbox.Entry, uploader: ProfileUploader) -> some View {
        let r = entry.recording
        let file = RoomAudio.finished(entry.id, in: uploader.recordingsFolder)
        return VStack(alignment: .leading, spacing: Space.s) {
            HStack {
                Text(r.title ?? (r.isPhoneCall ? CallImport.placeholder : "In-person meeting")).textRole(.body).foregroundStyle(Palette.ink)
                Spacer(minLength: Space.s)
                Text(duration(r.end.timeIntervalSince(r.start))).textRole(.secondary).foregroundStyle(Palette.secondary)
            }
            Text(r.start.formatted(date: .abbreviated, time: .shortened)).textRole(.secondary).foregroundStyle(Palette.secondary)
            HStack(spacing: Space.l) {
                if FileManager.default.fileExists(atPath: file.path) {
                    ShareLink(item: file) { Text("Share audio") }.foregroundStyle(Palette.accent)
                }
                Button("Delete", role: .destructive) { deleting = (uploader, entry.id, entry.isSent) }
                    .foregroundStyle(Palette.recording)
                    .disabled(!uploader.canRemove(entry.id, active: active(of: uploader)))
            }
            .buttonStyle(.borderless)
            .textRole(.secondary)
        }
        .padding(.vertical, 4)
    }

    /// The app's one recording that runs now, whichever profile it is in: its Delete is off.
    private func active(of uploader: ProfileUploader) -> String? {
        profiles.recorder.id
    }

    @ViewBuilder
    private func gone(_ items: [(profile: PhoneProfile, uploader: ProfileUploader)], title: String, footer: String) -> some View {
        if !items.isEmpty {
            Section {
                ForEach(items, id: \.profile.id) { item in
                    Text(item.profile.name).textRole(.headline).foregroundStyle(Palette.ink)
                    ForEach(item.uploader.outbox.entries) { entry in
                        leftRecording(entry, uploader: item.uploader)
                    }
                }
            } header: {
                PhoneLabel(title)
            } footer: {
                Text(footer).foregroundStyle(Palette.secondary)
            }
            .listRowBackground(Palette.fill)
        }
    }

    private func take(_ code: String) {
        applying = true
        added = nil
        addProblem = nil
        Task {
            defer { applying = false }
            switch await profiles.apply(ProfileCode.parse(code)) {
            case .done(let words): added = words
            case .failed(let problem): addProblem = problem
            }
        }
    }
}

/// The Meetings title's mark: the profile's dot and name. It opens Settings on the Profile screen.
struct ProfileMark: View {
    let profile: PhoneProfile
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: Space.s) {
                ProfileDot(color: profile.color, size: 10)
                Text(profile.name).textRole(.secondary).fontWeight(.semibold).foregroundStyle(Palette.ink).lineLimit(1)
            }
        }
        .accessibilityLabel(PhoneProfileWords.label(profile.name))
    }
}
