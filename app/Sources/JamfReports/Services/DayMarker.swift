import Foundation

/// One-line day stamp at <workspace>/automation/.<name>-last (yyyy-MM-dd), or in this Mac's
/// Application Support when that folder is refused (`AutomationStateFile`).
/// Best-effort persistence shared by GUI and headless once-per-day signals.
struct DayMarker: Sendable {
    let name: String

    /// The day last stamped, or nil when the marker is absent or unreadable.
    func lastStampedDay(in workspace: URL) -> String? {
        guard let text = try? String(contentsOf: markerURL(in: workspace), encoding: .utf8)
        else { return nil }
        let day = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return day.isEmpty ? nil : day
    }

    func isStamped(_ key: String, in workspace: URL) -> Bool {
        lastStampedDay(in: workspace) == key
    }

    /// Best-effort: creates the folder if needed and never throws.
    func stamp(day: String, in workspace: URL) {
        try? AutomationStateFile.write(Data(day.utf8), to: markerURL(in: workspace))
    }

    /// Gives the stamp back, so the day or hour counts as unclaimed. Best-effort.
    func clear(in workspace: URL) {
        try? FileManager.default.removeItem(at: markerURL(in: workspace))
    }

    enum SendOutcome: Sendable, Equatable {
        case sent
        /// The send ran and failed: nothing is stamped, the next pass retries.
        case failed
        /// Another process is sending, or has already sent today: nothing was attempted.
        case skipped
    }

    /// A claim older than this belongs to a sender that died mid-send.
    static let claimStaleAfter: TimeInterval = 10 * 60

    /// Runs `send` for `day` with an exclusive claim on every workspace's marker, so the GUI and
    /// the tick never both post the same digest between one's stamp read and the other's stamp.
    /// The stamp is re-read after the claim (a sender that finished in between has stamped and
    /// released), written only after a confirmed send and before the claim is released, so a
    /// failed send leaves neither stamp nor claim and the next pass retries.
    func sendOnce(
        day: String, in workspaces: [URL], now: Date = Date(),
        send: @Sendable () async -> Bool
    ) async -> SendOutcome {
        var claimed: [URL] = []
        defer { claimed.forEach(AutomationStateFile.releaseClaim) }
        for workspace in workspaces {
            let url = claimURL(in: workspace)
            do {
                guard try AutomationStateFile.claimExclusively(
                    url, staleAfter: Self.claimStaleAfter, now: now) else { return .skipped }
                claimed.append(url)
            } catch {
                // An unwritable folder cannot hold a claim; sending anyway keeps the alert.
                let reason = error.localizedDescription
                AppLogger.webhook.warning(
                    "\(name, privacy: .public) claim failed: \(reason, privacy: .public)")
            }
        }
        if workspaces.contains(where: { isStamped(day, in: $0) }) { return .skipped }
        guard await send() else { return .failed }
        workspaces.forEach { stamp(day: day, in: $0) }
        return .sent
    }

    private func claimURL(in workspace: URL) -> URL {
        AutomationStateFile.url(named: ".\(name)-sending", in: workspace)
    }

    private func markerURL(in workspace: URL) -> URL {
        AutomationStateFile.url(named: ".\(name)-last", in: workspace)
    }
}
