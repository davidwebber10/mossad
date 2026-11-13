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
    /// Whether a person's read is covered now (the owner shares the screen or records a call with them), and the
    /// click that opens it.
    var covered: (String?) -> Bool = { _ in false }
    var uncover: (String?) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: Rhythm.rowGap) {
            ForEach(input.people) { person in
                VStack(alignment: .leading, spacing: Rhythm.pairGap) {
                    PersonName(person.name, person: .some(person.name))
                        .font(.system(size: Rhythm.secondarySize, weight: .semibold))
                        .foregroundStyle(Palette.secondary)
                    if covered(person.personID) {
                        PersonaCoverRow { uncover(person.personID) }.padding(.top, 2)
                    } else if person.showsCard, let card = person.card {
                        // How to present to them: for 2 people at most, built by code from shown traits.
                        PersonaCardView(card: card, first: person.name.split(separator: " ").first.map(String.init) ?? person.name, compact: true)
                            .padding(.top, 2)
                    } else if let headline = person.headline {
                        Text(headline).foregroundStyle(Palette.ink).fixedSize(horizontal: false, vertical: true)
                    }
                    if !covered(person.personID), let note = person.note {
                        Text(note).foregroundStyle(person.headline == nil ? Palette.ink : Palette.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    // What the owner confirmed about this person in the findings deck.
                    ForEach(covered(person.personID) ? [] : person.learnings, id: \.self) { learning in
                        Label(learning, systemImage: "checkmark.circle").labelStyle(.titleAndIcon)
                            .font(.system(size: Rhythm.secondarySize)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .font(.system(size: Rhythm.bodySize))
        .textSelection(.enabled)
    }
}
