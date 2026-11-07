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
    /// Counts the owner's match edits, so a load that started before an edit does not put back the older file.
    private var edits = 0
    /// The same for imports: a load that started before one must not put back the older chart.
    private var imports = 0

    /// The name of the file the owner picked; the copy on disk is always org.csv.
    var fileName: String { UserDefaults.standard.string(forKey: "orgChartFileName") ?? "org.csv" }

    init(paths: Paths) { self.paths = paths }

    func reload() {
        let paths = paths, started = edits, importsBefore = imports
        Task {
            let (chart, matches, imported) = await Task.detached(priority: .userInitiated) {
                let url = paths.people.appendingPathComponent("org.csv")
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                return (OrgChart.load(paths: paths), OrgMatches.load(paths: paths), date)
            }.value
            if imports == importsBefore {
                self.chart = chart
                self.imported = imported
            }
            if edits == started { self.matches = matches }
            loaded = true
        }
    }

    func match(_ name: String) -> OrgChart.Match? { chart?.person(matching: name, overrides: matches) }

    func isOutside(_ name: String) -> Bool { matches.isOutside(name) }

    /// A person in the file, or nil for "Outside the company".
    func setMatch(_ name: String, to personID: String?) {
        prepareEdit()
        if let personID { matches.set(name, to: personID) } else { matches.setOutside(name) }
        save()
    }

    func clearMatch(_ name: String) {
        prepareEdit()
        matches.clear(name)
        save()
    }

    func importFile(_ url: URL) throws {
        let chart = try OrgChart.import(from: url, paths: paths)
        UserDefaults.standard.set(url.lastPathComponent, forKey: "orgChartFileName")
        imports += 1
        self.chart = chart
        imported = Date()
        if !loaded { matches = OrgMatches.load(paths: paths) }
        loaded = true
    }

    /// The saved matches are the base of any edit: a state that was never loaded must not save an empty set
    /// over them.
    private func prepareEdit() {
        if !loaded, edits == 0 { matches = OrgMatches.load(paths: paths) }
        edits += 1
    }

    private func save() {
        do { try matches.save(paths: paths) } catch { Log.error("Saving the org chart matches failed: \(error)") }
    }
}
