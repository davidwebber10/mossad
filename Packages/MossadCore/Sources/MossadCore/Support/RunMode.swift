import Foundation

/// Whether the window app records and processes (`full`) or only shows (`inert`). A run on a made-up registry is
/// inert, so a proof run never records a call or touches a service.
public enum RunMode: Equatable, Sendable {
    case full, inert

    public static func decide(preview: Bool, rehearsal: Bool, secondCopy: Bool, madeUpRegistry: Bool) -> RunMode {
        preview || rehearsal || secondCopy || madeUpRegistry ? .inert : .full
    }
}
