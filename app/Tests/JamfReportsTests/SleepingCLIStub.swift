import Foundation

/// A script that stands in for a jamf-cli that starts and then stalls. Its name is not
/// `jamf-cli`, which `CLIBridge.codesignGate` keys on. `exec` replaces the shell, so the
/// timeout's SIGTERM reaches the sleeper and no grandchild holds the pipes open.
enum SleepingCLIStub {
    /// `writesPartialFile` drops a file into the last argument first, as `pro backup --output
    /// <dir>` does before it stalls.
    static func make(in dir: URL, seconds: Int = 30, writesPartialFile: Bool = false) throws -> URL {
        let url = dir.appendingPathComponent("stub-cli-\(UUID().uuidString)")
        let partial = writesPartialFile
            ? "for a; do last=$a; done\necho partial > \"$last/partial.json\"\n" : ""
        let script = "#!/bin/sh\n\(partial)exec /bin/sleep \(seconds)\n"
        try script.write(to: url, atomically: true, encoding: .utf8)
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
