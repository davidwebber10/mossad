import SwiftUI

/// A person's initials on their hue, as the canvas draws avatars. The hue comes from the name, so it is the same
/// on every device and in every list; the owner always has the first hue. Hollow marks someone Mossad has not met
/// or not placed: a ring and quiet initials.
struct PersonMark: View {
    let name: String
    var size: CGFloat = 28
    var isOwner = false
    var hollow = false

    var body: some View {
        Text(Self.initials(name))
            .font(.system(size: Self.textSize(size), weight: .semibold))
            .foregroundStyle(hollow ? Palette.secondary : .white)
            .frame(width: size, height: size)
            .background {
                if hollow {
                    Circle().strokeBorder(Palette.ring, lineWidth: 1.5)
                } else {
                    Circle().fill(isOwner ? Palette.speaker(0) : Self.color(for: name))
                }
            }
            .accessibilityHidden(true)
    }

    /// The canvas: 11 on a 28 pt mark, 11.5 on 32, 15 on 44.
    private static func textSize(_ size: CGFloat) -> CGFloat {
        size < 36 ? min(11.5, size * 0.4) : size * 0.34
    }

    /// A stable hash: Swift's own `hashValue` changes on every launch. The first hue is the owner's, so others
    /// take one of the other eleven.
    static func color(for name: String) -> Color {
        let hash = name.lowercased().unicodeScalars.reduce(UInt32(5381)) { ($0 &<< 5) &+ $0 &+ $1.value }
        return Palette.speaker(1 + Int(hash % UInt32(Palette.speakers.count - 1)))
    }

    static func initials(_ name: String) -> String {
        let words = name.split(separator: " ").filter { $0.first?.isLetter == true }
        let letters = words.count > 1 ? [words.first!, words.last!] : Array(words.prefix(1))
        return letters.compactMap { $0.first.map { String($0).uppercased() } }.joined()
    }
}
