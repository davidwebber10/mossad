import MossadCore
import SwiftUI

/// The company's domains: the field, the suggestions, and what they do. Nothing applies until Save.
struct CompanyDomainsSheet: View {
    static let key = CompanyDomains.defaultsKey

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
            VStack(alignment: .leading, spacing: Rhythm.rowGap) {
                Text("List every domain of your company, such as example.com and exampleinc.com. When an invite has an address on one of them that no person has, and exactly one person has the same name before the @ on another of them, Mossad knows that it is that person. When two people have that name, it is nobody.")
                    .font(.system(size: Rhythm.bodySize)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
                TextField("Domains", text: $text, prompt: Text("example.com, exampleinc.com"), axis: .vertical)
                    .textFieldStyle(SheetFieldStyle())
                    .lineLimit(1...3)
                let refused = CompanyDomains.refused(in: text)
                if !refused.isEmpty {
                    Text("\(refused.joined(separator: ", ")) is a mail service for anyone, so it is not in the list.")
                        .font(.system(size: Rhythm.secondarySize)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
                }
                let fresh = suggestions.filter { !draft.domains.contains($0) }
                if !fresh.isEmpty {
                    VStack(alignment: .leading, spacing: Rhythm.itemGap) {
                        Text("Suggested from your email and the other addresses of the people you saved").font(.system(size: Rhythm.secondarySize)).foregroundStyle(Palette.tertiary)
                        FlowLayout(spacing: 6) {
                            ForEach(fresh, id: \.self) { d in
                                Button { text = CompanyDomains(draft.domains + [d]).text } label: {
                                    Label(d, systemImage: "plus").font(.system(size: Rhythm.secondarySize))
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
            let owner = [ownerEmail] + (controller.library.owner?.emails ?? [])
            // Only the domains where one saved person has addresses on yours and on another: a vendor in many
            // invites is another company.
            var people = controller.library.profiles.map(\.emails)
            people += (controller.library.identity?.people.people ?? []).filter(\.isLive).map { $0.emails.filter { $0.state != .rejected }.map(\.address) }
            suggestions = CompanyDomains.suggestions(ownerEmails: owner, people: people)
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
        refreshPeopleReferences()
        coachPeopleCache.set(0, version: coachVersion + 1, value: library.identity.map { CoachPeople(people: $0.people.people) } ?? .none)
        coachVersion += 1
        refresh()
    }
}
