import Foundation

/// The words of Settings > General > Profiles that depend on the state of the file.
public enum ProfileSettingsWords {
    /// The group's footer, or nil when the file is as it should be.
    public static func footer(_ loaded: ProfileRegistry.Loaded) -> String? {
        switch loaded.state {
        case .none, .read: nil
        case .unreadable: "The list of profiles could not be read. Mossad did not change it."
        case .newer: "A newer Mossad wrote the list of profiles. This one can switch, but changes nothing in it."
        case .partial: "Mossad left out a profile whose folder it cannot use: \(loaded.leftOut.joined(separator: ", ")). It did not change the file."
        }
    }
}
