import Foundation

extension ConfigDoctorService {

    /// One `.fail` row when config.yaml's `jamf_cli.profile` names a profile other than the
    /// workspace's own (blank and equal are fine). A copied or renamed workspace, or an edit by
    /// a peer on a shared one, ends up here: `ReportEngine.generate` and `CollectRouter` refuse
    /// to run it, so it should be seen before the next scheduled run.
    static func profileMismatchRows(profile: String, config: ReportConfig) -> [DoctorRow] {
        let named = config.jamfCli?.resolvedProfile ?? ""
        guard !named.isEmpty, named != profile else { return [] }
        let shownNamed = ConfigSchema.displayText(named)
        let shownProfile = ConfigSchema.displayText(profile)
        let caseOnly = ProfileService.isCaseVariant(named, of: profile)
        return [DoctorRow(
            id: "config.profile_mismatch",
            severity: .fail,
            title: "jamf_cli.profile names a different profile than this workspace",
            detail: "config.yaml sets jamf_cli.profile to '\(shownNamed)' but this workspace is "
                + "for '\(shownProfile)'" + (caseOnly ? " (the names differ only in case)" : "")
                + ". Generating a report and collecting refuse to run until they agree.",
            hint: "Edit the jamf_cli: profile line in config.yaml to read '\(shownProfile)', "
                + "or remove the line. A copied or renamed workspace keeps the old name."
        )]
    }
}
