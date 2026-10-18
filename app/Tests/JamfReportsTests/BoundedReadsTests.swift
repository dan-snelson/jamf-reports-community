import XCTest
@testable import JamfReports

/// Reads of files a peer on a shared workspace can write refuse a link, a FIFO and an
/// oversize file, and never block (#284). Each blocking call runs on its own thread with a
/// deadline, so a regression fails the test instead of hanging the run.
final class BoundedReadsTests: XCTestCase {

    private let fm = FileManager.default
    private let profile = "boundedreads"
    private let deadline: TimeInterval = 5
    nonisolated(unsafe) private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = fm.temporaryDirectory
            .appendingPathComponent("jrc-bounded-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("JRC_TEST_WORKSPACES_ROOT")
        if let root { try? fm.removeItem(at: root) }
        root = nil
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private func workspace() throws -> URL {
        let url = try XCTUnwrap(ProfileService.workspaceURL(for: profile))
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func fifo(at url: URL) throws {
        try fm.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        XCTAssertEqual(mkfifo(url.path, 0o600), 0)
    }

    private func link(_ url: URL, to target: URL) throws {
        try fm.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: url, withDestinationURL: target)
    }

    private func sparse(_ url: URL, bytes: UInt64) throws {
        try fm.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        XCTAssertTrue(fm.createFile(atPath: url.path, contents: nil))
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: bytes)
        try handle.close()
    }

    /// `body`'s result, or nil when it had not returned after `deadline` seconds.
    private func within<T: Sendable>(_ body: @escaping @Sendable () -> T) -> T? {
        let box = ResultBox<T>()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { box.value = body(); done.signal() }
        return done.wait(timeout: .now() + deadline) == .success ? box.value : nil
    }

    private final class ResultBox<T: Sendable>: @unchecked Sendable { var value: T? }

    // MARK: - BoundedFile.readTail

    func testReadTailReturnsTheEndAndSaysItCutTheFile() throws {
        let file = root.appendingPathComponent("big.log")
        try Data("0123456789".utf8).write(to: file)
        let whole = try BoundedFile.readTail(file, limit: 20)
        XCTAssertEqual(String(decoding: whole.data, as: UTF8.self), "0123456789")
        XCTAssertFalse(whole.truncated)
        let cut = try BoundedFile.readTail(file, limit: 4)
        XCTAssertEqual(String(decoding: cut.data, as: UTF8.self), "6789")
        XCTAssertTrue(cut.truncated)
    }

    func testReadTailRefusesALinkAndAFIFO() throws {
        let real = root.appendingPathComponent("real.log")
        try Data("x".utf8).write(to: real)
        let linked = root.appendingPathComponent("linked.log")
        try link(linked, to: real)
        XCTAssertThrowsError(try BoundedFile.readTail(linked, limit: 10))
        let pipe = root.appendingPathComponent("pipe.log")
        try fifo(at: pipe)
        let outcome = within { (try? BoundedFile.readTail(pipe, limit: 10)) == nil }
        XCTAssertEqual(outcome, true, "a FIFO must be refused without blocking")
    }

    // MARK: - Run logs

    private func logsDir() throws -> URL {
        try workspace().appendingPathComponent("automation/logs", isDirectory: true)
    }

    func testRunHistoryTailReadRefusesALinkAndAFIFO() throws {
        let logs = try logsDir()
        try fm.createDirectory(at: logs, withIntermediateDirectories: true)
        let real = logs.appendingPathComponent("real.log")
        try Data("exit 0 after 1s\n".utf8).write(to: real)
        XCTAssertEqual(RunHistoryService.parseLogTail(from: real).0, 0)

        let linked = logs.appendingPathComponent("linked.log")
        try link(linked, to: real)
        XCTAssertNil(RunHistoryService.parseLogTail(from: linked).0)

        let pipe = logs.appendingPathComponent("pipe.log")
        try fifo(at: pipe)
        let exit = within { RunHistoryService.parseLogTail(from: pipe).0 }
        XCTAssertNotNil(exit, "parseLogTail must not block on a FIFO")
        XCTAssertNil(exit ?? nil)
    }

    func testRunHistoryLoadLogRefusesALinkAndAFIFO() throws {
        let logs = try logsDir()
        try fm.createDirectory(at: logs, withIntermediateDirectories: true)
        let real = logs.appendingPathComponent("real.log")
        try Data("[ok] done\nexit 0 after 1s\n".utf8).write(to: real)
        XCTAssertFalse(RunHistoryService.loadLog(real).isEmpty)

        let linked = logs.appendingPathComponent("linked.log")
        try link(linked, to: real)
        XCTAssertTrue(RunHistoryService.loadLog(linked).isEmpty)

        let pipe = logs.appendingPathComponent("pipe.log")
        try fifo(at: pipe)
        let lines = within { RunHistoryService.loadLog(pipe).count }
        XCTAssertEqual(lines, 0, "loadLog must not block on a FIFO")
    }

