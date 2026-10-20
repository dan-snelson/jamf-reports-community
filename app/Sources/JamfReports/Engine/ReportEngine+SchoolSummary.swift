import Foundation

extension ReportEngine {

    /// The day's summary for a Jamf School workspace, from its `school-devices` rows
    /// (`SchoolFleetService`; devices in School's trash are already left out). Macs are
    /// `totalDevices`, every other platform is `mobileDeviceCount` (nil when there is none, as
    /// `mobileOnlySummary` records nothing for a fleet with no mobile devices). `staleCount`
    /// counts the Macs whose check-in is more than `staleDays` ago, as the Pro summary does, and
    /// is nil on a fleet with no Macs (as `mobileOnlySummary`): mobile staleness waits for the
    /// mobile spec's M2 `mobile` object, so no mixed count is recorded. The Mac security
    /// figures are School data it does not carry, so they stay nil. Nil when there are no devices.
    static func schoolSummary(
        from snapshot: SchoolFleetService.Snapshot, date: String, staleDays: Int, now: Date,
        collectionSources: [String: String]?, collectedByHost: String?
    ) -> DailySummary? {
        let macDevices = snapshot.devices.filter { $0.platform == "macOS" }
        let macs = macDevices.count
        let staleMacs = macDevices.filter { $0.isStale(atDays: staleDays, now: now) }.count
        let mobile = snapshot.devices.filter { !["macOS", "Unknown"].contains($0.platform) }.count
        guard macs + mobile > 0 else { return nil }
        return DailySummary(
            date: date, totalDevices: macs, fileVaultPct: nil, compliancePct: nil,
            staleCount: macs > 0 ? staleMacs : nil,
            osCurrentPct: nil, crowdstrikePct: nil, patchPct: nil,
            source: "jamf-cli", collectionSources: collectionSources,
            mobileDeviceCount: mobile > 0 ? mobile : nil, collectedByHost: collectedByHost)
    }

    /// Writes `summary_<day>.json` for a School collect that landed `school-devices`, replacing
    /// a same-day file (its numbers are older). A run that did not land the devices source
    /// writes nothing and leaves the file as it is, so cached rows are never dated today.
    @discardableResult
    static func writeSchoolSummary(
        dataDir: URL, summariesDir: URL, landedKinds: Set<String>, staleDays: Int,
        day: Date = Date(), onLine: @Sendable @escaping (CLIBridge.LogLine) -> Void
    ) -> SummaryEmitOutcome {
        guard landedKinds.contains(SchoolFleetService.devicesKind) else {
            return .nothingToSummarize
        }
        let date = SummaryJSONParser.dateFormatter.string(from: day)
        guard let summary = schoolSummary(
            from: SchoolFleetService.load(dataDir: dataDir), date: date, staleDays: staleDays,
            now: day, collectionSources: [SchoolFleetService.devicesKind: "live"],
            collectedByHost: collectingHostLabel(dataDir: dataDir))
        else {
            let msg = "[warn] Jamf School returned 0 devices — summary not written"
            AppLogger.collect.warning("\(msg, privacy: .public)")
            onLine(.init(timestamp: Date(), level: .warn, text: msg))
            return .nothingToSummarize
        }
        do {
            try FileManager.default.createDirectory(
                at: summariesDir, withIntermediateDirectories: true)
        } catch {
            let msg = "\(summaryNotWrittenMarker) the summaries directory could not be created"
            AppLogger.collect.warning("\(msg, privacy: .public)")
            onLine(.init(timestamp: Date(), level: .warn, text: msg))
            return .directoryUnavailable
        }
        let file = summariesDir.appendingPathComponent("summary_\(date).json")
        return writeSummaryFile(summary, to: file, onLine: onLine) ? .wrote : .writeFailed
    }
}
