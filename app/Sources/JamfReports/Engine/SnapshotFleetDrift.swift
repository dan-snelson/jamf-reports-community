import Foundation

/// What changed between two `computers` snapshots: Macs that joined or left, macOS versions
/// that changed, and Macs that crossed the stale rule. Macs are joined by Jamf ID, then serial
/// (`ComputerDateIndex`); a Mac with neither is counted in `unidentified`, never joined by name.
struct SnapshotFleetDrift {
    struct StaleChange {
        let current: ComputerDates
        let priorAge: StaleAge?
        let currentAge: StaleAge?
    }

    let joined: [ComputerDates]
    let left: [ComputerDates]
    let osChanged: [(prior: ComputerDates, current: ComputerDates)]
    let becameStale: [StaleChange]
    let noLongerStale: [StaleChange]
    let unidentified: Int

    /// Each snapshot is judged as of its own collection time, so a Mac that went quiet after the
    /// baseline was taken shows as newly stale.
    init(
        current: [ComputerDates], currentAt: Date,
        prior: [ComputerDates], priorAt: Date, rule: StaleRule
    ) {
        func identified(_ macs: [ComputerDates]) -> [ComputerDates] {
            macs.filter { $0.jamfID != nil || $0.serial != nil }
        }
        let now = identified(current), before = identified(prior)
        unidentified = (current.count - now.count) + (prior.count - before.count)
        let priorIndex = ComputerDateIndex(before), currentIndex = ComputerDateIndex(now)
        func sortedByName(_ macs: [ComputerDates]) -> [ComputerDates] {
            macs.sorted { ($0.name ?? "").localizedCaseInsensitiveCompare($1.name ?? "")
                == .orderedAscending }
        }
        func isNew(_ mac: ComputerDates, in index: ComputerDateIndex) -> Bool {
            index.match(jamfID: mac.jamfID, serial: mac.serial) == nil
        }
        joined = sortedByName(now.filter { isNew($0, in: priorIndex) })
        left = sortedByName(before.filter { isNew($0, in: currentIndex) })

        func age(_ mac: ComputerDates, at date: Date) -> StaleAge? {
            rule.age(of: StaleInputs(
                checkIn: mac.checkIn, inventory: mac.inventory, contact: mac.contact,
                carriesDates: true), now: date)
        }
        func stale(_ age: StaleAge?) -> Bool { age.map { $0 > .days(rule.days) } ?? false }
        var osChanged: [(ComputerDates, ComputerDates)] = []
        var becameStale: [StaleChange] = [], noLongerStale: [StaleChange] = []
        for mac in sortedByName(now) {
            guard let old = priorIndex.match(jamfID: mac.jamfID, serial: mac.serial)
            else { continue }
            let was = OSVersionName.normalized(old.osVersion ?? "")
            let isNow = OSVersionName.normalized(mac.osVersion ?? "")
            if !was.isEmpty, !isNow.isEmpty, was != isNow { osChanged.append((old, mac)) }
            let (oldAge, newAge) = (age(old, at: priorAt), age(mac, at: currentAt))
            let change = StaleChange(current: mac, priorAge: oldAge, currentAge: newAge)
            if !stale(oldAge) && stale(newAge) { becameStale.append(change) }
            if stale(oldAge) && !stale(newAge) { noLongerStale.append(change) }
        }
        self.osChanged = osChanged
        self.becameStale = becameStale
        self.noLongerStale = noLongerStale
    }
}

extension CoreDashboard {

