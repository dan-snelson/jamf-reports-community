import Foundation

/// `branding.logo_path`, read for the first tab of a workbook.
enum ReportLogo {
    /// The largest logo file read. A logo is a few KB to a few hundred.
    static let maxLogoBytes = 2 * 1_048_576

    /// Load and validate the PNG at `branding.logo_path`.
    ///
    /// The path is tilde expanded and, when relative, the workspace's. It must be a regular
    /// file (a FIFO or device would block or never end), is read up to `maxLogoBytes`, and is
    /// never in a system or credentials folder unless it is inside the workspace. An absolute
    /// path elsewhere needs no opt-in: logos have always been read from anywhere. A value the
    /// shared config pin holds back reads as no logo. Returns nil, with one warning that shows
    /// the typed value through `ConfigSchema.displayText`, when it cannot be used.
    /// The returned Data is safe to embed via `Worksheet.insertImage`.
    static func load(
        from config: ReportConfig, profile: String?, warn: (String) -> Void = logoWarning
    ) -> Data? {
        let workspace = profile.flatMap { $0.isEmpty ? nil : ProfileService.workspaceURL(for: $0) }
        if let workspace, SharedConfigPin.safePathValue(
            workspace: workspace, section: "branding", key: "logo_path") != nil { return nil }
        guard let typed = config.branding?.logoPath?
            .trimmingCharacters(in: .whitespacesAndNewlines), !typed.isEmpty else { return nil }
        switch readLogo(typed: typed, workspace: workspace) {
        case .success(let data):
            return data
        case .failure(let problem):
            warn("[warn] branding.logo_path '\(ConfigSchema.displayText(typed))' "
                + "\(problem.rawValue); logo not embedded.")
            return nil
        }
    }

    enum LogoProblem: String, Error {
        case reserved = "is in a folder reserved by macOS or holding credentials"
        case leavesWorkspace = "is in the workspace but resolves to a file outside it"
        case notFound = "was not found"
        case notRegular = "is not a regular file"
        case unreadable = "could not be read"
        case tooLarge = "is over 2 MB"
        case notPNG = "is not a PNG"
    }

    private static func readLogo(typed: String, workspace: URL?) -> Result<Data, LogoProblem> {
        let expanded = WorkspacePaths.expandTilde(typed)
        let named: URL
        if !expanded.hasPrefix("/"), let workspace {
            named = workspace.appendingPathComponent(expanded)
        } else {
            named = URL(fileURLWithPath: expanded)
        }
        let resolved = named.resolvingSymlinksInPath().standardizedFileURL
        // A logo the workspace names (relative, or an absolute path inside it) must also land
        // there: a symlink swapped in for it by a peer is refused, not followed to ~/Desktop.
        let inside = logoIsInside(workspace: workspace)
        if inside(named.standardizedFileURL.path), !inside(resolved.path) {
            return .failure(.leavesWorkspace)
        }
        if !inside(resolved.path), WorkspacePaths.isSensitiveAbsolutePath(resolved) {
            return .failure(.reserved)
        }
        let data: Data
        do {
            data = try BoundedFile.read(resolved, limit: maxLogoBytes)
        } catch BoundedFile.Failure.tooLarge {
            return .failure(.tooLarge)
        } catch BoundedFile.Failure.notRegular {
            return .failure(.notRegular)
        } catch BoundedFile.Failure.unreadable(let code) {
            return .failure(code == ENOENT ? .notFound : .unreadable)
        } catch {
            return .failure(.unreadable)
        }
        // PNG magic bytes: 0x89 50 4E 47 0D 0A 1A 0A
        let pngMagic: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        guard data.count >= pngMagic.count,
              data.prefix(pngMagic.count).elementsEqual(pngMagic) else {
            return .failure(.notPNG)
        }
        return .success(data)
    }

    /// Whether a path is the workspace or below it, as the workspace is spelled and with its
    /// symlinks resolved. Always false without a workspace.
    private static func logoIsInside(workspace: URL?) -> (String) -> Bool {
        let roots = workspace.map {
            [$0.standardizedFileURL.path, $0.resolvingSymlinksInPath().standardizedFileURL.path]
        } ?? []
        return { path in roots.contains { path == $0 || path.hasPrefix($0 + "/") } }
    }

    private static func logoWarning(_ message: String) {
        AppLogger.report.warning("\(message, privacy: .private)")
        fputs(message + "\n", stderr)
    }
}
