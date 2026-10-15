import Foundation

extension CLIBridge {

    /// Newest regular `.csv` in the profile workspace (`csv-inbox/` preferred; falls back to root).
    ///
    /// A link, FIFO or directory named `*.csv` is never picked (another Mac can plant one on a
    /// shared workspace); each is named in one `[warn]` line to `onWarning` and the app log.
    /// Used by `main.swift`'s `--scheduled-run` dispatch and `ConfigDoctorService`.
    /// `nonisolated` because the headless `scheduled-run` is detached and not main-actor-bound,
    /// and the implementation only touches `FileManager` + value types.
    nonisolated static func newestCSV(
        in profile: String, onWarning: ((String) -> Void)? = nil
    ) -> URL? {
        guard let workspace = ProfileService.workspaceURL(for: profile) else { return nil }
        let inbox = workspace.appendingPathComponent("csv-inbox")
        let dir = FileManager.default.fileExists(atPath: inbox.path) ? inbox : workspace
        return InventoryCSV.newest(in: dir) { entry, reason in
            let line = "[warn] ignoring \(entry.lastPathComponent) in \(dir.lastPathComponent)/: "
                + "it is \(reason), and only regular files are read. Replace it with the export."
            AppLogger.cli.warning("\(line, privacy: .private)")
            onWarning?(line)
        }
    }
}
