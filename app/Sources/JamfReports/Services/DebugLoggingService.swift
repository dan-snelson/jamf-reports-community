import Foundation

/// What a configuration profile sets for our subsystem; a nil field is one it leaves unset.
struct ManagedDebugLogging: Equatable {
    var persistVerbose: Bool?
    var revealPrivate: Bool?
}

/// Reads what a deployed `com.apple.system.logging` profile sets for our subsystem and holds
/// the bundled profile and the one-Mac `log config` commands. It writes nothing: os_log reads
/// settings only from such a profile, the app's Info.plist and `/System/Library`, so a per-user
/// Subsystems plist changes nothing.
///
/// Profile schema: a `DEFAULT-OPTIONS` dict with a `Level` dict of `Enable`/`Persist` level
/// strings (`Off`/`Default`/`Info`/`Debug`) and an `Enable-Private-Data` Bool (`man 5 os_log`).
enum DebugLoggingService {
    static let subsystem = "com.github.tonyyo11.jamf-reports-community"

    /// For one Mac, run in Terminal as an administrator; `resetCommand` returns to the default.
    static let enableCommand =
        "sudo log config --subsystem \(subsystem) --mode \"level:debug,persist:debug\""
    static let resetCommand = "sudo log config --subsystem \(subsystem) --reset"

    /// URL of the bundled MDM debug-logging profile (`com.apple.system.logging`,
    /// persist-verbose only), for the Settings "Reveal MDM profile" affordance and
    /// admin Jamf deployment.
    ///
    /// In the packaged `.app`, `build-app.sh` flattens the profile into
    /// `Contents/Resources/` (`Bundle.main`). SwiftPM's `Bundle.module` accessor
    /// `fatalError`s when the resource bundle is absent from a signed `.app`, so it is
    /// only touched in DEBUG (`swift run` / tests) — mirrors `Theme.FontRegistry`.
    static var bundledProfileURL: URL? {
        if let url = Bundle.main.url(forResource: "JamfReports-Debug-Logging", withExtension: "mobileconfig") {
            return url
        }
        #if DEBUG
        return Bundle.module.url(forResource: "JamfReports-Debug-Logging", withExtension: "mobileconfig")
        #else
        return nil
        #endif
    }

    /// The preference domain macOS installs a `com.apple.system.logging` profile into
    /// (`/Library/Managed Preferences`, per computer or per user).
    static let managedDomain = "com.apple.system.logging"

    /// What a deployed logging profile sets for this subsystem's `DEFAULT-OPTIONS`, read
    /// best-effort through the managed preferences layer; nil when no profile sets either switch.
    static func managed(
        defaults: UserDefaults? = UserDefaults(suiteName: managedDomain)
    ) -> ManagedDebugLogging? {
        guard let defaults, ManagedPreference.isForced("Subsystems", defaults: defaults),
              let subsystems = defaults.dictionary(forKey: "Subsystems"),
              let opts = (subsystems[subsystem] as? [String: Any])?["DEFAULT-OPTIONS"]
                as? [String: Any] else { return nil }
        let state = ManagedDebugLogging(
            persistVerbose: persists(opts), revealPrivate: opts["Enable-Private-Data"] as? Bool)
        return state == ManagedDebugLogging() ? nil : state
    }

    /// `Persist` as the bundled profile writes it, or under `Level` as os_log(5) documents it.
    private static func persists(_ opts: [String: Any]) -> Bool? {
        let level = ((opts["Level"] as? [String: Any])?["Persist"] as? String)
            ?? opts["Persist"] as? String
        return level.map { ["info", "debug"].contains($0.lowercased()) }
    }
}
