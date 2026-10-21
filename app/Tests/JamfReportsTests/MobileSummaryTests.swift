import XCTest
@testable import JamfReports

/// The daily summary's `mobile` object (mobile spec 4.2): Jamf Pro's from a `mobile-devices-list`
/// snapshot, each share over the devices that report the field, an unreported pair absent.
final class MobileSummaryTests: XCTestCase {

    private var root: URL!
    private var dataDir: URL!
    private var summariesDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = GoldenFleetWorkspace.freshRoot()
        dataDir = root.appendingPathComponent("jamf-cli-data", isDirectory: true)
        summariesDir = root.appendingPathComponent("summaries", isDirectory: true)
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    /// jamf-cli's `pro mobile-devices list` with the four sections, from the dummy tenant.
    private var fixtureData: Data {
        get throws {
            let dir = TestFixtures.dir("jamf-cli-data-mobile-sections/mobile-devices-list")
            let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil).first)
            return try Data(contentsOf: file)
        }
    }

    private var iOSLatest: [Int: String] {
        SOFAFeedService.latestByMajor(SOFAFeedService.load(
            from: TestFixtures.dir("sofa").appendingPathComponent("ios_data_feed.json"),
            platform: "ios"))
    }

    private let now = ISO8601DateFormatter().date(from: "2026-10-19T12:00:00Z") ?? Date()

    func testTheRealListShapeGivesEachShareOverTheDevicesThatReportIt() throws {
        let mobile = try XCTUnwrap(MobileSummary.fromMobileDevicesList(
            try fixtureData, latestByMajor: iOSLatest, staleDays: 30, now: now))
        XCTAssertEqual(mobile.managed, 6)
        XCTAssertEqual(mobile.unmanaged, 0)
        XCTAssertEqual(mobile.supervised, .init(met: 0, of: 6))
        XCTAssertEqual(mobile.passcode, .init(met: 4, of: 6))
        XCTAssertEqual(mobile.dataProtection, .init(met: 5, of: 6))
        XCTAssertEqual(mobile.activationLock, .init(met: 3, of: 6))
        XCTAssertEqual(mobile.jailbroken, 1)
        XCTAssertEqual(mobile.stale, 6, "last inventory in 2020")
        XCTAssertNil(mobile.osCurrent, "iOS 7 and 8 are majors the feed does not track")
        XCTAssertNil(mobile.updateErrors, "no scan")
    }

    func testOSCurrencyAgainstTheIOSFeedLeavesAnUntrackedMajorUnknown() {
        let devices = ["18.7.8", "18.1", "26.5.0", "17.5"].map {
            MobileSummary.Device(managed: true, iOSVersion: $0)
        } + [MobileSummary.Device(managed: true)]
        let mobile = MobileSummary.build(devices, latestByMajor: iOSLatest, staleDays: 30, now: now)
        XCTAssertEqual(mobile?.osCurrent, .init(met: 2, of: 3), "17.5 and the TV are not judged")
        XCTAssertNil(MobileSummary.build(devices, latestByMajor: [:], staleDays: 30, now: now)?
            .osCurrent, "no feed cached")
    }

    func testAnAppleTVIsNotJudgedAgainstTheIOSFeed() {
        let tv = MobileDeviceInventoryItem(
            deviceType: "tvOS",
            hardware: .init(model: "Apple TV 4K", modelIdentifier: "AppleTV11,1"))
        XCTAssertNil(MobileSummary.device(tv).iOSVersion)
    }

    func testAPairNoDeviceReportsIsAbsentAndNoMobileDeviceIsNoObject() {
        let mobile = MobileSummary.build(
            [MobileSummary.Device(managed: false)], latestByMajor: [:], staleDays: 30, now: now)
        XCTAssertEqual(mobile?.unmanaged, 1)
        XCTAssertNil(mobile?.supervised)
        XCTAssertNil(mobile?.passcode)
        XCTAssertNil(mobile?.stale)
        XCTAssertNil(mobile?.jailbroken)
        XCTAssertNil(MobileSummary.build([], latestByMajor: [:], staleDays: 30, now: now))
        let flat = Data(#"[{"id":"1","name":"Device 1","deviceType":"iOS"}]"#.utf8)
        XCTAssertNil(MobileSummary.fromMobileDevicesList(
            flat, latestByMajor: [:], staleDays: 30, now: now),
            "a row with no section says nothing")
    }

    func testUpdateErrorsCountOnlyNonComputerRowsOfAScan() throws {
        let scan = try Data(contentsOf: TestFixtures.dir("jamf-cli-data/update-device-failures")
            .appendingPathComponent("update-device-failures.json"))
        XCTAssertEqual(ReportEngine.mobileUpdateErrorCount(scan), 1)
        let summaryOnly = Data(#"[{"total":3,"status_summary":[]}]"#.utf8)
        XCTAssertNil(ReportEngine.mobileUpdateErrorCount(summaryOnly), "no scan, not 0 errors")
    }

    func testTheProSummaryStepWritesTheObjectBesideTheCount() throws {
        let rows = try XCTUnwrap(
            JSONSerialization.jsonObject(with: fixtureData) as? [[String: Any]])
        try GoldenFleetWorkspace.writeSnapshot(
            kind: MobileFleetService.deviceKind, dataDir: dataDir,
            at: Date().addingTimeInterval(-3_600), rows: rows)
        let engine = ReportEngine(config: ReportConfig(), dataDir: dataDir)
        XCTAssertEqual(engine.emitSummaryJSON(summariesDir: summariesDir, liveKinds: nil), .wrote)
        let written = try XCTUnwrap(SummaryJSONParser.parseDirectory(summariesDir).first)
        XCTAssertEqual(written.totalDevices, 0, "mobile-only: `mobileOnlySummary`")
        XCTAssertEqual(written.mobileDeviceCount, 6)
        XCTAssertEqual(written.mobile?.passcode, .init(met: 4, of: 6))
    }

    func testAShareCountingMoreDevicesThanReportIsOutOfRange() {
        let json = #"""
        {"date":"2026-10-19","totalDevices":0,"source":"jamf-cli",
         "mobile":{"managed":3,"unmanaged":0,"passcode":{"met":4,"of":3}}}
        """#
        XCTAssertThrowsError(try SummaryJSONParser.decode(Data(json.utf8)))
        let fine = json.replacingOccurrences(of: #""met":4"#, with: #""met":3"#)
        XCTAssertEqual(try SummaryJSONParser.decode(Data(fine.utf8)).mobile?.passcode?.pct, 100)
    }

    // MARK: - Same-day rebuild

    private func day(mobile: MobileSummary?, count: Int? = nil) -> DailySummary {
        DailySummary(
            date: "2026-10-19", totalDevices: 10, fileVaultPct: nil, compliancePct: nil,
            staleCount: nil, osCurrentPct: nil, crowdstrikePct: nil, patchPct: nil,
            source: "jamf-cli", mobileDeviceCount: count, mobile: mobile)
    }

    func testARebuildKeepsAMobileFigureItCouldNotMeasure() {
        let morning = MobileSummary(
            managed: 5, unmanaged: 0, osCurrent: .init(met: 4, of: 5), stale: 1)
        let evening = MobileSummary(managed: 6, unmanaged: 1, stale: 2)
        let merged = day(mobile: evening, count: 7).filling(from: day(mobile: morning, count: 5))
        XCTAssertEqual(merged.mobile?.managed, 6, "this run's counts")
        XCTAssertEqual(merged.mobile?.stale, 2)
        XCTAssertEqual(merged.mobile?.osCurrent, .init(met: 4, of: 5))
        XCTAssertEqual(day(mobile: nil).filling(from: day(mobile: morning)).mobile, morning)
    }

    func testAFreshSummaryThatMeasuresMobileReplacesOneThatDidNot() {
        let figures = MobileSummary(managed: 1, unmanaged: 0)
        XCTAssertTrue(ReportEngine.freshSummaryIsBetter(
            existing: day(mobile: nil, count: 1), fresh: day(mobile: figures, count: 1)))
        XCTAssertFalse(ReportEngine.freshSummaryIsBetter(
            existing: day(mobile: figures, count: 1), fresh: day(mobile: nil, count: 1)))
    }

    // MARK: - Alerts

    func testAnAbsentPairNeverFiresAndAPresentOneDoes() {
        let rules = [
            AlertRule(metric: "mobile_passcode_pct", when: "below", threshold: 90),
            AlertRule(metric: "mobile_jailbroken_count", when: "above", threshold: 0),
        ]
        let unreported = day(mobile: MobileSummary(managed: 2, unmanaged: 0))
        XCTAssertTrue(MetricAlertEvaluator.evaluate(
            rules: rules, current: unreported, prior: nil).isEmpty)
        XCTAssertTrue(MetricAlertEvaluator.evaluate(
            rules: rules, current: day(mobile: nil), prior: nil).isEmpty)
        let reported = day(mobile: MobileSummary(
            managed: 2, unmanaged: 0, passcode: .init(met: 1, of: 2), jailbroken: 1))
        XCTAssertEqual(MetricAlertEvaluator.evaluate(
            rules: rules, current: reported, prior: nil).map(\.metricLabel),
            ["Mobile passcode compliance", "Jailbroken mobile devices"])
    }
}
