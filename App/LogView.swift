import MossadCore
import SwiftUI

struct LogView: View {
    @State private var text = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Last 500 lines").foregroundStyle(.secondary)
                Spacer()
                Button("Refresh", action: load)
            }
            .padding(8)
            ScrollView {
                Text(text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .defaultScrollAnchor(.bottom)
        }
        .onAppear(perform: load)
    }

    private func load() {
        guard let url = Log.fileURL, let content = try? String(contentsOf: url, encoding: .utf8) else {
            text = "No log yet."
            return
        }
        text = content.split(separator: "\n", omittingEmptySubsequences: false).suffix(500).joined(separator: "\n")
    }
}
