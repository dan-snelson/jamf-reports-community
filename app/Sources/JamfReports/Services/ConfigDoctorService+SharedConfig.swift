import Foundation

extension ConfigDoctorService {

    /// One `.warn` row, with a Confirm button, when a shared workspace's config.yaml differs
    /// from the values this Mac pinned (`SharedConfigPin`). Never `.fail`: the run it describes
    /// already used the safe values, and a scheduled run must not turn red for it.
    static func sharedConfigRows(
        profile: String, appSupport: URL = AppSupport.directory()
    ) -> [DoctorRow] {
        let drifts = SharedConfigPin.check(profile: profile, appSupport: appSupport).drifts
        guard !drifts.isEmpty else { return [] }
        func shown(_ value: String) -> String {
            if value.hasPrefix("(") { return value }
            return value.isEmpty ? "(not set)" : "\"\(ConfigSchema.displayText(value))\""
        }
        let lines = drifts.map { drift in
            let key = drift.key == .notifyURL ? "notify.url" : drift.key.rawValue
            return "\(key): pinned \(shown(drift.pinned)), now \(shown(drift.current))"
        }
        return [DoctorRow(
            id: "shared_config.drift",
            severity: .warn,
            title: "Shared config changed since this Mac pinned it",
            detail: lines.joined(separator: "\n"),
            hint: "A Mac sharing this workspace edited config.yaml, or it was edited here. Until "
                + "you confirm, every screen, report and run on this Mac uses the safe value "
                + "for each key (workspace Generated Reports folder, archive instead of "
                + "delete, no webhook send, no Protect collection).",
            action: .confirmSharedConfig(drifts)
        )]
    }
}
