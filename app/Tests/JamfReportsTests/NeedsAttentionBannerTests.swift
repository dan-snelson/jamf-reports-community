import XCTest
@testable import JamfReports

/// The banner's "Needs attention" entry: its rank, its button and its Dismiss.
@MainActor
final class NeedsAttentionBannerTests: XCTestCase {
    private func freshness(_ kind: DataFreshnessIssue.Kind) -> DataFreshnessIssue {
        DataFreshnessIssue(
            snapshotKind: "security", tier: .refresh, kind: kind,
            lastSuccess: Date(timeIntervalSince1970: 1_700_000_000), consecutiveFailures: 3,
            lastFailure: nil)
    }

    private func item(_ code: AttentionCode, _ message: String, seen: TimeInterval = 0,
                      runLog: String? = nil) -> AttentionItem {
        let date = Date(timeIntervalSince1970: 1_790_000_000 + seen)
        return AttentionItem(code: code, message: message, firstSeen: date, lastSeen: date,
                             count: 1, profile: "p", runLog: runLog)
    }

    func testItRanksBelowFailingCollectsAndAboveStaleData() throws {
        let open = [item(.webhookRejected, "webhook rejected (HTTP 404)"),
                    item(.protectBackupSkipped, "Protect not backed up")]
        let failing = try XCTUnwrap(GlobalHealthBanner.headline(
            freshness: [freshness(.failing)], automation: [], attention: open))
        XCTAssertTrue(failing.text.contains("failing to collect"), failing.text)

        let shown = try XCTUnwrap(GlobalHealthBanner.headline(
            freshness: [freshness(.stale)], automation: [], attention: open))
        XCTAssertEqual(shown.text, "2 things need attention")
        XCTAssertEqual(shown.detail, "webhook rejected (HTTP 404); Protect not backed up")
        XCTAssertEqual(GlobalHealthBanner.headline(
            freshness: [], automation: [], attention: [open[1]])?.text,
            "1 thing needs attention")
        XCTAssertEqual(GlobalHealthBanner.headline(
            freshness: [], automation: [], sharedConfig: ["output.output_dir"],
            attention: open)?.text, "Shared config needs confirming on this Mac")
    }

    func testTheButtonFollowsTheTopItemsCode() {
        func action(_ code: AttentionCode) -> GlobalHealthBanner.PrimaryAction {
            GlobalHealthBanner.primaryAction(
                freshness: [freshness(.stale)], canCollect: true,
                attention: [item(code, "x"), item(.webhookRejected, "y")])
        }
        XCTAssertEqual(action(.webhookRejected), .openAutomation)
        XCTAssertEqual(action(.protectBackupSkipped), .openBackups)
        XCTAssertEqual(action(.protectBackupPartial), .openBackups)
        for code in [AttentionCode.schoolZeroDevices, .eaSnapshotUnreadable,
                     .fleetDriftLargeChange, .lostModeStripFailed] {
            XCTAssertEqual(action(code), .openRunHistory, code.rawValue)
        }
        XCTAssertEqual(GlobalHealthBanner.primaryAction(
            freshness: [freshness(.failing)], canCollect: true,
            attention: [item(.protectBackupSkipped, "x")]), .collectNow,
            "a failing collect keeps its button")
    }

    func testTheNewestSightingLeads() {
        let ordered = AttentionItem.ordered([
            item(.schoolZeroDevices, "old", seen: 0), item(.webhookRejected, "new", seen: 60),
        ])
        XCTAssertEqual(ordered.map(\.code), [.webhookRejected, .schoolZeroDevices])
    }

    func testDismissHidesAnItemUntilItIsSeenAgain() throws {
        let suite = "attention-dismiss-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let open = item(.webhookRejected, "HTTP 404")
        AttentionDismissals.dismiss([open], in: defaults)
        XCTAssertTrue(AttentionDismissals.isDismissed(open, in: defaults))
        var again = open
        again.lastSeen = open.lastSeen.addingTimeInterval(3600)
        XCTAssertFalse(AttentionDismissals.isDismissed(again, in: defaults))
        XCTAssertFalse(AttentionDismissals.isDismissed(
            item(.schoolZeroDevices, "x"), in: defaults))
    }
}
