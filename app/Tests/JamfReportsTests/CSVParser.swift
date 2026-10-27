import Foundation

typealias CSVRow = [String: String]

/// RFC-4180 CSV reader for test fixtures (quoted fields, escaped quotes, UTF-8 BOM). The app
/// reads a CSV only through `ScaffoldService.readSample`.
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
