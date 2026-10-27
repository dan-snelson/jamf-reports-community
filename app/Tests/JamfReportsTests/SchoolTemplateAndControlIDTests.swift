import XCTest
@testable import JamfReports

// MARK: - SchoolTemplateAndControlIDTests

/// SchoolTemplate registration and resolution.
final class SchoolTemplateAndControlIDTests: XCTestCase {

    // MARK: - #4 SchoolTemplate

    func testSchoolTemplateIdentifier() {
        XCTAssertEqual(SchoolTemplate().identifier, "school")
    }

    func testSchoolTemplateIsRegisteredInAllTemplates() {
        let identifiers = TemplateResolver.allTemplates.map(\.identifier)
        XCTAssertTrue(
            identifiers.contains("school"),
            "SchoolTemplate must be registered in TemplateResolver.allTemplates; got: \(identifiers)"
        )
    }

    func testTemplateResolverReturnsSchoolTemplate() {
        let resolved = TemplateResolver.resolve(identifier: "school")
        XCTAssertEqual(
            resolved.identifier,
            "school",
            "TemplateResolver.resolve(identifier: 'school') must return SchoolTemplate, " +
            "not the Executive fallback"
        )
    }

    func testSchoolTemplateDataTierIsSchool() {
        XCTAssertEqual(SchoolTemplate().recommendedSchedule, TemplateDataTier.school)
    }

    func testSchoolTemplateHasAudience() {
        XCTAssertFalse(
            SchoolTemplate().audience.isEmpty,
            "SchoolTemplate.audience must not be empty"
        )
    }

    func testSchoolTemplateIncludesAtLeastFourSheets() {
        XCTAssertGreaterThanOrEqual(
            SchoolTemplate().includedSheets.count, 4,
            "SchoolTemplate must include at least 4 sheets"
        )
    }

    func testSchoolTemplateIncludesAtLeastFourHTMLSections() {
        XCTAssertGreaterThanOrEqual(
            SchoolTemplate().htmlSections.count, 4,
            "SchoolTemplate must include at least 4 HTML sections"
        )
    }

    func testAllTemplatesHaveAudience() {
        for template in TemplateResolver.allTemplates {
            XCTAssertFalse(
                template.audience.isEmpty,
                "\(type(of: template)).audience must not be empty"
            )
        }
    }

    func testTemplateResolverFallsBackToExecutiveForUnknown() {
        let resolved = TemplateResolver.resolve(identifier: "does-not-exist")
        XCTAssertEqual(
            resolved.identifier,
            "executive",
            "Unknown identifier must fall back to ExecutiveTemplate"
        )
    }
}
