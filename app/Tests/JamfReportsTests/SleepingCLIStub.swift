import Foundation

/// A script that stands in for a jamf-cli that starts and then stalls. Its name is not
/// `jamf-cli`, which `CLIBridge.codesignGate` keys on. `exec` replaces the shell, so the
/// timeout's SIGTERM reaches the sleeper and no grandchild holds the pipes open.
enum SleepingCLIStub {
    static func make(in dir: URL, seconds: Int = 30) throws -> URL {
        let url = dir.appendingPathComponent("stub-cli-\(UUID().uuidString)")
        try "#!/bin/sh\nexec /bin/sleep \(seconds)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    static func makeTempDirectory() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("JRC-SleepingStub-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
