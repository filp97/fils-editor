//
//  CSVDocument.swift
//  fil's editor
//

import Combine
import AppKit
import SwiftUI
import UniformTypeIdentifiers

final class CSVDocument: ReferenceFileDocument {
    typealias Snapshot = CSVTable

    @Published var table: CSVTable
    /// Sheet names when the open file is an Excel workbook; empty for CSV/text.
    @Published private(set) var sheetNames: [String] = []
    @Published private(set) var currentSheetIndex = 0

    /// Raw `.xlsx` bytes kept so the user can switch sheets without reopening the file.
    private var spreadsheetData: Data?

    var isSpreadsheetSource: Bool { spreadsheetData != nil }

    nonisolated static var readableContentTypes: [UTType] {
        [.commaSeparatedText, .tabSeparatedText, .delimitedText, .plainText, .spreadsheetML]
    }

    nonisolated static var writableContentTypes: [UTType] {
        [.commaSeparatedText, .tabSeparatedText, .plainText]
    }

    init() {
        table = .empty()
    }

    required nonisolated init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }

        if Self.isSpreadsheetContentType(configuration.contentType) {
            let info = try XLSXImporter.workbookInfo(from: data)
            spreadsheetData = data
            sheetNames = info.sheetNames
            currentSheetIndex = 0
            table = try XLSXImporter.table(from: data, sheetIndex: 0)
            return
        }

        let decoded = TextFileEncoding.decode(data)
        var parsed = CSVTable.parse(decoded.text)
        parsed.fileEncoding = decoded.format
        table = parsed
    }

    private nonisolated static func isSpreadsheetContentType(_ type: UTType) -> Bool {
        type.conforms(to: .spreadsheetML)
            || type.identifier == "org.openxmlformats.spreadsheetml.sheet"
            || type.preferredFilenameExtension?.lowercased() == "xlsx"
    }

    /// Reloads `table` from another worksheet of the open XLSX file. Clears undo: the
    /// registered snapshots belong to the previous sheet and would restore it over this one.
    func selectSheet(at index: Int, undoManager: UndoManager?) {
        guard let data = spreadsheetData,
              sheetNames.indices.contains(index),
              index != currentSheetIndex else { return }
        do {
            table = try XLSXImporter.table(from: data, sheetIndex: index)
            currentSheetIndex = index
            undoManager?.removeAllActions()
        } catch {
            NSSound.beep()
        }
    }

    func snapshot(contentType: UTType) throws -> CSVTable {
        table
    }

    nonisolated func fileWrapper(snapshot: CSVTable, configuration: WriteConfiguration) throws -> FileWrapper {
        // Never write CSV text into an .xlsx: the workbook would be destroyed. Saving an Excel
        // file must go through "Save As…" with a CSV/TSV type.
        if Self.isSpreadsheetContentType(configuration.contentType) {
            throw CocoaError(.fileWriteUnknown, userInfo: [
                NSLocalizedDescriptionKey: "Excel files can't be overwritten.",
                NSLocalizedRecoverySuggestionErrorKey: "Use “Save As…” and choose the CSV or TSV format.",
            ])
        }
        var table = snapshot
        if configuration.contentType.conforms(to: .tabSeparatedText) {
            table.delimiter = "\t"
        }
        return FileWrapper(regularFileWithContents: table.serializedData())
    }

    // MARK: - Undoable mutations

    /// Applies a change to the table and registers a snapshot-based undo action.
    func modify(_ actionName: String, undoManager: UndoManager?, _ body: (inout CSVTable) -> Void) {
        let oldTable = table
        body(&table)
        guard table != oldTable else { return }
        undoManager?.registerUndo(withTarget: self) { document in
            document.modify(actionName, undoManager: undoManager) { $0 = oldTable }
        }
        undoManager?.setActionName(actionName)
    }

    // MARK: - Lookup

    func rowIndex(of id: CSVRow.ID) -> Int? {
        table.rows.firstIndex { $0.id == id }
    }

    func cell(rowID: CSVRow.ID, columnIndex: Int) -> String {
        guard let rowIndex = rowIndex(of: rowID),
              table.rows[rowIndex].cells.indices.contains(columnIndex) else { return "" }
        return table.rows[rowIndex].cells[columnIndex]
    }

    // MARK: - Cells

    func setCell(rowID: CSVRow.ID, columnIndex: Int, value: String, undoManager: UndoManager?) {
        guard cell(rowID: rowID, columnIndex: columnIndex) != value else { return }
        modify("Edit Cell", undoManager: undoManager) { table in
            guard let rowIndex = table.rows.firstIndex(where: { $0.id == rowID }),
                  table.rows[rowIndex].cells.indices.contains(columnIndex) else { return }
            table.rows[rowIndex].cells[columnIndex] = value
        }
    }

    // MARK: - Rows

    @discardableResult
    func insertRow(at index: Int, undoManager: UndoManager?) -> CSVRow.ID? {
        let clamped = min(max(index, 0), table.rows.count)
        modify("Insert Row", undoManager: undoManager) { $0.insertRow(at: clamped) }
        guard table.rows.indices.contains(clamped) else { return nil }
        return table.rows[clamped].id
    }

    @discardableResult
    func appendRow(undoManager: UndoManager?) -> CSVRow.ID? {
        insertRow(at: table.rows.count, undoManager: undoManager)
    }

    @discardableResult
    func duplicateRow(id: CSVRow.ID, undoManager: UndoManager?) -> CSVRow.ID? {
        var newRowID: CSVRow.ID?
        modify("Duplicate Row", undoManager: undoManager) { table in
            guard let index = table.rows.firstIndex(where: { $0.id == id }) else { return }
            let newRow = CSVRow(cells: table.rows[index].cells)
            newRowID = newRow.id
            table.rows.insert(newRow, at: index + 1)
        }
        return newRowID
    }

    func removeRows(ids: Set<CSVRow.ID>, undoManager: UndoManager?) {
        guard !ids.isEmpty else { return }
        modify("Delete Rows", undoManager: undoManager) { table in
            table.rows.removeAll { ids.contains($0.id) }
        }
    }

    // MARK: - Columns

    func insertColumn(at index: Int, undoManager: UndoManager?) {
        modify("Insert Column", undoManager: undoManager) { $0.insertColumn(at: index) }
    }

    func appendColumn(undoManager: UndoManager?) {
        insertColumn(at: table.columns.count, undoManager: undoManager)
    }

    func removeColumn(at index: Int, undoManager: UndoManager?) {
        modify("Delete Column", undoManager: undoManager) { $0.removeColumn(at: index) }
    }

    func clearColumns(at indices: Set<Int>, undoManager: UndoManager?) {
        guard !indices.isEmpty else { return }
        let sorted = indices.sorted()
        modify("Clear Columns", undoManager: undoManager) { table in
            for columnIndex in sorted {
                guard table.columns.indices.contains(columnIndex) else { continue }
                for rowIndex in table.rows.indices {
                    guard table.rows[rowIndex].cells.indices.contains(columnIndex) else { continue }
                    table.rows[rowIndex].cells[columnIndex] = ""
                }
            }
        }
    }

    func renameColumn(at index: Int, name: String, undoManager: UndoManager?) {
        guard table.columns.indices.contains(index), !name.isEmpty else { return }
        modify("Rename Column", undoManager: undoManager) { $0.columns[index].name = name }
    }

    func moveColumn(from source: Int, to destination: Int, undoManager: UndoManager?) {
        modify("Move Column", undoManager: undoManager) { $0.moveColumn(from: source, to: destination) }
    }

    // MARK: - Table operations

    func sortRows(by columnIndex: Int, ascending: Bool, undoManager: UndoManager?) {
        modify("Sort Rows", undoManager: undoManager) { $0.sortRows(by: columnIndex, ascending: ascending) }
    }

    func setDelimiter(_ delimiter: Character, undoManager: UndoManager?) {
        modify("Change Delimiter", undoManager: undoManager) { $0.delimiter = delimiter }
    }

    func setLineEnding(_ lineEnding: CSVLineEnding, undoManager: UndoManager?) {
        modify("Change Line Ending", undoManager: undoManager) { $0.lineEnding = lineEnding }
    }

    func setHasHeaderRow(_ flag: Bool, undoManager: UndoManager?) {
        modify(flag ? "Use Header Row" : "Remove Header Row", undoManager: undoManager) { $0.setHasHeaderRow(flag) }
    }

    /// All cells containing `find`, in row-major order.
    func findMatches(find: String, caseSensitive: Bool) -> [CellAddress] {
        guard !find.isEmpty else { return [] }
        let options: String.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
        var results: [CellAddress] = []
        for row in table.rows {
            for (columnIndex, cell) in row.cells.enumerated() {
                if cell.range(of: find, options: options) != nil {
                    results.append(CellAddress(rowID: row.id, columnIndex: columnIndex))
                }
            }
        }
        return results
    }

    /// Replaces every occurrence of `find` in all cells. Returns the number of cells changed.
    @discardableResult
    func replaceAll(find: String, with replacement: String, caseSensitive: Bool, undoManager: UndoManager?) -> Int {
        guard !find.isEmpty else { return 0 }
        var changedCells = 0
        modify("Replace All", undoManager: undoManager) { table in
            let options: String.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
            for rowIndex in table.rows.indices {
                for cellIndex in table.rows[rowIndex].cells.indices {
                    let original = table.rows[rowIndex].cells[cellIndex]
                    guard original.range(of: find, options: options) != nil else { continue }
                    table.rows[rowIndex].cells[cellIndex] = original.replacingOccurrences(
                        of: find, with: replacement, options: options
                    )
                    changedCells += 1
                }
            }
        }
        return changedCells
    }
}
