import Foundation

typealias CSVRow = [String: String]

/// Minimal RFC-4180-compliant CSV parser that handles quoted fields, escaped quotes,
/// and UTF-8-sig BOM stripping. Replaces pandas for the sheet-generation path.
enum CSVParser {

    enum ParseError: Error { case empty, encodingFailed }

    /// Parse CSV data into an array of column-name-keyed dictionaries.
    static func parse(_ data: Data) throws -> ([String], [CSVRow]) {
        // Strip UTF-8 BOM if present
        var raw = data
        let bom: [UInt8] = [0xEF, 0xBB, 0xBF]
        if raw.prefix(3).elementsEqual(bom) { raw = raw.dropFirst(3) }
        guard let text = String(data: raw, encoding: .utf8) else {
            throw ParseError.encodingFailed
        }
        let rows = parseText(text)
        guard let header = rows.first, !header.isEmpty else { throw ParseError.empty }
        let columns = header
        let records: [CSVRow] = rows.dropFirst().compactMap { row -> CSVRow? in
            guard !row.isEmpty else { return nil }
            var dict = CSVRow()
            for (idx, col) in columns.enumerated() {
                dict[col] = idx < row.count ? row[idx] : ""
            }
            return dict
        }
        return (columns, records)
    }

    /// Parse only the header row, skipping the full O(rows) scan in `parseText`.
    /// ponytail: splits on the first raw CR or LF, so a header containing a
    /// quoted embedded newline would truncate — no Jamf export emits one.
    static func parseHeader(_ data: Data) -> [String]? {
        var raw = data
        let bom: [UInt8] = [0xEF, 0xBB, 0xBF]
        if raw.prefix(3).elementsEqual(bom) { raw = raw.dropFirst(3) }
        let headerBytes: Data
        if let newlineIndex = raw.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            headerBytes = raw[..<newlineIndex]
        } else {
            headerBytes = raw
        }
        guard let text = String(data: headerBytes, encoding: .utf8) else { return nil }
        return parseText(text).first
    }

    /// Walks Unicode scalars, not Characters: "\r\n" is ONE Character that equals neither
    /// "\r" nor "\n", so a CSV saved by Excel or Windows read as a single row, and a combining
    /// mark after a comma or quote fused with it.
    static func parseText(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var fields: [String] = []
        var field = ""
        var inQuote = false
        let scalars = text.unicodeScalars
        var idx = scalars.startIndex

        while idx < scalars.endIndex {
            let ch = scalars[idx]
            var next = scalars.index(after: idx)

            if inQuote {
                if ch == "\"" {
                    if next < scalars.endIndex && scalars[next] == "\"" {
                        field.unicodeScalars.append(ch)
                        next = scalars.index(after: next)
                    } else {
                        inQuote = false
                    }
                } else {
                    field.unicodeScalars.append(ch)
                }
            } else {
                switch ch {
                case "\"":
                    inQuote = true
                case ",":
                    fields.append(field.trimmingCharacters(in: .init(charactersIn: " \t")))
                    field = ""
                case "\r", "\n":
                    if ch == "\r" && next < scalars.endIndex && scalars[next] == "\n" {
                        next = scalars.index(after: next)
                    }
                    fields.append(field.trimmingCharacters(in: .init(charactersIn: " \t")))
                    rows.append(fields)
                    fields = []
                    field = ""
                default:
                    field.unicodeScalars.append(ch)
                }
            }
            idx = next
        }
        // Last field / row
        if !field.isEmpty || !fields.isEmpty {
            fields.append(field.trimmingCharacters(in: .init(charactersIn: " \t")))
            if fields.contains(where: { !$0.isEmpty }) {
                rows.append(fields)
            }
        }
        return rows
    }
}
