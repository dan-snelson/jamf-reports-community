import XCTest
@testable import JamfReports

final class FleetOverviewStabilityTests: XCTestCase {
    func testWordFollowsTheToneThresholds() {
        XCTAssertEqual(stabilityWord(85), "Healthy")
        XCTAssertEqual(stabilityWord(84.9), "Watch")
        XCTAssertEqual(stabilityWord(70), "Watch")
        XCTAssertEqual(stabilityWord(69.9), "Low")
        XCTAssertNil(stabilityWord(nil))
    }

    func testPillTextAndAccessibilityLabelCarryTheWord() {
        XCTAssertEqual(stabilityPillText(92.34), "Healthy · 92.3%")
        XCTAssertEqual(stabilityPillText(nil), "--")
        XCTAssertEqual(stabilityAccessibilityLabel(72, hasSummary: true), "Stability Watch, 72.0 percent")
        XCTAssertEqual(stabilityAccessibilityLabel(nil, hasSummary: true), "Stability unknown")
        XCTAssertEqual(stabilityAccessibilityLabel(nil, hasSummary: false), "Stability: no data")
    }
}
