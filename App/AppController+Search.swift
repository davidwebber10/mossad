import Combine
import Foundation
import MossadCore

extension AppController {
    /// Meetings settle in bursts while a call is processed, so changes wait a moment and go in together.
    func observeForSearch() {
        searchObservers = [
            $meetings.debounce(for: .milliseconds(400), scheduler: RunLoop.main)
                .sink { [weak self] _ in MainActor.assumeIsolated { self?.updateSearch() } },
            $commitmentsVersion.dropFirst().receive(on: RunLoop.main)
                .sink { [weak self] _ in MainActor.assumeIsolated { self?.updateSearch() } },
            $chatsVersion.dropFirst().receive(on: RunLoop.main)
                .sink { [weak self] _ in MainActor.assumeIsolated { self?.updateSearch() } },
            // The Meetings list search runs again on each new index, so a changed meeting shows its new place.
            search.$version.dropFirst().receive(on: RunLoop.main)
                .sink { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, !self.meetingQuery.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                        self.filterMeetings(debounce: false)
                    }
                },
        ]
    }

    /// Command-F: the page's own search when it has one, else the search of everything.
    func find() {
        guard !search.isOpen else { return }
        if listSearches > 0 { findRequest += 1 } else { openSearch() }
    }

    func updateSearch() {
        search.update(SearchModel.Snapshot(records: meetings, library: library, paths: paths))
    }

    /// Command-K: opens the palette over the window, or closes it when it is open.
    func toggleSearch() {
        if search.isOpen { search.isOpen = false } else { openSearch() }
    }

    func openSearch(_ query: String? = nil) {
        if let query { search.query = query }
        open(section)
        // People, tasks, and chats can change without a signal (an edit in People, a new chat): take them in now.
        updateSearch()
        search.isOpen = true
        search.search()
    }

    /// Opens a result where it lives and closes the palette. `transcript` (Command-Return) opens a meeting's
    /// Transcript tab rather than its summary.
    func openResult(_ hit: SearchHit, transcript: Bool = false) {
        search.isOpen = false
        search.remember(search.query)
        switch hit {
        case .meeting(let m):
            if transcript { openTranscript(m.callID) } else { openMeeting(m.callID) }
        case .moment(let m):
            openMeeting(m.callID, at: m.time)
        case .person(let p):
            openPerson(p.name.text)
        case .outcome(let o):
            if let at = o.time { showMoment(o.callID, at: at) } else if transcript { openTranscript(o.callID) } else { openMeeting(o.callID) }
        case .task(let t):
            taskToOpen = t.commitmentID
            open(.commitments)
        case .chat(let c):
            chatToOpen = c.chatID
            open(.chat)
        }
    }

    func openTranscript(_ callID: String) {
        seekRequest = SeekRequest(callID: callID, at: 0, play: false, mark: false)
        openMeeting(callID)
    }
}
