import Foundation

/// A candidate Extension Attribute the walkthrough proposes adopting into `custom_eas` or
/// `security_agents`. The user selects which proposals to adopt — nothing is written automatically.
struct ProposedEA: Identifiable, Sendable, Equatable {
    /// Human label.
    let name: String
    /// What the report matches on: the CSV header, or the EA name in `ea-results`.
    let column: String
    /// Guessed EA type — one of `boolean|date|percentage|version|text`.
    let type: String
    /// Preview value; also the default `true_value` / connected value on adoption.
    let sampleValue: String
    var id: String { column }
}

/// The one guess at a custom EA's type from its values, shared by the CSV walkthrough and the
/// collected-EA candidates.
enum EATypeGuess {

    /// Sample values (lowercased) that read as a boolean.
    static let booleanSampleValues: Set<String> = [
        "yes", "no", "true", "false", "enabled", "disabled", "installed",
        "not installed", "encrypted", "not encrypted", "compliant",
        "non-compliant", "on", "off",
    ]

    /// Guess the EA type from a normalized header (may be empty) and its sample values.
    static func guess(header: String, sampleValue: String, samples: [String]) -> String {
        if headerSuggestsDate(header) || sampleParsesAsDate(sampleValue) { return "date" }
        if header.contains("version") || sampleLooksLikeVersion(sampleValue) { return "version" }
        if header.contains("percent") || header.contains("%") || sampleValue.hasSuffix("%") {
            return "percentage"
        }
        if booleanSampleValues.contains(sampleValue.lowercased()) || samplesLookBoolean(samples) {
            return "boolean"
        }
        return "text"
    }

    private static func headerSuggestsDate(_ header: String) -> Bool {
        ["date", "expire", "expiry", "enrolled", "checkin"].contains { header.contains($0) }
    }

    private static func sampleParsesAsDate(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        // Match common Jamf date shapes: YYYY-MM-DD or YYYY/MM/DD, optionally with
        // a time and timezone — but NOT a date followed by free text (e.g.
        // "2026-04-07 12:58:59 -0600: Completed: …"), which is a status string,
        // not a date EA. The anchor after the optional time/tz prevents that.
        let pattern = "^\\d{4}[-/]\\d{1,2}[-/]\\d{1,2}"
            + "([ T]\\d{1,2}:\\d{2}(:\\d{2})?( ?([-+]\\d{2}:?\\d{2}|Z|[A-Za-z]{2,4}))?)?$"
        return value.range(of: pattern, options: .regularExpression) != nil
    }

    private static func sampleLooksLikeVersion(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        return value.range(of: "^\\d+(\\.\\d+)+$", options: .regularExpression) != nil
    }

    /// True when the distinct non-empty samples are <= 2 and look boolean-ish.
    private static func samplesLookBoolean(_ samples: [String]) -> Bool {
        let distinct = Set(samples.filter { !$0.isEmpty }.map { $0.lowercased() })
        guard !distinct.isEmpty, distinct.count <= 2 else { return false }
        return distinct.allSatisfy { booleanSampleValues.contains($0) }
    }
}
