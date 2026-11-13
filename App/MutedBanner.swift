import MossadCore
import SwiftUI

/// Shown while the person is muted in the call app: Mossad records silence on their mic meanwhile. A quiet
/// note on the fill, not a warning: being muted is normal.
struct MutedBanner: View {
    let platform: Platform
    var compact = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.m) {
            Image(systemName: "mic.slash").font(.system(size: compact ? 12 : 13.5, weight: .medium)).foregroundStyle(Palette.secondary)
            Text("\(Text("Muted in \(platform.displayName).").fontWeight(.semibold).foregroundStyle(Palette.ink)) \(Text("Your mic is not recorded while you are muted.").foregroundStyle(Palette.secondary))")
                .font(.system(size: compact ? 12 : 12.5))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, compact ? 10 : 14).padding(.vertical, compact ? 8 : 10)
        .background(Palette.fill, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}
