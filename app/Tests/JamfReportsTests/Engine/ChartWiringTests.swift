import Foundation
import XCTest
@testable import JamfReports

// MARK: - ChartWiringTests
// Tests for ReportEngine.renderChartSheet and the config-driven chart branches.
// Verifies each branch executes without error; full sheet-name introspection
// would require exposing Workbook internals, so we rely on no-throw behavior.

final class ChartWiringTests: XCTestCase {

    // MARK: - Helpers

    private func makeSummary(
        date: String,
        totalDevices: Int = 100,
        fileVaultPct: Double = 90.0,
        patchPct: Double = 80.0,
        staleCount: Int = 5,
        osCurrentPct: Double = 70.0,
        compliancePct: Double? = nil
    ) -> DailySummary {
        DailySummary(
            date: date,
            totalDevices: totalDevices,
            fileVaultPct: fileVaultPct,
            compliancePct: compliancePct,
            staleCount: staleCount,
            osCurrentPct: osCurrentPct,
            crowdstrikePct: nil,
            patchPct: patchPct,
            source: "jamf-cli"
        )
    }

    private func writeSummary(_ summary: DailySummary, to dir: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        let data = try encoder.encode(summary)
        let file = dir.appendingPathComponent("summary_\(summary.date).json")
        try data.write(to: file)
    }

    private func tempDir() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-charts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    // MARK: - Empty summaries dir produces no crash

    func testRenderChartSheetEmptyDirDoesNotCrash() throws {
        let tmp = try tempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let config = ReportConfig()
        let engine = ReportEngine(config: config, dataDir: tmp)
        // Should complete without crashing or throwing.
        engine.renderChartSheet(workbook: Workbook(), summariesDir: tmp)
    }

    // MARK: - Single summary produces chart path without error

    func testRenderChartSheetSingleSummary() throws {
        let tmp = try tempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        try writeSummary(makeSummary(date: "2026-01-01"), to: tmp)

        var config = ReportConfig()
        var charts = ChartsConfig()
        charts.enabled = true
        config.charts = charts

        let engine = ReportEngine(config: config, dataDir: tmp)
        engine.renderChartSheet(workbook: Workbook(), summariesDir: tmp)
    }

    // MARK: - Two summaries triggers line chart (time series path)

    func testRenderChartSheetTwoSummaries() throws {
        let tmp = try tempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        try writeSummary(makeSummary(date: "2026-01-01"), to: tmp)
        try writeSummary(makeSummary(date: "2026-02-01"), to: tmp)

        var config = ReportConfig()
        var charts = ChartsConfig()
        charts.enabled = true
        config.charts = charts

        let engine = ReportEngine(config: config, dataDir: tmp)
        engine.renderChartSheet(workbook: Workbook(), summariesDir: tmp)
    }

    // MARK: - deviceStateTrend.enabled=true branch

    func testDeviceStateTrendEnabledBranch() throws {
        let tmp = try tempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        try writeSummary(makeSummary(date: "2026-01-01", staleCount: 10), to: tmp)
        try writeSummary(makeSummary(date: "2026-02-01", staleCount: 8), to: tmp)

        var config = ReportConfig()
        var charts = ChartsConfig()
        charts.enabled = true
        var dss = DeviceStateTrendConfig()
        dss.enabled = true
        charts.deviceStateTrend = dss
        config.charts = charts

        let engine = ReportEngine(config: config, dataDir: tmp)
        engine.renderChartSheet(workbook: Workbook(), summariesDir: tmp)
    }

    // MARK: - perMajorCharts=true branch (no inventory-summary needed)

    func testPerMajorChartsBranchFallback() throws {
        let tmp = try tempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        try writeSummary(makeSummary(date: "2026-01-01", osCurrentPct: 75.0), to: tmp)

        var config = ReportConfig()
        var charts = ChartsConfig()
        charts.enabled = true
        var osAdopt = OSAdoptionConfig()
        osAdopt.perMajorCharts = true
        charts.osAdoption = osAdopt
        config.charts = charts

        let engine = ReportEngine(config: config, dataDir: tmp)
        // Falls back to summary.osCurrentPct when no inventory-summary snapshot exists.
        engine.renderChartSheet(workbook: Workbook(), summariesDir: tmp)
    }

    // MARK: - complianceTrend.enabled

    private let eaColumn = "EA - Failures"

    private func baseline(_ column: String) -> ComplianceBaselineConfig {
        ComplianceBaselineConfig(name: "Baseline \(column)", failuresCountColumn: column)
    }

