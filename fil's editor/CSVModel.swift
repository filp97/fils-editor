//
//  CSVModel.swift
//  fil's editor
//

import Foundation

nonisolated struct CSVColumn: Identifiable, Hashable, Sendable {
    let id: UUID
    var name: String

    init(id: UUID = UUID(), name: String) {
        self.id = id
        self.name = name
    }
}

nonisolated struct CSVRow: Identifiable, Hashable, Sendable {
    let id: UUID
    var cells: [String]

    init(id: UUID = UUID(), cells: [String]) {
        self.id = id
        self.cells = cells
    }
}

nonisolated enum CSVLineEnding: String, Hashable, Sendable, CaseIterable {
    case crlf = "\r\n"
    case lf = "\n"
    case cr = "\r"

    var label: String {
        switch self {
        case .crlf: "Windows (CRLF)"
        case .lf: "Unix (LF)"
        case .cr: "Classic Mac (CR)"
        }
    }

    static func detect(in text: String) -> CSVLineEnding {
        // unicodeScalars: a grapheme-cluster scan would see "\r\n" as one Character.
        var previousWasCR = false
        for scalar in text.unicodeScalars.prefix(16384) {
            if scalar == "\n" {
                return previousWasCR ? .crlf : .lf
            }
            if previousWasCR {
                return .cr
            }
            previousWasCR = scalar == "\r"
        }
        return previousWasCR ? .cr : .crlf
    }
}