    func testRunHistoryLoadLogKeepsOnlyTheTailOfAHugeLog() throws {
        let logs = try logsDir()
        try fm.createDirectory(at: logs, withIntermediateDirectories: true)
        let file = logs.appendingPathComponent("huge.log")
        try sparse(file, bytes: 6 * 1024 * 1024)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("\nlast line\n".utf8))
        try handle.close()
        let lines = RunHistoryService.loadLog(file)
        XCTAssertEqual(lines.first?.text, "[truncated — showing tail]")
        XCTAssertEqual(lines.last?.text, "last line")
    }

    func testLaunchAgentTailReadRefusesALinkAndAFIFO() throws {
        let logs = try logsDir()
        try fm.createDirectory(at: logs, withIntermediateDirectories: true)
        let real = logs.appendingPathComponent("real.log")
        try Data("exit 0 after 1s\n".utf8).write(to: real)
        XCTAssertEqual(LaunchAgentService.parseLogTail(from: real).exitCode, 0)

        let linked = logs.appendingPathComponent("linked.log")
        try link(linked, to: real)
        XCTAssertNil(LaunchAgentService.parseLogTail(from: linked).exitCode)

        let pipe = logs.appendingPathComponent("pipe.log")
        try fifo(at: pipe)
        let exit = within { LaunchAgentService.parseLogTail(from: pipe).exitCode }
        XCTAssertNotNil(exit, "parseLogTail must not block on a FIFO")
        XCTAssertNil(exit ?? nil)
    }

    // MARK: - Per-run summary beside the log

    private func summaryURL(for log: URL) -> URL {
        log.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("snapshots/computers/summaries")
            .appendingPathComponent("summary_\(log.deletingPathExtension().lastPathComponent).json")
    }

    func testPartialRunSummaryIsReadOnlyFromARegularFile() throws {
        let logs = try logsDir()
        let log = logs.appendingPathComponent("run.log")
        let summary = summaryURL(for: log)
        try fm.createDirectory(at: summary.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        let partial = Data(#"{"status":"partial"}"#.utf8)
        try partial.write(to: summary)
        XCTAssertTrue(RunHistoryService.isPartialRun(logURL: log, logTailText: ""))

        let elsewhere = root.appendingPathComponent("elsewhere.json")
        try partial.write(to: elsewhere)
        try fm.removeItem(at: summary)
        try link(summary, to: elsewhere)
        XCTAssertFalse(RunHistoryService.isPartialRun(logURL: log, logTailText: ""))

        try fm.removeItem(at: summary)
        try fifo(at: summary)
        let result = within { RunHistoryService.isPartialRun(logURL: log, logTailText: "") }
        XCTAssertEqual(result, false, "a FIFO summary must be ignored without blocking")

        try fm.removeItem(at: summary)
        try sparse(summary, bytes: UInt64(BoundedFile.documentLimit) + 1)
        XCTAssertFalse(RunHistoryService.isPartialRun(logURL: log, logTailText: ""))
    }

    // MARK: - Run status file

    private func status(_ ws: URL, label: String) -> URL {
        ws.appendingPathComponent("automation/\(label)_status.json")
    }

    private static func lastRunSuccess(profile: String, label: String) -> Bool? {
        let schedule = Schedule(
            name: "n", profile: profile, schedule: "Daily 06:20", cadence: "custom",
            mode: .snapshotOnly, next: "—", last: "—", lastStatus: .ok, artifacts: [],
            enabled: true, launchAgentLabel: label)
        return LaunchAgentService.healthInputs(
            schedules: [schedule], statusProfile: nil).first?.lastRunSuccess
    }

    func testRunStatusFileRefusesALinkAFIFOAndAnOversizeFile() throws {
        let ws = try workspace()
        let label = "com.github.tonyyo11.jamf-reports-community.\(profile).daily"
        let file = status(ws, label: label)
        let body = Data(#"{"success": true, "finished_at": "2026-09-07T10:00:00Z"}"#.utf8)
        try fm.createDirectory(at: file.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        try body.write(to: file)
        XCTAssertEqual(Self.lastRunSuccess(profile: profile, label: label), true)

        let elsewhere = ws.appendingPathComponent("automation/other.json")
        try body.write(to: elsewhere)
        try fm.removeItem(at: file)
        try link(file, to: elsewhere)
        XCTAssertNil(Self.lastRunSuccess(profile: profile, label: label))

        try fm.removeItem(at: file)
        try fifo(at: file)
        let profile = self.profile
        let fromFIFO = within { Self.lastRunSuccess(profile: profile, label: label) }
        XCTAssertNotNil(fromFIFO, "a FIFO status file must not block the read")
        XCTAssertNil(fromFIFO ?? nil)

        try fm.removeItem(at: file)
        try sparse(file, bytes: UInt64(BoundedFile.documentLimit) + 1)
        XCTAssertNil(Self.lastRunSuccess(profile: profile, label: label))
    }

    // MARK: - Retention marker

    private func retentionWorkspace() throws -> URL {
        let ws = try workspace()
        try "retention:\n  enabled: true\n  snapshot_keep_days: 30\n".write(
            to: ws.appendingPathComponent("config.yaml"), atomically: true, encoding: .utf8)
        return ws
    }

    func testRetentionMarkerFIFOIsNotReadAndDoesNotBlock() throws {
        let ws = try retentionWorkspace()
        try fifo(at: ws.appendingPathComponent(".retention-last"))
        let profile = self.profile
        let finished: Int? = within { SnapshotRetentionService.sweepIfDue(profile: profile) }
        XCTAssertNotNil(finished, "sweepIfDue must not block on a FIFO marker")
    }

    func testRetentionMarkerLinkToToday_DoesNotSkipTheSweep() throws {
        let ws = try retentionWorkspace()
        let today = DateFormatter()
        today.dateFormat = "yyyy-MM-dd"
        let target = root.appendingPathComponent("today.txt")
        try today.string(from: Date()).write(to: target, atomically: true, encoding: .utf8)
        try link(ws.appendingPathComponent(".retention-last"), to: target)
        // An old snapshot is archived only when the sweep runs.
        let dir = ws.appendingPathComponent("jamf-cli-data/computers", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let old = dir.appendingPathComponent("computers_20250101T000000.json")
        try "[]".write(to: old, atomically: true, encoding: .utf8)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -90 * 86_400)],
                             ofItemAtPath: old.path)
        SnapshotRetentionService.sweepIfDue(profile: profile)
        XCTAssertFalse(fm.fileExists(atPath: old.path), "a linked marker is not a record")
    }

    func testRetentionMarkerOversizeIsNotARecord() throws {
        let ws = try retentionWorkspace()
        try sparse(ws.appendingPathComponent(".retention-last"),
                   bytes: UInt64(BoundedFile.stateFileLimit) + 1)
        XCTAssertNil(BoundedFile.stateText(ws.appendingPathComponent(".retention-last")))
    }

    // MARK: - Cached snapshots (Audit screen)

    private func snapshotDir() throws -> URL {
        let dir = try workspace().appendingPathComponent("jamf-cli-data/audit", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testCachedSnapshotsSkipALinkAFIFOAndAnOversizeFile() async throws {
        let dir = try snapshotDir()
        let good = Data(#"[{"section":"summary"}]"#.utf8)
        try good.write(to: dir.appendingPathComponent("audit_20260101T000000.json"))
        let elsewhere = root.appendingPathComponent("elsewhere.json")
        try good.write(to: elsewhere)
        try link(dir.appendingPathComponent("audit_20260102T000000.json"), to: elsewhere)
        try fifo(at: dir.appendingPathComponent("audit_20260103T000000.json"))
        try sparse(dir.appendingPathComponent("audit_20260104T000000.json"),
                   bytes: UInt64(BoundedFile.snapshotLimit) + 1)

        let profile = self.profile
        let found = expectation(description: "snapshots read")
        let box = ResultBox<[CLIBridge.CachedJSONSnapshot]>()
        Task.detached { [box] in
            box.value = await CLIBridge().cachedJSONSnapshots(
                profile: profile, type: "audit", limit: 10)
            found.fulfill()
        }
        await fulfillment(of: [found], timeout: deadline)
        XCTAssertEqual(box.value?.map(\.data), [good])
    }

    // MARK: - Device-detail cache

    private func stub() throws -> URL {
        let stub = root.appendingPathComponent("stub-\(UUID().uuidString.prefix(6))")
        try "#!/bin/sh\nprintf '%s' '{\"id\":\"1\"}'\n".write(
            to: stub, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        return stub
    }

    private func detail(live stub: URL?) async -> CLIBridge.DeviceDetailResult? {
        let profile = self.profile
        let finished = expectation(description: "device detail")
        let box = ResultBox<CLIBridge.DeviceDetailResult>()
        Task.detached { [box] in
            box.value = await CLIBridge().singleDeviceDetail(
                profile: profile, deviceID: "C02TEST", cacheSubdir: "devices",
                jamfCLIArgs: { ["pro", "device", $0] }, locateJamfCLI: { stub })
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: deadline)
        return box.value
    }

    func testDeviceCacheIsNotReadThroughALinkAFIFOOrWhenOversize() async throws {
        _ = try workspace()
        let seeded = await detail(live: try stub())
        let cache = try XCTUnwrap(seeded?.cacheURL)
        let cached = await detail(live: nil)
        XCTAssertEqual(cached?.fromCache, true, "a regular cache is still read")

        let elsewhere = root.appendingPathComponent("elsewhere.json")
        try Data(#"{"id":"planted"}"#.utf8).write(to: elsewhere)
        try fm.removeItem(at: cache)
        try link(cache, to: elsewhere)
        let viaLink = await detail(live: nil)
        XCTAssertNil(viaLink)

        try fm.removeItem(at: cache)
        try fifo(at: cache)
        let viaFIFO = await detail(live: nil)
        XCTAssertNil(viaFIFO)

        try fm.removeItem(at: cache)
        try sparse(cache, bytes: UInt64(BoundedFile.deviceDetailLimit) + 1)
        let oversize = await detail(live: nil)
        XCTAssertNil(oversize)
    }
}
