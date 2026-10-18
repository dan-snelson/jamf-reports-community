import Foundation

/// One Mac's value of a custom EA, from a CSV column or from `ea-results`.
struct EAEntry: Sendable {
    let device: String
    let serial: String
    let value: String
}

/// The typed tab (boolean, percentage, version, text, date) of one `custom_eas` entry. Both
/// sources feed it `EAEntry`s, so a CSV and an `ea-results` workbook read the same.
struct EASheetWriter: Sendable {
    let config: ReportConfig
    let workbook: Workbook
    let orgName: String
    let deviceHeader: String
    let serialHeader: String

    func write(_ ea: CustomEAConfig, entries: [EAEntry]) {
        switch ea.type {
        case .boolean:    writeBoolean(ea, entries)
        case .percentage: writePercentage(ea, entries)
        case .version:    writeVersion(ea, entries)
        case .text:       writeText(ea, entries)
        case .date:       writeDate(ea, entries)
        }
    }

    func title(_ base: String) -> String {
        orgName.isEmpty ? base : "\(orgName) \u{2014} \(base)"
    }

    private func writeBoolean(_ ea: CustomEAConfig, _ entries: [EAEntry]) {
        let ws = workbook.addSheet(ea.name)
        var row = ws.writeSheetHeader(title: title(ea.name), subtitle: ea.column, ncols: 4)
        ws.setColumnWidth(0, 0, 24)
        ws.setColumnWidth(1, 1, 12)

        let trueValue = ea.trueValue?.lowercased() ?? "true"
        var trueCount = 0, falseCount = 0, unknownCount = 0
        for entry in entries {
            let val = entry.value.trimmingCharacters(in: .whitespaces)
            if val.isEmpty { unknownCount += 1 }
            else if val.lowercased() == trueValue { trueCount += 1 }
            else { falseCount += 1 }
        }
        let total = trueCount + falseCount + unknownCount
        let pct = total > 0 ? Double(trueCount) / Double(total) : 0

        ws.write("Status", row: row, col: 0, format: .header)
        ws.write("Count", row: row, col: 1, format: .header)
        ws.write("Percent", row: row, col: 2, format: .header)
        row += 1
        ws.write(ea.trueValue ?? "True", row: row, col: 0, format: .cell)
        ws.write(trueCount, row: row, col: 1, format: .green)
        let pctFormat: CellFormat = pct >= 0.95 ? .pctGreen : pct >= 0.80 ? .pctYellow : .pctRed
        ws.write(pct, row: row, col: 2, format: pctFormat)
        row += 1
        ws.write("Other", row: row, col: 0, format: .cell)
        ws.write(falseCount, row: row, col: 1, format: falseCount > 0 ? .red : .cell)
        row += 1
        if unknownCount > 0 {
            ws.write("Unknown/Blank", row: row, col: 0, format: .cell)
            ws.write(unknownCount, row: row, col: 1, format: .cell)
        }
    }

    private func writePercentage(_ ea: CustomEAConfig, _ entries: [EAEntry]) {
        let ws = workbook.addSheet(ea.name)
        var row = ws.writeSheetHeader(title: title(ea.name), subtitle: ea.column, ncols: 4)
        ws.setColumnWidth(0, 0, 20)
        ws.setColumnWidth(1, 1, 12)

        let warn = ea.warningThreshold ?? config.thresholds?.resolvedWarningDisk ?? 80
        let crit = ea.criticalThreshold ?? config.thresholds?.resolvedCriticalDisk ?? 90

        var distribution: [String: Int] = [:]
        for entry in entries {
            let val = entry.value.trimmingCharacters(in: .whitespaces)
            distribution[val, default: 0] += 1
        }

        ws.write("Value", row: row, col: 0, format: .header)
        ws.write("Count", row: row, col: 1, format: .header)
        ws.write("Status", row: row, col: 2, format: .header)
        row += 1

        let byNumber = distribution.sorted {
            ($0.key as NSString).doubleValue < ($1.key as NSString).doubleValue
        }
        for (val, count) in byNumber {
            let num = (val as NSString).doubleValue
            let fmt: CellFormat = num >= Double(crit) ? .red : num >= Double(warn) ? .yellow : .cell
            let status = num >= Double(crit) ? "Critical" : num >= Double(warn) ? "Warning" : "OK"
            ws.write(val, row: row, col: 0, format: fmt)
            ws.write(count, row: row, col: 1, format: fmt)
            ws.write(status, row: row, col: 2, format: fmt)
            row += 1
        }
    }

