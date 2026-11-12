import Foundation
import MossadCore

/// The anonymous usage statistics: counts and fixed words, at most once a day, never while a call records.
/// `UsageStats` decides what goes; this part gathers what the app already knows and sends it.
extension AppController {
    /// Who may send: never a preview, Rehearsal, a second copy, a demo folder (`MOSSAD_ROOT`), or a debug build
    /// without the hidden flag.
    var usageStatsGate: UsageReportPlan.Gate {
        UsageReportPlan.Gate(enabled: usageStatsEnabled, inert: isInert, rehearsal: Rehearsal.isOn,
                             rootOverride: !(ProcessInfo.processInfo.environment["MOSSAD_ROOT"] ?? "").isEmpty,
                             debugBuild: DevHooks.debug, debugFlag: UserDefaults.standard.bool(forKey: UsageReportPlan.debugKey))
    }

    /// At launch: a random wait of 1 to 30 minutes, then once an hour the day is marked and a due report goes.
    func startUsageStats() {
        usageStatsTask?.cancel()
        usageStatsTask = nil
        guard usageStatsGate.allows else { return }
        let counters = usageCounters
        Task.detached(priority: .utility) { counters.markActive() }
        usageStatsTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(UsageReportPlan.launchDelay(Double.random(in: 0...1))))
            while !Task.isCancelled {
                await self?.sendUsageStatsIfDue()
                try? await Task.sleep(for: .seconds(3_600))
                guard let self, !Task.isCancelled, self.usageStatsGate.allows else { return }
                Task.detached(priority: .utility) { counters.markActive() }
            }
        }
    }

    /// The switch in Settings. Off stops at once: the wait or a request on its way is cancelled, and what was
    /// counted is deleted.
    func setUsageStats(_ on: Bool) {
        usageStatsEnabled = on
        if on {
            startUsageStats()
        } else {
            usageStatsTask?.cancel()
            usageStatsTask = nil
            let counters = usageCounters
            Task.detached(priority: .utility) { counters.delete() }
        }
    }

    /// A failed step or a call that could not be confirmed: counted by its kind only, and only while the
    /// statistics are on.
    func countUsage(_ step: UsageStats.Step) {
        guard usageStatsGate.allows else { return }
        let counters = usageCounters
        Task.detached(priority: .utility) { counters.record(step) }
    }

    private func sendUsageStatsIfDue() async {
        let defaults = UserDefaults.standard
        let last = defaults.object(forKey: UsageReportPlan.lastAttemptKey) as? Date
        guard usageStatsGate.allows, !isRecording, UsageReportPlan.isDue(lastAttempt: last, now: Date()) else { return }
        let stats = await makeUsageStats()
        guard !Task.isCancelled, usageStatsGate.allows, !isRecording else { return }
        // Before the send: a failure waits for the next day, with no retry in between.
        defaults.set(Date(), forKey: UsageReportPlan.lastAttemptKey)
        let endpoint = UsageReportPlan.endpoint(override: defaults.string(forKey: UsageReportPlan.endpointKey))
        let version = Self.appVersion.version
        // Off the main thread; turning the setting off cancels the request on its way.
        let send = Task.detached(priority: .utility) {
            await UsageReportPlan.send(stats, endpoint: endpoint, appVersion: version)
        }
        await withTaskCancellationHandler { _ = await send.value } onCancel: { send.cancel() }
    }

    /// The report as it would go now. The "What is sent" sheet shows this.
    func makeUsageStats() async -> UsageStats {
        let records = meetings
        let transcription = transcriptionProvider
        let summary = aiProvider
        let transcriptionReady = transcription.key.map(hasKey) ?? true
        let features = UsageStats.Features(
            coach: coachEnabled, screens: captureScreens, google: googleConnected, server: hasServer,
            iphone: records.contains { $0.bundleID == PhoneRecording.bundleID }, backup: backupChoice != .none,
            mcp: (UserDefaults.standard.object(forKey: Self.mcpLastUsedKey) as? Date).map { Date().timeIntervalSince($0) < 30 * 86_400 } ?? false,
            shares: shareBook.links.contains { !$0.isExpired() && $0.stopping != true })
        let people = library.identity?.people.people.filter { $0.isLive && !$0.isOwner }.count
            ?? library.profiles.filter { !$0.isOwner }.count
        let recurring = series.all.count
        let counters = usageCounters
        let commitments = paths.commitments
        let id = UsageReportPlan.installID()
        let (version, build) = Self.appVersion
        let summaryReady = hasLanguageModel
        return await Task.detached(priority: .utility) {
            let open = ((try? CommitmentBook.load(from: commitments)) ?? CommitmentBook()).visible.filter { $0.done == nil }.count
            let input = UsageStats.Input(
                installID: id, appVersion: version, build: build, os: ProcessInfo.processInfo.operatingSystemVersion,
                cpuBrand: Self.cpuBrand(), language: Locale.current.language.languageCode?.identifier,
                region: Locale.current.region?.identifier, records: records, counters: counters.read(),
                transcription: transcriptionReady ? transcription : nil, summary: summaryReady ? summary : nil,
                features: features, people: people, recurring: recurring, commitmentsOpen: open)
            return UsageStats.make(input)
        }.value
    }

    /// Set by `Mossad --mcp` each time another AI app starts it. Only the date is kept.
    nonisolated static let mcpLastUsedKey = "mcpLastUsed"

    nonisolated static var appVersion: (version: String, build: String) {
        let info = Bundle.main.infoDictionary
        return (info?["CFBundleShortVersionString"] as? String ?? "0", info?["CFBundleVersion"] as? String ?? "0")
    }

    /// "Apple M3 Pro"; `UsageStats` keeps only the family.
    nonisolated static func cpuBrand() -> String? {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &bytes, &size, nil, 0) == 0 else { return nil }
        return String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
