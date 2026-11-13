import MossadCore
import SwiftUI

/// "Your points, 2 open" in the quick panel during a call, over the quick questions: one row that opens to the
/// live page's checklist (`LivePointRows`, the same model and rules). A time chip opens the live transcript under
/// the list. The panel remembers open or closed on its own. Hidden when the call has no points.
struct AskPanelPoints: View {
    @EnvironmentObject var controller: AppController
    @ObservedObject var model: LivePointsModel
    let record: CallRecord
    /// A hairline over it, under a thread.
    let divided: Bool
    /// Its height as shown, for `AskPanelSizing`: the thread gives way to it.
    let height: (CGFloat) -> Void
    @AppStorage("askPanelPointsOpen") private var expanded = false
    @State private var peek: TimeInterval?
    @State private var listHeight: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var previewOpen = DevHooks.askPoints
    private var isOpen: Bool { previewOpen ?? expanded }

    var body: some View {
        let points = controller.livePointList()
        VStack(spacing: 0) {
            if !points.isEmpty {
                TimelineView(.periodic(from: .now, by: 15)) { context in
                    let open = LivePointRules.open(points, marks: model.marks).count
                    let late = LivePointRules.nearEnd(plannedEnd: record.plannedEnd, now: context.date, open: open)
                    VStack(alignment: .leading, spacing: 0) {
                        header(open: open, late: late)
                        if isOpen { list(points) }
                    }
                }
                .overlay(alignment: .top) { if divided { Rectangle().fill(Palette.hairline).frame(height: 1) } }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height($0) }
        .task(id: record.id) {
            // The catalog, the invite, and the names heard change during the call; the live page may be closed.
            var n = 0
            while !Task.isCancelled {
                controller.refreshLivePoints(record)
                n += 1
                try? await Task.sleep(for: .seconds(n < 5 ? 1 : 10))
            }
        }
    }

    private func header(open: Int, late: Bool) -> some View {
        Button {
            withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) {
                if let open = previewOpen { previewOpen = !open } else { expanded.toggle() }
            }
        } label: {
            HStack(spacing: 7) {
                IconImage(isOpen ? .chevronDown : .chevronRight, size: 9).foregroundStyle(Palette.tertiary).frame(width: 12)
                Text("Your points").font(.system(size: 12.5, weight: .medium)).foregroundStyle(Palette.ink)
                Text(open == 0 ? "all raised" : "\(open) open")
                    .font(.system(size: 12.5, weight: late ? .semibold : .regular)).monospacedDigit()
                    .foregroundStyle(late ? Palette.accent : Palette.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .frame(height: AskPanelSizing.pointsRow)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isOpen ? "Hide your points" : "Show your points")
        .accessibilityLabel("Your points, \(open == 0 ? "all raised" : "\(open) open")\(late ? ", the meeting ends soon" : "")")
        .accessibilityHint(isOpen ? "Hides the list" : "Shows the list")
    }

    private func list(_ points: [NextTimePoint]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                LivePointRows(model: model, record: record, points: points, show: { at in
                    withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) { peek = peek == at ? nil : at }
                }, compact: true)
                if let peek {
                    LivePeekView(model: controller.live, at: peek, owner: controller.ownerName, room: record.platform == .inPerson)
                        .padding(.horizontal, 8)
                }
            }
            .padding(.leading, 8).padding(.trailing, 16).padding(.bottom, 6)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
        }
        .frame(height: min(listHeight, AskPanelSizing.pointsMax - AskPanelSizing.pointsRow))
        .scrollIndicators(listHeight > AskPanelSizing.pointsMax - AskPanelSizing.pointsRow ? .automatic : .never)
    }
}