    /// The two newest-day `computers` snapshots: the newest, and the newest stamped on an
    /// earlier local calendar day. Same-day collects are one day of history, not a baseline.
    private func driftSnapshots() ->
        (current: (url: URL, date: Date), prior: (url: URL, date: Date))? {
        let snapshots = TrendStore.datedSnapshots(of: "computers", in: dataDir)
        guard let current = snapshots.last else { return nil }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: current.date)
        guard let prior = snapshots.last(where: { calendar.startOfDay(for: $0.date) < today })
        else { return nil }
        return (current, prior)
    }

    func writeFleetDrift() throws {
        guard let pair = driftSnapshots() else {
            throw CoreDashboardError.noCachedData(names: ["computers (two different days)"])
        }
        guard let current = ComputerDates.decodeSnapshot(try Data(contentsOf: pair.current.url)),
              let prior = ComputerDates.decodeSnapshot(try Data(contentsOf: pair.prior.url)) else {
            throw CoreDashboardError.noCachedData(names: ["computers"])
        }
        let rule = config.staleRule
        let drift = SnapshotFleetDrift(
            current: current, currentAt: pair.current.date,
            prior: prior, priorAt: pair.prior.date, rule: rule)

        let ws = workbook.addSheet("Fleet Drift")
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HH:mm"
        var row = ws.writeSheetHeader(
            title: "Fleet Drift",
            subtitle: "Collected \(stamp.string(from: pair.current.date)) vs "
                + "\(stamp.string(from: pair.prior.date)) | \(ruleSubtitle(rule)) | "
                + "Generated: \(ISO8601DateFormatter().string(from: Date()))",
            ncols: 6)
        ws.setColumnWidth(0, 0, 34)
        ws.setColumnWidth(1, 5, 22)

        func section(
            _ title: String, note: String? = nil, _ headers: [String], _ cells: [[String]]
        ) {
            row = Self.writeSectionWithNote(
                ws: ws, row: row, title: title, note: note, headers: headers, dataRows: cells)
        }
        func listing(_ mac: ComputerDates) -> [String] {
            [mac.name ?? "", mac.serial ?? "", mac.osVersion ?? "",
             mac.checkIn.map(ISO8601DateFormatter().string(from:)) ?? ""]
        }
        func days(_ age: StaleAge?) -> String {
            switch age {
            case .days(let count)?: "\(count)"
            case .never?: "Never"
            case nil: ""
            }
        }
        let listHeaders = ["Name", "Serial", "OS", "Last Check-in"]
        let staleHeaders = ["Name", "Serial", "Prior Days Stale", "Current Days Stale"]
        let note = drift.unidentified > 0
            ? "\(drift.unidentified) Macs with no Jamf ID or serial left out" : nil
        section("New Enrollments", note: note, listHeaders, drift.joined.map(listing))
        section("Departed Devices", listHeaders, drift.left.map(listing))
        section("New Stale", staleHeaders, drift.becameStale.map {
            [$0.current.name ?? "", $0.current.serial ?? "", days($0.priorAge), days($0.currentAge)]
        })
        section("Recovered Stale", staleHeaders, drift.noLongerStale.map {
            [$0.current.name ?? "", $0.current.serial ?? "", days($0.priorAge), days($0.currentAge)]
        })
        section("OS Changed", ["Name", "Serial", "Prior OS", "Current OS"], drift.osChanged.map {
            [$0.current.name ?? "", $0.current.serial ?? "",
             $0.prior.osVersion ?? "", $0.current.osVersion ?? ""]
        })
    }

    @discardableResult
    private static func writeSectionWithNote(
        ws: Worksheet,
        row: Int,
        title: String,
        note: String?,
        headers: [String],
        dataRows: [[String]]
    ) -> Int {
        var r = row
        ws.write(title, row: r, col: 0, format: .header)
        if let note { ws.write(note, row: r, col: 1, format: .subtitle) }
        r += 1
        for (colIdx, header) in headers.enumerated() {
            ws.write(header, row: r, col: colIdx, format: .header)
        }
        r += 1
        if dataRows.isEmpty {
            ws.write("No changes", row: r, col: 0, format: .cell)
            r += 1
        } else {
            for cells in dataRows {
                for (colIdx, cell) in cells.enumerated() {
                    ws.write(cell, row: r, col: colIdx, format: .cell)
                }
                r += 1
            }
        }
        r += 1  // blank separator row
        return r
    }
}
