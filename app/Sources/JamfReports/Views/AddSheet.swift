import SwiftUI

/// Opens the Add sheet from anywhere in the shell; `ContentView` presents it. `userInfo["product"]`
/// may name an `AddSheetPlan.NewProduct` raw value to open on.
extension Notification.Name {
    static let showAddSheet = Notification.Name("JamfReports.showAddSheet")
}

struct AddSheetRequest: Identifiable {
    let id = UUID()
    var product: AddSheetPlan.NewProduct?
}

extension AddSheetPlan.NewProduct {
    var title: String {
        switch self {
        case .jamfPro: "Jamf Pro"
        case .platformAPI: "Platform API"
        case .jamfSchool: "Jamf School"
        }
    }

    var icon: String {
        switch self {
        case .jamfPro: "server.rack"
        case .platformAPI: "person.badge.key.fill"
        case .jamfSchool: "graduationcap.fill"
        }
    }

    var summary: String {
        switch self {
        case .jamfPro: "A Jamf Pro server with an API client (OAuth2): on-prem, GovCloud or cloud."
        case .platformAPI: "A Jamf Account integration, recommended for Jamf Cloud."
        case .jamfSchool: "A Jamf School network, with its Network ID and API key."
        }
    }

    /// The onboarding path and connection type this product runs.
    @MainActor var onboarding: (OnboardingFlow.ProductPath, OnboardingFlow.ProConnectionType?) {
        switch self {
        case .jamfPro: (.pro, .oauth2)
        case .platformAPI: (.pro, .platformGateway)
        case .jamfSchool: (.school, nil)
        }
    }
}

/// One Add flow (environment spec 5.1, first slice): Settings › Add connection, the workspace
/// menu's Add item and Data Sources' Jamf School suggestion all open it. New workspace runs the
/// product's onboarding path; Add to current connects Jamf Protect to the active Jamf Pro
/// workspace; the profiles jamf-cli already has that no workspace uses are listed for either.
struct AddSheet: View {
    var requested: AddSheetPlan.NewProduct?
    /// Starts the onboarding path for a new workspace; the sheet has closed by then.
    var onStartOnboarding: (AddSheetPlan.NewProduct) -> Void

    @Environment(WorkspaceStore.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorSchemeContrast) private var contrast

    @State private var choice: AddSheetPlan.Choice = .newWorkspace
    @State private var choiceTouched = false
    @State private var discovery: AddSheetDiscovery?
    @State private var isChecking = false
    @State private var adoptFlow: ExistingCLISetupFlow?
    @State private var adoptingName: String?
    @State private var message: String?
    @State private var errorText: String?
    @State private var showingProtectConnect = false

    /// The active workspace takes Jamf Protect: a live Jamf Pro workspace on disk.
    private var currentIsProWorkspace: Bool {
        !workspace.demoMode && !workspace.isSchoolWorkspace
            && workspace.initializedProfiles.contains { $0.name == workspace.profile }
    }

    private var currentAcceptsProtect: Bool {
        currentIsProWorkspace && discovery != nil && discovery?.currentProtect == nil
    }

