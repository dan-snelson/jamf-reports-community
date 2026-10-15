import Foundation

/// The one way the app picks and reads a Jamf Pro inventory CSV from a folder another Mac can
/// write (`csv-inbox/`). A link, FIFO or directory named `*.csv` is never picked, and a read
/// opens the file once, refuses a link and stops at a size cap.
enum InventoryCSV {

    /// 256 MB: about 2 KB a row with many EA columns puts 100,000 rows near 200 MB, so a real
    /// fleet fits and only a planted or runaway file does not.
    static let maxBytes = 256 * 1024 * 1024

    struct ReadError: Error, LocalizedError, Equatable {
        let fileName: String
        let reason: String
        var errorDescription: String? { "inventory CSV \(fileName) not read: \(reason)" }
    }

    /// Why `url` is not a regular file, judged without following a link; nil for a regular file
    /// (and for a name that does not exist, which the caller's open reports).
    static func nonRegularReason(_ url: URL) -> String? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        switch info.st_mode & S_IFMT {
        case S_IFREG: return nil
        case S_IFLNK: return "a symbolic link"
        case S_IFDIR: return "a directory"
        default: return "not a regular file"
        }
    }

    /// The `.csv` entries directly in `directory`: regular files, and the others with why each
    /// is not one (a link, FIFO or directory named `*.csv`).
    static func entries(
        in directory: URL
    ) -> (regular: [URL], skipped: [(url: URL, reason: String)]) {
        let all = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        var regular: [URL] = []
        var skipped: [(url: URL, reason: String)] = []
        for entry in all where entry.pathExtension.lowercased() == "csv" {
            if let reason = nonRegularReason(entry) {
                skipped.append((entry, reason))
            } else {
                regular.append(entry)
            }
        }
        return (regular, skipped)
    }

    /// Newest regular `.csv` directly in `directory`. Each entry skipped for not being a regular
    /// file goes to `onSkip` with the reason.
    static func newest(in directory: URL, onSkip: (URL, String) -> Void) -> URL? {
        let found = entries(in: directory)
        for skipped in found.skipped { onSkip(skipped.url, skipped.reason) }
        func modified(_ url: URL) -> Date {
            (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? .distantPast
        }
        return found.regular.max { modified($0) < modified($1) }
    }

    /// The bytes of the regular file at `url`, at most `limit`. A link is refused unless
    /// `followLinks`, which is for a path the person at this Mac typed or chose, never one
    /// found in a folder another Mac writes.
    static func read(_ url: URL, limit: Int = maxBytes, followLinks: Bool = false) throws -> Data {
        do {
            return try BoundedFile.read(url, limit: limit, followSymlinks: followLinks)
        } catch BoundedFile.Failure.tooLarge {
            throw ReadError(
                fileName: url.lastPathComponent,
                reason: "larger than \(limit / 1_048_576) MB")
        } catch BoundedFile.Failure.notRegular {
            throw ReadError(fileName: url.lastPathComponent, reason: "not a regular file")
        } catch BoundedFile.Failure.unreadable(let code) {
            let reason = code == ELOOP
                ? "a symbolic link" : String(cString: strerror(code))
            throw ReadError(fileName: url.lastPathComponent, reason: reason)
        }
    }

    /// `read` as UTF-8 text without a leading byte-order mark.
    static func readText(
        _ url: URL, limit: Int = maxBytes, followLinks: Bool = false
    ) throws -> String {
        let data = try read(url, limit: limit, followLinks: followLinks)
        guard var text = String(data: data, encoding: .utf8) else {
            throw ReadError(fileName: url.lastPathComponent, reason: "not UTF-8 text")
        }
        if text.hasPrefix("\u{FEFF}") { text = String(text.dropFirst()) }
        return text
    }
}
