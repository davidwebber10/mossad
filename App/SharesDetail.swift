import Charts
import MossadCore
import SwiftUI

/// One share: its link to copy, who opened it and when, its PIN, its expiry, and the way to stop it.
struct ShareDetailPane: View {
    @EnvironmentObject var controller: AppController
    let row: ShareRow
    @ObservedObject var model: SharesModel
    let edit: (CallRecord) -> Void

    @State private var working = false
    @State private var error: FriendlyError?
    @State private var copied: String?
    @State private var confirmStop = false

    private var link: MeetingLink? { row.link }
    private var address: URL? { ShareSample.kind != nil ? URL(string: "https://notes.example.com") : controller.serverConnection?.address }
    private var record: CallRecord? { link.flatMap { l in controller.meetings.first { $0.id == l.callID } } }
    private var numbers: Bool { model.server == .ok }
    private var detail: ShareDetail? { model.details[row.id] }

    var body: some View {
        DetailColumn {
            PageToolbar {
                ToolbarCapsule {
                    if let text = copyText {
                        ToolbarIconButton(icon: copied == "bar" ? .checkSmall : .copy, label: row.copyTitle) { put(text, as: "bar") }
                    }
                    ToolbarMenuButton(icon: .more, label: "More") {
                        if let link, row.state == .live { Button("Open in browser") { controller.openShare(link) } }
                        if let link { Button("Open the meeting") { controller.openMeeting(link.callID) }.disabled(record == nil) }
                        if let record, row.state == .live { Button("Change settings…") { edit(record) } }
                        Divider()
                        Button(row.state == .live ? "Stop sharing" : "Remove", role: .destructive, action: stop)
                    }
                }
            }
        } content: {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    ServerNotice(server: model.server).padding(.top, 18)
                    if let error { ErrorCard(error: error).padding(.top, 14) }
                    LabelColumnStack(spacing: 30, divided: true) {
                        LabelColumn(label: "Link", labelTopPadding: 9) { linkGroup }
                        LabelColumn(label: "Views", labelTopPadding: 4) { viewsGroup }
                        if link != nil, row.state == .live { LabelColumn(label: "PIN", labelTopPadding: 5) { pinGroup } }
                        LabelColumn(label: "Expires", labelTopPadding: 5) { expiryGroup }
                    }
                    .padding(.top, 26)
                }
                .frame(maxWidth: 820, alignment: .leading)
                .padding(.horizontal, Detail.gutter).padding(.top, Detail.bodyTop).padding(.bottom, 72)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task(id: row.id) { await model.loadDetail(row.id, controller) }
        .onChange(of: row.remote?.views) { _, _ in Task { await model.loadDetail(row.id, controller) } }
        .confirmationDialog("Stop sharing “\(row.title)”?", isPresented: $confirmStop) {
            Button("Stop sharing", role: .destructive) { run { try await controller.stopSharing(shareID: row.id); await model.load(controller) } }
        } message: {
            Text("Another Mac made this link. It stops working at once, and it cannot be brought back from here.")
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(row.title)
                .font(.system(size: 22, weight: .semibold)).tracking(-0.4)
                .foregroundStyle(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: 6) {
                Text(subtitle).foregroundStyle(Palette.secondary)
                if let link, record != nil {
                    Text("·").foregroundStyle(Palette.tertiaryMark)
                    Button("Open the meeting") { controller.openMeeting(link.callID) }
                        .buttonStyle(SettingsTextButtonStyle(color: Palette.accent, weight: .medium))
                }
            }
            .font(.system(size: 12.5))
        }
    }

    private var subtitle: String {
        var parts = ["Shared \(row.created.formatted(.dateTime.month(.wide).day().year()))"]
        if let o = link?.options {
            let shown = [o.summary ? "summary" : nil, o.transcript ? "transcript" : nil, o.recording ? "recording" : nil].compactMap { $0 }
            if !shown.isEmpty { parts.append("shows the \(ListFormatter.localizedString(byJoining: shown))") }
        }
        return parts.joined(separator: ", ")
    }

    // MARK: Link

    private var copyText: String? { row.state == .live ? address.flatMap { row.copyText(on: $0) } : nil }

