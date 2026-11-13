import AppKit
import MossadCore
import SwiftUI

/// Settings › Storage & Sync › Usage statistics: the one switch, its one line, and the way to see the report.
struct UsageStatsGroup: View {
    @EnvironmentObject var controller: AppController
    @State private var showing = false

    var body: some View {
        SettingsGroup(label: "Usage statistics") {
            HStack(alignment: .center, spacing: Space.m) {
                VStack(alignment: .leading, spacing: Rhythm.pairGap) {
                    SettingsRowText(title: "Send anonymous usage statistics",
                                    detail: "Counts only: app version, Mac model, how many meetings, which features are on. Never names, words, or files.")
                    Button("What is sent") { showing = true }
                        .buttonStyle(SettingsTextButtonStyle(color: Palette.accent, weight: .medium))
                        .accessibilityHint("Shows the exact report that Mossad would send next")
                }
                Spacer(minLength: Space.m)
                Toggle(isOn: Binding(get: { controller.usageStatsEnabled }, set: { controller.setUsageStats($0) })) { EmptyView() }
                    .toggleStyle(SheetSwitchStyle())
                    .fixedSize()
                    .accessibilityLabel("Send anonymous usage statistics")
            }
            .padding(.vertical, 9)
        }
        .sheet(isPresented: $showing) { UsageStatsSheet() }
    }
}

/// The exact JSON of the next report, as it would go now, and the reset of the random id.
struct UsageStatsSheet: View {
    @EnvironmentObject var controller: AppController
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var resets = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(icon: .analytics, title: "What is sent", subtitle: "The next report, exactly as Mossad would send it.", close: { dismiss() })
            VStack(alignment: .leading, spacing: Rhythm.rowGap) {
                Text(controller.usageStatsEnabled
                     ? "At most once a day, Mossad sends this to getmossad.com. A report never starts while a call records. The server also keeps the day and the country of the request, and not your IP address."
                     : "The setting is off, so Mossad sends nothing. This is what a report would hold.")
                    .font(.system(size: Rhythm.bodySize)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
                ScrollView {
                    Text(text.isEmpty ? " " : text)
                        .font(.system(size: Rhythm.secondarySize, design: .monospaced)).foregroundStyle(Palette.ink)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .frame(height: 320)
                .background(Palette.fill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                Text("The ID is a random number made on this Mac. It is not from your Mac or your account, and it only tells one report from the next.")
                    .font(.system(size: Rhythm.secondarySize)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 22).padding(.vertical, 16)
            SheetFooter {
                Button("Reset anonymous ID") {
                    UsageReportPlan.resetInstallID()
                    resets += 1
                }
                .buttonStyle(.sheetText)
            } trailing: {
                Button("Done") { dismiss() }.buttonStyle(.sheetPrimary).keyboardShortcut(.defaultAction)
            }
        }
        .mossadSheet(width: 520)
        .task(id: resets) {
            guard let stats = await controller.makeUsageStats() else {
                text = "Mossad is still reading your meetings and calendar. The report shows here when they are read."
                return
            }
            text = (try? stats.json(pretty: true)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        }
    }
}
