import Foundation
import XCTest
@testable import JamfReports

/// Puts a profile's `ProfileAuthMethod` answer in the cache without a real jamf-cli: a stub
/// that prints a `config list` row, and a config file holding the `product:` key. The stub is
/// not named `jamf-cli`, since `CLIBridge.codesignGate` keys on that filename. Callers
/// invalidate the cache in tearDown.
enum ProductGuardSeed {
    @discardableResult
    static func seed(
        profile: String, authMethod: String = "oauth2", product: String? = nil,
        scopeIDs: String = "", in dir: URL
    ) throws -> ProfileAuthMethod.Resolved? {
        let stub = dir.appendingPathComponent("config-stub-\(UUID().uuidString.prefix(6))")
        let row = #"{"name":"\#(profile)","auth-method":"\#(authMethod)"\#(scopeIDs)}"#
        try "#!/bin/sh\nprintf '%s' '[\(row)]'\n".write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        var file = "profiles:\n    \(profile):\n        auth-method: \(authMethod)\n"
        if let product { file += "        product: \(product)\n" }
        let configFile = dir.appendingPathComponent("jamf-cli-config-\(UUID().uuidString.prefix(6)).yaml")
        try file.write(to: configFile, atomically: true, encoding: .utf8)
        return ProfileAuthMethod.resolve(profile: profile, binary: stub, configFile: configFile)
    }
}

/// Collects log lines from `@Sendable` callbacks.
final class ProductGuardLines: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    func add(_ line: CLIBridge.LogLine) { lock.withLock { stored.append(line.text) } }
    var all: [String] { lock.withLock { stored } }
}
