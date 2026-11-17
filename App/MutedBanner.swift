import MossadCore
import SwiftUI

/// Shown while the person is muted in the call app: Mossad records silence on their mic meanwhile. When the mute
/// button could not be read for a while, it says the owner was muted when last seen, and that the mic records. A
/// quiet note on the fill, not a warning: being muted is normal.
struct MutedBanner: View {
    let mute: ShownMute
    let platform: Platform
    var compact = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.m) {
            Image(systemName: "mic.slash").font(.system(size: compact ? 12 : 13.5, weight: .medium)).foregroundStyle(Palette.secondary)
            let words = mute.banner(platform: platform) ?? (lead: "", detail: "")
            Text("\(Text(words.lead).fontWeight(.semibold).foregroundStyle(Palette.ink)) \(Text(words.detail).foregroundStyle(Palette.secondary))")
                .font(.system(size: compact ? 12 : 12.5))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, compact ? 10 : 14).padding(.vertical, compact ? 8 : 10)
        .background(Palette.fill, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}
