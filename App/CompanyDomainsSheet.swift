import MossadCore
import SwiftUI

/// The company's domains: the field, the suggestions, and what they do. Nothing applies until Save.
struct CompanyDomainsSheet: View {
    static let key = "companyDomains"

    @EnvironmentObject var controller: AppController
    @AppStorage(Self.key) private var saved = ""
    @AppStorage("ownerEmail") private var ownerEmail = ""
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var suggestions: [String] = []

    private var draft: CompanyDomains { .parse(text) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(icon: .people, title: "Company domains", subtitle: "One person can have an address on each.", close: { dismiss() })
            VStack(alignment: .leading, spacing: 12) {
                Text("List every domain of your company, such as example.com and exampleinc.com. When an invite has an address on one of them that no person has, and exactly one person has the same name before the @ on another of them, Mossad knows that it is that person. When two people have that name, it is nobody.")
                    .font(.system(size: 12.5)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
                TextField("Domains", text: $text, prompt: Text("example.com, exampleinc.com"), axis: .vertical)
                    .textFieldStyle(SheetFieldStyle())
                    .lineLimit(1...3)
                let fresh = suggestions.filter { !draft.domains.contains($0) }
                if !fresh.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Suggested from your email and your invites").font(.system(size: 11.5)).foregroundStyle(Palette.tertiary)
                        FlowLayout(spacing: 6) {
                            ForEach(fresh, id: \.self) { d in
                                Button { text = CompanyDomains(draft.domains + [d]).text } label: {
                                    Label(d, systemImage: "plus").font(.system(size: 12))
                                        .padding(.horizontal, 8).frame(height: 22)
                                        .background(Palette.fill, in: Capsule())
                                }
                                .buttonStyle(.plain)
                                .help("Add \(d) to the list")
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 22).padding(.vertical, 16)
            SheetFooter {
                Button("Cancel") { dismiss() }.buttonStyle(.sheetSecondary).keyboardShortcut(.cancelAction)
                Button("Save") { save() }.buttonStyle(.sheetPrimary).keyboardShortcut(.defaultAction)
                    .disabled(draft == .parse(saved))
            }
        }
        .mossadSheet(width: 460)
        .task {
            text = CompanyDomains.parse(saved).text
            let owner = [ownerEmail] + (controller.library.owner?.emails ?? []), records = controller.meetings
            suggestions = await Task.detached(priority: .userInitiated) {
                CompanyDomains.suggestions(ownerEmails: owner, invites: records.map { $0.attendees + ($0.invitees ?? []).compactMap(\.email) })
            }.value
        }
    }

    private func save() {
        saved = draft.text
        controller.companyDomainsChanged(draft)
        dismiss()
    }
}

extension AppController {
    /// The owner saved the company's domains: each resolver made from now reads them, and the meetings' names follow.
    func companyDomainsChanged(_ domains: CompanyDomains) {
        CompanyDomains.current = domains
        Log.info("Company domains: \(domains.domains.count) saved")
        relinkEmails()
        refresh()
    }
}
