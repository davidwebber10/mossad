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
    @State private var deleting: (uploader: ProfileUploader, id: String)?

    var body: some View {
        let book = profiles.book
        List {
            Section {
                ForEach(book.listed) { profile in
                    row(profile, active: profile.id == book.activeProfile.id)
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

            let leaving = profiles.leavingWithRecordings
            if !leaving.isEmpty {
                Section {
                    ForEach(leaving, id: \.profile.id) { item in
                        Text(item.profile.name).textRole(.headline).foregroundStyle(Palette.ink)
                        ForEach(item.uploader.outbox.entries) { entry in
                            leftRecording(entry, uploader: item.uploader)
                        }
                    }
                } header: {
                    PhoneLabel(PhoneProfileWords.leavingTitle)
                } footer: {
                    Text(PhoneProfileWords.leavingFooter).foregroundStyle(Palette.secondary)
                }
                .listRowBackground(Palette.fill)
            }
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
            Text("The audio is deleted from this iPhone. Your Mac never got it.")
        }
    }

    private func row(_ profile: PhoneProfile, active: Bool) -> some View {
        let uploader = profiles.uploader(for: profile)
        let count = uploader?.outbox.entries.count ?? 0
        let troubled = uploader.map { u in u.outbox.entries.contains { u.syncStatus.uploads[$0.id] != nil } } ?? false
        let line: (String, Color)? = if uploader == nil {
            (PhoneProfileWords.cannotOpen, Palette.recording)
        } else if let note = PhoneProfileWords.note(for: profile, hasServer: uploader?.server != nil) {
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
                Button("Delete", role: .destructive) { deleting = (uploader, entry.id) }
                    .foregroundStyle(Palette.recording)
                    .disabled(!uploader.canRemove(entry.id, active: active(of: uploader)))
            }
            .buttonStyle(.borderless)
            .textRole(.secondary)
        }
        .padding(.vertical, 4)
    }

    /// The recording that runs now, for the profile that shows: a profile that left can still show while it records.
    private func active(of uploader: ProfileUploader) -> String? {
        uploader === profiles.store.uploader ? profiles.store.recorder.id : nil
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
