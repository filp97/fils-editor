//
//  XLSXImporter.swift
//  fil's editor
//

import CoreXLSX
import Foundation
import UniformTypeIdentifiers

extension UTType {
    /// Excel Open XML workbook (`.xlsx`).
    nonisolated static var spreadsheetML: UTType {
        UTType(filenameExtension: "xlsx")
            ?? UTType(importedAs: "org.openxmlformats.spreadsheetml.sheet")
    }
}

enum XLSXImporterError: LocalizedError {
    case emptyWorkbook
    case invalidSheetIndex

    var errorDescription: String? {
        switch self {
        case .emptyWorkbook: "The Excel file contains no sheets."
        case .invalidSheetIndex: "Invalid sheet."
        }
    }
}

nonisolated struct XLSXWorkbookInfo: Sendable {
    let sheetNames: [String]
}

nonisolated enum XLSXImporter {
    /// Lists sheet names without fully materializing every sheet's cells.
    static func workbookInfo(from data: Data) throws -> XLSXWorkbookInfo {
        let file = try XLSXFile(data: data)
        let names = try sheetEntries(in: file).map(\.name)
        guard !names.isEmpty else { throw XLSXImporterError.emptyWorkbook }
        return XLSXWorkbookInfo(sheetNames: names)
    }

    /// Loads one worksheet into a `CSVTable` (first row = column headers).
    static func table(from data: Data, sheetIndex: Int) throws -> CSVTable {
        let file = try XLSXFile(data: data)
        let entries = try sheetEntries(in: file)
        guard entries.indices.contains(sheetIndex) else {
            throw XLSXImporterError.invalidSheetIndex
        }
        let sharedStrings = try file.parseSharedStrings()
        let worksheet = try file.parseWorksheet(at: entries[sheetIndex].path)
        return table(from: worksheet, sharedStrings: sharedStrings)
    }

    // MARK: - Private

    private static func sheetEntries(in file: XLSXFile) throws -> [(name: String, path: String)] {
        var result: [(name: String, path: String)] = []
        for workbook in try file.parseWorkbooks() {
            let pairs = try file.parseWorksheetPathsAndNames(workbook: workbook)
            for (index, pair) in pairs.enumerated() {
                let name = pair.name?.trimmingCharacters(in: .whitespacesAndNewlines)
                let display = (name?.isEmpty == false) ? name! : "Sheet \(index + 1)"
                result.append((name: display, path: pair.path))
            }
        }
        return result
    }

    private static func table(from worksheet: Worksheet, sharedStrings: SharedStrings?) -> CSVTable {
        let rows = worksheet.data?.rows ?? []
        guard !rows.isEmpty else {
            return CSVTable.empty(columns: 1, rows: 1)
        }

        var maxColumn = 1
        var maxRow = 1
        var grid: [Int: [Int: String]] = [:]

        for row in rows {
            let rowIndex = Int(row.reference)
            maxRow = max(maxRow, rowIndex)
            for cell in row.cells {
                let columnIndex = columnIndex(from: cell.reference.column.value)
                maxColumn = max(maxColumn, columnIndex)
                let text = displayValue(for: cell, sharedStrings: sharedStrings)
                if !text.isEmpty {
                    grid[rowIndex, default: [:]][columnIndex] = text
                }
            }
        }

        // Treat the first non-empty spreadsheet row as the header when present;
        // otherwise invent default column names.
        let headerRowIndex = (1...maxRow).first { rowIndex in
            (1...maxColumn).contains { !(grid[rowIndex]?[$0] ?? "").isEmpty }
        } ?? 1

        let headerValues = (1...maxColumn).map { grid[headerRowIndex]?[$0] ?? "" }
        let hasNamedHeader = headerValues.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        let columns: [CSVColumn]
        let dataStartRow: Int
        if hasNamedHeader {
            columns = headerValues.enumerated().map { index, name in
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                return CSVColumn(name: trimmed.isEmpty ? CSVTable.defaultColumnName(index) : trimmed)
            }
            dataStartRow = headerRowIndex + 1
        } else {
            columns = (0..<maxColumn).map { CSVColumn(name: CSVTable.defaultColumnName($0)) }
            dataStartRow = headerRowIndex
        }

        var csvRows: [CSVRow] = []
        if dataStartRow <= maxRow {
            for rowIndex in dataStartRow...maxRow {
                let cells = (1...maxColumn).map { grid[rowIndex]?[$0] ?? "" }
                // Skip completely empty trailing rows.
                if cells.allSatisfy({ $0.isEmpty }) { continue }
                csvRows.append(CSVRow(cells: cells))
            }
        }

        // Keep empty sheets usable in the grid.
        if csvRows.isEmpty {
            csvRows = [CSVRow(cells: Array(repeating: "", count: columns.count))]
        }

        return CSVTable(
            columns: columns,
            rows: csvRows,
            delimiter: ",",
            hasHeaderRow: true,
            lineEnding: .lf
        )
    }

    /// Converts Excel column letters (A, B, …, Z, AA, …) to a 1-based index.
    private static func columnIndex(from reference: String) -> Int {
        var result = 0
        for scalar in reference.uppercased().unicodeScalars {
            guard scalar >= "A", scalar <= "Z" else { continue }
            result = result * 26 + Int(scalar.value - UnicodeScalar("A").value) + 1
        }
        return max(result, 1)
    }

    private static func displayValue(for cell: Cell, sharedStrings: SharedStrings?) -> String {
        if let sharedStrings,
           cell.type == .sharedString,
           let index = cell.value.flatMap(Int.init),
           sharedStrings.items.indices.contains(index) {
            let item = sharedStrings.items[index]
            if let text = item.text, !text.isEmpty { return text }
            let rich = item.richText.compactMap(\.text).joined()
            if !rich.isEmpty { return rich }
        }
        if let sharedStrings, let text = cell.stringValue(sharedStrings), !text.isEmpty {
            return text
        }
        if cell.type == .inlineStr {
            if let text = cell.inlineString?.text, !text.isEmpty { return text }
        }
        if cell.type == .bool, let raw = cell.value {
            switch raw {
            case "1", "true", "TRUE": return "TRUE"
            case "0", "false", "FALSE": return "FALSE"
            default: return raw
            }
        }
        // Formulas expose the cached calculated value in `value` when present.
        if let value = cell.value {
            return value
        }
        return ""
    }
}