    @ViewBuilder
    private var linkGroup: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let address, let url = row.url(on: address) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(url.absoluteString).lineLimit(1).truncationMode(.middle)
                    if case .on(let pin) = row.pin { Text("PIN: \(pin)") }
                }
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(row.state == .live ? Palette.ink : Palette.tertiary)
                .textSelection(.enabled)
                .padding(.horizontal, 12).padding(.vertical, 10)
                .frame(maxWidth: 520, alignment: .leading)
                .background(Palette.fill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            switch row.state {
            case .live:
                if let text = copyText, let address, let url = row.url(on: address) {
                    HStack(spacing: 8) {
                        Button(copied == "all" ? "Copied" : row.copyTitle) { put(text, as: "all") }.buttonStyle(.settingsAccent)
                        if case .on = row.pin {
                            Button(copied == "link" ? "Copied" : "Copy link only") { put(url.absoluteString, as: "link") }.buttonStyle(.settings)
                        }
                        if let link { Button("Open in browser") { controller.openShare(link) }.buttonStyle(.settings).help("Your own visits from here are not counted as views") }
                    }
                } else {
                    note("Another Mac made this link, so this Mac cannot copy it. Its numbers show here, and you can stop it.")
                }
                if row.pin == .unknown { note("This link asks for a PIN that another Mac set. Make a new PIN to copy it from here.") }
                if row.pin == .locked {
                    note("Locked: too many wrong PINs were entered. Nobody can open the page until you make a new PIN.", color: Palette.recording)
                }
            case .expired:
                note("This link has expired. The copy of the meeting on your server is deleted. Choose a new time under Expires to share it again with the same link.")
            case .missing:
                note("Your server no longer has this link, so it does not work. Remove it from this list, or share the meeting again.")
            }
        }
    }

    private func note(_ text: String, color: Color = Palette.secondary) -> some View {
        Text(text).font(.system(size: 12.5)).foregroundStyle(color).lineSpacing(2)
            .frame(maxWidth: 520, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Views

    @ViewBuilder
    private var viewsGroup: some View {
        if let remote = row.remote, numbers || remote.viewers != nil {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 0) {
                    SmallFigure(value: "\(remote.views)", label: remote.views == 1 ? "view" : "views").frame(width: 110, alignment: .leading)
                    SmallFigure(value: "\(remote.viewers ?? 0)", label: remote.viewers == 1 ? "person" : "people").frame(width: 110, alignment: .leading)
                    SmallFigure(value: remote.lastView.map { ago($0) } ?? "Not yet", label: "last viewed")
                }
                if let detail, remote.views > 0 {
                    ViewsChart(days: ShareDetail.filled(detail.days), total: remote.views)
                    HStack(alignment: .top, spacing: 36) {
                        breakdown("Opened on", detail.devices.map { (ShareDetail.deviceName($0.name), $0.count) })
                        breakdown("From", detail.countries.map { (ShareDetail.countryName($0.name), $0.count) })
                    }
                    Text("A person is one browser. The count holds no names and no addresses. Your own visits from “Open in browser” are left out.")
                        .font(.system(size: 11.5)).foregroundStyle(Palette.tertiary)
                        .frame(maxWidth: 520, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                }
            }
        } else if let remote = row.remote {
            note("\(remote.views == 1 ? "1 view" : "\(remote.views) views"). Your server counts who opened a link, and when, after its update.")
        } else {
            switch model.server {
            case .unknown: note("Asking your server…")
            case .old, .needsMigration: note("Your server counts who opened a link, and when, after its update.")
            default: note("The numbers show when your server answers.")
            }
        }
    }

    /// "2 hours ago", "Just now", or "Oct 11", for the figure over "last viewed".
    private func ago(_ date: Date) -> String {
        var text = (row.lastViewedText() ?? "").replacingOccurrences(of: "Last viewed ", with: "")
        if text.hasPrefix("on ") { text.removeFirst(3) }
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    private func breakdown(_ title: String, _ rows: [(String, Int)]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Palette.secondary)
            ForEach(rows, id: \.0) { name, count in
                HStack(spacing: 10) {
                    Text(name).foregroundStyle(Palette.ink)
                    Spacer(minLength: 12)
                    Text("\(count)").monospacedDigit().foregroundStyle(Palette.secondary)
                }
                .font(.system(size: 12.5))
            }
        }
        .frame(width: 190, alignment: .leading)
        .opacity(rows.isEmpty ? 0 : 1)
        .accessibilityElement(children: .combine)
    }

    // MARK: PIN

    @ViewBuilder
    private var pinGroup: some View {
        if !numbers {
            note("Update your server to protect a link with a PIN.")
        } else {
            VStack(alignment: .leading, spacing: 10) {
                switch row.pin {
                case .on(let pin):
                    HStack(spacing: 14) {
                        PINDigits(pin: pin, size: 17)
                        Button("New PIN") { setPIN(SharePIN.random()) }.buttonStyle(.settings)
                        Button("Remove PIN") { setPIN(nil) }.buttonStyle(SettingsTextButtonStyle(color: Palette.secondary, weight: .medium))
                    }
                    note(wrongText ?? "People need the link and these 4 digits. A new PIN ends the access of everyone who used the old one.")
                case .off:
                    HStack(spacing: 14) {
                        Text("No PIN").font(.system(size: 13)).foregroundStyle(Palette.ink)
                        Button("Add a PIN") { setPIN(SharePIN.random()) }.buttonStyle(.settings)
                    }
                    note("Anyone who has the link can open the page.")
                case .unknown, .locked:
                    HStack(spacing: 14) {
                        Text(row.pin == .locked ? "Locked" : "On").font(.system(size: 13, weight: .medium))
                            .foregroundStyle(row.pin == .locked ? Palette.recording : Palette.ink)
                        Button("New PIN") { setPIN(SharePIN.random()) }.buttonStyle(.settingsAccent)
                        Button("Remove PIN") { setPIN(nil) }.buttonStyle(SettingsTextButtonStyle(color: Palette.secondary, weight: .medium))
                    }
                    if let wrongText { note(wrongText) }
                }
            }
            .disabled(working)
        }
    }

    private var wrongText: String? {
        guard let wrong = row.remote?.wrongPins, wrong > 0 else { return nil }
        return "\(wrong == 1 ? "1 wrong PIN was" : "\(wrong) wrong PINs were") entered since this PIN was made. 30 lock the page."
    }

    // MARK: Expiry

    private var expiryGroup: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                Text(expiryLine).font(.system(size: 13)).foregroundStyle(Palette.ink)
                if link != nil, row.state != .missing {
                    Menu(row.state == .live ? "Change" : "Share again") {
                        ForEach(ShareOptions.expiryChoices, id: \.self) { days in
                            Button(days.map { "For \($0) days from today" } ?? "Until I stop it") { setExpiry(days) }
                        }
                    }
                    .menuStyle(.button).buttonStyle(.settings).fixedSize()
                    .disabled(working || (row.state == .expired && record == nil))
                }
                if working { ProgressView().controlSize(.small) }
            }
            if row.state == .expired, record == nil, link != nil { note("The meeting is not on this Mac any more, so the link cannot be shared again.") }
            Button(row.state == .live ? "Stop sharing" : "Remove from this list", action: stop)
                .buttonStyle(SettingsTextButtonStyle(color: Palette.recording, weight: .medium))
                .disabled(working)
                .padding(.top, 4)
        }
    }

    private var expiryLine: String {
        guard row.state != .missing else { return "Not on your server" }
        guard let expires = row.expires else { return "Never expires" }
        let day = expires.formatted(.dateTime.weekday(.wide).month(.wide).day())
        return row.state == .expired ? "Expired on \(day)" : "\(row.expiryText()), on \(day)"
    }

    // MARK: Actions

    private func put(_ text: String, as kind: String) {
        copy(text)
        copied = kind
        Task { try? await Task.sleep(for: .seconds(2)); if copied == kind { copied = nil } }
    }

    private func run(_ work: @escaping @MainActor () async throws -> Void) {
        guard ShareSample.kind == nil else { return }
        working = true
        error = nil
        Task {
            do { try await work() } catch {
                Log.error("Share change failed: \(error)")
                let friendly = FriendlyError(error, context: .sharing, service: "your server")
                if friendly.shouldShow(failures: 1) { self.error = friendly }
            }
            working = false
        }
    }

    private func setPIN(_ pin: String?) {
        guard let link else { return }
        run {
            try await controller.setPIN(link, pin: pin)
            await model.load(controller)
        }
    }

    private func setExpiry(_ days: Int?) {
        guard let link else { return }
        run {
            try await controller.setExpiry(link, days: days, live: row.state == .live)
            await model.load(controller)
        }
    }

    /// A link of this Mac stops with a few seconds to undo, and no question. A link of another Mac cannot be
    /// brought back from here, so that one asks.
    private func stop() {
        guard ShareSample.kind == nil else { return }
        if let link {
            if row.state == .live { controller.stopSharingSoon(link) } else { run { try await controller.stopSharing(link) } }
        } else {
            confirmStop = true
        }
    }
}

