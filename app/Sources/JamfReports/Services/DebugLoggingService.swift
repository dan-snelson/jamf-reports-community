import Foundation

/// Two independent debug-logging flags for our OSLog subsystem.
struct DebugLoggingState: Equatable {
    /// Persist debug/info entries in the local store (PII still rendered `<private>`).
    var persistVerbose: Bool
    /// `Enable-Private-Data` — show interpolated values in full. Default off; warned.
    var revealPrivate: Bool
    static let off = DebugLoggingState(persistVerbose: false, revealPrivate: false)
}

/// What a configuration profile sets for our subsystem; a nil field is left to the user's switch.
struct ManagedDebugLogging: Equatable {
    var persistVerbose: Bool?
    var revealPrivate: Bool?
}

/// Reads/writes the per-user OSLog Subsystems config plist (no privilege escalation —
/// it lives under the user's `~/Library/Preferences`). Changes take effect at the NEXT
/// process launch, since OSLog reads this configuration at process start.
///
/// Schema (`/Library/Preferences/Logging/Subsystems/<subsystem>.plist`, also the shape of
/// the `com.apple.system.logging` MDM payload): a `DEFAULT-OPTIONS` dict with
/// `Enable-Level`/`Persist` level strings (`Off`/`Default`/`Info`/`Debug`) and an
/// `Enable-Private-Data` Bool. Confirmed against `man log` (`level`/`persist` hierarchy).
enum DebugLoggingService {
    static let subsystem = "com.github.tonyyo11.jamf-reports-community"

    static var defaultPlistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/Logging/Subsystems/\(subsystem).plist")
    }

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

    static func current(at url: URL = defaultPlistURL) -> DebugLoggingState {
        guard let data = try? Data(contentsOf: url),
              let root = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = root as? [String: Any] else { return .off }
        let opts = (dict["DEFAULT-OPTIONS"] as? [String: Any]) ?? [:]
        return DebugLoggingState(
            persistVerbose: persists(opts) ?? false,
            revealPrivate: (opts["Enable-Private-Data"] as? Bool) ?? false)
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

    static func apply(_ state: DebugLoggingState, at url: URL = defaultPlistURL) throws {
        var opts: [String: Any] = [:]
        if state.persistVerbose {
            opts["Enable-Level"] = "Debug"
            opts["Persist"] = "Debug"
        }
        if state.revealPrivate { opts["Enable-Private-Data"] = true }
        let dict: [String: Any] = opts.isEmpty ? [:] : ["DEFAULT-OPTIONS": opts]
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        try data.write(to: url, options: .atomic)
    }
}
