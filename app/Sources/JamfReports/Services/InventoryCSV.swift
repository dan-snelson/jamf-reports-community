import Foundation

/// The one way the app reads a Jamf Pro inventory CSV (the one-time EA import): the file is
/// opened once, a link is refused unless the person chose the path, and a size cap applies.
enum InventoryCSV {

    /// 256 MB: about 2 KB a row with many EA columns puts 100,000 rows near 200 MB, so a real
    /// fleet fits and only a planted or runaway file does not.
    static let maxBytes = 256 * 1024 * 1024

    struct ReadError: Error, LocalizedError, Equatable {
        let fileName: String
        let reason: String
        var errorDescription: String? { "inventory CSV \(fileName) not read: \(reason)" }
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
