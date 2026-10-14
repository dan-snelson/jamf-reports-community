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
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    // MARK: - Exclusive claim

    /// Creates `url` with `O_CREAT|O_EXCL|O_NOFOLLOW` (0600): true when this caller made it, false
    /// when it exists and is younger than `staleAfter`. An older file belongs to a sender that
    /// died, so it is removed and the claim retried once. Two callers that take the same stale
    /// claim in the same instant can both win; that needs a crash first and costs one card.
    static func claimExclusively(
        _ url: URL, staleAfter: TimeInterval, now: Date = Date()
    ) throws -> Bool {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        for attempt in 0..<2 {
            let descriptor = open(url.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
            if descriptor >= 0 {
                close(descriptor)
                return true
            }
            guard errno == EEXIST else {
                throw CocoaError(.fileWriteUnknown, userInfo: [
                    NSLocalizedDescriptionKey: "claim \(url.lastPathComponent): "
                        + String(cString: strerror(errno))])
            }
            var info = stat()
            guard lstat(url.path, &info) == 0 else { continue }   // gone meanwhile: retry
            let age = now.timeIntervalSince1970 - TimeInterval(info.st_mtimespec.tv_sec)
            guard age >= staleAfter, attempt == 0 else { return false }
            unlink(url.path)
        }
        return false
    }

    static func releaseClaim(_ url: URL) {
        unlink(url.path)
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
