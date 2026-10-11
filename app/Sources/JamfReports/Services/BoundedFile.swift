import Foundation

/// A read of a file another Mac can write, bounded in size and type. The file is opened once
/// (non-blocking, so a FIFO planted at the name cannot hang the open), its type is checked on
/// that descriptor, and the bytes come from the same descriptor, so the check and the read
/// cannot be about two different files.
enum BoundedFile {

    enum Failure: Error, Equatable {
        /// A FIFO, device, socket or directory.
        case notRegular
        /// More than `limit` bytes; `read` stopped at `limit + 1`.
        case tooLarge
        /// `open` or `read` failed with this errno (ENOENT is a missing file).
        case unreadable(Int32)
    }

    /// At most `limit` bytes of the regular file at `url`.
    static func read(_ url: URL, limit: Int) throws -> Data {
        let descriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw Failure.unreadable(errno) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw Failure.unreadable(errno) }
        guard (info.st_mode & S_IFMT) == S_IFREG else { throw Failure.notRegular }
        let data: Data
        do {
            data = try handle.read(upToCount: limit + 1) ?? Data()
        } catch {
            throw Failure.unreadable(EIO)
        }
        guard data.count <= limit else { throw Failure.tooLarge }
        return data
    }
}
