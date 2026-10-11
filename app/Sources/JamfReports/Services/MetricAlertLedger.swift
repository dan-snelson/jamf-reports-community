import Foundation

/// Per-day, per-rule dedup ledger for metric-alert cards (2.6 "trust trio" #1).
///
/// On managed-automation scan days two snapshot-only runs collect the same
/// day's summary (freshness daily + scan weekly, ~10 min apart) and both
/// evaluate the alert rules — without a ledger they post identical cards. A
/// persistent condition also re-cards on every run. The ledger records which
/// rule keys have already been carded today and filters them out, while a rule
/// that trips for the FIRST time later the same day still alerts.
///
/// Stored at `<workspace>/automation/.metric-alerts-ledger.json`. Best-effort
/// I/O: a read or write failure returns the input keys unchanged, so alerting fails toward
/// SENDING, never toward silence. The exception is a refused folder (`automation` is a
/// symlink): the ledger can never be written, so every key reads as already carded and
/// nothing is sent on every pass.
struct MetricAlertLedger: Sendable {
    let workspace: URL

    /// Nil when `automation` is a symlink.
    private var fileURL: URL? {
        WorkspacePaths.confinedFolderOrWarn(["automation"], under: workspace)?
            .appendingPathComponent(".metric-alerts-ledger.json")
    }

    private struct Record: Codable {
        var day: String
        var keys: [String]
    }

    /// Return the subset of `keys` not yet carded for `day`, WITHOUT persisting.
    /// A stale record from a prior day resets: today's keys are all new. On a
    /// read failure returns `keys` unchanged so a ledger problem never silences
    /// an alert.
    func pendingKeys(day: String, keys: [String]) -> [String] {
        guard !keys.isEmpty, let url = fileURL else { return [] }
        let existing = load(from: url)
        let already: Set<String> = existing?.day == day ? Set(existing?.keys ?? []) : []
        return keys.filter { !already.contains($0) }
    }

    /// Mark `keys` as carded for `day`, merged with anything already carded
    /// today so a later same-day run dedups against the full set.
    ///
    /// Call this ONLY after a confirmed send. Recording first would let a
    /// transient webhook failure silence that rule for the rest of the day —
    /// the same discipline `DayMarker` uses for the overdue digest.
    func record(day: String, keys: [String]) {
        guard !keys.isEmpty, let url = fileURL else { return }
        let existing = load(from: url)
        let already: Set<String> = existing?.day == day ? Set(existing?.keys ?? []) : []
        save(Record(day: day, keys: Array(already.union(keys))), to: url)
    }

    private func load(from url: URL) -> Record? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Record.self, from: data)
    }

    private func save(_ record: Record, to fileURL: URL) {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try JSONEncoder().encode(record).write(to: fileURL, options: .atomic)
        } catch {
            AppLogger.webhook.warning(
                "MetricAlertLedger: could not persist ledger — same-day dedup may not hold: \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}
