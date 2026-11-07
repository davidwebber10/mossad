import Foundation

/// "Jordan L." for "Jordan Lee", so two people with one first name stay apart; unnamed voices keep their
/// label ("Speaker C").
func shortName(_ name: String) -> String {
    if name.hasPrefix("Speaker ") || name.contains("@") { return name }
    let words = name.split(separator: " ")
    guard let first = words.first else { return name }
    guard words.count > 1, let initial = words.last?.first else { return String(first) }
    return "\(first) \(initial)."
}

/// The first word of a name, for matching an action item owner written as a first name.
func firstName(_ name: String) -> String {
    name.split(separator: " ").first.map(String.init) ?? name
}
