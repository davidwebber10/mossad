import MossadCore
import SwiftUI

/// The "Coach" section of an upcoming meeting's page. Its only input is `PrepCoach` (MossadCore, `Prep/`), which
/// `MeetingPrep` fills from the coach's memory; the page shows the section only when the input is not empty.
///
/// Today it shows, for each invited person the coach knows, the one line of the coach's read on them and the
/// coach's note. The coach is being designed again: what it adds for a meeting to come goes into `PrepCoach` and
/// is drawn here, and nothing else on the page changes.
struct PrepCoachSection: View {
    let input: PrepCoach

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(input.people) { person in
                VStack(alignment: .leading, spacing: 2) {
                    PersonName(person.name, person: .some(person.name))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Palette.secondary)
                    if let headline = person.headline {
                        Text(headline).foregroundStyle(Palette.ink).fixedSize(horizontal: false, vertical: true)
                    }
                    if let note = person.note {
                        Text(note).foregroundStyle(person.headline == nil ? Palette.ink : Palette.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .font(.system(size: 13))
        .textSelection(.enabled)
    }
}
