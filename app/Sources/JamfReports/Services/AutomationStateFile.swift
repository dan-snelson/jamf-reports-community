import CryptoKit
import Foundation

/// Where a workspace's small automation state files live (`DayMarker`, `MetricAlertLedger`).
/// Normally `<workspace>/automation/<file>`. When `automation` is refused (a symbolic link), the
/// file moves to this Mac's Application Support, keyed by the workspace, so once-per-day and
/// once-per-hour de-duplication still works: reading a refused file as "sent" muted alerts, and
/// reading it as "not sent" repeated them on every 300 s wake.
enum AutomationStateFile {

    /// True when the workspace's `automation` folder is refused by `WorkspacePaths.confinedFolder`.
    static func isRefused(in workspace: URL) -> Bool {
        (try? WorkspacePaths.confinedFolder(["automation"], under: workspace)) == nil
    }

    static func url(named fileName: String, in workspace: URL) -> URL {
        do {
            return try WorkspacePaths.confinedFolder(["automation"], under: workspace)
                .appendingPathComponent(fileName)
        } catch {
            // The folder name only: the workspace path is not for the log.
            AppLogger.collect.warning(
                "\("automation", privacy: .public) folder refused; its state is kept on this Mac")
            return fallbackURL(named: fileName, in: workspace)
        }
    }

    /// Creates the folder if needed and writes atomically. A file kept on this Mac is 0600.
    static func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        if isFallback(url) {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    // MARK: - Fallback

    private static var fallbackFolder: URL {
        AppSupport.directory().appendingPathComponent("automation-fallback", isDirectory: true)
    }

    private static func isFallback(_ url: URL) -> Bool {
        url.deletingLastPathComponent().standardizedFileURL == fallbackFolder.standardizedFileURL
    }

    /// Keyed by a SHA-256 of the resolved workspace path and the file name, so two workspaces
    /// never share a file and no path appears in the name.
    private static func fallbackURL(named fileName: String, in workspace: URL) -> URL {
        let key = workspace.resolvingSymlinksInPath().standardizedFileURL.path + "\n" + fileName
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }
        return fallbackFolder.appendingPathComponent(digest.joined() + ".state")
    }
}
