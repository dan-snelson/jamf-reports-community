import Foundation
import Synchronization

/// `AIPolicy`, a preference an organization sets with a configuration profile: the limit on AI
/// above every workspace's `ai:` block. Absent, the workspace decides. A future tier adds a
/// value here, never a second key.
enum AIPolicy: String, Sendable {
    case off
    case onDevice

    static let defaultsKey = "AIPolicy"

    /// The last unrecognised value logged, so a value is named once, not on every read.
    private static let loggedValue = Mutex<String?>(nil)

    /// nil when the key is absent. Any value other than `off` or `onDevice` reads as `off`, so
    /// a typo never turns AI on.
    static func current(defaults: UserDefaults = .standard) -> AIPolicy? {
        guard let raw = defaults.object(forKey: defaultsKey) else { return nil }
        if let text = raw as? String, let policy = AIPolicy(rawValue: text) { return policy }
        let shown = ConfigSchema.displayText(String(describing: raw))
        let isNew = loggedValue.withLock { last in
            defer { last = shown }
            return last != shown
        }
        if isNew {
            AppLogger.event(.ui, .error,
                            "AIPolicy '\(shown)' is not off or onDevice; AI is turned off")
        }
        return .off
    }

    func allows(_ tier: AIConfig.Tier) -> Bool {
        switch self {
        case .off: false
        case .onDevice: tier == .onDevice
        }
    }

    /// Settings' AI switches are locked while the policy turns AI off.
    static func locksSettings(defaults: UserDefaults = .standard) -> Bool {
        current(defaults: defaults) == .off
    }

    /// The line Settings shows under its AI controls, nil when no policy is set.
    static func settingsNote(defaults: UserDefaults = .standard) -> String? {
        let forced = ManagedPreference.isForced(defaultsKey, defaults: defaults)
        switch current(defaults: defaults) {
        case nil: return nil
        case .off:
            return forced ? ManagedPreference.note
                : "AI is turned off on this Mac by the AIPolicy preference."
        case .onDevice:
            return forced ? "Your organization limits AI to on-device models."
                : "The AIPolicy preference on this Mac limits AI to on-device models."
        }
    }
}

extension AIConfig {
    /// The config with the organization's policy applied: off when the policy does not allow
    /// this config's tier.
    func effective(policy: AIPolicy?) -> AIConfig {
        guard let policy, !policy.allows(resolvedTier) else { return self }
        var off = self
        off.enabled = false
        return off
    }
}
