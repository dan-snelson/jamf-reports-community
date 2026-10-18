import Foundation
import XCTest
@testable import JamfReports

/// Tests for `GroupInventoryService` — decode of both snapshot shapes,
/// aggregate computation, and empty-state behavior.
///
/// `GroupInventoryService` is a `Sendable` struct with `nonisolated static`
/// load methods. No `@MainActor` needed — matches `PatchStatusService` pattern.
final class GroupInventoryServiceTests: XCTestCase {

    // MARK: - Helpers

    private func writeTmp(_ content: String, name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString).json")
        try Data(content.utf8).write(to: url)
        return url
    }

    private func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - load — advanced mobile device searches

    func testLoadAdvancedSearchesDecodes() throws {
        let json = """
        {
          "totalCount": 2,
          "results": [
            {"id": "211", "name": "iPads No Passcode",
             "criteria": [], "displayFields": [], "siteId": "-1"},
            {"id": "212", "name": "iPhones Unmanaged",
             "criteria": [], "displayFields": [], "siteId": "-1"}
          ]
        }
        """
        let url = try writeTmp(json, name: "searches")
        defer { remove(url) }

        let snap = GroupInventoryService.load(
            searchesURL: url, computerGroupsURL: nil, mobileGroupsURL: nil)
        XCTAssertEqual(snap.advancedSearchCount, 2)
        XCTAssertEqual(snap.advancedMobileSearches[0].name, "iPads No Passcode")
        XCTAssertEqual(snap.advancedMobileSearches[1].id, "212")
        XCTAssertTrue(snap.isDetected)
    }

    /// A successfully-decoded empty envelope means collect ran — isDetected must be true
    /// even when results is empty. Distinguishes "never collected" from "collected, zero results".
    func testLoadAdvancedSearchesEmptyEnvelopeStillDetected() throws {
        let json = #"{"totalCount": 0, "results": []}"#
        let url = try writeTmp(json, name: "searches-empty")
        defer { remove(url) }

        let snap = GroupInventoryService.load(
            searchesURL: url, computerGroupsURL: nil, mobileGroupsURL: nil)
        XCTAssertEqual(snap.advancedSearchCount, 0)
        XCTAssertTrue(snap.isDetected)
    }

    // MARK: - load — classic computer groups

    func testLoadClassicComputerGroupsDecodes() throws {
        let json = """
        [
          {"id": 1, "is_smart": true,  "name": "Smart Mac Group"},
          {"id": 2, "is_smart": false, "name": "Static Lab Macs"},
          {"id": 3,                    "name": "No Flag Group"}
        ]
        """
        let url = try writeTmp(json, name: "computer-groups")
        defer { remove(url) }

        let snap = GroupInventoryService.load(
            searchesURL: nil, computerGroupsURL: url, mobileGroupsURL: nil)
        XCTAssertEqual(snap.classicComputerGroupCount, 3)
        XCTAssertEqual(snap.classicComputerSmartGroupCount, 1)
        XCTAssertEqual(
            snap.classicComputerStaticGroupCount, 2,
            "missing is_smart must count as static")
        XCTAssertTrue(snap.isDetected)
    }

    /// A successfully-decoded empty array means collect ran — isDetected must be true.
    func testLoadClassicComputerGroupsEmptyArrayStillDetected() throws {
        let url = try writeTmp("[]", name: "computer-groups-empty")
        defer { remove(url) }

        let snap = GroupInventoryService.load(
            searchesURL: nil, computerGroupsURL: url, mobileGroupsURL: nil)
        XCTAssertEqual(snap.classicComputerGroupCount, 0)
        XCTAssertTrue(snap.isDetected)
    }

    // MARK: - load — classic mobile device groups

    func testLoadClassicMobileGroupsDecodes() throws {
        let json = """
        [
          {"id": 10, "is_smart": true,  "name": "Smart All iPads"},
          {"id": 11, "is_smart": false, "name": "Static Kiosk iPads"}
        ]
        """
        let url = try writeTmp(json, name: "mobile-groups")
        defer { remove(url) }

        let snap = GroupInventoryService.load(
            searchesURL: nil, computerGroupsURL: nil, mobileGroupsURL: url)
        XCTAssertEqual(snap.classicMobileGroupCount, 2)
        XCTAssertEqual(snap.classicMobileSmartGroupCount, 1)
        XCTAssertEqual(snap.classicMobileStaticGroupCount, 1)
        XCTAssertTrue(snap.isDetected)
    }

    // MARK: - load — all three sources combined

    func testLoadAllThreeSourcesCombined() throws {
        let searchesJSON = """
        {"totalCount": 1, "results": [
          {"id": "100", "name": "Test Search",
           "criteria": [], "displayFields": [], "siteId": "-1"}
        ]}
        """
        let computerJSON = #"[{"id": 5, "is_smart": true, "name": "Smart Mac Group"}]"#
        let mobileJSON = #"[{"id": 6, "is_smart": false, "name": "Static iPad Group"}]"#

        let searchesURL = try writeTmp(searchesJSON, name: "searches-all")
        let computerURL = try writeTmp(computerJSON, name: "computer-all")
        let mobileURL = try writeTmp(mobileJSON, name: "mobile-all")
        defer {
            remove(searchesURL); remove(computerURL); remove(mobileURL)
        }

        let snap = GroupInventoryService.load(
            searchesURL: searchesURL,
            computerGroupsURL: computerURL,
            mobileGroupsURL: mobileURL
        )
        XCTAssertEqual(snap.advancedSearchCount, 1)
        XCTAssertEqual(snap.classicComputerGroupCount, 1)
        XCTAssertEqual(snap.classicMobileGroupCount, 1)
        XCTAssertTrue(snap.isDetected)
        XCTAssertNotNil(snap.sourceFile)
        XCTAssertNotNil(snap.snapshotDate)
    }

    // MARK: - load — nil URLs

    func testLoadAllNilURLsReturnsEmpty() {
        let snap = GroupInventoryService.load(
            searchesURL: nil, computerGroupsURL: nil, mobileGroupsURL: nil)
        XCTAssertEqual(snap, .empty)
        XCTAssertFalse(snap.isDetected)
    }

    // MARK: - Snapshot.empty

    func testEmptySnapshotHasZeroCounts() {
        let empty = GroupInventoryService.Snapshot.empty
        XCTAssertEqual(empty.advancedSearchCount, 0)
        XCTAssertEqual(empty.classicComputerGroupCount, 0)
        XCTAssertEqual(empty.classicMobileGroupCount, 0)
        XCTAssertFalse(empty.isDetected)
        XCTAssertNil(empty.sourceFile)
        XCTAssertNil(empty.snapshotDate)
    }

    /// Snapshot decoded to all-empty arrays: isDetected=true (collect ran).
    /// Snapshot.empty (no files): isDetected=false (collect never ran).
    /// The two must be distinguishable so GroupsView shows the right empty state.
    func testDecodedEmptyArraysIsDetectedVsNeverCollected() throws {
        let allEmptyJSON = #"{"totalCount": 0, "results": []}"#
        let url = try writeTmp(allEmptyJSON, name: "detected-empty")
        defer { remove(url) }

        let decoded = GroupInventoryService.load(
            searchesURL: url, computerGroupsURL: nil, mobileGroupsURL: nil)
        XCTAssertTrue(decoded.isDetected, "decoded empty result must be detected")
        XCTAssertTrue(decoded.decodedAnySource)

        let neverCollected = GroupInventoryService.Snapshot.empty
        XCTAssertFalse(neverCollected.isDetected, ".empty must not be detected")
        XCTAssertFalse(neverCollected.decodedAnySource)
    }

    // MARK: - Equatable

    func testSnapshotEquality() throws {
        let json = #"[{"id": 1, "is_smart": true, "name": "Group A"}]"#
        let url = try writeTmp(json, name: "eq-test")
        defer { remove(url) }

        let snap1 = GroupInventoryService.load(
            searchesURL: nil, computerGroupsURL: url, mobileGroupsURL: nil)
        let snap2 = GroupInventoryService.load(
            searchesURL: nil, computerGroupsURL: url, mobileGroupsURL: nil)
        XCTAssertEqual(snap1, snap2)
    }

    // MARK: - cacheSource

    func testCacheSourceIsNeverFetchedWhenSnapshotDateNil() {
        let snap = GroupInventoryService.Snapshot.empty
        XCTAssertEqual(snap.cacheSource, .neverFetchedLive)
    }

    func testCacheSourceIsFreshForRecentSnapshot() throws {
        let json = #"[{"id": 1, "is_smart": false, "name": "G"}]"#
        let url = try writeTmp(json, name: "fresh-test")
        defer { remove(url) }

        let snap = GroupInventoryService.load(
            searchesURL: nil, computerGroupsURL: url, mobileGroupsURL: nil)
        // File was just written — snapshotDate is within the 36-hour window.
        XCTAssertEqual(snap.cacheSource, .fresh)
    }

    // MARK: - Membership, analysis and policy joins

    private func makeDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("group-inv-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func write(_ content: String, _ name: String, in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data(content.utf8).write(to: url)
        return url
    }

    private let computerJSON = """
    [{"id": 1, "is_smart": true, "name": "All"}, {"id": 2, "is_smart": false, "name": "Empty"},
     {"id": 3, "is_smart": false, "name": "Unlisted"}]
    """
    private let mobileJSON = #"[{"id": 1, "is_smart": true, "name": "All iPads"}]"#

    func testMembershipJoinsByIdAndType() throws {
        let dir = try makeDir()
        defer { remove(dir) }
        // Group 3 is in no `groups` row; mobile group 1 shares an id with computer group 1.
        let groups = """
        [{"groupJamfProId": "1", "groupType": "COMPUTER", "membershipCount": 101,
          "groupDescription": "  Everything ", "smart": true},
         {"groupJamfProId": "2", "groupType": "COMPUTER", "membershipCount": 0,
          "groupDescription": ""},
         {"groupJamfProId": "1", "groupType": "MOBILE", "membershipCount": 7}]
        """
        let snap = GroupInventoryService.load(
            searchesURL: nil,
            computerGroupsURL: try write(computerJSON, "c.json", in: dir),
            mobileGroupsURL: try write(mobileJSON, "m.json", in: dir),
            groupsURL: try write(groups, "g.json", in: dir))

        let all = snap.classicComputerGroups[0], empty = snap.classicComputerGroups[1]
        XCTAssertEqual(snap.detail(for: all, .computer).memberCount, 101)
        XCTAssertEqual(snap.detail(for: all, .computer).description, "Everything")
        XCTAssertEqual(snap.detail(for: snap.classicMobileGroups[0], .mobile).memberCount, 7)
        XCTAssertTrue(snap.detail(for: empty, .computer).isEmpty)
        XCTAssertNil(snap.detail(for: empty, .computer).description)
        XCTAssertNil(snap.detail(for: snap.classicComputerGroups[2], .computer).memberCount,
                     "no groups row must read as unknown, not 0")
        XCTAssertEqual(snap.emptyGroupCount, 1)
        XCTAssertNil(snap.unusedGroupCount)
        XCTAssertNil(snap.unscopedPolicyCount)
    }

    func testEmptyGroupCountIsNilWithoutGroupsSnapshot() throws {
        let dir = try makeDir()
        defer { remove(dir) }
        let snap = GroupInventoryService.load(
            searchesURL: nil, computerGroupsURL: try write(computerJSON, "c.json", in: dir),
            mobileGroupsURL: nil)
        XCTAssertNil(snap.emptyGroupCount)
    }

    func testGroupsFixtureDecodesAndJoins() throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/jamf-cli-data/groups/groups.json")
        let dir = try makeDir()
        defer { remove(dir) }
        let snap = GroupInventoryService.load(
            searchesURL: nil,
            computerGroupsURL: try write(
                #"[{"id": 67, "name": "Screensaver"}, {"id": 1, "is_smart": true, "name": "A"}]"#,
                "c.json", in: dir),
            mobileGroupsURL: nil, groupsURL: fixture)
        XCTAssertEqual(snap.detail(for: snap.classicComputerGroups[0], .computer).memberCount, 0)
        XCTAssertEqual(snap.detail(for: snap.classicComputerGroups[1], .computer).memberCount, 101)
    }

    func testBadFieldCostsThatFieldNotTheList() throws {
        let dir = try makeDir()
        defer { remove(dir) }
        let groups = """
        [{"groupJamfProId": 1, "groupType": "COMPUTER", "membershipCount": "many",
          "groupDescription": {"x": 1}},
         "not a row",
         {"groupJamfProId": "2", "groupType": "COMPUTER", "membershipCount": 5}]
        """
        let snap = GroupInventoryService.load(
            searchesURL: nil, computerGroupsURL: try write(computerJSON, "c.json", in: dir),
            mobileGroupsURL: nil, groupsURL: try write(groups, "g.json", in: dir))
        let first = snap.detail(for: snap.classicComputerGroups[0], .computer)
        XCTAssertNil(first.memberCount)
        XCTAssertNil(first.description)
        XCTAssertEqual(snap.detail(for: snap.classicComputerGroups[1], .computer).memberCount, 5)
    }

    func testUnusedGroupsAndAnalysisDateFromAnalyzeSnapshot() throws {
        let dir = try makeDir()
        defer { remove(dir) }
        let analysis = """
        [{"id": "2", "name": "Empty", "memberCount": 0, "type": "static"}, {"id": 99}]
        """
        let url = try write(analysis, "group-tools-analyze_20260915T060000.json", in: dir)
        let snap = GroupInventoryService.load(
            searchesURL: nil, computerGroupsURL: try write(computerJSON, "c.json", in: dir),
            mobileGroupsURL: nil, analysisURL: url)
        XCTAssertEqual(snap.detail(for: snap.classicComputerGroups[1], .computer).unused, true)
        XCTAssertEqual(snap.detail(for: snap.classicComputerGroups[0], .computer).unused, false)
        XCTAssertEqual(snap.unusedGroupCount, 1, "ids the group list lacks are not counted")
        XCTAssertEqual(snap.analysisDate, CloudStorage.snapshotTimestamp(of: url))
    }

    func testUnreadableAnalysisLeavesUnusedUnknown() throws {
        let dir = try makeDir()
        defer { remove(dir) }
        let snap = GroupInventoryService.load(
            searchesURL: nil, computerGroupsURL: try write(computerJSON, "c.json", in: dir),
            mobileGroupsURL: nil, analysisURL: try write("{}", "a.json", in: dir))
        XCTAssertNil(snap.unusedGroupCount)
        XCTAssertNil(snap.analysisDate)
        XCTAssertNil(snap.detail(for: snap.classicComputerGroups[0], .computer).unused)
    }

    func testUnscopedPolicyCountComesFromNoScopeFindings() throws {
        let dir = try makeDir()
        defer { remove(dir) }
        let policy = """
        [{"summary": {"total_policies": 3, "enabled": 3, "disabled": 0, "config_findings": 3,
                      "warnings": 2, "info": 1},
          "config_findings": [
            {"severity": "warning", "policy": "A", "policy_id": "1", "check": "no_scope",
             "detail": ""},
            {"severity": "warning", "policy": "B", "policy_id": "2", "check": "no_scope",
             "detail": ""},
            {"severity": "info", "policy": "C", "policy_id": "3", "check": "no_category",
             "detail": ""}]}]
        """
        let snap = GroupInventoryService.load(
            searchesURL: nil, computerGroupsURL: try write(computerJSON, "c.json", in: dir),
            mobileGroupsURL: nil, policyStatusURL: try write(policy, "p.json", in: dir))
        XCTAssertEqual(snap.unscopedPolicyCount, 2)
    }

    // MARK: - Newest by stamp

    func testNewestSnapshotIgnoresConflictCopyAndDatesFromFilename() throws {
        let dir = try makeDir()
        defer { remove(dir) }
        let stem = "classic-computer-groups_"
        _ = try write(#"[{"id": 1, "name": "Old"}]"#, stem + "20260901T060000.json", in: dir)
        _ = try write(#"[{"id": 1, "name": "New"}]"#, stem + "20260910T060000.json", in: dir)
        _ = try write(#"[{"id": 1, "name": "Copy"}]"#, stem + "20260910T060000 2.json", in: dir)

        let newest = try XCTUnwrap(FileManager.newestJSONFile(in: dir))
        let snap = GroupInventoryService.load(
            searchesURL: nil, computerGroupsURL: newest, mobileGroupsURL: nil)
        XCTAssertEqual(snap.classicComputerGroups.first?.name, "New")
        XCTAssertEqual(snap.snapshotDate, CloudStorage.snapshotTimestamp(of: newest))
    }

    // MARK: - Equality

    /// Same file name and stamp, different rows: the old count-only comparison called these equal.
    func testSnapshotEqualityComparesContent() throws {
        let dir = try makeDir()
        defer { remove(dir) }
        let url = try write(
            #"[{"id": 1, "name": "One"}]"#, "a_20260901T060000.json", in: dir)
        let first = GroupInventoryService.load(
            searchesURL: nil, computerGroupsURL: url, mobileGroupsURL: nil)
        _ = try write(#"[{"id": 1, "name": "Two"}]"#, "a_20260901T060000.json", in: dir)
        let second = GroupInventoryService.load(
            searchesURL: nil, computerGroupsURL: url, mobileGroupsURL: nil)
        XCTAssertNotEqual(first, second)
    }

    // MARK: - Criteria summary

    private func search(_ criteriaJSON: String) throws -> AdvancedMobileSearchRow {
        let json = #"{"id": "1", "name": "S", "criteria": \#(criteriaJSON)}"#
        return try JSONDecoder().decode(AdvancedMobileSearchRow.self, from: Data(json.utf8))
    }

    func testCriteriaSummaryJoinsWithAndOrAndParens() throws {
        let row = try search("""
        [{"name": "Model", "priority": 1, "andOr": "and", "searchType": "like", "value": "iPad",
          "openingParen": true, "closingParen": false},
         {"name": "Model", "priority": 2, "andOr": "or", "searchType": "like", "value": "iPhone",
          "openingParen": false, "closingParen": true},
         {"name": "Last Inventory Update", "priority": 0, "andOr": "and",
          "searchType": "more than x days ago", "value": "7"}]
        """)
        XCTAssertEqual(
            row.criteriaSummary,
            "Last Inventory Update more than x days ago 7 AND (Model like iPad "
                + "OR Model like iPhone)")
    }

    func testCriteriaSummaryWithNoCriteria() throws {
        XCTAssertEqual(try search("[]").criteriaSummary, AdvancedMobileSearchRow.noCriteriaText)
        let missing = try JSONDecoder().decode(
            AdvancedMobileSearchRow.self, from: Data(#"{"id": "1"}"#.utf8))
        XCTAssertEqual(missing.criteriaSummary, AdvancedMobileSearchRow.noCriteriaText)
    }

    func testCriteriaSummaryDefaultsMissingConnectorAndValue() throws {
        let row = try search("""
        [{"name": "Passcode Status", "searchType": "is", "value": "Not Present"},
         {"name": "Supervised", "searchType": "is"}]
        """)
        XCTAssertEqual(row.criteriaSummary, "Passcode Status is Not Present AND Supervised is")
    }
}
