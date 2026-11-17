#if DEBUG
import Foundation

/// The made-up meeting of the move's proof runs, in a made-up profile's empty folder only. Every name and word is
/// made up; the word "zebrafinch" marks each thing of the meeting, so a proof can show that none is left behind.
public enum MoveProof {
    public static let mark = "zebrafinch"

    /// An audio file imported as a room recording, then set to `summarized` with two voices (the owner and "Sam
    /// Carter"), a fingerprint of 8 numbers for each, six lines, a summary, and one chat that read only this call.
    /// The books name it too: a task, a point for next time that the call closed, and a coach's note. The worker's
    /// first pass makes the recording and writes the note. Returns the call id.
    public static func makeWritten(audio: URL, paths: Paths, ownerName: String, now: Date) throws -> String {
        let start = now.addingTimeInterval(-7200)
        let id = CallID.make(start)
        let probe = PhoneRecording(id: id, start: start, end: start.addingTimeInterval(60), title: nil)
        var r = try PhoneRecording.importAudio(audio, recording: probe, into: paths)
        r.customTitle = "Proof \(mark) meeting"
        r.speakerNames = ["me:A": ownerName, "me:B": "Sam Carter"]
        r.speakerEmbeddings = ["me:A": [0.9, 0.1, 0.2, 0.1, 0.3, 0.1, 0.2, 0.1], "me:B": [0.1, 0.8, 0.1, 0.3, 0.1, 0.2, 0.1, 0.4]]
        r.speakerSamples = ["me:A": SpeakerSampleDetail(seconds: 30, quality: 0.9), "me:B": SpeakerSampleDetail(seconds: 30, quality: 0.9)]
        r.utterances = (0..<6).map { i in
            let at = Double(i) * 5
            return Utterance(track: .me, speakerLabel: i % 2 == 0 ? "A" : "B", start: at, end: at + 4,
                             text: "The \(mark) count is \(i + 1).")
        }
        r.summary = "The two counted \(mark) birds for the proof."
        r.status = .summarized
        try r.save(to: paths.callDirectory(id))

        var chat = Chat(title: r.title)
        chat.callID = id
        chat.messages = [ChatMessage(role: .user, text: "How many \(mark) birds?"),
                         ChatMessage(role: .assistant, text: "Six, see [00:25](mossad://call/\(id)?t=25)")]
        try ChatStore(directory: paths.chats).save(chat)

        var tasks = (try? CommitmentBook.load(from: paths.commitments)) ?? CommitmentBook()
        tasks.items.append(Commitment(text: "Count the \(mark) birds again", to: "Sam Carter", callID: id, callTitle: r.title,
                                      madeAt: start, due: nil, created: now))
        try tasks.save(to: paths.commitments)
        _ = try NextTimeBook.change(in: paths.nextTime) { book in
            var point = NextTimePoint(text: "Ask about the birds", personName: "Sam Carter", rank: 1, created: start.addingTimeInterval(-86_400))
            point.done = .init(callID: id, at: 25, quote: "The \(mark) count is 6.", date: now, byOwner: false)
            book.points.append(point)
        }
        var coach = (try? CoachProfile.load(from: paths.coach)) ?? CoachProfile()
        coach.observations.append(CoachObservation(callID: id, date: now, pattern: "Clear counts", result: .did,
                                                   note: "Counted the \(mark) birds clearly."))
        try coach.save(to: paths.coach)
        return id
    }
}
#endif