    /// File names of the images `renderChartSheet` embeds for a workspace whose two dated
    /// `ea-results` snapshots hold failure counts for `eaColumn`, with `baselines` configured.
    private func mscpImages(
        trend: ComplianceTrendConfig?, baselines: [ComplianceBaselineConfig]
    ) throws -> [String] {
        let tmp = try tempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let eaDir = tmp.appendingPathComponent("ea-results", isDirectory: true)
        try FileManager.default.createDirectory(at: eaDir, withIntermediateDirectories: true)
        for stamp in ["20260101T120000", "20260201T120000"] {
            let rows: [[String: Any]] = [
                ["device": "mac-a", "ea_name": eaColumn, "value": 0],
                ["device": "mac-b", "ea_name": eaColumn, "value": 5],
                ["device": "mac-c", "ea_name": eaColumn, "value": 60],
            ]
            try JSONSerialization.data(withJSONObject: rows)
                .write(to: eaDir.appendingPathComponent("ea-results_\(stamp).json"))
        }
        let summaries = tmp.appendingPathComponent("summaries", isDirectory: true)
        try FileManager.default.createDirectory(at: summaries, withIntermediateDirectories: true)

        var config = ReportConfig()
        config.compliance = ComplianceConfig(
            enabled: true, failuresCountColumn: nil, failuresListColumn: nil,
            baselineLabel: nil, framework: nil, baselines: baselines)
        var charts = ChartsConfig()
        charts.complianceTrend = trend
        config.charts = charts
        let workbook = Workbook()
        ReportEngine(config: config, dataDir: tmp)
            .renderChartSheet(workbook: workbook, summariesDir: summaries)
        // No Charts sheet at all when nothing has data to draw.
        return workbook.sheet(named: ReportEngine.chartsSheetName)?.imageEmbeds.map(\.filename) ?? []
    }

    func testTheBandTrendIsDrawnWhenEnabledIsTrueOrAbsent() throws {
        for trend in [ComplianceTrendConfig(enabled: true), ComplianceTrendConfig(enabled: nil), nil] {
            let images = try mscpImages(trend: trend, baselines: [baseline(eaColumn)])
            XCTAssertTrue(images.contains("mscp-band-trend.png"),
                          "trend \(String(describing: trend?.enabled)) must draw the band trend")
        }
    }

    func testTheBandTrendIsLeftOutWhenEnabledIsFalseAndTheDonutStays() throws {
        let images = try mscpImages(trend: ComplianceTrendConfig(enabled: false),
                                    baselines: [baseline(eaColumn)])
        XCTAssertFalse(images.contains("mscp-band-trend.png"))
        XCTAssertTrue(images.contains("mscp-donut-0.png"))
    }

    /// The trend follows the first baseline that has data, not the first one configured.
    func testTheBandTrendFollowsTheFirstBaselineWithData() throws {
        let images = try mscpImages(
            trend: nil, baselines: [baseline("EA - Missing"), baseline(eaColumn)])
        XCTAssertTrue(images.contains("mscp-band-trend.png"))
    }

    func testNoBaselineWithDataDrawsNoBandTrend() throws {
        let images = try mscpImages(trend: nil, baselines: [baseline("EA - Missing")])
        XCTAssertFalse(images.contains("mscp-band-trend.png"))
    }

    /// The chart that tested each day's compliance percentage against failure-count bands and
    /// plotted 1.0 is gone, whatever the summaries and the retired `bands` hold.
    func testNoChartPlotsCompliancePercentAgainstFailureCountBands() throws {
        let charts = try XCTUnwrap(ConfigLoader.loadFromString("""
        charts:
          compliance_trend:
            enabled: true
            bands:
              - {label: "Pass", min_failures: 0, max_failures: 0, color: "#4472C4"}
        """).charts)
        XCTAssertEqual(charts.complianceTrend?.enabled, true, "an old file still loads")
        XCTAssertFalse(try chartImages(charts).contains("compliance_bands.png"))
    }

    // MARK: - osAdoption.per_major_charts

    /// A missing key is on, which is what the Customize screen shows for it.
    func testOSAdoptionChartIsDrawnWhenTheKeyIsAbsentOrTrue() throws {
        var absent = ChartsConfig()
        absent.osAdoption = OSAdoptionConfig()
        var explicit = ChartsConfig()
        explicit.osAdoption = OSAdoptionConfig(perMajorCharts: true)
        for charts in [ChartsConfig(), absent, explicit] {
            XCTAssertTrue(try chartImages(charts).contains("os_adoption.png"))
        }
    }

    func testOSAdoptionChartIsLeftOutWhenPerMajorChartsIsFalse() throws {
        var charts = ChartsConfig()
        charts.osAdoption = OSAdoptionConfig(perMajorCharts: false)
        let images = try chartImages(charts)
        XCTAssertFalse(images.contains("os_adoption.png"))
        XCTAssertTrue(images.contains("fleet_trend.png"), "the rest of the Charts tab stays")
    }

    /// File names of the images `renderChartSheet` embeds for two summaries.
    private func chartImages(_ charts: ChartsConfig) throws -> [String] {
        let tmp = try tempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        try writeSummary(makeSummary(date: "2026-01-01", compliancePct: 0), to: tmp)
        try writeSummary(makeSummary(date: "2026-02-01", compliancePct: 0), to: tmp)

        var config = ReportConfig()
        config.charts = charts
        let workbook = Workbook()
        ReportEngine(config: config, dataDir: tmp)
            .renderChartSheet(workbook: workbook, summariesDir: tmp)
        let sheet = try XCTUnwrap(workbook.sheet(named: ReportEngine.chartsSheetName))
        return sheet.imageEmbeds.map(\.filename)
    }
}
