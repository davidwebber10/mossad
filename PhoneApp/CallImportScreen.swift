import MossadCore
import SwiftUI
import UIKit

/// An audio file that iOS handed to the app, such as a call recording from "Share Audio" in Notes.
struct IncomingAudio: Identifiable, Equatable {
    let url: URL
    let id = UUID()
}

/// "Import check": what iOS hands over with a shared audio file, for the owner to report from a real iPhone before the
/// import is built.
struct CallImportScreen: View {
    let incoming: IncomingAudio
    @Environment(\.dismiss) private var dismiss
    @State private var file: CallImport.File?
    /// When the app got the file, to set against the file's own dates.
    @State private var openedAt = Date()

    private var lines: [(label: String, value: String)] {
        guard let file else { return [] }
        return [
            ("Name", file.name),
            ("Type", file.typeIdentifier ?? "None"),
            ("Size", file.bytes.map { "\($0) bytes" } ?? "None"),
            ("Length", file.length.map { String(format: "%.1f seconds", $0) } ?? "None"),
            ("Metadata date", Self.text(file.metadataDate)),
            ("File date", Self.text(file.fileDate)),
            ("Opened at", Self.text(openedAt)),
        ]
    }

    private static func text(_ date: Date?) -> String {
        guard let date else { return "None" }
        return date.formatted(.dateTime.year().month().day().hour().minute().second().timeZone())
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if file == nil {
                        ProgressView().frame(maxWidth: .infinity).padding(.vertical, Space.l)
                    }
                    ForEach(lines, id: \.label) { line in
                        HairlineRow {
                            VStack(alignment: .leading, spacing: Space.xs) {
                                PhoneLabel(line.label)
                                Text(line.value).textRole(.body).textSelection(.enabled)
                            }
                        }
                    }
                    Button("Copy") {
                        UIPasteboard.general.string = lines.map { "\($0.label): \($0.value)" }.joined(separator: "\n")
                    }
                    .buttonStyle(PhoneFillButtonStyle(wide: true))
                    .disabled(file == nil)
                    .padding(.top, Space.l)
                }
                .padding(.horizontal, Space.l)
            }
            .navigationTitle("Import check")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        try? FileManager.default.removeItem(at: incoming.url)
                        dismiss()
                    }
                }
            }
        }
        .task(id: incoming.id) {
            openedAt = Date()
            let url = incoming.url
            file = await Task.detached { await CallImport.read(url) }.value
        }
    }
}