    private func writeVersion(_ ea: CustomEAConfig, _ entries: [EAEntry]) {
        let ws = workbook.addSheet(ea.name)
        var row = ws.writeSheetHeader(title: title(ea.name), subtitle: ea.column, ncols: 4)
        ws.setColumnWidth(0, 0, 24)
        ws.setColumnWidth(1, 1, 12)
        ws.setColumnWidth(2, 2, 12)

        let currentVersions = ea.currentVersions?.map { $0.lowercased() } ?? []
        var distribution: [String: Int] = [:]
        for entry in entries {
            let val = entry.value.trimmingCharacters(in: .whitespaces)
            distribution[val, default: 0] += 1
        }

        ws.write("Version", row: row, col: 0, format: .header)
        ws.write("Count", row: row, col: 1, format: .header)
        ws.write("Status", row: row, col: 2, format: .header)
        row += 1

        for (ver, count) in distribution.sorted(by: { lhs, rhs in
            Self.compareVersions(lhs.key, rhs.key) > 0
        }) {
            let isCurrent = currentVersions.contains { ver.lowercased().hasPrefix($0) }
            let fmt: CellFormat = isCurrent ? .green : currentVersions.isEmpty ? .cell : .yellow
            let status = currentVersions.isEmpty ? "" : (isCurrent ? "Current" : "Outdated")
            ws.write(ver, row: row, col: 0, format: fmt)
            ws.write(count, row: row, col: 1, format: fmt)
            ws.write(status, row: row, col: 2, format: fmt)
            row += 1
        }
    }

    private func writeText(_ ea: CustomEAConfig, _ entries: [EAEntry]) {
        let ws = workbook.addSheet(ea.name)
        var row = ws.writeSheetHeader(title: title(ea.name), subtitle: ea.column, ncols: 3)
        ws.setColumnWidth(0, 0, 30)
        ws.setColumnWidth(1, 1, 12)

        var frequency: [String: Int] = [:]
        for entry in entries {
            let val = entry.value.trimmingCharacters(in: .whitespaces)
            frequency[val.isEmpty ? "(blank)" : val, default: 0] += 1
        }

        ws.write("Value", row: row, col: 0, format: .header)
        ws.write("Count", row: row, col: 1, format: .header)
        row += 1

        for (val, count) in frequency.sorted(by: { $0.value > $1.value }) {
            ws.write(val, row: row, col: 0, format: .cell)
            ws.write(count, row: row, col: 1, format: .cell)
            row += 1
        }
    }

    private func writeDate(_ ea: CustomEAConfig, _ entries: [EAEntry]) {
        let ws = workbook.addSheet(ea.name)
        var row = ws.writeSheetHeader(title: title(ea.name), subtitle: ea.column, ncols: 5)
        ws.setColumnWidth(0, 0, 30)
        ws.setColumnWidth(1, 1, 16)
        ws.setColumnWidth(2, 2, 20)
        ws.setColumnWidth(3, 3, 14)

        let warnDays = ea.warningDays ?? config.thresholds?.resolvedCertWarningDays ?? 90
        let now = Date()

        ws.write(deviceHeader, row: row, col: 0, format: .header)
        ws.write(serialHeader, row: row, col: 1, format: .header)
        ws.write("Date Value", row: row, col: 2, format: .header)
        ws.write("Days Until", row: row, col: 3, format: .header)
        ws.write("Status", row: row, col: 4, format: .header)
        row += 1

        let dateParser = DateParser()
        for entry in entries {
            let rawDate = entry.value.trimmingCharacters(in: .whitespaces)
            guard !rawDate.isEmpty else { continue }
            let parsedDate = dateParser.parse(rawDate)
            let daysUntil = parsedDate.map { Int($0.timeIntervalSince(now) / 86400) }

            let fmt: CellFormat
            let status: String
            if let days = daysUntil {
                if days < 0 { fmt = .red; status = "Expired" }
                else if days <= warnDays { fmt = .yellow; status = "Expiring (\(days)d)" }
                else { fmt = .cell; status = "OK" }
            } else {
                fmt = .cell; status = "Unknown"
            }
            ws.write(entry.device, row: row, col: 0, format: fmt)
            ws.write(entry.serial, row: row, col: 1, format: fmt)
            ws.write(rawDate, row: row, col: 2, format: fmt)
            ws.write(daysUntil.map { "\($0)" } ?? "", row: row, col: 3, format: fmt)
            ws.write(status, row: row, col: 4, format: fmt)
            row += 1
        }
    }

    private static func compareVersions(_ lhs: String, _ rhs: String) -> Int {
        let lParts = lhs.split(separator: ".").compactMap { Int($0) }
        let rParts = rhs.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(lParts.count, rParts.count) {
            let l = i < lParts.count ? lParts[i] : 0
            let r = i < rParts.count ? rParts[i] : 0
            if l != r { return l > r ? 1 : -1 }
        }
        return 0
    }
}

/// The custom EA tabs and the EA Warnings tab, read from the `ea-results` and
/// `computer-extension-attributes` snapshots, so a jamf-cli workbook needs no CSV for them.
struct EASheets: Sendable {
    let config: ReportConfig
    let workbook: Workbook
    let profile: String?
    private let tabs: [(ea: CustomEAConfig, entries: [EAEntry])]
    private let warnings: [(ea: CustomEAConfig, reason: String)]

