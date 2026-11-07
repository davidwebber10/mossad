import MossadCore
import SwiftUI

/// The canvas's warning icon (16 pt grid, 1.5 pt round strokes), drawn here so both apps share it.
struct WarningMark: View {
    var size: CGFloat = 16

    var body: some View {
        Triangle()
            .stroke(style: StrokeStyle(lineWidth: 1.5 * size / 16, lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    /// M8 2 l6.5 11.5 h-13 z, M8 6.5 v3, M8 11.6 v.1.
    private struct Triangle: Shape {
        func path(in rect: CGRect) -> Path {
            let u = rect.width / 16
            func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * u, y: rect.minY + y * u) }
            var path = Path()
            path.move(to: p(8, 2)); path.addLine(to: p(14.5, 13.5)); path.addLine(to: p(1.5, 13.5)); path.closeSubpath()
            path.move(to: p(8, 6.5)); path.addLine(to: p(8, 9.5))
            path.move(to: p(8, 11.6)); path.addLine(to: p(8, 11.7))
            return path
        }
    }
}

/// A failure the owner should know about: what happened in a few words, what happens next, Try again when it can
/// help, and the raw error behind Details. Accent-tinted like the other "needs you" cards; red only for recording.
struct ErrorCard: View {
    let error: FriendlyError
    var retryTitle = "Try again"
    /// Shown whenever given: callers pass it only when trying again can help (`canRetry`), or after a fix.
    var retry: (() -> Void)?
    /// A line the caller adds after the sentence, such as when the audio was saved.
    var note: String?

    @State private var details = false
    @ScaledMetric(relativeTo: .headline) private var iconSize: CGFloat = ErrorLook.icon

    private var tint: Color { error.isAboutRecording ? Palette.recording : Palette.accent }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: ErrorLook.iconGap) {
                WarningMark(size: iconSize).foregroundStyle(tint).padding(.top, ErrorLook.iconTop)
                VStack(alignment: .leading, spacing: ErrorLook.lineGap) {
                    Text(error.title).textRole(.headline).foregroundStyle(Palette.ink)
                    if !sentence.isEmpty {
                        Text(sentence).textRole(.secondary).foregroundStyle(Palette.secondary)
                    }
                    #if os(iOS)
                    buttons.padding(.top, Space.s)
                    #endif
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                #if !os(iOS)
                buttons
                #endif
            }
            if details {
                Text(error.technical)
                    .font(.system(size: ErrorLook.detailSize, design: .monospaced))
                    .foregroundStyle(Palette.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Space.s + 2)
                    .background(Palette.fill, in: RoundedRectangle(cornerRadius: Radius.control + 2, style: .continuous))
                    .padding(.top, Space.m)
                    .padding(.leading, iconSize + ErrorLook.iconGap)
                    .transition(.opacity)
            }
        }
        .padding(ErrorLook.padding)
        .background(error.isAboutRecording ? Palette.recordingTint : Palette.accentTint,
                    in: RoundedRectangle(cornerRadius: ErrorLook.radius, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(error.title). \(sentence)")
    }

    private var sentence: String { [error.message, note ?? ""].filter { !$0.isEmpty }.joined(separator: " ") }

    private var buttons: some View {
        HStack(spacing: Space.s) {
            if let retry {
                Button(retryTitle, action: retry).buttonStyle(.mossadFill)
            }
            if !error.technical.isEmpty {
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { details.toggle() }
                } label: {
                    HStack(spacing: 3) {
                        Text(details ? "Hide details" : "Details")
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                            .rotationEffect(.degrees(details ? 180 : 0))
                    }
                    .textRole(.secondary).fontWeight(.medium).foregroundStyle(tint)
                    .frame(minHeight: 26)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(details ? "Hide details" : "Show details")
            }
        }
        .fixedSize()
    }
}

/// The same message under a field or a button: the icon and the title, then the sentence, with no card.
struct InlineError: View {
    let error: FriendlyError
    @ScaledMetric(relativeTo: .footnote) private var iconSize: CGFloat = 13

    var body: some View {
        let size = iconSize
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            WarningMark(size: size)
                .foregroundStyle(error.isAboutRecording ? Palette.recording : Palette.accent)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - size * 0.18 }
            Text("\(Text(error.title).fontWeight(.semibold).foregroundStyle(Palette.ink))\(Text(error.message.isEmpty ? "" : ". \(error.message)").foregroundStyle(Palette.secondary))")
                .textRole(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .help(error.technical)
        .accessibilityElement(children: .combine)
    }
}

/// Sizes of the error card, from the permissions card it matches.
enum ErrorLook {
    #if os(iOS)
    static let icon: CGFloat = 18
    static let padding = EdgeInsets(top: 14, leading: 14, bottom: 14, trailing: 14)
    static let iconTop: CGFloat = 1
    #else
    static let icon: CGFloat = 16
    static let padding = EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 12)
    static let iconTop: CGFloat = 0
    #endif
    static let iconGap: CGFloat = 10
    static let lineGap: CGFloat = 2
    static let radius: CGFloat = 12
    static let detailSize: CGFloat = 11
}

/// Errors for screenshots, one per surface, so each card can be checked without breaking anything.
enum ErrorPreview {
    static func sample(_ surface: String) -> FriendlyError? {
        switch surface {
        case "sync": FriendlyError(URLError(.cannotConnectToHost), context: .syncing, service: "your server")
        case "chat": FriendlyError(SummaryError.http(529, #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#), context: .chatting)
        case "key": FriendlyError(SummaryError.http(401, #"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#), context: .coaching)
        case "recorder":
            FriendlyError(NSError(domain: NSOSStatusErrorDomain, code: -50), context: .recording,
                          technical: "The audio session failed: The operation couldn’t be completed. (OSStatus error -50.) (-50)")
        case "connect": FriendlyError(URLError(.timedOut), context: .connectingServer, service: "your server")
        case "org": FriendlyError(OrgChart.ParseError.missingColumns, context: .importingOrgChart)
        case "upload": FriendlyError(ServerError.http(0, "The recording did not upload."), context: .uploadingAudio, service: "iCloud")
        default: nil
        }
    }
}
