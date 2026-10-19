import Foundation

/// What the Add sheet offers (environment spec 5.1, first slice): a new workspace for Jamf Pro,
/// the Platform API or Jamf School, Jamf Protect added to the current workspace, and the jamf-cli
/// profiles no workspace uses. Pure; `AddSheetDiscovery.load` supplies the disk and jamf-cli facts.
enum AddSheetPlan {
    /// What the sheet says once Set up workspace finished for `name`: the workspace exists, so
    /// the row leaves the list, and a first collect that failed must be said here instead.
    static func adoptionOutcome(
        name: String, status: ExistingCLISetupFlow.ProfileStatus?
    ) -> (message: String?, error: String?) {
        if case .failed(let reason) = status {
            return (nil, "\(name)'s workspace was created, but its first collect failed "
                + "(\(reason)). Fix the cause, then collect from that workspace.")
        }
        return ("\(name) is set up. Switch to it from the workspace menu.", nil)
    }

    enum Choice: Equatable, Sendable {
        case newWorkspace
        case addToCurrent
    }

    /// A product a new workspace is set up for, each through its onboarding path.
    enum NewProduct: String, CaseIterable, Identifiable, Sendable {
        case jamfPro, platformAPI, jamfSchool
        var id: String { rawValue }
    }

    struct UnassignedProfile: Identifiable, Equatable, Sendable {
        enum Use: Equatable, Sendable {
            /// A Jamf Pro, Platform API or Jamf School login: set up as a workspace of its own.
            case newWorkspace
            /// A Jamf Protect login: added to the current Jamf Pro workspace.
            case addToCurrent
            /// Nothing the app can do with it today, and why.
            case unavailable(String)
        }

        let name: String
        let product: JamfCLIProduct
        let url: String
        let use: Use
        var id: String { name }
    }

    static let securityCloudReason = "Jamf Security Cloud is not supported yet."

    /// The jamf-cli profiles no workspace uses: neither a workspace folder of their own nor
    /// named by a workspace's `protect.profile` or `school_cli.profile`. Names compare by
    /// folder key, since a case variant shares its workspace's folder. `unusable` holds
    /// `ProfileService.unusableProfiles` explanations.
    static func unassigned(
        profiles: [JamfCLIProfile],
        workspaces: [String],
        paired: Set<String>,
        unusable: [String: String]
    ) -> [UnassignedProfile] {
        let used = Set((workspaces + Array(paired)).map(ProfileName.folderKey))
        return profiles
            .filter { !used.contains(ProfileName.folderKey($0.name)) }
            .map { profile in
                UnassignedProfile(
                    name: profile.name, product: profile.product, url: profile.url,
                    use: use(of: profile, unusable: unusable[profile.name]))
            }
    }

    private static func use(
        of profile: JamfCLIProfile, unusable: String?
    ) -> UnassignedProfile.Use {
        if let unusable { return .unavailable(unusable) }
        if profile.isOrganizationLevel {
            return .unavailable(PlatformScopeLevel.organizationLevelReason)
        }
        switch profile.product {
        case .protect: return .addToCurrent
        case .securityCloud: return .unavailable(securityCloudReason)
        case .pro, .school, .unknown: return .newWorkspace
        }
    }

    /// The choice the sheet opens on; the user can always change it. A product asked for by
    /// the caller, or an unassigned MDM login (the current workspace already has one), opens
    /// New workspace; an unassigned Protect login opens Add to current while the current
    /// workspace can take Jamf Protect.
    static func preselection(
        unassigned: [UnassignedProfile],
        currentAcceptsProtect: Bool,
        requested: NewProduct?
    ) -> Choice {
        guard requested == nil, currentAcceptsProtect else { return .newWorkspace }
        if unassigned.contains(where: { $0.use == .newWorkspace }) { return .newWorkspace }
        if unassigned.contains(where: { $0.use == .addToCurrent }) { return .addToCurrent }
        return .newWorkspace
    }
}

/// What the Add sheet reads when it opens and on Re-check. `load` runs `jamf-cli config list`,
/// so callers run it off the main actor.
struct AddSheetDiscovery: Sendable {
    /// Nil when jamf-cli's profiles could not be read, which is not the same as "none".
    var unassigned: [AddSheetPlan.UnassignedProfile]?
    /// The Protect profile the current workspace's config.yaml names, if any.
    var currentProtect: String?

    static func load(currentWorkspace: String?) -> AddSheetDiscovery {
        let root = ProfileService.workspacesRoot()
        let currentProtect = currentWorkspace.flatMap {
            ConnectedProducts.read(profile: $0, under: root).protectProfile
        }
        guard let listed = ProfileService.listJamfCLIProfiles(scheduleCounts: [:]) else {
            return AddSheetDiscovery(unassigned: nil, currentProtect: currentProtect)
        }
        let names = listed.map(\.name)
        // A Protect or Security Cloud login's own folder (made by 2.9.0) is not a workspace.
        let workspaces = listed
            .filter {
                !$0.product.isNeverAWorkspace && ProfileService.hasWorkspace($0.name, under: root)
            }
            .map(\.name)
            + ProfileService.localOnlyWorkspaces(under: root, cliNames: names)
        var paired = Set<String>()
        for workspace in workspaces {
            let products = ConnectedProducts.read(profile: workspace, under: root)
            paired.formUnion([products.protectProfile, products.foreignSchoolProfile]
                .compactMap { $0 })
        }
        let unassigned = AddSheetPlan.unassigned(
            profiles: listed, workspaces: workspaces, paired: paired,
            unusable: ProfileService.unusableProfiles(in: names).mapValues(\.explanation))
        return AddSheetDiscovery(unassigned: unassigned, currentProtect: currentProtect)
    }
}
