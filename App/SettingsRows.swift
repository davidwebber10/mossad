import AppKit
import SwiftUI

/// Rows that Settings pages share with setup's look: a help link, and a Check with its result.

/// "Read the guide ↗": a quiet link in the accent that opens a help page in the browser.
struct SettingsHelpLink: View {
    let title: String
    let url: URL

    var body: some View {
        Link(destination: url) {
            HStack(spacing: 3) {
                Text(title)
                IconImage(.arrowUp, size: 9).rotationEffect(.degrees(45))
            }
        }
        .font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.accent)
        .accessibilityLabel("\(title), opens in the browser")
    }
}

/// What a check of a key or a connection found.
enum SettingsCheck: Equatable {
    case idle, checking, passed
    case failed(String)
}

/// Check, with its result before it: a spinner, a green check and a few words, or nothing. A failure shows as a
/// line of its own under the row (`SettingsCheckFailure`), where a sentence has room.
struct SettingsCheckButton: View {
    let state: SettingsCheck
    var passed = "Works"
    var title = "Check"
    let action: () -> Void

    var body: some View {
        HStack(spacing: Space.s) {
            switch state {
            case .checking: ProgressView().controlSize(.small)
            case .passed: PassLine(text: passed)
            case .idle, .failed: EmptyView()
            }
            Button(title, action: action).buttonStyle(.settings).disabled(state == .checking)
        }
    }
}

struct SettingsCheckFailure: View {
    let state: SettingsCheck

    var body: some View {
        if case .failed(let message) = state {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                WarningMark(size: 12).foregroundStyle(Palette.accent)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
                Text(message).font(.system(size: 12)).foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, 9)
            .accessibilityElement(children: .combine)
        }
    }
}
