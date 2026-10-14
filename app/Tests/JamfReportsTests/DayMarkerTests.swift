import XCTest
@testable import JamfReports

/// Round-trip + edge tests for the persisted once-per-day marker
/// (`<workspace>/automation/.<name>-last`). Pure filesystem, no launchctl.
final class DayMarkerTests: XCTestCase {

    private func makeWorkspace() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("DayMarker-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testStampThenReadRoundTrips() throws {
        let workspace = try makeWorkspace()
        let marker = DayMarker(name: "overdue-notify")
        marker.stamp(day: "2026-07-09", in: workspace)
        XCTAssertEqual(marker.lastStampedDay(in: workspace), "2026-07-09")
    }

    func testAbsentMarkerReadsNil() throws {
        let workspace = try makeWorkspace()
        XCTAssertNil(DayMarker(name: "overdue-notify").lastStampedDay(in: workspace))
    }

    func testStampOverwritesSameDayMarker() throws {
        let workspace = try makeWorkspace()
        let marker = DayMarker(name: "catch-up")
        marker.stamp(day: "2026-07-08", in: workspace)
        marker.stamp(day: "2026-07-09", in: workspace)
        XCTAssertEqual(marker.lastStampedDay(in: workspace), "2026-07-09")
    }

    func testDistinctNamesDoNotCollide() throws {
        let workspace = try makeWorkspace()
        DayMarker(name: "overdue-notify").stamp(day: "2026-07-01", in: workspace)
        DayMarker(name: "catch-up").stamp(day: "2026-07-02", in: workspace)
        XCTAssertEqual(
            DayMarker(name: "overdue-notify").lastStampedDay(in: workspace), "2026-07-01")
        XCTAssertEqual(
            DayMarker(name: "catch-up").lastStampedDay(in: workspace), "2026-07-02")
    }

    func testMissingWorkspaceReadsNilWithoutThrowing() {
        // A workspace path that was never created → read returns nil, no throw.
        let missing = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("DayMarker-missing-\(UUID().uuidString)", isDirectory: true)
        XCTAssertNil(DayMarker(name: "overdue-notify").lastStampedDay(in: missing))
    }

    // MARK: - sendOnce

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.lock(); value += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    private func claimFile(_ workspace: URL) -> URL {
        workspace.appendingPathComponent("automation/.overdue-notify-sending")
    }

    func testTwoConcurrentSendersPostOnce() async throws {
        let workspace = try makeWorkspace()
        let sends = Counter()
        let marker = DayMarker(name: "overdue-notify")
        async let first = marker.sendOnce(day: "2026-10-14", in: [workspace]) {
            sends.increment()
            try? await Task.sleep(nanoseconds: 300_000_000)
            return true
        }
        async let second = marker.sendOnce(day: "2026-10-14", in: [workspace]) {
            sends.increment()
            try? await Task.sleep(nanoseconds: 300_000_000)
            return true
        }
        let outcomes = await [first, second]
        XCTAssertEqual(sends.count, 1)
        XCTAssertEqual(outcomes.filter { $0 == .sent }.count, 1)
        XCTAssertEqual(outcomes.filter { $0 == .skipped }.count, 1)
        XCTAssertTrue(marker.isStamped("2026-10-14", in: workspace))
        XCTAssertFalse(FileManager.default.fileExists(atPath: claimFile(workspace).path))
    }

    func testAFailedSendLeavesNoClaimAndNoStamp() async throws {
        let workspace = try makeWorkspace()
        let marker = DayMarker(name: "overdue-notify")
        let outcome = await marker.sendOnce(day: "2026-10-14", in: [workspace]) { false }
        XCTAssertEqual(outcome, .failed)
        XCTAssertFalse(marker.isStamped("2026-10-14", in: workspace))
        XCTAssertFalse(FileManager.default.fileExists(atPath: claimFile(workspace).path))

        let sends = Counter()
        let retry = await marker.sendOnce(day: "2026-10-14", in: [workspace]) {
            sends.increment()
            return true
        }
        XCTAssertEqual(retry, .sent)
        XCTAssertEqual(sends.count, 1)
    }

