import Foundation
import MossadCore

extension AppController {
    /// How far back the first run reads calls for commitments.
    static let commitmentsBackfillDays = 14.0

    var commitmentBook: CommitmentBook { (try? CommitmentBook.load(from: paths.commitments)) ?? CommitmentBook() }

    /// Reads new calls for what the owner promised, one at a time.
    func runCommitments() {
        guard !isInert else { return }
        guard !findingCommitments, let llm = languageModel else { return }
        if commitmentsSince == 0 { commitmentsSince = Date().addingTimeInterval(-Self.commitmentsBackfillDays * 86_400).timeIntervalSince1970 }
        findingCommitments = true
        let runner = CommitmentRunner(paths: paths, finder: CommitmentFinder(llm: llm, ownerName: ownerName),
                                      since: Date(timeIntervalSince1970: commitmentsSince))
        Task {
            if await runner.run() > 0 {
                commitmentsVersion += 1
                syncNow()
            }
            findingCommitments = false
        }
    }

    func changeCommitments(_ change: (inout CommitmentBook) -> Void) {
        // A book that cannot be read is not an empty book: saving a changed empty one would replace every commitment.
        do {
            var book = try CommitmentBook.load(from: paths.commitments)
            change(&book)
            try book.save(to: paths.commitments)
        } catch { Log.error("Saving commitments failed: \(error)") }
        commitmentsVersion += 1
        syncNow()
    }

    /// Gives each commitment the id of the person it was promised to, on a sure match, and the person's name of
    /// now after a rename. It writes only when something changed, with a copy of the book as it was before the
    /// first change. An id is not the owner's change, so the time of the last change stays.
    func linkCommitmentPeople(_ people: [Person], records: [CallRecord]) {
        guard !isInert, !people.isEmpty else { return }
        let refs = PersonReferences(people: people)
        let file = paths.commitments.appendingPathComponent(CommitmentBook.fileName)
        guard let book = try? CommitmentBook.load(from: paths.commitments), refs.refresh(book, records: records) != book,
              ReferenceBackup.keep(file, as: CommitmentBook.fileName, paths: paths) else { return }
        changeCommitments { $0 = refs.refresh($0, records: records) }
    }

    func saveCommitment(_ c: Commitment) {
        changeCommitments { book in
            if book.items.contains(where: { $0.id == c.id }) {
                book.update(c.id) { $0 = c }
            } else {
                book.items.append(c)
            }
        }
    }

    func toggleDone(_ id: UUID) {
        changeCommitments { $0.update(id) { $0.done = $0.done == nil ? Date() : nil } }
    }

    func deleteCommitment(_ id: UUID) {
        changeCommitments { $0.delete(id) }
    }
}