/// Views per day since the first one: a bar for each day, and a gap for a day with none.
private struct ViewsChart: View {
    let days: [ShareDetail.Day]
    let total: Int

    private var points: [(date: Date, views: Int)] {
        days.compactMap { d in ShareDetail.date(of: d.day).map { ($0, d.views) } }
    }

    var body: some View {
        let points = points
        Chart {
            ForEach(points, id: \.date) { p in
                BarMark(x: .value("Day", p.date, unit: .day), y: .value("Views", p.views))
                    .foregroundStyle(Palette.accentFill)
                    .cornerRadius(2)
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: max(1, points.count / 6))) { _ in
                AxisValueLabel(format: .dateTime.month(.abbreviated).day(), centered: true)
                    .font(.system(size: 10.5)).foregroundStyle(Palette.tertiary)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { v in
                AxisGridLine().foregroundStyle(Palette.hairline)
                AxisValueLabel {
                    if let n = v.as(Int.self) { Text("\(n)").font(.system(size: 10.5)).foregroundStyle(Palette.tertiary) }
                }
            }
        }
        .chartPlotStyle { $0.overlay(alignment: .bottom) { Hairline() } }
        .frame(maxWidth: 520).frame(height: 120)
        .accessibilityLabel("Views by day, \(total) in all")
    }
}