    private var isAdopting: Bool { adoptFlow?.isRunning == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().background(Theme.Colors.hairlineStrong)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if currentIsProWorkspace { choiceRow }
                    productsSection
                    existingProfilesSection
                }
                .padding(20)
            }
            Divider().background(Theme.Colors.hairlineStrong)
            footer
        }
        .frame(minWidth: 600, idealWidth: 680, minHeight: 560, idealHeight: 640)
        .background(Theme.Colors.winBG)
        .interactiveDismissDisabled(isAdopting)
        .background {
            Button("", action: close)
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        .task { await recheck() }
        .sheet(isPresented: $showingProtectConnect, onDismiss: { Task { await recheck() } }) {
            ProductConnectSheetView(profileSlug: workspace.profile)
        }
    }

    // MARK: - Header and footer

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Add")
                .font(Theme.Fonts.serif(22, weight: .bold))
                .foregroundStyle(Theme.Colors.fg)
            Text("Set up a new workspace, add Jamf Protect to this one, or use a profile "
                + "jamf-cli already has.")
                .font(.callout)
                .foregroundStyle(Theme.Text.tertiary(contrast))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(EdgeInsets(top: 24, leading: 24, bottom: 16, trailing: 24))
    }

    private var footer: some View {
        HStack {
            Spacer()
            PNPButton(title: "Close", style: .neutral, size: .md, action: close)
                .disabled(isAdopting)
        }
        .padding(16)
    }

    private func close() {
        guard !isAdopting else { return }
        dismiss()
    }

    // MARK: - Step 1: what are you adding

    private var choiceRow: some View {
        HStack(alignment: .top, spacing: 12) {
            choiceCard(
                .newWorkspace, icon: "folder.badge.plus", title: "New workspace",
                body: "Jamf Pro, the Platform API or Jamf School, in a workspace of its own.")
            choiceCard(
                .addToCurrent, icon: "plus.rectangle.on.rectangle",
                title: "Add to \(workspace.profile)",
                body: "Jamf Protect alerts and analytics beside this workspace's Jamf Pro data.")
        }
    }

    private func choiceCard(
        _ value: AddSheetPlan.Choice, icon: String, title: String, body: String
    ) -> some View {
        let selected = choice == value
        return Button {
            choice = value
            choiceTouched = true
        } label: {
            HStack(alignment: .top, spacing: 12) {
                productIcon(icon, size: 40)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(Theme.Colors.fg)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(body)
                        .font(.footnote)
                        .foregroundStyle(Theme.Colors.fg2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.Colors.winBG2, in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(selected ? Theme.Colors.gold : Theme.Colors.hairlineStrong,
                                  lineWidth: selected ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func productIcon(_ name: String, size: CGFloat) -> some View {
        Image(systemName: name)
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(Theme.Colors.goldBright)
            .frame(width: size, height: size)
            .background(Theme.Colors.gold.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
            .accessibilityHidden(true)
    }

    // MARK: - Products

    @ViewBuilder
    private var productsSection: some View {
        if choice == .addToCurrent && currentIsProWorkspace {
            protectCard
        } else {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 170), spacing: 12, alignment: .top)],
                spacing: 12
            ) {
                ForEach(AddSheetPlan.NewProduct.allCases) { productCard($0) }
            }
        }
    }

    private func productCard(_ product: AddSheetPlan.NewProduct) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            productIcon(product.icon, size: 36)
            Text(product.title).font(.headline).foregroundStyle(Theme.Colors.fg)
            Text(product.summary)
                .font(.footnote)
                .foregroundStyle(Theme.Colors.fg2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            PNPButton(title: "Connect new", icon: "arrow.right", size: .sm) {
                startOnboarding(product)
            }
            .disabled(isAdopting)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 190, alignment: .topLeading)
        .background(Theme.Colors.winBG2, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.Colors.hairlineStrong))
    }

    private func startOnboarding(_ product: AddSheetPlan.NewProduct) {
        guard !isAdopting else { return }
        dismiss()
        onStartOnboarding(product)
    }

    private var protectCard: some View {
        Card(padding: 16) {
            HStack(alignment: .top, spacing: 12) {
                productIcon("shield.lefthalf.filled", size: 36)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Jamf Protect").font(.headline).foregroundStyle(Theme.Colors.fg)
                    if let connected = discovery?.currentProtect {
                        Text("\(workspace.profile) already uses the Jamf Protect profile "
                            + "\(connected). Change it from Data Sources.")
                            .font(.footnote)
                            .foregroundStyle(Theme.Text.tertiary(contrast))
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("Connect a Jamf Protect tenant with an API client. Its alerts, "
                            + "computers and insights are collected with this workspace.")
                            .font(.footnote)
                            .foregroundStyle(Theme.Colors.fg2)
                            .fixedSize(horizontal: false, vertical: true)
                        PNPButton(title: "Connect new", icon: "arrow.right", size: .sm) {
                            showingProtectConnect = true
                        }
                        .disabled(isAdopting || discovery == nil)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: - Step 2: profiles jamf-cli already has

    private var visibleRows: [AddSheetPlan.UnassignedProfile] {
        let rows = discovery?.unassigned ?? []
        if choice == .addToCurrent && currentIsProWorkspace {
            return currentAcceptsProtect ? rows.filter { $0.use == .addToCurrent } : []
        }
        return rows.filter { $0.use != .addToCurrent }
    }

    private var existingProfilesSection: some View {
        Card(padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Profiles jamf-cli already has")
                        .font(.headline)
                        .foregroundStyle(Theme.Colors.fg)
                    Spacer()
                    PNPButton(title: "Re-check", icon: "arrow.clockwise", size: .sm) {
                        Task { await recheck() }
                    }
                    .disabled(isChecking || isAdopting || workspace.demoMode)
                }
                if let message { banner(message, tone: .info, icon: "checkmark.circle.fill") }
                if let errorText {
                    banner(errorText, tone: .warn, icon: "exclamationmark.triangle.fill")
                }
                existingProfilesBody
            }
        }
    }

    @ViewBuilder
    private var existingProfilesBody: some View {
        if workspace.demoMode {
            note("Demo mode is on. Profiles jamf-cli already has are listed once a real "
                + "connection is set up.")
        } else if isChecking && discovery == nil {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                note("Reading jamf-cli's profiles…")
            }
        } else if discovery != nil && discovery?.unassigned == nil {
            note("Could not read jamf-cli's profiles. Check that jamf-cli is installed, then "
                + "Re-check.")
        } else if visibleRows.isEmpty {
            note(emptyText)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(visibleRows) { row in
                    profileRow(row)
                    if row.id != visibleRows.last?.id {
                        Divider().background(Theme.Hairline.standard)
                    }
                }
            }
        }
    }

    private var emptyText: String {
        if choice == .addToCurrent && currentIsProWorkspace {
            return currentAcceptsProtect
                ? "No Jamf Protect profile in jamf-cli is free to add. Connect new above."
                : "This workspace already has Jamf Protect."
        }
        return "Every jamf-cli profile already has a workspace. Profiles made in Terminal "
            + "appear here after Re-check."
    }

    private func profileRow(_ row: AddSheetPlan.UnassignedProfile) -> some View {
        HStack(alignment: .top, spacing: 10) {
            productIcon(icon(for: row.product), size: 28)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Mono(text: row.name, size: 12, color: Theme.Colors.fg)
                    Pill(text: row.product.displayName, tone: .muted)
                }
                if !row.url.isEmpty {
                    Text(row.url)
                        .font(.caption)
                        .foregroundStyle(Theme.Text.tertiary(contrast))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                rowDetail(row)
            }
            Spacer(minLength: 8)
            rowAction(row)
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func rowDetail(_ row: AddSheetPlan.UnassignedProfile) -> some View {
        if case .unavailable(let reason) = row.use {
            note(reason)
        } else if row.name == adoptingName, let flow = adoptFlow {
            adoptStatus(flow.statuses[row.name] ?? .pending, flow: flow)
        }
    }

    @ViewBuilder
    private func adoptStatus(
        _ status: ExistingCLISetupFlow.ProfileStatus, flow: ExistingCLISetupFlow
    ) -> some View {
        switch status {
        case .pending: EmptyView()
        case .initializing: note("Creating the workspace…")
        case .collecting: note("Collecting · \(flow.progress.summary)")
        case .done:
            note(["Workspace set up", flow.kindSummaries[adoptingName ?? ""]?.summary]
                .compactMap { $0 }.joined(separator: " · "))
        case .failed(let reason):
            Text(reason)
                .font(.caption)
                .foregroundStyle(Theme.Colors.warn)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func rowAction(_ row: AddSheetPlan.UnassignedProfile) -> some View {
        switch row.use {
        case .newWorkspace:
            if row.name == adoptingName && isAdopting {
                ProgressView().controlSize(.small)
            } else {
                PNPButton(title: "Set up workspace", icon: "folder.badge.plus", size: .sm) {
                    Task { await adopt(row) }
                }
                .disabled(isAdopting || isChecking)
            }
        case .addToCurrent:
            PNPButton(title: "Add to \(workspace.profile)", icon: "plus", size: .sm) {
                addProtect(row)
            }
            .disabled(isAdopting || isChecking)
        case .unavailable:
            EmptyView()
        }
    }

    private func icon(for product: JamfCLIProduct) -> String {
        switch product {
        case .pro, .unknown: "server.rack"
        case .school: "graduationcap.fill"
        case .protect: "shield.lefthalf.filled"
        case .securityCloud: "cloud.fill"
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(Theme.Text.tertiary(contrast))
            .fixedSize(horizontal: false, vertical: true)
    }

    private func banner(_ text: String, tone: InlineBannerTone, icon: String) -> some View {
        InlineBanner(icon: icon, tone: tone) {
            Text(text)
                .font(.footnote)
                .foregroundStyle(Theme.Colors.fg2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Actions

    /// Reads jamf-cli's profiles again (off the main actor), then sets the opening choice once.
    private func recheck() async {
        guard !workspace.demoMode, !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        let current = currentIsProWorkspace ? workspace.profile : nil
        let found = await Task.detached { AddSheetDiscovery.load(currentWorkspace: current) }.value
        discovery = found
        guard !choiceTouched else { return }
        choice = AddSheetPlan.preselection(
            unassigned: found.unassigned ?? [],
            currentAcceptsProtect: currentIsProWorkspace && found.currentProtect == nil,
            requested: requested)
    }

    /// Sets up a workspace for a profile jamf-cli already has: the setup the first launch runs
    /// for existing profiles (workspace, School routing, first collect), for this one profile.
    private func adopt(_ row: AddSheetPlan.UnassignedProfile) async {
        guard !isAdopting else { return }
        message = nil
        errorText = nil
        let profile = JamfCLIProfile(
            name: row.name, url: row.url, schedules: 0, status: .idle, product: row.product)
        let flow = ExistingCLISetupFlow(profiles: [profile])
        adoptFlow = flow
        adoptingName = row.name
        await flow.run()
        guard flow.canContinue else {
            errorText = flow.completionText
            return
        }
        workspace.reloadFromDisk()
        message = "\(row.name) is set up. Switch to it from the workspace menu."
        await recheck()
    }

    /// Names a Protect profile jamf-cli already has in this workspace's config.yaml.
    private func addProtect(_ row: AddSheetPlan.UnassignedProfile) {
        guard currentIsProWorkspace else { return }
        message = nil
        errorText = nil
        do {
            let report = try OnboardingFlow.writeProtectConfig(
                profileSlug: workspace.profile, protectProfileName: row.name)
            message = (["Jamf Protect profile \(row.name) added to \(workspace.profile). "
                + "The next collect reads its data."] + report.notes).joined(separator: " ")
        } catch {
            errorText = "Could not add \(row.name): \(error.localizedDescription)"
        }
        Task { await recheck() }
    }
}
