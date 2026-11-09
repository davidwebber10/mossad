import MossadCore
import SwiftUI

/// Rehearsal's slim bar over setup.
struct RehearsalBar: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        HStack(spacing: Space.s) {
            RehearsalMark()
            Spacer(minLength: 0)
        }
        .padding(.leading, Onboard.gutter - 12).padding(.trailing, 16)
        .frame(height: Onboard.topRow)
        .background { WindowDragArea() }
    }
}
