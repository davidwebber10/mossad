import MossadCore
import SwiftUI

/// The state a meeting row and the calendar call out next to its length.
enum MeetingBadge { case needsNames, processing, failed, recording }

extension Platform {
    var color: Color { Palette.platform(self) }
}
