import Foundation

/// Finds the Jamf Pro computer a probe row describes, by identifier only. Same rule as
/// `DeviceRecordMerger`: a candidate shares an identifier with the probe and no identifier
/// they both carry differs. A name never decides. An identifier value on more than
/// `DeviceRecordMerger.maxRecordsPerSharedIdentifier` records is a placeholder and joins nothing.
struct DeviceCorrelation: Sendable {
    enum Match: Equatable, Sendable {
        case matched(Int, via: DeviceIdentifier)
        case unmatched
        case ambiguous(Int)
        case noIdentifier
    }

    private let records: [DeviceInventoryRecord]
    private let index: [DeviceIdentifier: [String: [Int]]]

    init(records: [DeviceInventoryRecord]) {
        self.records = records
        var index: [DeviceIdentifier: [String: [Int]]] = [:]
        for (position, record) in records.enumerated() {
            for (kind, value) in record.identifiers {
                index[kind, default: [:]][value, default: []].append(position)
            }
        }
        self.index = index
    }

    /// `probe` carries the identifiers of the row to place (a record with only those set).
    func match(_ probe: DeviceInventoryRecord) -> Match {
        let identifiers = probe.identifiers
        guard !identifiers.isEmpty else { return .noIdentifier }
        let cap = DeviceRecordMerger.maxRecordsPerSharedIdentifier
        var via: [Int: DeviceIdentifier] = [:]
        // Strongest first, so a candidate keeps the strongest identifier it shares.
        for (kind, value) in identifiers {
            guard let holders = index[kind]?[value], holders.count <= cap else { continue }
            for position in holders
            where via[position] == nil && !probe.disagrees(with: records[position]) {
                via[position] = kind
            }
        }
        let strong = via.filter { $0.value.isStrong }
        let pool = strong.isEmpty ? via : strong
        switch pool.count {
        case 0: return .unmatched
        case 1: return pool.first.map { .matched($0.key, via: $0.value) } ?? .unmatched
        default: return .ambiguous(pool.count)
        }
    }
}

/// Which Protect computers are Jamf Pro computers. Protect's `uuid` is taken to be the
/// hardware UUID, Jamf Pro's `udid` (unverified against a tenant); `hostname` is never matched.
struct ProtectProCorrelation: Sendable {
    var protectCount = 0
    var matched = 0
    var ambiguous = 0
    var noIdentifier = 0
    var notInPro: [ProtectComputerRow] = []
    var proWithoutProtect: [DeviceInventoryRecord] = []

    static func build(
        protect: [ProtectComputerRow], pro: [DeviceInventoryRecord]
    ) -> ProtectProCorrelation {
        let correlation = DeviceCorrelation(records: pro)
        var result = ProtectProCorrelation(protectCount: protect.count)
        var claimed = Set<Int>()
        for row in protect {
            var probe = DeviceInventoryRecord.empty(id: "protect", source: "protect")
            probe.udid = row.uuid
            probe.serial = row.serial ?? ""
            switch correlation.match(probe) {
            case .matched(let position, _):
                result.matched += 1
                claimed.insert(position)
            case .unmatched: result.notInPro.append(row)
            case .ambiguous: result.ambiguous += 1
            case .noIdentifier: result.noIdentifier += 1
            }
        }
        result.proWithoutProtect = pro.enumerated()
            .filter { !claimed.contains($0.offset) }.map(\.element)
        return result
    }

    /// nil when there is no Jamf Pro `computers` snapshot to match against.
    static func load(
        protect: [ProtectComputerRow], profile: String, demoMode: Bool
    ) -> ProtectProCorrelation? {
        let pro = demoMode
            ? DemoData.outreachRecords
            : DeviceInventoryService.cachedComputerRecords(profile: profile)
        return pro.map { build(protect: protect, pro: $0) }
    }
}
