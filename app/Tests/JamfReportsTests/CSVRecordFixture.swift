import Foundation
@testable import JamfReports

extension DeviceInventoryService {

    /// A Computers record built from one Jamf Pro CSV export row. The app reads no CSV for this
    /// screen any more; tests keep it as a compact way to write a record with real export headers.
    static func recordFromCSV(
        _ row: [String: String], source: String, staleThresholdDays: Int = 30
    ) -> DeviceInventoryRecord {
        func cell(_ candidates: [String]) -> String {
            for key in candidates {
                let value = (row[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { return value }
            }
            return ""
        }
        func yesNo(_ text: String) -> Bool? {
            switch text.lowercased() {
            case "yes", "true": true
            case "no", "false": false
            default: nil
            }
        }
        let name = cell(["Computer Name", "Device Name", "Name"])
        let serial = cell(["Serial Number", "Serial"])
        let jamfID = cell(["Jamf ID", "Computer ID", "JSS Computer ID", "ID"])
        let id = !serial.isEmpty ? "serial:\(serial.lowercased())"
            : !jamfID.isEmpty ? "jamf:\(jamfID)"
            : name.isEmpty ? "device:unknown" : "name:\(name.lowercased())"
        var record = DeviceInventoryRecord.empty(id: id, source: source)
        record.jamfID = jamfID
        record.managementID = cell(["Management ID", "Jamf Management ID"]).nilIfEmpty
        record.udid = cell(["UDID"]).nilIfEmpty
        record.name = name
        record.serial = serial
        record.osVersion = cell(["Operating System", "Operating System Version", "OS Version", "macOS"])
        record.model = cell(["Model", "Model Identifier"])
        record.user = cell(["Username", "User Last Logged in - Computer", "Full Name", "User"])
        record.email = cell(["Email Address", "Email", "Primary Email"])
        record.department = cell(["Department"])
        record.building = cell(["Building"])
        record.site = cell(["Site"])
        record.ipAddress = cell(["IP Address", "Last IP Address"])
        record.assetTag = cell(["Asset Tag"])
        record.managedState = cell(["Managed"])
        record.lastContact = cell(["Last Check-in", "Last Contact", "Last Contact Date"])
        record.lastInventory = cell(["Last Inventory Update", "Last Report", "Report Date"])
        record.checkInDate = parseDate(record.lastContact)
        record.inventoryDate = parseDate(record.lastInventory)
        record.daysSinceContact = Int(cell(["Days Since Contact", "Days Since Check-in"]))
            ?? record.checkInDate.map { StaleRule.wholeDays(from: $0, to: Date()) }
        record.stale = (record.daysSinceContact ?? 0) > staleThresholdDays
        record.fileVault = cell(["FileVault Status", "FileVault 2 Status", "FileVault 2 Enabled"])
        record.sip = cell(["System Integrity Protection", "SIP"])
        record.firewall = cell(["Firewall Enabled", "Firewall"])
        record.gatekeeper = cell(["Gatekeeper"])
        record.bootstrapToken = cell(["Bootstrap Token Escrowed"])
        record.hardwareEncrypted = HardwareEncryption.isHardwareEncrypted(
            appleSilicon: yesNo(cell(["Apple Silicon"])),
            modelIdentifier: cell(["Model Identifier"]),
            architecture: cell(["Architecture Type", "Architecture"]))
        return record
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
