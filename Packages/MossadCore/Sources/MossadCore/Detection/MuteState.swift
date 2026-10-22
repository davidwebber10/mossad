import Foundation

/// Whether the person is muted in the call app, read from the labels of its mute button.
/// The button names the action it would take: "Turn on microphone" shows up while muted.
public enum MuteState {
    /// nil when no known label is present: unknown never changes the recording.
    public static func from(labels: [String], platform: Platform) -> Bool? {
        let lower = labels.map { $0.lowercased() }
        func has(_ prefix: String) -> Bool { lower.contains { $0.hasPrefix(prefix) } }
        switch platform {
        case .meet:
            if has("turn on microphone") { return true }
            if has("turn off microphone") { return false }
        case .zoom:
            if has("unmute audio") || has("unmute my audio") { return true }
            if has("mute audio") || has("mute my audio") { return false }
        case .inPerson:
            return nil
        case .teams:
            if has("unmute") { return true }
            if has("mute (") || lower.contains("mute") { return false }
        }
        return nil
    }
}
