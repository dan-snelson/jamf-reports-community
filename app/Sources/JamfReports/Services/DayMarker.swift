import Foundation

/// One-line day stamp at <workspace>/automation/.<name>-last (yyyy-MM-dd).
/// Best-effort persistence shared by GUI and headless once-per-day signals.
struct DayMarker: Sendable {
    let name: String

    /// The day last stamped, or nil when the marker is absent or unreadable.
    func lastStampedDay(in workspace: URL) -> String? {
        guard let url = markerURL(in: workspace),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let day = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return day.isEmpty ? nil : day
    }

    /// Whether `key` is stamped. A marker whose folder is refused (`automation` is a symlink)
    /// reads as stamped: it can never be written, so reading it as unclaimed would repeat the
    /// action on every pass. That fails toward not sending and not re-running.
    func isStamped(_ key: String, in workspace: URL) -> Bool {
        markerURL(in: workspace) == nil || lastStampedDay(in: workspace) == key
    }

    /// Best-effort: creates `automation/` if needed and never throws. Nothing is written when
    /// `automation` is a symlink.
    func stamp(day: String, in workspace: URL) {
        guard let url = markerURL(in: workspace) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? day.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Gives the stamp back, so the day or hour counts as unclaimed. Best-effort.
    func clear(in workspace: URL) {
        guard let url = markerURL(in: workspace) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private func markerURL(in workspace: URL) -> URL? {
        WorkspacePaths.confinedFolderOrWarn(["automation"], under: workspace)?
            .appendingPathComponent(".\(name)-last")
    }
}