nonisolated struct CSVTable: Hashable, Sendable {
    var columns: [CSVColumn]
    var rows: [CSVRow]
    var delimiter: Character
    var hasHeaderRow: Bool
    /// New documents default to CRLF so files round-trip with Windows tools untouched.
    var lineEnding: CSVLineEnding
    /// Encoding and BOM of the file this table was read from; `serializedData()` writes it back.
    var fileEncoding: TextFileEncoding

    init(columns: [CSVColumn] = [], rows: [CSVRow] = [], delimiter: Character = ",", hasHeaderRow: Bool = true, lineEnding: CSVLineEnding = .crlf, fileEncoding: TextFileEncoding = .utf8) {
        self.columns = columns
        self.rows = rows
        self.delimiter = delimiter
        self.hasHeaderRow = hasHeaderRow
        self.lineEnding = lineEnding
        self.fileEncoding = fileEncoding
    }

    static func defaultColumnName(_ index: Int) -> String {
        "Column \(index + 1)"
    }

    /// Name shown in the UI. Column names may be empty (an empty header cell, or no header row):
    /// the stored name stays empty so saving does not invent header text.
    func displayName(ofColumn index: Int) -> String {
        guard columns.indices.contains(index) else { return Self.defaultColumnName(index) }
        let name = columns[index].name
        return name.isEmpty ? Self.defaultColumnName(index) : name
    }

    static func empty(columns columnCount: Int = 3, rows rowCount: Int = 5) -> CSVTable {
        let columns = (0..<columnCount).map { CSVColumn(name: defaultColumnName($0)) }
        let rows = (0..<rowCount).map { _ in CSVRow(cells: Array(repeating: "", count: columnCount)) }
        return CSVTable(columns: columns, rows: rows)
    }

    // MARK: - Parsing

    static func detectDelimiter(in text: String) -> Character {
        let candidates: [Character] = [",", ";", "\t", "|"]
        let sample = text.prefix(8192)
        var best: (delimiter: Character, count: Int) = (",", 0)
        for candidate in candidates {
            var count = 0
            var inQuotes = false
            for ch in sample {
                if ch == "\"" {
                    inQuotes.toggle()
                } else if ch == candidate && !inQuotes {
                    count += 1
                }
            }
            if count > best.count {
                best = (candidate, count)
            }
        }
        return best.delimiter
    }

    static func parse(_ text: String, delimiter explicitDelimiter: Character? = nil, hasHeaderRow: Bool = true) -> CSVTable {
        let delimiter = explicitDelimiter ?? detectDelimiter(in: text)
        let lineEnding = CSVLineEnding.detect(in: text)
        var records = parseRecords(text, delimiter: delimiter)

        // Drop trailing fully-empty records (common with trailing newlines)
        while let last = records.last, last.allSatisfy(\.isEmpty) {
            records.removeLast()
        }

        guard !records.isEmpty else {
            var table = CSVTable.empty()
            table.delimiter = delimiter
            table.lineEnding = lineEnding
            return table
        }

        let width = records.map(\.count).max() ?? 1

        var columns: [CSVColumn]
        if hasHeaderRow {
            let headerRecord = records.removeFirst()
            columns = (0..<width).map { i in
                CSVColumn(name: i < headerRecord.count ? headerRecord[i] : "")
            }
        } else {
            columns = (0..<width).map { _ in CSVColumn(name: "") }
        }

        let rows = records.map { record -> CSVRow in
            var cells = record
            if cells.count < width {
                cells.append(contentsOf: Array(repeating: "", count: width - cells.count))
            }
            return CSVRow(cells: cells)
        }

        return CSVTable(columns: columns, rows: rows, delimiter: delimiter, hasHeaderRow: hasHeaderRow, lineEnding: lineEnding)
    }

    /// RFC 4180-style parser: handles quoted fields, escaped quotes ("") and \n, \r\n, \r line endings.
    static func parseRecords(_ text: String, delimiter: Character) -> [[String]] {
        var records: [[String]] = []
        var record: [String] = []
        var field = ""
        var inQuotes = false

        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            if inQuotes {
                if c == "\"" {
                    let next = text.index(after: i)
                    if next < text.endIndex && text[next] == "\"" {
                        field.append("\"")
                        i = next
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(c)
                }
            } else {
                switch c {
                case "\"" where field.isEmpty:
                    inQuotes = true
                case delimiter:
                    record.append(field)
                    field = ""
                // In Swift "\r\n" is a single Character (grapheme cluster),
                // so CRLF must be matched explicitly alongside "\n" and "\r".
                case "\n", "\r", "\r\n":
                    record.append(field)
                    field = ""
                    records.append(record)
                    record = []
                default:
                    field.append(c)
                }
            }
            i = text.index(after: i)
        }
        if !field.isEmpty || !record.isEmpty {
            record.append(field)
            records.append(record)
        }
        return records
    }

    // MARK: - Serialization

    func serialized() -> String {
        var lines: [String] = []
        if hasHeaderRow {
            lines.append(encodeRecord(columns.map(\.name)))
        }
        for row in rows {
            lines.append(encodeRecord(row.cells))
        }
        let newline = lineEnding.rawValue
        return lines.joined(separator: newline) + newline
    }

    /// File bytes in the table's original encoding (see `fileEncoding`).
    func serializedData() -> Data {
        fileEncoding.encode(serialized())
    }

    private func encodeRecord(_ fields: [String]) -> String {
        fields.map(encodeField).joined(separator: String(delimiter))
    }

    private func encodeField(_ value: String) -> String {
        let needsQuoting = value.contains(delimiter) || value.contains("\"")
            || value.contains("\n") || value.contains("\r") || value.contains("\r\n")
        guard needsQuoting else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    // MARK: - Mutations

    mutating func setHasHeaderRow(_ flag: Bool) {
        guard flag != hasHeaderRow else { return }
        if flag {
            if !rows.isEmpty {
                let first = rows.removeFirst()
                for i in columns.indices {
                    columns[i].name = i < first.cells.count ? first.cells[i] : ""
                }
            }
            hasHeaderRow = true
        } else {
            rows.insert(CSVRow(cells: columns.map(\.name)), at: 0)
            for i in columns.indices {
                columns[i].name = ""
            }
            hasHeaderRow = false
        }
    }

    mutating func insertRow(at index: Int) {
        let clamped = min(max(index, 0), rows.count)
        rows.insert(CSVRow(cells: Array(repeating: "", count: columns.count)), at: clamped)
    }

    mutating func insertColumn(at index: Int, name: String? = nil) {
        let clamped = min(max(index, 0), columns.count)
        columns.insert(CSVColumn(name: name ?? Self.defaultColumnName(columns.count)), at: clamped)
        for i in rows.indices {
            rows[i].cells.insert("", at: clamped)
        }
    }

    mutating func removeColumn(at index: Int) {
        guard columns.indices.contains(index), columns.count > 1 else { return }
        columns.remove(at: index)
        for i in rows.indices where rows[i].cells.indices.contains(index) {
            rows[i].cells.remove(at: index)
        }
    }

    mutating func moveColumn(from source: Int, to destination: Int) {
        guard columns.indices.contains(source), columns.indices.contains(destination), source != destination else { return }
        let column = columns.remove(at: source)
        columns.insert(column, at: destination)
        for i in rows.indices where rows[i].cells.indices.contains(source) {
            let cell = rows[i].cells.remove(at: source)
            rows[i].cells.insert(cell, at: destination)
        }
    }

    /// Numbers sort numerically before text; empty cells stay at the bottom in both directions.
    /// Keys are computed once per row so the comparator is cheap and consistent (a strict
    /// weak ordering, which mixing numeric and text comparisons pair by pair is not).
    mutating func sortRows(by columnIndex: Int, ascending: Bool) {
        guard columns.indices.contains(columnIndex) else { return }
        let keyed = rows.map { row -> (row: CSVRow, text: String, number: Double?) in
            let text = columnIndex < row.cells.count ? row.cells[columnIndex] : ""
            return (row, text, Self.sortNumber(text))
        }
        let sorted = keyed.sorted { a, b in
            let aEmpty = a.text.isEmpty, bEmpty = b.text.isEmpty
            if aEmpty || bEmpty { return !aEmpty && bEmpty }
            let comparison: ComparisonResult
            switch (a.number, b.number) {
            case let (l?, r?):
                comparison = l < r ? .orderedAscending : (l > r ? .orderedDescending : .orderedSame)
            case (.some, nil):
                comparison = .orderedAscending
            case (nil, .some):
                comparison = .orderedDescending
            case (nil, nil):
                comparison = a.text.localizedStandardCompare(b.text)
            }
            return ascending ? comparison == .orderedAscending : comparison == .orderedDescending
        }
        rows = sorted.map(\.row)
    }

    /// Plain decimal numbers only ("12", "-3.5", "2,5", "1e3"); not "nan", "inf" or hex.
    private static func sortNumber(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              trimmed.unicodeScalars.allSatisfy({ "0123456789+-.,eE".unicodeScalars.contains($0) }),
              let value = Double(trimmed.replacingOccurrences(of: ",", with: ".")),
              value.isFinite else { return nil }
        return value
    }
}
