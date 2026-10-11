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

    private func markerURL(in workspace: URL) -> URL {
        AutomationStateFile.url(named: ".\(name)-last", in: workspace)
    }
}
