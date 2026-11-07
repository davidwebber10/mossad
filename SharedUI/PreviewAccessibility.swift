import Foundation

/// Development hooks for screenshots: SwiftUI cannot set Reduce Transparency or Increase Contrast for one app,
/// so a `--ui-preview` run with MOSSAD_REDUCE_TRANSPARENCY=1 or MOSSAD_INCREASE_CONTRAST=1 shows those looks
/// without changing the system setting. Never in a normal run.
enum PreviewAccessibility {
    private static let preview = CommandLine.arguments.contains("--ui-preview")
    static let reduceTransparency = preview && ProcessInfo.processInfo.environment["MOSSAD_REDUCE_TRANSPARENCY"] != nil
    static let increaseContrast = preview && ProcessInfo.processInfo.environment["MOSSAD_INCREASE_CONTRAST"] != nil
}
