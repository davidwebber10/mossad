import Foundation
import MossadCore

/// The imported org chart and the owner's own matches, as People reads them. Parsing a large export takes a
/// moment, so it runs off the main thread.
@MainActor
final class OrgState: ObservableObject {
    @Published private(set) var chart: OrgChart?
    @Published private(set) var matches = OrgMatches()
    @Published private(set) var imported: Date?
    @Published private(set) var loaded = false
    let paths: Paths

    /// The name of the file the owner picked; the copy on disk is always org.csv.
    var fileName: String { UserDefaults.standard.string(forKey: "orgChartFileName") ?? "org.csv" }

    init(paths: Paths) { self.paths = paths }

    func reload() {
        let paths = paths
        Task {
            let (chart, matches, imported) = await Task.detached(priority: .userInitiated) {
                let url = paths.people.appendingPathComponent("org.csv")
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                return (OrgChart.load(paths: paths), OrgMatches.load(paths: paths), date)
            }.value
            self.chart = chart
            self.matches = matches
            self.imported = imported
            loaded = true
        }
    }

    func match(_ name: String) -> OrgChart.Match? { chart?.person(matching: name, overrides: matches) }

    func isOutside(_ name: String) -> Bool { matches.isOutside(name) }

    /// A person in the file, or nil for "Outside the company".
    func setMatch(_ name: String, to personID: String?) {
        if let personID { matches.set(name, to: personID) } else { matches.setOutside(name) }
        save()
    }

    func clearMatch(_ name: String) {
        matches.clear(name)
        save()
    }

    func importFile(_ url: URL) throws {
        let chart = try OrgChart.import(from: url, paths: paths)
        UserDefaults.standard.set(url.lastPathComponent, forKey: "orgChartFileName")
        self.chart = chart
        imported = Date()
        reload()
    }

    private func save() {
        do { try matches.save(paths: paths) } catch { Log.error("Saving the org chart matches failed: \(error)") }
    }
}
