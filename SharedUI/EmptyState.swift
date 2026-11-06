import SwiftUI

/// A page or tab with nothing to show yet: a quiet symbol, what is missing, what fills it, and at most one
/// action. No card around it; it sits on the page.
struct EmptyState: View {
    let symbol: String
    let title: String
    let message: String
    var action: (title: String, run: () -> Void)?

    @ScaledMetric(relativeTo: .title2) private var symbolSize: CGFloat = 26
    @ScaledMetric(relativeTo: .headline) private var titleSize: CGFloat = 14
    @ScaledMetric(relativeTo: .body) private var messageSize: CGFloat = 13

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: symbolSize, weight: .light))
                .foregroundStyle(Palette.tertiaryMark)
                .frame(height: symbolSize + 6)
                .accessibilityHidden(true)
            Text(title)
                .font(.system(size: titleSize, weight: .semibold))
                .foregroundStyle(Palette.ink)
                .multilineTextAlignment(.center)
            Text(message)
                .font(.system(size: messageSize))
                .foregroundStyle(Palette.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(messageSize * 0.3)
                .frame(maxWidth: 300)
                .fixedSize(horizontal: false, vertical: true)
            if let action {
                Button(action.title, action: action.run)
                    .buttonStyle(.mossadFill)
                    .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
        .accessibilityElement(children: .contain)
    }
}

/// The quiet secondary button of the canvas: ink on the fill, 26 pt tall. Banners and empty states use it.
struct FillButtonStyle: ButtonStyle {
    @ScaledMetric(relativeTo: .body) private var textSize: CGFloat = 12.5
    @ScaledMetric(relativeTo: .body) private var height: CGFloat = 26
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: textSize, weight: .medium))
            .foregroundStyle(Palette.ink)
            .lineLimit(1)
            .padding(.horizontal, 11)
            .frame(height: height)
            .background(Palette.fill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                if configuration.isPressed {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.fill)
                }
            }
            .opacity(isEnabled ? 1 : 0.5)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

extension ButtonStyle where Self == FillButtonStyle {
    static var mossadFill: FillButtonStyle { FillButtonStyle() }
}
