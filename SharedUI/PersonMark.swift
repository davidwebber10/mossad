import SwiftUI

/// A person's initials in their color. The color comes from the name, so it is the same on every device and
/// in every list.
struct PersonMark: View {
    let name: String
    var size: CGFloat = 28

    var body: some View {
        Text(Self.initials(name))
            .font(.system(size: size * 0.4, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Self.color(for: name).gradient, in: Circle())
            .accessibilityHidden(true)
    }

    static let palette: [Color] = [
        Color(red: 0.04, green: 0.48, blue: 1), Color(red: 1, green: 0.58, blue: 0), Color(red: 0.69, green: 0.32, blue: 0.87),
        Color(red: 0.2, green: 0.78, blue: 0.35), Color(red: 1, green: 0.18, blue: 0.33), Color(red: 0.19, green: 0.69, blue: 0.78),
        Color(red: 0.37, green: 0.36, blue: 0.9), Color(red: 0.64, green: 0.52, blue: 0.37),
    ]

    /// A stable hash: Swift's own `hashValue` changes on every launch.
    static func color(for name: String) -> Color {
        let hash = name.lowercased().unicodeScalars.reduce(UInt32(5381)) { ($0 &<< 5) &+ $0 &+ $1.value }
        return palette[Int(hash % UInt32(palette.count))]
    }

    static func initials(_ name: String) -> String {
        let words = name.split(separator: " ").filter { $0.first?.isLetter == true }
        let letters = words.count > 1 ? [words.first!, words.last!] : Array(words.prefix(1))
        return letters.compactMap { $0.first.map { String($0).uppercased() } }.joined()
    }
}