    func testAFreshClaimMakesTheSecondSenderSkip() async throws {
        let workspace = try makeWorkspace()
        let marker = DayMarker(name: "overdue-notify")
        XCTAssertTrue(try AutomationStateFile.claimExclusively(
            claimFile(workspace), staleAfter: DayMarker.claimStaleAfter))
        let sends = Counter()
        let outcome = await marker.sendOnce(day: "2026-10-14", in: [workspace]) {
            sends.increment()
            return true
        }
        XCTAssertEqual(outcome, .skipped)
        XCTAssertEqual(sends.count, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: claimFile(workspace).path),
                      "another sender's claim is not released by a skipper")
    }

    func testAStaleClaimIsTakenOver() async throws {
        let workspace = try makeWorkspace()
        let marker = DayMarker(name: "overdue-notify")
        XCTAssertTrue(try AutomationStateFile.claimExclusively(
            claimFile(workspace), staleAfter: DayMarker.claimStaleAfter))
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-DayMarker.claimStaleAfter - 60)],
            ofItemAtPath: claimFile(workspace).path)
        let sends = Counter()
        let outcome = await marker.sendOnce(day: "2026-10-14", in: [workspace]) {
            sends.increment()
            return true
        }
        XCTAssertEqual(outcome, .sent)
        XCTAssertEqual(sends.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: claimFile(workspace).path))
    }

    func testAnAlreadyStampedDaySkipsAfterTheClaim() async throws {
        let workspace = try makeWorkspace()
        let marker = DayMarker(name: "overdue-notify")
        marker.stamp(day: "2026-10-14", in: workspace)
        let sends = Counter()
        let outcome = await marker.sendOnce(day: "2026-10-14", in: [workspace]) {
            sends.increment()
            return true
        }
        XCTAssertEqual(outcome, .skipped)
        XCTAssertEqual(sends.count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: claimFile(workspace).path))
    }

    func testEveryWorkspaceOfABatchIsClaimedAndStamped() async throws {
        let first = try makeWorkspace()
        let second = try makeWorkspace()
        let marker = DayMarker(name: "overdue-notify")
        XCTAssertTrue(try AutomationStateFile.claimExclusively(
            claimFile(second), staleAfter: DayMarker.claimStaleAfter))
        let sends = Counter()
        let held = await marker.sendOnce(day: "2026-10-14", in: [first, second]) {
            sends.increment()
            return true
        }
        XCTAssertEqual(held, .skipped)
        XCTAssertEqual(sends.count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: claimFile(first).path),
                       "the claim taken on the first is given back")

        AutomationStateFile.releaseClaim(claimFile(second))
        let sent = await marker.sendOnce(day: "2026-10-14", in: [first, second]) { true }
        XCTAssertEqual(sent, .sent)
        XCTAssertTrue(marker.isStamped("2026-10-14", in: first))
        XCTAssertTrue(marker.isStamped("2026-10-14", in: second))
    }

    func testTheClaimNeverFollowsASymlink() throws {
        let workspace = try makeWorkspace()
        let target = workspace.appendingPathComponent("victim")
        try FileManager.default.createDirectory(
            at: claimFile(workspace).deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: claimFile(workspace), withDestinationURL: target)
        XCTAssertFalse(try AutomationStateFile.claimExclusively(
            claimFile(workspace), staleAfter: DayMarker.claimStaleAfter))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path), "nothing created through it")
    }

    private final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        func append(_ line: String) { lock.lock(); items.append(line); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
    }

    func testASkipForAFreshClaimIsLogged() async throws {
        let workspace = try makeWorkspace()
        XCTAssertTrue(try AutomationStateFile.claimExclusively(
            claimFile(workspace), staleAfter: DayMarker.claimStaleAfter))
        let lines = Lines()
        let outcome = await DayMarker(name: "overdue-notify").sendOnce(
            day: "2026-10-14", in: [workspace], onLine: { lines.append($0) }
        ) { true }
        XCTAssertEqual(outcome, .skipped)
        XCTAssertEqual(lines.all.count, 1)
        XCTAssertTrue(lines.all.first?.contains("another sender holds a claim") == true)
    }

    func testAFutureDatedClaimIsTakenOver() async throws {
        let workspace = try makeWorkspace()
        XCTAssertTrue(try AutomationStateFile.claimExclusively(
            claimFile(workspace), staleAfter: DayMarker.claimStaleAfter))
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(86_400)],
            ofItemAtPath: claimFile(workspace).path)
        let sends = Counter()
        let outcome = await DayMarker(name: "overdue-notify").sendOnce(
            day: "2026-10-14", in: [workspace]) {
            sends.increment()
            return true
        }
        XCTAssertEqual(outcome, .sent)
        XCTAssertEqual(sends.count, 1)
    }

    func testAClaimDatedWithinTheClockSkewToleranceStillHolds() throws {
        let workspace = try makeWorkspace()
        XCTAssertTrue(try AutomationStateFile.claimExclusively(
            claimFile(workspace), staleAfter: DayMarker.claimStaleAfter))
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(60)],
            ofItemAtPath: claimFile(workspace).path)
        XCTAssertFalse(try AutomationStateFile.claimExclusively(
            claimFile(workspace), staleAfter: DayMarker.claimStaleAfter))
    }

    func testAFolderAtTheClaimNameSendsAnywayWithAWarningAndIsLeftAlone() async throws {
        let workspace = try makeWorkspace()
        let inside = claimFile(workspace).appendingPathComponent("keep")
        try FileManager.default.createDirectory(
            at: claimFile(workspace), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: inside.path, contents: Data())
        let marker = DayMarker(name: "overdue-notify")
        let lines = Lines()
        let sends = Counter()
        for _ in 0..<2 {
            let day = "2026-10-1\(sends.count + 4)"
            let outcome = await marker.sendOnce(
                day: day, in: [workspace], onLine: { lines.append($0) }
            ) {
                sends.increment()
                return true
            }
            XCTAssertEqual(outcome, .sent)
        }
        XCTAssertEqual(sends.count, 2, "a folder at the name must not silence the digest")
        XCTAssertEqual(lines.all.filter { $0.hasPrefix("[warn]") }.count, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: inside.path), "never entered")
    }

    func testClaimingOverAFolderThrowsInsteadOfReturningHeld() throws {
        let workspace = try makeWorkspace()
        try FileManager.default.createDirectory(
            at: claimFile(workspace), withIntermediateDirectories: true)
        XCTAssertThrowsError(try AutomationStateFile.claimExclusively(
            claimFile(workspace), staleAfter: DayMarker.claimStaleAfter))
    }
}
