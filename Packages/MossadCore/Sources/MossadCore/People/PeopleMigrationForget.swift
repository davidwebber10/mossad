import Foundation

/// The two files of the migration (`migration-plan.json` and `migration-report.md`) hold call ids, speaker keys, and
/// names. `runAtLaunch` writes them again only when it has changes, so a meeting that moved to another profile, and a
/// person the move removed, would stay in them for good. The move's removal writes them again without both.
extension PeopleMigration.Plan {
    /// The version of the plan this build writes.
    public static let currentVersion = 1
}

extension PeopleMigration {
    /// The plan without one call and without the people the removal deleted (their names and addresses from the plan's
    /// own people). The rest is as it was, also `basis`, so the plan still reads and an apply of it brings nothing back.
    public static func forgetting(_ plan: Plan, callID: String, people gone: Set<String>) -> Plan {
        var p = plan
        let removed = plan.people.filter { gone.contains($0.id.rawValue) }
        let words = Set(removed.flatMap { person in [person.displayName] + person.forms.map(\.text) + person.emails.map(\.address) }
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        // A whole field is the name; in a line of text the name is a whole word with its own capitals ("Sam" is not in
        // "Samuel Lee", and "Will" is not in "it will").
        func isName(_ field: String) -> Bool {
            let f = field.trimmingCharacters(in: .whitespaces)
            return f.contains(callID) || words.contains { $0.caseInsensitiveCompare(f) == .orderedSame }
        }
        func names(_ text: String) -> Bool {
            text.contains(callID) || words.contains { word in
                let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: word) + "(?![\\p{L}\\p{N}])"
                return text.range(of: pattern, options: [.regularExpression]) != nil
            }
        }
        p.people.removeAll { gone.contains($0.id.rawValue) }
        p.samples.removeAll { $0.callID == callID || $0.personID.map { gone.contains($0.rawValue) } == true }
        var r = p.report
        r.newLinks.removeAll { isName($0.written) || isName($0.person) }
        r.notResolved = r.notResolved.compactMap { u in
            guard !isName(u.label) else { return nil }
            var u = u
            let had = u.meetings.contains(callID)
            u.meetings.removeAll { $0 == callID }
            return had && u.meetings.isEmpty ? nil : u
        }
        r.orphans.removeAll { isName($0.key) }
        r.samplesWithoutProvenance.removeAll { isName($0.person) }
        if var x = r.references {
            x.labels.removeAll(where: names)
            x.refused.removeAll { $0 == callID }
            r.references = x
        }
        r.notes.removeAll(where: names)
        r.errors.removeAll(where: names)
        p.report = r
        return p
    }

    /// Writes both files again without the call and the people, only when they are there and change. A plan that
    /// does not read leaves the report without each line that names the call. Throws when a write fails.
    public static func forget(callID: String, people gone: Set<String>, paths: Paths) throws {
        let planFile = paths.people.appendingPathComponent(planName), reportFile = paths.people.appendingPathComponent(reportName)
        if let data = try? Data(contentsOf: planFile), let plan = try? JSONDecoder.callRecord.decode(Plan.self, from: data) {
            // A plan of a newer build is never written by this one: it would lose the fields it does not know.
            guard plan.version <= Plan.currentVersion else { return }
            let kept = forgetting(plan, callID: callID, people: gone)
            if kept != plan { try write(kept, to: paths.people) }
            return
        }
        guard let report = try? String(contentsOf: reportFile, encoding: .utf8) else { return }
        let lines = report.components(separatedBy: "\n")
        let kept = lines.filter { !$0.contains(callID) }
        if kept.count != lines.count { try kept.joined(separator: "\n").write(to: reportFile, atomically: true, encoding: .utf8) }
    }
}