    /// Nil when this source has nothing to say: no custom EAs, or no collected data. A CSV
    /// workbook with no collected values keeps its own CSV tabs.
    static func load(
        config: ReportConfig, workbook: Workbook, dataDir: URL, profile: String?,
        csvPresent: Bool
    ) -> EASheets? {
        guard let eas = config.customEas, !eas.isEmpty else { return nil }
        let rows = snapshot("ea-results", in: dataDir)
            .flatMap { EAResultRow.decodeSnapshot($0).rows } ?? []
        let names = snapshot("computer-extension-attributes", in: dataDir)
            .flatMap { try? JSONDecoder().decode([ExtensionAttribute].self, from: $0) }
            .flatMap { $0.isEmpty ? nil : Set($0.map { key($0.name) }) }
        guard !rows.isEmpty || (!csvPresent && names != nil) else { return nil }
        // Only the date tab has a Serial column, and the rows carry no serial of their own.
        let serials = eas.contains { $0.type == .date }
            ? snapshot("computers", in: dataDir).map(serialsByName) ?? [:] : [:]

        var tabs: [(ea: CustomEAConfig, entries: [EAEntry])] = []
        var warnings: [(ea: CustomEAConfig, reason: String)] = []
        for ea in eas {
            let column = key(ea.column)
            let entries = rows.filter { key($0.eaName) == column && !column.isEmpty }.map { row in
                let device = (row.device ?? row.computerName ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let serial = row.serial.flatMap { key($0).isEmpty ? nil : $0 }
                    ?? serials[key(device)] ?? ""
                return EAEntry(device: device, serial: serial, value: row.value?.stringValue ?? "")
            }
            if !entries.isEmpty { tabs.append((ea, entries)); continue }
            let reason = column.isEmpty ? "No column configured"
                : names == nil ? "No values collected"
                : names?.contains(column) == true ? "Defined in Jamf Pro, no values collected"
                : "Not defined in Jamf Pro"
            warnings.append((ea, reason))
        }
        return EASheets(config: config, workbook: workbook, profile: profile,
                        tabs: tabs, warnings: warnings)
    }

    /// Tab names and writers, in the order the CSV path used: one per EA, then EA Warnings.
    var sheetPlan: [(name: String, write: () -> Void)] {
        var plan = tabs.map { tab in
            (name: tab.ea.name, write: { writer.write(tab.ea, entries: tab.entries) })
        }
        if !warnings.isEmpty { plan.append((name: "EA Warnings", write: writeWarnings)) }
        return plan
    }

    @discardableResult
    func writeAll(sheets: SheetsConfig) -> [String] {
        let kept = sheets.applyTo(sheetPlan)
        kept.forEach { $0.write() }
        if let logo = CSVDashboard.loadLogoData(from: config, profile: profile) {
            for name in kept.map(\.name) {
                workbook.sheet(named: name)?.insertImage(
                    row: 0, col: 0, data: logo, filename: "logo.png", xScale: 1.0, yScale: 1.0)
            }
        }
        return kept.map(\.name)
    }

    private var writer: EASheetWriter {
        EASheetWriter(config: config, workbook: workbook,
                      orgName: config.branding?.resolvedOrgName ?? "",
                      deviceHeader: "Computer Name", serialHeader: "Serial Number")
    }

    private func writeWarnings() {
        let ws = workbook.addSheet("EA Warnings")
        var row = ws.writeSheetHeader(
            title: writer.title("Custom EA Warnings"),
            subtitle: "These Custom EAs have no tab: nothing was collected for them",
            ncols: 3)
        ws.setColumnWidth(0, 0, 30)
        ws.setColumnWidth(1, 1, 40)
        ws.setColumnWidth(2, 2, 40)
        ws.write("EA Name", row: row, col: 0, format: .header)
        ws.write("Expected EA", row: row, col: 1, format: .header)
        ws.write("Reason", row: row, col: 2, format: .header)
        row += 1
        for (ea, reason) in warnings {
            ws.write(ea.name, row: row, col: 0, format: .yellow)
            ws.write(ea.column, row: row, col: 1, format: .yellow)
            ws.write(reason, row: row, col: 2, format: .yellow)
            row += 1
        }
    }

    private static func key(_ text: String?) -> String {
        (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func snapshot(_ kind: String, in dataDir: URL) -> Data? {
        try? ReportEngine.loadLatestSnapshotData(kind: kind, dataDir: dataDir)
    }

    /// Serial by computer name, only for a name one Mac has: two Macs can share a name, and a
    /// guess would put one Mac's serial on the other's row.
    private static func serialsByName(_ data: Data) -> [String: String] {
        let object = try? JSONSerialization.jsonObject(with: data)
        let items = (object as? [[String: Any]])
            ?? (object as? [String: Any]).flatMap { $0["results"] as? [[String: Any]] } ?? []
        var counts: [String: Int] = [:]
        var serials: [String: String] = [:]
        for item in items {
            let general = item["general"] as? [String: Any]
            let name = key((general?["name"] as? String) ?? (item["name"] as? String))
            guard !name.isEmpty else { continue }
            counts[name, default: 0] += 1
            if let serial = ComputerDates(item: item).serial { serials[name] = serial }
        }
        return serials.filter { counts[$0.key] == 1 }
    }
}
