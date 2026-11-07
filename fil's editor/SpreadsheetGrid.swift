//
//  SpreadsheetGrid.swift
//  fil's editor
//

import AppKit
import SwiftUI

struct CellAddress: Hashable {
    let rowID: CSVRow.ID
    let columnIndex: Int
}

private struct GridBorders: OptionSet {
    let rawValue: Int
    static let top = GridBorders(rawValue: 1 << 0)
    static let bottom = GridBorders(rawValue: 1 << 1)
    static let leading = GridBorders(rawValue: 1 << 2)
    static let trailing = GridBorders(rawValue: 1 << 3)
    static let all: GridBorders = [.top, .bottom, .leading, .trailing]
}

struct SpreadsheetGrid: View {
    @ObservedObject var document: CSVDocument
    let rows: [CSVRow]
    let rowNumbers: [CSVRow.ID: Int]
    let highlightText: String
    let caseSensitive: Bool
    @Binding var selectedCell: CellAddress?
    @Binding var selectedRows: Set<CSVRow.ID>
    @Binding var selectedColumns: Set<Int>
    @Binding var editingCell: CellAddress?
    @Binding var editingText: String
    @Binding var zoom: CGFloat
    var scrollToSelectionToken: Int = 0
    var deleteSelectionRequest: Int = 0
    var keyboardCaptureSuppressed = false
    var onReleaseFindBarFocus: (() -> Void)?
    var undoManager: UndoManager?
    let contextMenuContent: (CSVRow.ID, Int) -> AnyView

    @State private var editingSelectAllOnFocus = true
    @State private var selectionAnchor: CellAddress?
    @State private var rowSelectionAnchorIndex: Int?
    @State private var rowSelectionActiveIndex: Int?
    @State private var columnSelectionAnchorIndex: Int?
    @State private var columnSelectionActiveIndex: Int?
    @State private var editingOriginalText = ""
    @State private var scrollRevealToken = 0
    @State private var scrollRevealRowIndex: Int?
    @State private var scrollRevealColumnIndex: Int?
    @State private var scrollRevealRowDelta = 0
    @State private var scrollRevealColumnDelta = 0
    /// First data-row index currently materialised for scrolling (windowed virtualisation).
    @State private var rowWindowStart = 0

    private var rowHeight: CGFloat { (22 * zoom).rounded() }
    private var rowNumberWidth: CGFloat { (44 * zoom).rounded() }
    private var minColumnWidth: CGFloat { (140 * zoom).rounded() }
    private var headerHeight: CGFloat { (24 * zoom).rounded() }
    private var fontSize: CGFloat { NSFont.preferredFont(forTextStyle: .callout).pointSize * zoom }

    private struct GridLayout {
        let columnWidth: CGFloat
        let contentWidth: CGFloat
        let dataContentHeight: CGFloat
        let fillerRowCount: Int
        let visibleRowCapacity: Int
    }

    var body: some View {
        Color(nsColor: .textBackgroundColor)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .topLeading) {
                GeometryReader { geometry in
                    let layout = gridLayout(for: geometry.size)
                    let dataHeight = max(0, geometry.size.height - headerHeight)

                    ScrollView(.horizontal) {
                        VStack(alignment: .leading, spacing: 0) {
                            headerRow(columnWidth: layout.columnWidth)
                                .frame(width: layout.contentWidth, alignment: .leading)

                            ScrollView(.vertical) {
                                dataContent(layout: layout)
                                    .frame(width: layout.contentWidth, alignment: .topLeading)
                                    .background {
                                        GridScrollRevealBridge(
                                            token: scrollRevealToken,
                                            rowIndex: scrollRevealRowIndex,
                                            columnIndex: scrollRevealColumnIndex,
                                            rowDelta: scrollRevealRowDelta,
                                            columnDelta: scrollRevealColumnDelta,
                                            metrics: GridScrollMetrics(
                                                rowHeight: rowHeight,
                                                headerHeight: headerHeight,
                                                rowNumberWidth: rowNumberWidth,
                                                columnWidth: layout.columnWidth,
                                                contentWidth: layout.contentWidth,
                                                contentHeight: layout.dataContentHeight,
                                                frozenHeader: true
                                            )
                                        )
                                        GridZoomMonitor(zoom: $zoom)
                                        GridScrollOffsetObserver(
                                            rowHeight: rowHeight,
                                            overscan: 16,
                                            rowCount: rows.count,
                                            windowStart: $rowWindowStart
                                        )
                                        GridClickMonitor(
                                            rowCount: rows.count,
                                            columnCount: document.table.columns.count,
                                            rowHeight: rowHeight,
                                            rowNumberWidth: rowNumberWidth,
                                            columnWidth: layout.columnWidth,
                                            isEditing: editingCell != nil,
                                            onSelectCell: { rowIndex, columnIndex in
                                                guard rows.indices.contains(rowIndex),
                                                      document.table.columns.indices.contains(columnIndex) else { return }
                                                let row = rows[rowIndex]
                                                selectCell(CellAddress(rowID: row.id, columnIndex: columnIndex))
                                            },
                                            onEditCell: { rowIndex, columnIndex in
                                                guard rows.indices.contains(rowIndex),
                                                      document.table.columns.indices.contains(columnIndex) else { return }
                                                let row = rows[rowIndex]
                                                let address = CellAddress(rowID: row.id, columnIndex: columnIndex)
                                                let value = columnIndex < row.cells.count ? row.cells[columnIndex] : ""
                                                editCell(
                                                    address,
                                                    value: value,
                                                    extendSelectionAnchor: isCellInSelection(
                                                        columnIndex: columnIndex,
                                                        displayIndex: rowIndex,
                                                        bounds: selectionBounds()
                                                    )
                                                )
                                            }
                                        )
                                    }
                            }
                            .frame(height: dataHeight)
                        }
                        .frame(width: layout.contentWidth, alignment: .topLeading)
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                }
            }
            .onChange(of: scrollToSelectionToken) { _, _ in
                if let cell = selectedCell {
                    selectionAnchor = cell
                }
                // Defer one frame so new rows are laid out before scrolling.
                DispatchQueue.main.async {
                    revealSelectionInView()
                }
            }
            .onChange(of: deleteSelectionRequest) { _, _ in
                deleteSelection()
            }
            .onChange(of: selectedRows) { _, newRows in
                guard editingCell == nil, selectedCell == nil, selectedColumns.isEmpty,
                      newRows.count == 1,
                      let rowID = newRows.first,
                      let index = rows.firstIndex(where: { $0.id == rowID }) else { return }
                rowSelectionAnchorIndex = index
                rowSelectionActiveIndex = index
            }
            .onChange(of: selectedCell) { _, newValue in
                guard editingCell == nil, let newValue else { return }
                clearRowSelection()
                clearColumnSelection()
                // Keep anchor fixed while extending a range with Shift+arrow.
                if let anchor = selectionAnchor, anchor != newValue { return }
                selectionAnchor = newValue
            }
            .overlay {
                if gridKeyboardActive && !keyboardCaptureSuppressed {
                    GridKeyboardHandler(
                        navigationMode: keyboardNavigationMode,
                        onEnter: { beginEditingSelectedCell() },
                        onType: { beginEditingSelectedCell(replacingWith: $0) },
                        onMoveUp: { moveSelectedCell(rowDelta: -1, extendSelection: $0) },
                        onMoveDown: { moveSelectedCell(rowDelta: 1, extendSelection: $0) },
                        onMoveLeft: { moveSelectedCell(columnDelta: -1, extendSelection: $0) },
                        onMoveRight: { moveSelectedCell(columnDelta: 1, extendSelection: $0) },
                        onMoveRowUp: { moveSelectedRows(rowDelta: -1, extendSelection: $0) },
                        onMoveRowDown: { moveSelectedRows(rowDelta: 1, extendSelection: $0) },
                        onMoveColumnLeft: { moveSelectedColumns(columnDelta: -1, extendSelection: $0) },
                        onMoveColumnRight: { moveSelectedColumns(columnDelta: 1, extendSelection: $0) },
                        onCopy: copySelection,
                        onPaste: pasteSelection,
                        onCut: cutSelection,
                        onDelete: deleteSelection,
                        onSelectAll: selectAllRows
                    )
                }
            }
    }

    private var keyboardNavigationMode: GridKeyboardNavigationMode {
        guard editingCell == nil else { return .none }
        if selectedCell != nil, selectedRows.isEmpty, selectedColumns.isEmpty { return .cell }
        if selectedCell == nil, !selectedRows.isEmpty, selectedColumns.isEmpty { return .row }
        if selectedCell == nil, selectedRows.isEmpty, !selectedColumns.isEmpty { return .column }
        return .none
    }

    private var gridKeyboardActive: Bool {
        editingCell == nil && (selectedCell != nil || !selectedRows.isEmpty || !selectedColumns.isEmpty)
    }

    private func clearColumnSelection() {
        selectedColumns.removeAll()
        columnSelectionAnchorIndex = nil
        columnSelectionActiveIndex = nil
    }

    private func clearRowSelection() {
        selectedRows.removeAll()
        rowSelectionAnchorIndex = nil
        rowSelectionActiveIndex = nil
    }

    private func columnScrollID(_ index: Int) -> String {
        "grid-column-\(index)"
    }

    private func revealSelectionInView() {
        if let cell = selectedCell,
           let rowIndex = rows.firstIndex(where: { $0.id == cell.rowID }) {
            requestScrollReveal(rowIndex: rowIndex, columnIndex: cell.columnIndex)
            return
        }
        if selectedCell == nil, selectedRows.count == 1,
           let rowID = selectedRows.first,
           let rowIndex = rows.firstIndex(where: { $0.id == rowID }) {
            requestScrollReveal(rowIndex: rowIndex, rowDelta: 1)
        }
    }

    private func requestScrollReveal(
        rowIndex: Int? = nil,
        columnIndex: Int? = nil,
        rowDelta: Int = 0,
        columnDelta: Int = 0
    ) {
        var resolvedRowIndex = rowIndex
        var resolvedColumnIndex = columnIndex

        if resolvedRowIndex == nil, let cell = selectedCell,
           let index = rows.firstIndex(where: { $0.id == cell.rowID }) {
            resolvedRowIndex = index
            resolvedColumnIndex = resolvedColumnIndex ?? cell.columnIndex
        } else if resolvedRowIndex == nil, let activeIndex = rowSelectionActiveIndex, rows.indices.contains(activeIndex) {
            resolvedRowIndex = activeIndex
        }

        if resolvedColumnIndex == nil, let activeIndex = columnSelectionActiveIndex {
            resolvedColumnIndex = activeIndex
        } else if resolvedColumnIndex == nil, let column = selectedColumns.min() {
            resolvedColumnIndex = column
        }

        scrollRevealRowIndex = resolvedRowIndex
        scrollRevealColumnIndex = resolvedColumnIndex
        scrollRevealRowDelta = rowDelta
        scrollRevealColumnDelta = columnDelta
        scrollRevealToken += 1
    }

    private func beginEditingSelectedCell(replacingWith replacement: String? = nil) {
        guard let address = selectedCell else { return }
        commitEditing()
        clearRowSelection()
        clearColumnSelection()
        selectedCell = address
        if selectionAnchor == nil {
            selectionAnchor = address
        }
        editingSelectAllOnFocus = replacement == nil
        editingOriginalText = document.cell(rowID: address.rowID, columnIndex: address.columnIndex)
        editingText = replacement ?? editingOriginalText
        editingCell = address
        CellEditorFocusBridge.focusActiveEditor(selectAll: replacement == nil)
    }

    private func cancelEditing() {
        guard editingCell != nil else { return }
        editingText = editingOriginalText
        editingCell = nil
    }

    private func moveSelectedCell(
        rowDelta: Int = 0, columnDelta: Int = 0, extendSelection: Bool = false
    ) {
        guard let current = selectedCell,
              let currentRowIndex = rows.firstIndex(where: { $0.id == current.rowID }) else { return }

        let newRowIndex = currentRowIndex + rowDelta
        guard rows.indices.contains(newRowIndex) else { return }

        let newColumnIndex = current.columnIndex + columnDelta
        guard document.table.columns.indices.contains(newColumnIndex) else { return }

        let newAddress = CellAddress(rowID: rows[newRowIndex].id, columnIndex: newColumnIndex)
        clearRowSelection()
        clearColumnSelection()

        if extendSelection {
            if selectionAnchor == nil {
                selectionAnchor = current
            }
            selectedCell = newAddress
        } else {
            selectionAnchor = newAddress
            selectedCell = newAddress
        }
        requestScrollReveal(
            rowIndex: newRowIndex,
            columnIndex: newColumnIndex,
            rowDelta: rowDelta,
            columnDelta: columnDelta
        )
    }

    private func moveSelectedRows(rowDelta: Int, extendSelection: Bool) {
        guard !rows.isEmpty else { return }

        let anchorIndex = rowSelectionAnchorIndex
            ?? rowSelectionActiveIndex
            ?? selectedRows.compactMap { id in rows.firstIndex(where: { $0.id == id }) }.min()
        guard let anchorIndex, rows.indices.contains(anchorIndex) else { return }

        let activeIndex = rowSelectionActiveIndex ?? anchorIndex
        let newActiveIndex = activeIndex + rowDelta
        guard rows.indices.contains(newActiveIndex) else { return }

        if extendSelection {
            if rowSelectionAnchorIndex == nil {
                rowSelectionAnchorIndex = anchorIndex
            }
            let lo = min(rowSelectionAnchorIndex!, newActiveIndex)
            let hi = max(rowSelectionAnchorIndex!, newActiveIndex)
            selectedRows = Set(rows[lo...hi].map(\.id))
            rowSelectionActiveIndex = newActiveIndex
        } else {
            rowSelectionAnchorIndex = newActiveIndex
            rowSelectionActiveIndex = newActiveIndex
            selectedRows = [rows[newActiveIndex].id]
        }
        requestScrollReveal(rowIndex: newActiveIndex, rowDelta: rowDelta)
    }

    private func moveSelectedColumns(columnDelta: Int, extendSelection: Bool) {
        let columnCount = document.table.columns.count
        guard columnCount > 0 else { return }

        let anchorIndex = columnSelectionAnchorIndex
            ?? columnSelectionActiveIndex
            ?? selectedColumns.min()
        guard let anchorIndex, document.table.columns.indices.contains(anchorIndex) else { return }

        let activeIndex = columnSelectionActiveIndex ?? anchorIndex
        let newActiveIndex = activeIndex + columnDelta
        guard document.table.columns.indices.contains(newActiveIndex) else { return }

        if extendSelection {
            if columnSelectionAnchorIndex == nil {
                columnSelectionAnchorIndex = anchorIndex
            }
            let lo = min(columnSelectionAnchorIndex!, newActiveIndex)
            let hi = max(columnSelectionAnchorIndex!, newActiveIndex)
            selectedColumns = Set(lo...hi)
            columnSelectionActiveIndex = newActiveIndex
        } else {
            columnSelectionAnchorIndex = newActiveIndex
            columnSelectionActiveIndex = newActiveIndex
            selectedColumns = [newActiveIndex]
        }
        requestScrollReveal(columnIndex: newActiveIndex, columnDelta: columnDelta)
    }

    private func selectionBounds() -> (minRow: Int, maxRow: Int, minCol: Int, maxCol: Int)? {
        guard let active = selectedCell,
              let activeRow = rows.firstIndex(where: { $0.id == active.rowID }) else { return nil }
        let anchor = selectionAnchor ?? active
        guard let anchorRow = rows.firstIndex(where: { $0.id == anchor.rowID }) else { return nil }

        return (
            minRow: min(activeRow, anchorRow),
            maxRow: max(activeRow, anchorRow),
            minCol: min(active.columnIndex, anchor.columnIndex),
            maxCol: max(active.columnIndex, anchor.columnIndex)
        )
    }

    private func isCellInSelection(
        columnIndex: Int,
        displayIndex: Int,
        bounds: (minRow: Int, maxRow: Int, minCol: Int, maxCol: Int)?
    ) -> Bool {
        if selectedColumns.contains(columnIndex) { return true }
        guard selectedRows.isEmpty, let bounds else { return false }
        return displayIndex >= bounds.minRow && displayIndex <= bounds.maxRow
            && columnIndex >= bounds.minCol && columnIndex <= bounds.maxCol
    }

    private func isRowInSelection(_ displayIndex: Int, bounds: (minRow: Int, maxRow: Int, minCol: Int, maxCol: Int)?) -> Bool {
        guard selectedRows.isEmpty, let bounds else { return false }
        return displayIndex >= bounds.minRow && displayIndex <= bounds.maxRow
    }

    @ViewBuilder
    private func dataContent(layout: GridLayout) -> some View {
        let bounds = selectionBounds()
        let findMatches = findMatchAddresses()
        let start = min(rowWindowStart, max(0, rows.count))
        let end = min(rows.count, start + layout.visibleRowCapacity)
        // Windowed VStack: only ~visible+overscan rows exist as views (LazyVStack inside
        // nested ScrollViews still materialises too much on macOS and feels jerky).
        VStack(alignment: .leading, spacing: 0) {
            if start > 0 {
                Color.clear.frame(height: CGFloat(start) * rowHeight)
            }
            ForEach(start..<end, id: \.self) { index in
                dataRow(
                    rows[index],
                    displayIndex: index,
                    columnWidth: layout.columnWidth,
                    selectionBounds: bounds,
                    findMatches: findMatches
                )
            }
            if end < rows.count {
                Color.clear.frame(height: CGFloat(rows.count - end) * rowHeight)
            }
            ForEach(0..<layout.fillerRowCount, id: \.self) { fillerIndex in
                fillerRow(
                    displayIndex: rows.count + fillerIndex,
                    columnWidth: layout.columnWidth
                )
            }
        }
        .transaction { $0.animation = nil }
    }

    private func gridLayout(for size: CGSize) -> GridLayout {
        let columnCount = document.table.columns.count
        let dataWidth = rowNumberWidth + CGFloat(columnCount) * minColumnWidth

        let columnWidth: CGFloat
        let contentWidth: CGFloat
        if columnCount > 0, dataWidth <= size.width {
            contentWidth = size.width
            columnWidth = (size.width - rowNumberWidth) / CGFloat(columnCount)
        } else {
            columnWidth = minColumnWidth
            contentWidth = max(dataWidth, size.width)
        }

        let scrollAreaHeight = max(0, size.height - headerHeight)
        let visibleDataRows = max(0, Int(floor(scrollAreaHeight / rowHeight)))
        let fillerRowCount = max(0, visibleDataRows - rows.count)
        let dataRowsHeight = CGFloat(rows.count) * rowHeight
        let dataContentHeight = max(
            dataRowsHeight,
            CGFloat(rows.count + fillerRowCount) * rowHeight,
            scrollAreaHeight
        )
        // Visible rows + generous overscan on both sides (observer uses the same overscan).
        let visibleRowCapacity = max(visibleDataRows, 1) + 32

        return GridLayout(
            columnWidth: columnWidth,
            contentWidth: contentWidth,
            dataContentHeight: dataContentHeight,
            fillerRowCount: fillerRowCount,
            visibleRowCapacity: visibleRowCapacity
        )
    }

    // MARK: - Header

    private func headerRow(columnWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            gridCell(width: rowNumberWidth, height: headerHeight, borders: .all) {
                Text("#")
                    .font(.system(size: fontSize, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.horizontal, 6)
            }
            .background(Color(nsColor: .controlBackgroundColor))

            ForEach(Array(document.table.columns.enumerated()), id: \.element.id) { index, _ in
                gridCell(width: columnWidth, height: headerHeight, borders: [.top, .bottom, .trailing]) {
                    Text(document.table.displayName(ofColumn: index))
                        .font(.system(size: fontSize, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 6)
                }
                .background(headerBackground(for: index), ignoresSafeAreaEdges: [])
                .id(columnScrollID(index))
                .contentShape(Rectangle())
                .onTapGesture {
                    releaseFindBarFocus()
                    commitEditing()
                    selectedCell = nil
                    selectionAnchor = nil
                    clearRowSelection()
                    columnSelectionAnchorIndex = index
                    columnSelectionActiveIndex = index
                    selectedColumns = [index]
                }
            }
        }
    }

    // MARK: - Data row

    private func dataRow(
        _ row: CSVRow,
        displayIndex: Int,
        columnWidth: CGFloat,
        selectionBounds: (minRow: Int, maxRow: Int, minCol: Int, maxCol: Int)?,
        findMatches: Set<CellAddress>
    ) -> some View {
        HStack(spacing: 0) {
            rowNumberCell(for: row, rowIndex: displayIndex, selectionBounds: selectionBounds)

            ForEach(Array(document.table.columns.enumerated()), id: \.element.id) { columnIndex, _ in
                dataCell(
                    row: row,
                    columnIndex: columnIndex,
                    displayIndex: displayIndex,
                    columnWidth: columnWidth,
                    selectionBounds: selectionBounds,
                    findMatches: findMatches
                )
            }
        }
        .frame(height: rowHeight)
        .id(row.id)
    }

    private func fillerRow(displayIndex: Int, columnWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            gridCell(width: rowNumberWidth, height: rowHeight, borders: [.bottom, .trailing]) {
                Color.clear
            }
            .background(Color(nsColor: .controlBackgroundColor))

            ForEach(Array(document.table.columns.enumerated()), id: \.element.id) { _ in
                gridCell(width: columnWidth, height: rowHeight, borders: [.bottom, .trailing]) {
                    Color.clear
                }
                .background(alternatingRowColor(displayIndex))
            }
        }
        .frame(height: rowHeight)
    }

    private func rowNumberCell(
        for row: CSVRow,
        rowIndex: Int,
        selectionBounds: (minRow: Int, maxRow: Int, minCol: Int, maxCol: Int)?
    ) -> some View {
        let isRowSelected = selectedRows.contains(row.id)
        let isRowHighlighted = isRowInSelection(rowIndex, bounds: selectionBounds)

        return gridCell(width: rowNumberWidth, height: rowHeight, borders: [.bottom, .trailing]) {
            Text("\(rowNumbers[row.id] ?? 0)")
                .font(.system(size: fontSize))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.horizontal, 6)
        }
        .background {
            if isRowSelected || isRowHighlighted {
                Color.selectionFill
            } else {
                Color(nsColor: .controlBackgroundColor)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            releaseFindBarFocus()
            commitEditing()
            selectedCell = nil
            selectionAnchor = nil
            clearColumnSelection()
            selectRowNumbers(
                rowID: row.id,
                rowIndex: rowIndex,
                extendSelection: NSEvent.modifierFlags.contains(.shift)
            )
        }
    }

    private func selectRowNumbers(rowID: CSVRow.ID, rowIndex: Int, extendSelection: Bool) {
        if extendSelection, let anchorIndex = rowSelectionAnchorIndex ?? rowSelectionActiveIndex {
            let lo = min(anchorIndex, rowIndex)
            let hi = max(anchorIndex, rowIndex)
            selectedRows = Set(rows[lo...hi].map(\.id))
            rowSelectionActiveIndex = rowIndex
        } else {
            rowSelectionAnchorIndex = rowIndex
            rowSelectionActiveIndex = rowIndex
            selectedRows = [rowID]
        }
    }

    private func selectAllRows() {
        guard !rows.isEmpty else { return }
        commitEditing()
        selectedCell = nil
        selectionAnchor = nil
        clearColumnSelection()
        // Displayed rows only: with the find filter on, ⌘A then Delete must not remove hidden rows.
        selectedRows = Set(rows.map(\.id))
        rowSelectionAnchorIndex = 0
        rowSelectionActiveIndex = max(0, rows.count - 1)
    }

    private func dataCell(
        row: CSVRow,
        columnIndex: Int,
        displayIndex: Int,
        columnWidth: CGFloat,
        selectionBounds: (minRow: Int, maxRow: Int, minCol: Int, maxCol: Int)?,
        findMatches: Set<CellAddress>
    ) -> some View {
        let address = CellAddress(rowID: row.id, columnIndex: columnIndex)
        let value = columnIndex < row.cells.count ? row.cells[columnIndex] : ""

        return GridDataCell(
            address: address,
            value: value,
            displayIndex: displayIndex,
            columnWidth: columnWidth,
            rowHeight: rowHeight,
            fontSize: fontSize,
            isCellSelected: isCellInSelection(
                columnIndex: columnIndex,
                displayIndex: displayIndex,
                bounds: selectionBounds
            ),
            isRowSelected: selectedRows.contains(row.id),
            isColumnSelected: selectedColumns.contains(columnIndex),
            isEditing: editingCell == address,
            isFindMatch: findMatches.contains(address),
            selectAllOnFocus: editingSelectAllOnFocus,
            editingText: $editingText,
            onSelect: {
                selectCell(address)
            },
            onEdit: {
                editCell(address, value: value, extendSelectionAnchor: isCellInSelection(
                    columnIndex: columnIndex,
                    displayIndex: displayIndex,
                    bounds: selectionBounds
                ))
            },
            onCommitEdit: { commitEditing(advancingToNextColumn: false) },
            onSubmitEdit: { commitEditing(advancingToNextColumn: true) },
            onCancelEdit: cancelEditing,
            contextMenu: {
                AnyView(
                    Group {
                        Button("Copy") { copySelection() }
                        Button("Cut") { cutSelection() }
                        Button("Paste") { pasteSelection() }
                        Divider()
                        contextMenuContent(row.id, columnIndex)
                    }
                )
            }
        )
        .equatable()
    }

    private func releaseFindBarFocus() {
        onReleaseFindBarFocus?()
    }

    private func selectCell(_ address: CellAddress) {
        releaseFindBarFocus()
        commitEditing()
        clearRowSelection()
        clearColumnSelection()
        selectedCell = address
        selectionAnchor = address
    }

    private func editCell(_ address: CellAddress, value: String, extendSelectionAnchor: Bool) {
        releaseFindBarFocus()
        commitEditing(advancingToNextColumn: false)
        clearRowSelection()
        clearColumnSelection()
        selectedCell = address
        if !extendSelectionAnchor {
            selectionAnchor = address
        }
        editingSelectAllOnFocus = true
        editingOriginalText = value
        editingText = value
        editingCell = address
        CellEditorFocusBridge.focusActiveEditor(selectAll: true)
    }

    // MARK: - Styling

    private func headerBackground(for columnIndex: Int) -> Color {
        if selectedColumns.contains(columnIndex) {
            return Color.selectionFill
        }
        guard selectedRows.isEmpty, selectedColumns.isEmpty, let bounds = selectionBounds() else {
            return Color(nsColor: .controlBackgroundColor)
        }
        if columnIndex >= bounds.minCol && columnIndex <= bounds.maxCol {
            return Color.selectionFill
        }
        return Color(nsColor: .controlBackgroundColor)
    }

    private func cellBackground(
        displayIndex: Int,
        isRowSelected: Bool,
        isCellSelected: Bool,
        isFindMatch: Bool,
        isEditing: Bool
    ) -> Color {
        if isFindMatch {
            return Color.yellow.opacity(0.35)
        }
        if isRowSelected || (isCellSelected && !isEditing) {
            return .selectionFill
        }
        return alternatingRowColor(displayIndex)
    }

    private func alternatingRowColor(_ index: Int) -> Color {
        let colors = NSColor.alternatingContentBackgroundColors
        guard colors.count >= 2 else {
            return Color(nsColor: .textBackgroundColor)
        }
        return Color(nsColor: colors[index % 2])
    }

    private func findMatchAddresses() -> Set<CellAddress> {
        guard !highlightText.isEmpty else { return [] }
        let options: String.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
        var matches = Set<CellAddress>()
        for row in rows {
            for (columnIndex, cell) in row.cells.enumerated() {
                if cell.range(of: highlightText, options: options) != nil {
                    matches.insert(CellAddress(rowID: row.id, columnIndex: columnIndex))
                }
            }
        }
        return matches
    }

    private func isMultiCellSelection() -> Bool {
        guard let bounds = selectionBounds() else { return false }
        return bounds.minRow != bounds.maxRow || bounds.minCol != bounds.maxCol
    }

    private func deleteSelection() {
        commitEditing()
        if !selectedRows.isEmpty {
            let idsToRemove = selectedRows
            document.removeRows(ids: idsToRemove, undoManager: undoManager)
            selectedRows.removeAll()
            rowSelectionAnchorIndex = nil
            rowSelectionActiveIndex = nil
            selectedCell = nil
            selectionAnchor = nil
            editingCell = nil
            editingText = ""
        } else if !selectedColumns.isEmpty {
            document.clearColumns(at: selectedColumns, undoManager: undoManager)
        } else if isMultiCellSelection(), let bounds = selectionBounds() {
            clearCells(in: bounds)
        } else if let cell = selectedCell {
            document.setCell(
                rowID: cell.rowID,
                columnIndex: cell.columnIndex,
                value: "",
                undoManager: undoManager
            )
            if editingCell == cell {
                editingText = ""
                editingCell = nil
            }
        }
    }

    private func cutSelection() {
        copySelection()
        cutCopiedSelection()
    }

    private func cutCopiedSelection() {
        if !selectedColumns.isEmpty {
            document.clearColumns(at: selectedColumns, undoManager: undoManager)
        } else if !selectedRows.isEmpty {
            let idsToRemove = selectedRows
            document.removeRows(ids: idsToRemove, undoManager: undoManager)
            selectedRows.removeAll()
            rowSelectionAnchorIndex = nil
            rowSelectionActiveIndex = nil
            selectedCell = nil
            selectionAnchor = nil
        } else if let bounds = selectionBounds(), isMultiCellSelection() {
            clearCells(in: bounds)
        } else if let cell = selectedCell {
            document.setCell(
                rowID: cell.rowID,
                columnIndex: cell.columnIndex,
                value: "",
                undoManager: undoManager
            )
            if editingCell == cell {
                editingText = ""
                editingCell = nil
            }
        }
    }

    private func clearCells(in bounds: (minRow: Int, maxRow: Int, minCol: Int, maxCol: Int)) {
        document.modify("Clear Cells", undoManager: undoManager) { table in
            for rowIndex in bounds.minRow...bounds.maxRow {
                let rowID = rows[rowIndex].id
                guard let docRowIndex = table.rows.firstIndex(where: { $0.id == rowID }) else { continue }
                for colIndex in bounds.minCol...bounds.maxCol {
                    Self.ensureCell(at: colIndex, in: docRowIndex, table: &table)
                    table.rows[docRowIndex].cells[colIndex] = ""
                }
            }
        }
        if let editing = editingCell,
           let rowIndex = rows.firstIndex(where: { $0.id == editing.rowID }),
           rowIndex >= bounds.minRow, rowIndex <= bounds.maxRow,
           editing.columnIndex >= bounds.minCol, editing.columnIndex <= bounds.maxCol {
            editingText = ""
            editingCell = nil
        }
    }

    private func copySelection() {
        commitEditing()
        let text: String?
        if !selectedColumns.isEmpty {
            let sortedColumns = selectedColumns.sorted()
            let lines = document.table.rows.map { row in
                sortedColumns.map { colIndex in
                    colIndex < row.cells.count ? row.cells[colIndex] : ""
                }.joined(separator: "\t")
            }
            text = lines.joined(separator: "\n")
        } else if !selectedRows.isEmpty {
            let lines = document.table.rows
                .filter { selectedRows.contains($0.id) }
                .map { $0.cells.joined(separator: "\t") }
            text = lines.isEmpty ? nil : lines.joined(separator: "\n")
        } else if let bounds = selectionBounds() {
            let lines = (bounds.minRow...bounds.maxRow).map { rowIndex in
                let rowID = rows[rowIndex].id
                let cells = document.table.rows.first { $0.id == rowID }?.cells ?? []
                return (bounds.minCol...bounds.maxCol).map { colIndex in
                    colIndex < cells.count ? cells[colIndex] : ""
                }.joined(separator: "\t")
            }
            text = lines.joined(separator: "\n")
        } else if let cell = selectedCell {
            text = document.cell(rowID: cell.rowID, columnIndex: cell.columnIndex)
        } else {
            return
        }
        guard let text else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString(text, forType: .string)
    }

    private func pasteSelection() {
        commitEditing()
        guard let pasteboardString = NSPasteboard.general.string(forType: .string) else { return }
        let grid = Self.parsePasteboardGrid(pasteboardString)
        guard !grid.isEmpty else { return }

        if Self.isSingleValueGrid(grid), !selectedColumns.isEmpty {
            let value = grid[0][0]
            let sortedColumns = selectedColumns.sorted()
            document.modify("Paste", undoManager: undoManager) { table in
                for colIndex in sortedColumns {
                    guard table.columns.indices.contains(colIndex) else { continue }
                    for rowIndex in table.rows.indices {
                        guard table.rows[rowIndex].cells.indices.contains(colIndex) else { continue }
                        table.rows[rowIndex].cells[colIndex] = value
                    }
                }
            }
            return
        }

        if Self.isSingleValueGrid(grid), let bounds = selectionBounds(), isMultiCellSelection() {
            let value = grid[0][0]
            document.modify("Paste", undoManager: undoManager) { table in
                for rowIndex in bounds.minRow...bounds.maxRow {
                    let rowID = rows[rowIndex].id
                    guard let docRowIndex = table.rows.firstIndex(where: { $0.id == rowID }) else { continue }
                    for colIndex in bounds.minCol...bounds.maxCol {
                        Self.ensureCell(at: colIndex, in: docRowIndex, table: &table)
                        table.rows[docRowIndex].cells[colIndex] = value
                    }
                }
            }
            return
        }

        if !Self.isSingleValueGrid(grid), let bounds = selectionBounds(), isMultiCellSelection() {
            pasteGrid(grid, into: bounds)
            return
        }

        if !Self.isSingleValueGrid(grid), !selectedColumns.isEmpty {
            let sortedColumns = selectedColumns.sorted()
            guard let startColumn = sortedColumns.first else { return }
            pasteGrid(grid, startingAtRowID: rows.first?.id ?? document.table.rows.first?.id, columnIndex: startColumn)
            return
        }

        if !Self.isSingleValueGrid(grid), !selectedRows.isEmpty,
           let startRowID = rows.first(where: { selectedRows.contains($0.id) })?.id
            ?? document.table.rows.first(where: { selectedRows.contains($0.id) })?.id {
            pasteGrid(grid, startingAtRowID: startRowID, columnIndex: 0)
            return
        }

        let startRowID: CSVRow.ID
        let startColumnIndex: Int
        if let bounds = selectionBounds() {
            startRowID = rows[bounds.minRow].id
            startColumnIndex = bounds.minCol
        } else if let cell = selectedCell {
            startRowID = cell.rowID
            startColumnIndex = cell.columnIndex
        } else if let rowID = document.table.rows.first(where: { selectedRows.contains($0.id) })?.id {
            startRowID = rowID
            startColumnIndex = 0
        } else {
            return
        }
        guard let startRowIndex = document.rowIndex(of: startRowID) else { return }
        pasteGrid(grid, startingAtDocumentRowIndex: startRowIndex, columnIndex: startColumnIndex)
    }

    private func pasteGrid(
        _ grid: [[String]],
        into bounds: (minRow: Int, maxRow: Int, minCol: Int, maxCol: Int)
    ) {
        let gridHeight = grid.count
        let gridWidth = grid.map(\.count).max() ?? 0
        guard gridHeight > 0, gridWidth > 0 else { return }

        var lastAddress: CellAddress?

        document.modify("Paste", undoManager: undoManager) { table in
            for displayRow in bounds.minRow...bounds.maxRow {
                guard rows.indices.contains(displayRow) else { continue }
                let rowID = rows[displayRow].id
                guard let docRowIndex = table.rows.firstIndex(where: { $0.id == rowID }) else { continue }
                let rowOffset = displayRow - bounds.minRow
                for colIndex in bounds.minCol...bounds.maxCol {
                    let colOffset = colIndex - bounds.minCol
                    let pasteRow = grid[rowOffset % gridHeight]
                    guard !pasteRow.isEmpty else { continue }
                    let value = pasteRow[colOffset % pasteRow.count]
                    Self.ensureCell(at: colIndex, in: docRowIndex, table: &table)
                    table.rows[docRowIndex].cells[colIndex] = value
                    lastAddress = CellAddress(rowID: rowID, columnIndex: colIndex)
                }
            }
        }

        updateSelectionAfterPaste(
            lastAddress: lastAddress,
            anchorRowID: rows[bounds.minRow].id,
            anchorColumnIndex: bounds.minCol
        )
    }

    private func pasteGrid(
        _ grid: [[String]],
        startingAtRowID startRowID: CSVRow.ID?,
        columnIndex startColumnIndex: Int
    ) {
        guard let startRowID, let startRowIndex = document.rowIndex(of: startRowID) else { return }
        pasteGrid(grid, startingAtDocumentRowIndex: startRowIndex, columnIndex: startColumnIndex)
    }

    private func pasteGrid(
        _ grid: [[String]],
        startingAtDocumentRowIndex startRowIndex: Int,
        columnIndex startColumnIndex: Int
    ) {
        var lastAddress: CellAddress?

        document.modify("Paste", undoManager: undoManager) { table in
            // Grow the table to the right so pasted values beyond the last column stay visible
            // and every row keeps the same number of fields as the header.
            let neededColumns = startColumnIndex + (grid.map(\.count).max() ?? 0)
            while table.columns.count < neededColumns {
                table.insertColumn(at: table.columns.count)
            }
            for (rowOffset, pasteRow) in grid.enumerated() {
                let targetRowIndex = startRowIndex + rowOffset
                while targetRowIndex >= table.rows.count {
                    table.insertRow(at: table.rows.count)
                }
                for (colOffset, value) in pasteRow.enumerated() {
                    let targetColIndex = startColumnIndex + colOffset
                    Self.ensureCell(at: targetColIndex, in: targetRowIndex, table: &table)
                    table.rows[targetRowIndex].cells[targetColIndex] = value
                    lastAddress = CellAddress(
                        rowID: table.rows[targetRowIndex].id,
                        columnIndex: targetColIndex
                    )
                }
            }
        }

        updateSelectionAfterPaste(
            lastAddress: lastAddress,
            anchorRowID: document.table.rows[startRowIndex].id,
            anchorColumnIndex: startColumnIndex
        )
    }

    private func updateSelectionAfterPaste(
        lastAddress: CellAddress?,
        anchorRowID: CSVRow.ID,
        anchorColumnIndex: Int
    ) {
        guard let lastAddress else { return }
        selectedCell = lastAddress
        selectionAnchor = CellAddress(rowID: anchorRowID, columnIndex: anchorColumnIndex)
        clearRowSelection()
        clearColumnSelection()
    }

    private static func ensureCell(at columnIndex: Int, in rowIndex: Int, table: inout CSVTable) {
        guard table.rows.indices.contains(rowIndex) else { return }
        while table.rows[rowIndex].cells.count <= columnIndex {
            table.rows[rowIndex].cells.append("")
        }
    }

    private static func isSingleValueGrid(_ grid: [[String]]) -> Bool {
        grid.count == 1 && grid[0].count == 1
    }

    private static func parsePasteboardGrid(_ text: String) -> [[String]] {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.count > 1, lines.last?.isEmpty == true, normalized.hasSuffix("\n") {
            lines.removeLast()
        }
        return lines.map { line in
            line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        }
    }

    private func commitEditing(advancingToNextColumn: Bool = false) {
        guard let editing = editingCell else { return }
        let value = editingText

        if advancingToNextColumn && isMultiCellSelection(), let bounds = selectionBounds() {
            // Bounds are display indices (filtered rows); map each one to its document row by id.
            let rowIDs = Set((bounds.minRow...bounds.maxRow).compactMap { rows.indices.contains($0) ? rows[$0].id : nil })
            document.modify("Edit Cells", undoManager: undoManager) { table in
                for rowIndex in table.rows.indices where rowIDs.contains(table.rows[rowIndex].id) {
                    for colIndex in bounds.minCol...bounds.maxCol {
                        guard table.rows[rowIndex].cells.indices.contains(colIndex) else { continue }
                        table.rows[rowIndex].cells[colIndex] = value
                    }
                }
            }
        } else {
            document.setCell(
                rowID: editing.rowID,
                columnIndex: editing.columnIndex,
                value: value,
                undoManager: undoManager
            )
        }
        editingCell = nil

        let current = CellAddress(rowID: editing.rowID, columnIndex: editing.columnIndex)
        if advancingToNextColumn {
            let nextIndex = editing.columnIndex + 1
            if nextIndex < document.table.columns.count {
                selectedCell = CellAddress(rowID: editing.rowID, columnIndex: nextIndex)
            } else {
                selectedCell = current
            }
            selectionAnchor = selectedCell
        } else {
            selectedCell = current
        }
        selectedRows.removeAll()
        clearColumnSelection()
    }

    // MARK: - Grid chrome

    private func gridCell<Content: View>(
        width: CGFloat,
        height: CGFloat,
        borders: GridBorders,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .frame(width: width, height: height, alignment: .leading)
            .overlay {
                GridLines(borders: borders)
            }
    }
}

// MARK: - Equatable data cell (avoids redrawing the whole grid on selection)

private struct GridDataCell<ContextMenu: View>: View, Equatable {
    let address: CellAddress
    let value: String
    let displayIndex: Int
    let columnWidth: CGFloat
    let rowHeight: CGFloat
    let fontSize: CGFloat
    let isCellSelected: Bool
    let isRowSelected: Bool
    let isColumnSelected: Bool
    let isEditing: Bool
    let isFindMatch: Bool
    let selectAllOnFocus: Bool
    @Binding var editingText: String
    let onSelect: () -> Void
    let onEdit: () -> Void
    let onCommitEdit: () -> Void
    let onSubmitEdit: () -> Void
    let onCancelEdit: () -> Void
    @ViewBuilder let contextMenu: () -> ContextMenu

    static func == (lhs: GridDataCell<ContextMenu>, rhs: GridDataCell<ContextMenu>) -> Bool {
        lhs.address == rhs.address
            && lhs.value == rhs.value
            && lhs.displayIndex == rhs.displayIndex
            && lhs.columnWidth == rhs.columnWidth
            && lhs.rowHeight == rhs.rowHeight
            && lhs.fontSize == rhs.fontSize
            && lhs.isCellSelected == rhs.isCellSelected
            && lhs.isRowSelected == rhs.isRowSelected
            && lhs.isColumnSelected == rhs.isColumnSelected
            && lhs.isEditing == rhs.isEditing
            && lhs.isFindMatch == rhs.isFindMatch
            && lhs.selectAllOnFocus == rhs.selectAllOnFocus
    }

    @State private var editingFieldHadFocus = false

    var body: some View {
        Group {
            if isEditing {
                CellEditorTextField(
                    text: $editingText,
                    fontSize: fontSize,
                    selectAllOnFocus: selectAllOnFocus,
                    onSubmit: onSubmitEdit,
                    onCancel: onCancelEdit,
                    onFocusChange: { focused in
                        if focused {
                            editingFieldHadFocus = true
                        } else if isEditing, editingFieldHadFocus {
                            onCommitEdit()
                        }
                    }
                )
                .padding(.horizontal, 6)
            } else {
                Text(value)
                    .font(.system(size: fontSize))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 6)
            }
        }
        .frame(width: columnWidth, height: rowHeight, alignment: .leading)
        .overlay { GridLines(borders: [.bottom, .trailing]) }
        .background(backgroundColor)
        .contentShape(Rectangle())
        .contextMenu { contextMenu() }
        .onChange(of: isEditing) { _, nowEditing in
            if !nowEditing {
                editingFieldHadFocus = false
            }
        }
    }

    private var backgroundColor: Color {
        if isFindMatch {
            Color.yellow.opacity(0.35)
        } else if isRowSelected || isColumnSelected || (isCellSelected && !isEditing) {
            .selectionFill
        } else {
            alternatingRowColor(displayIndex)
        }
    }

    private func alternatingRowColor(_ index: Int) -> Color {
        let colors = NSColor.alternatingContentBackgroundColors
        guard colors.count >= 2 else { return Color(nsColor: .textBackgroundColor) }
        return Color(nsColor: colors[index % 2])
    }
}

// MARK: - Cell editor focus bridge

private enum CellEditorFocusBridge {
    static weak var field: NSTextField?

    static func focusActiveEditor(selectAll: Bool, attempt: Int = 0) {
        DispatchQueue.main.async {
            guard let field, let window = field.window else {
                if attempt < 30 {
                    focusActiveEditor(selectAll: selectAll, attempt: attempt + 1)
                }
                return
            }
            window.makeFirstResponder(field)
            guard let editor = field.currentEditor() else {
                if attempt < 30 {
                    focusActiveEditor(selectAll: selectAll, attempt: attempt + 1)
                }
                return
            }
            let length = (field.stringValue as NSString).length
            if selectAll {
                editor.selectedRange = NSRange(location: 0, length: length)
            } else {
                editor.selectedRange = NSRange(location: length, length: 0)
            }
        }
    }
}

// MARK: - Cell editor (cursor at end when typing to edit)

private struct CellEditorTextField: NSViewRepresentable {
    @Binding var text: String
    let fontSize: CGFloat
    let selectAllOnFocus: Bool
    let onSubmit: () -> Void
    let onCancel: () -> Void
    let onFocusChange: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = NSFont.systemFont(ofSize: fontSize)
        field.lineBreakMode = .byTruncatingTail
        field.delegate = context.coordinator
        field.stringValue = text
        CellEditorFocusBridge.field = field
        CellEditorFocusBridge.focusActiveEditor(selectAll: selectAllOnFocus)
        return field
    }

    static func dismantleNSView(_ nsView: NSTextField, coordinator: Coordinator) {
        if CellEditorFocusBridge.field === nsView {
            CellEditorFocusBridge.field = nil
        }
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        context.coordinator.parent = self
        CellEditorFocusBridge.field = nsView

        if nsView.font?.pointSize != fontSize {
            nsView.font = NSFont.systemFont(ofSize: fontSize)
        }

        if nsView.stringValue != text {
            nsView.stringValue = text
        }

        if nsView.window?.firstResponder !== nsView.currentEditor() {
            CellEditorFocusBridge.focusActiveEditor(selectAll: selectAllOnFocus && !context.coordinator.didApplyInitialSelection)
        } else if !context.coordinator.didApplyInitialSelection, let editor = nsView.currentEditor() {
            let length = (nsView.stringValue as NSString).length
            if selectAllOnFocus {
                editor.selectedRange = NSRange(location: 0, length: length)
            } else {
                editor.selectedRange = NSRange(location: length, length: 0)
            }
            context.coordinator.didApplyInitialSelection = true
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: CellEditorTextField
        var didApplyInitialSelection = false
        var didCancel = false

        init(parent: CellEditorTextField) {
            self.parent = parent
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func controlTextDidBeginEditing(_ obj: Notification) {
            didApplyInitialSelection = true
            parent.onFocusChange(true)
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            didApplyInitialSelection = false
            if didCancel {
                didCancel = false
                return
            }
            parent.onFocusChange(false)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                parent.onSubmit()
                return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                didCancel = true
                parent.onCancel()
                control.abortEditing()
                return true
            }
            return false
        }
    }
}

// MARK: - Grid keyboard (Return / type to edit selected cell)

private enum GridKeyboardNavigationMode {
    case none
    case cell
    case row
    case column
}

private struct GridKeyboardHandler: NSViewRepresentable {
    let navigationMode: GridKeyboardNavigationMode
    let onEnter: () -> Void
    let onType: (String) -> Void
    let onMoveUp: (Bool) -> Void
    let onMoveDown: (Bool) -> Void
    let onMoveLeft: (Bool) -> Void
    let onMoveRight: (Bool) -> Void
    let onMoveRowUp: (Bool) -> Void
    let onMoveRowDown: (Bool) -> Void
    let onMoveColumnLeft: (Bool) -> Void
    let onMoveColumnRight: (Bool) -> Void
    let onCopy: () -> Void
    let onPaste: () -> Void
    let onCut: () -> Void
    let onDelete: () -> Void
    let onSelectAll: () -> Void

    func makeNSView(context: Context) -> GridKeyboardNSView {
        let view = GridKeyboardNSView()
        updateKeyboardView(view)
        DispatchQueue.main.async {
            guard view.window != nil else { return }
            view.window?.makeFirstResponder(view)
        }
        return view
    }

    func updateNSView(_ nsView: GridKeyboardNSView, context: Context) {
        updateKeyboardView(nsView)
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            guard !GridKeyboardNSView.shouldDeferToTextInput(in: window) else { return }
            if window.firstResponder !== nsView {
                window.makeFirstResponder(nsView)
            }
        }
    }

    private func updateKeyboardView(_ nsView: GridKeyboardNSView) {
        nsView.navigationMode = navigationMode
        nsView.onEnter = onEnter
        nsView.onType = onType
        nsView.onMoveUp = onMoveUp
        nsView.onMoveDown = onMoveDown
        nsView.onMoveLeft = onMoveLeft
        nsView.onMoveRight = onMoveRight
        nsView.onMoveRowUp = onMoveRowUp
        nsView.onMoveRowDown = onMoveRowDown
        nsView.onMoveColumnLeft = onMoveColumnLeft
        nsView.onMoveColumnRight = onMoveColumnRight
        nsView.onCopy = onCopy
        nsView.onPaste = onPaste
        nsView.onCut = onCut
        nsView.onDelete = onDelete
        nsView.onSelectAll = onSelectAll
    }
}

private final class GridKeyboardNSView: NSView {
    var navigationMode: GridKeyboardNavigationMode = .none
    var onEnter: (() -> Void)?
    var onType: ((String) -> Void)?
    var onMoveUp: ((Bool) -> Void)?
    var onMoveDown: ((Bool) -> Void)?
    var onMoveLeft: ((Bool) -> Void)?
    var onMoveRight: ((Bool) -> Void)?
    var onMoveRowUp: ((Bool) -> Void)?
    var onMoveRowDown: ((Bool) -> Void)?
    var onMoveColumnLeft: ((Bool) -> Void)?
    var onMoveColumnRight: ((Bool) -> Void)?
    var onCopy: (() -> Void)?
    var onPaste: (() -> Void)?
    var onCut: (() -> Void)?
    var onDelete: (() -> Void)?
    var onSelectAll: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func cancelOperation(_ sender: Any?) {}

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        handleDeleteKey(event) || handleArrowKey(event) || handleCommandKey(event)
    }

    override func keyDown(with event: NSEvent) {
        if handleDeleteKey(event) { return }
        if handleCommandKey(event) { return }
        if handleArrowKey(event) { return }

        guard navigationMode == .cell else {
            super.keyDown(with: event)
            return
        }

        if !event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command),
           !event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.control),
           let text = Self.typableText(from: event) {
            onType?(text)
            return
        }

        super.keyDown(with: event)
    }

    @discardableResult
    private func handleDeleteKey(_ event: NSEvent) -> Bool {
        guard navigationMode != .none else { return false }
        guard !event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command) else {
            return false
        }
        switch event.keyCode {
        case 51, 117: // Backspace, Forward Delete
            onDelete?()
            return true
        default:
            return false
        }
    }

    private func handleCommandKey(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command) else {
            return false
        }
        if Self.shouldDeferToTextInput(in: window) { return false }
        switch event.keyCode {
        case 0:
            if navigationMode == .row {
                onSelectAll?()
                return true
            }
            return false
        case 7: onCut?(); return true
        case 8: onCopy?(); return true
        case 9: onPaste?(); return true
        default: return false
        }
    }

    static func shouldDeferToTextInput(in window: NSWindow?) -> Bool {
        guard let responder = window?.firstResponder else { return false }
        if responder is NSTextView || responder is NSTextField { return true }
        guard let view = responder as? NSView else { return false }
        var current: NSView? = view
        while let candidate = current {
            if candidate is NSTextField || candidate is NSTextView { return true }
            current = candidate.superview
        }
        return false
    }

    @discardableResult
    private func handleArrowKey(_ event: NSEvent) -> Bool {
        let extendSelection = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .contains(.shift)

        switch navigationMode {
        case .none:
            return false
        case .row:
            switch event.keyCode {
            case 53: return true
            case 126: onMoveRowUp?(extendSelection); return true
            case 125: onMoveRowDown?(extendSelection); return true
            default: return false
            }
        case .column:
            switch event.keyCode {
            case 53: return true
            case 123: onMoveColumnLeft?(extendSelection); return true
            case 124: onMoveColumnRight?(extendSelection); return true
            default: return false
            }
        case .cell:
            switch event.keyCode {
            case 53: return true
            case 36, 76: onEnter?(); return true
            case 126: onMoveUp?(extendSelection); return true
            case 125: onMoveDown?(extendSelection); return true
            case 123: onMoveLeft?(extendSelection); return true
            case 124: onMoveRight?(extendSelection); return true
            default: return false
            }
        }
    }

    private static func typableText(from event: NSEvent) -> String? {
        guard !Self.isNavigationKey(event) else { return nil }
        // `characters`, not `charactersIgnoringModifiers`: the latter drops Option, so ⌥ò typed
        // "ò" instead of "@" on an Italian keyboard.
        guard let characters = event.characters, !characters.isEmpty else { return nil }
        let isTypable = characters.unicodeScalars.allSatisfy { scalar in
            // Control characters and the private-use range AppKit uses for function keys (F1, Home…).
            !CharacterSet.controlCharacters.contains(scalar) && !(0xF700...0xF8FF).contains(scalar.value)
        }
        return isTypable ? characters : nil
    }

    private static func isNavigationKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 123, 124, 125, 126, 115, 119, 116, 121: return true // arrows, home, end, page up/down
        default: return false
        }
    }
}

// MARK: - Scroll reveal (keep keyboard selection visible)

private struct GridScrollMetrics: Equatable {
    let rowHeight: CGFloat
    let headerHeight: CGFloat
    let rowNumberWidth: CGFloat
    let columnWidth: CGFloat
    let contentWidth: CGFloat
    let contentHeight: CGFloat
    let frozenHeader: Bool
}

private struct GridScrollRevealBridge: NSViewRepresentable {
    let token: Int
    let rowIndex: Int?
    let columnIndex: Int?
    let rowDelta: Int
    let columnDelta: Int
    let metrics: GridScrollMetrics

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> GridScrollRevealNSView {
        GridScrollRevealNSView()
    }

    func updateNSView(_ nsView: GridScrollRevealNSView, context: Context) {
        guard token > 0, token != context.coordinator.lastProcessedToken else { return }
        context.coordinator.lastProcessedToken = token
        nsView.reveal(
            rowIndex: rowIndex,
            columnIndex: columnIndex,
            rowDelta: rowDelta,
            columnDelta: columnDelta,
            metrics: metrics
        )
    }

    final class Coordinator {
        var lastProcessedToken = 0
    }
}

private final class GridScrollRevealNSView: NSView {
    private var revealGeneration = 0

    override var isHidden: Bool {
        get { true }
        set {}
    }

    func reveal(
        rowIndex: Int?,
        columnIndex: Int?,
        rowDelta: Int,
        columnDelta: Int,
        metrics: GridScrollMetrics
    ) {
        revealGeneration += 1
        let generation = revealGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, generation == self.revealGeneration else { return }
            let scrollViews = Self.findScrollViews(from: self)
            guard !scrollViews.isEmpty else { return }

            let verticalScrollView = scrollViews[0]
            let horizontalScrollView = scrollViews.count > 1 ? scrollViews[scrollViews.count - 1] : scrollViews[0]

            if let rowIndex {
                Self.revealRow(
                    rowIndex: rowIndex,
                    columnIndex: columnIndex,
                    in: verticalScrollView,
                    horizontalScrollView: horizontalScrollView,
                    rowDelta: rowDelta,
                    columnDelta: columnDelta,
                    metrics: metrics
                )
            } else if let columnIndex {
                Self.revealColumn(
                    columnIndex: columnIndex,
                    in: horizontalScrollView,
                    columnDelta: columnDelta,
                    metrics: metrics
                )
            }
        }
    }

    private static func revealRow(
        rowIndex: Int,
        columnIndex: Int?,
        in verticalScrollView: NSScrollView,
        horizontalScrollView: NSScrollView,
        rowDelta: Int,
        columnDelta: Int,
        metrics: GridScrollMetrics
    ) {
        let clipView = verticalScrollView.contentView
        let visible = clipView.documentVisibleRect
        let flipped = verticalScrollView.documentView?.isFlipped ?? true
        let topInset = topScrollInset(for: verticalScrollView, metrics: metrics)

        let rowRect = rowRect(rowIndex: rowIndex, metrics: metrics, flipped: flipped)
        let revealRect: NSRect
        if let columnIndex {
            let columnLeading = metrics.rowNumberWidth + CGFloat(columnIndex) * metrics.columnWidth
            revealRect = NSRect(
                x: columnLeading,
                y: rowRect.minY,
                width: metrics.columnWidth,
                height: rowRect.height
            )
        } else {
            revealRect = NSRect(
                x: visible.minX,
                y: rowRect.minY,
                width: visible.width,
                height: rowRect.height
            )
        }

        if let origin = scrollOrigin(
            visible: visible,
            revealRect: NSRect(x: visible.minX, y: revealRect.minY, width: visible.width, height: revealRect.height),
            topInset: topInset,
            rowDelta: rowDelta,
            columnDelta: 0,
            metrics: metrics
        ) {
            clipView.scroll(to: NSPoint(x: visible.origin.x, y: origin.y))
            verticalScrollView.reflectScrolledClipView(clipView)
        }

        if let columnIndex, horizontalScrollView !== verticalScrollView {
            revealColumn(columnIndex: columnIndex, in: horizontalScrollView, columnDelta: columnDelta, metrics: metrics)
        } else if let columnIndex {
            let hClip = verticalScrollView.contentView
            let hVisible = hClip.documentVisibleRect
            if let origin = scrollOrigin(
                visible: hVisible,
                revealRect: revealRect,
                topInset: topInset,
                rowDelta: 0,
                columnDelta: columnDelta,
                metrics: metrics
            ) {
                hClip.scroll(to: origin)
                verticalScrollView.reflectScrolledClipView(hClip)
            }
        }
    }

    private static func revealColumn(
        columnIndex: Int,
        in scrollView: NSScrollView,
        columnDelta: Int,
        metrics: GridScrollMetrics
    ) {
        let clipView = scrollView.contentView
        let visible = clipView.documentVisibleRect
        let flipped = scrollView.documentView?.isFlipped ?? true
        let columnRect = columnRect(columnIndex: columnIndex, metrics: metrics, flipped: flipped)
        let revealRect = NSRect(
            x: columnRect.minX,
            y: visible.minY,
            width: columnRect.width,
            height: visible.height
        )

        guard let origin = scrollOrigin(
            visible: visible,
            revealRect: revealRect,
            topInset: 0,
            rowDelta: 0,
            columnDelta: columnDelta,
            metrics: metrics
        ) else { return }

        clipView.scroll(to: NSPoint(x: origin.x, y: visible.origin.y))
        scrollView.reflectScrolledClipView(clipView)
    }

    /// Computes a new scroll origin only along the axis being navigated, avoiding vertical/horizontal fight.
    private static func scrollOrigin(
        visible: NSRect,
        revealRect: NSRect,
        topInset: CGFloat,
        rowDelta: Int,
        columnDelta: Int,
        metrics: GridScrollMetrics
    ) -> NSPoint? {
        var origin = visible.origin
        var changed = false

        // Vertical — only when moving up/down, or when jumping to a match (both deltas zero).
        let adjustVertical = rowDelta != 0 || (rowDelta == 0 && columnDelta == 0)
        if adjustVertical {
            if rowDelta >= 0, revealRect.maxY > visible.maxY {
                origin.y = revealRect.maxY - visible.height
                changed = true
            } else if rowDelta <= 0, revealRect.minY < visible.minY + topInset {
                origin.y = max(0, revealRect.minY - topInset)
                changed = true
            }
        } else if revealRect.maxY > visible.maxY {
            // Horizontal navigation: correct vertical drift only if the row left the viewport entirely.
            origin.y = revealRect.maxY - visible.height
            changed = true
        } else if revealRect.minY < visible.minY {
            origin.y = max(0, revealRect.minY)
            changed = true
        }

        // Horizontal — only when moving left/right, or when jumping to a match.
        let adjustHorizontal = columnDelta != 0 || (rowDelta == 0 && columnDelta == 0)
        if adjustHorizontal {
            if columnDelta >= 0, revealRect.maxX > visible.maxX {
                origin.x = revealRect.maxX - visible.width
                changed = true
            } else if columnDelta <= 0, revealRect.minX < visible.minX {
                origin.x = revealRect.minX
                changed = true
            }
        } else if revealRect.maxX > visible.maxX {
            // Vertical navigation: nudge horizontally only if the column left the viewport.
            origin.x = revealRect.maxX - visible.width
            changed = true
        } else if revealRect.minX < visible.minX {
            origin.x = revealRect.minX
            changed = true
        }

        guard changed else { return nil }

        origin.x = max(0, min(origin.x, max(0, metrics.contentWidth - visible.width)))
        origin.y = max(0, min(origin.y, max(0, metrics.contentHeight - visible.height)))
        return origin
    }

    /// Area actually visible to the user at the top (excludes toolbar/title bar overlap).
    private static func topScrollInset(for scrollView: NSScrollView, metrics: GridScrollMetrics) -> CGFloat {
        let headerAllowance = metrics.frozenHeader ? 0 : metrics.headerHeight
        var inset: CGFloat = headerAllowance

        guard let window = scrollView.window else { return inset }

        let layoutTop = window.contentLayoutRect.maxY
        let clipView = scrollView.contentView
        let clipTop = clipView.convert(NSPoint(x: 0, y: clipView.bounds.height), to: nil).y
        let scrollTop = scrollView.convert(NSPoint(x: 0, y: scrollView.bounds.height), to: nil).y
        inset += max(0, max(clipTop, scrollTop) - layoutTop)

        if inset <= headerAllowance, let contentView = window.contentView {
            inset += contentView.safeAreaInsets.top
        }

        // Cap so inset does not fluctuate wildly between successive scroll steps.
        return min(inset, headerAllowance + 56)
    }

    private static func findScrollViews(from view: NSView) -> [NSScrollView] {
        var result: [NSScrollView] = []
        var seen = Set<ObjectIdentifier>()
        var current: NSView? = view
        while let candidate = current {
            if let scrollView = candidate.enclosingScrollView {
                let id = ObjectIdentifier(scrollView)
                if !seen.contains(id) {
                    seen.insert(id)
                    result.append(scrollView)
                }
            }
            current = candidate.superview
        }
        return result
    }

    private static func findScrollView(from view: NSView) -> NSScrollView? {
        findScrollViews(from: view).first
    }

    private static func rowRect(rowIndex: Int, metrics: GridScrollMetrics, flipped: Bool) -> NSRect {
        let rowTop = metrics.frozenHeader
            ? CGFloat(rowIndex) * metrics.rowHeight
            : metrics.headerHeight + CGFloat(rowIndex) * metrics.rowHeight
        if flipped {
            return NSRect(x: 0, y: rowTop, width: metrics.contentWidth, height: metrics.rowHeight)
        }
        let rowBottom = metrics.contentHeight - (metrics.frozenHeader ? 0 : metrics.headerHeight)
            - CGFloat(rowIndex + 1) * metrics.rowHeight
        return NSRect(x: 0, y: rowBottom, width: metrics.contentWidth, height: metrics.rowHeight)
    }

    private static func columnRect(columnIndex: Int, metrics: GridScrollMetrics, flipped: Bool) -> NSRect {
        let columnLeading = metrics.rowNumberWidth + CGFloat(columnIndex) * metrics.columnWidth
        return NSRect(x: columnLeading, y: 0, width: metrics.columnWidth, height: metrics.contentHeight)
    }

    private static func cellRect(
        rowIndex: Int,
        columnIndex: Int,
        metrics: GridScrollMetrics,
        flipped: Bool
    ) -> NSRect {
        let row = rowRect(rowIndex: rowIndex, metrics: metrics, flipped: flipped)
        let column = columnRect(columnIndex: columnIndex, metrics: metrics, flipped: flipped)
        return NSRect(x: column.minX, y: row.minY, width: column.width, height: row.height)
    }
}

// MARK: - Grid lines

private struct GridLines: View {
    let borders: GridBorders

    var body: some View {
        // Single Canvas stroke is much cheaper than GeometryReader + Rectangles per cell.
        Canvas { context, size in
            var path = Path()
            if borders.contains(.top) {
                path.move(to: CGPoint(x: 0, y: 0.5))
                path.addLine(to: CGPoint(x: size.width, y: 0.5))
            }
            if borders.contains(.bottom) {
                path.move(to: CGPoint(x: 0, y: size.height - 0.5))
                path.addLine(to: CGPoint(x: size.width, y: size.height - 0.5))
            }
            if borders.contains(.leading) {
                path.move(to: CGPoint(x: 0.5, y: 0))
                path.addLine(to: CGPoint(x: 0.5, y: size.height))
            }
            if borders.contains(.trailing) {
                path.move(to: CGPoint(x: size.width - 0.5, y: 0))
                path.addLine(to: CGPoint(x: size.width - 0.5, y: size.height))
            }
            context.stroke(path, with: .color(Color(nsColor: .gridColor)), lineWidth: 1)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Scroll window observer (drives row virtualisation)

struct GridScrollOffsetObserver: NSViewRepresentable {
    let rowHeight: CGFloat
    let overscan: Int
    let rowCount: Int
    @Binding var windowStart: Int

    func makeNSView(context: Context) -> GridScrollOffsetObserverView {
        let view = GridScrollOffsetObserverView()
        view.rowHeight = rowHeight
        view.overscan = overscan
        view.rowCount = rowCount
        view.onWindowStart = { windowStart = $0 }
        return view
    }

    func updateNSView(_ nsView: GridScrollOffsetObserverView, context: Context) {
        let heightChanged = abs(nsView.rowHeight - rowHeight) > 0.1
        nsView.rowHeight = rowHeight
        nsView.overscan = overscan
        nsView.rowCount = rowCount
        nsView.onWindowStart = { windowStart = $0 }
        if heightChanged {
            nsView.resetWindowTracking()
        }
        nsView.emitIfNeeded()
    }
}

final class GridScrollOffsetObserverView: NSView {
    var rowHeight: CGFloat = 22
    var overscan = 16
    var rowCount = 0
    var onWindowStart: ((Int) -> Void)?

    private var observedClip: NSClipView?
    private var lastStart = -1

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func resetWindowTracking() {
        lastStart = -1
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        detach()
        guard let clip = enclosingScrollView?.contentView else { return }
        clip.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(boundsDidChange),
            name: NSView.boundsDidChangeNotification,
            object: clip
        )
        observedClip = clip
        emitIfNeeded()
    }

    override func removeFromSuperview() {
        detach()
        super.removeFromSuperview()
    }

    private func detach() {
        if let observedClip {
            NotificationCenter.default.removeObserver(
                self,
                name: NSView.boundsDidChangeNotification,
                object: observedClip
            )
        }
        observedClip = nil
    }

    @objc private func boundsDidChange(_ notification: Notification) {
        emitIfNeeded()
    }

    func emitIfNeeded() {
        let y = enclosingScrollView?.contentView.bounds.origin.y ?? 0
        let height = max(rowHeight, 1)
        let rawStart = max(0, Int(floor(y / height)) - overscan)
        let clamped: Int
        if rowCount <= 0 {
            clamped = 0
        } else {
            clamped = min(rawStart, rowCount)
        }
        guard clamped != lastStart else { return }
        lastStart = clamped
        onWindowStart?(clamped)
    }
}

// MARK: - One click monitor for the whole grid (avoids per-cell NSView)

/// Handles left-click select / double-click edit without creating an AppKit view per cell.
/// Clicks on the row-number gutter pass through so existing SwiftUI handlers keep working.
struct GridClickMonitor: NSViewRepresentable {
    let rowCount: Int
    let columnCount: Int
    let rowHeight: CGFloat
    let rowNumberWidth: CGFloat
    let columnWidth: CGFloat
    let isEditing: Bool
    let onSelectCell: (Int, Int) -> Void
    let onEditCell: (Int, Int) -> Void

    func makeNSView(context: Context) -> GridClickMonitorView {
        let view = GridClickMonitorView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ nsView: GridClickMonitorView, context: Context) {
        nsView.rowCount = rowCount
        nsView.columnCount = columnCount
        nsView.rowHeight = rowHeight
        nsView.rowNumberWidth = rowNumberWidth
        nsView.columnWidth = columnWidth
        nsView.isEditing = isEditing
        nsView.onSelectCell = onSelectCell
        nsView.onEditCell = onEditCell
    }
}

final class GridClickMonitorView: NSView {
    var rowCount = 0
    var columnCount = 0
    var rowHeight: CGFloat = 22
    var rowNumberWidth: CGFloat = 44
    var columnWidth: CGFloat = 140
    var isEditing = false
    var onSelectCell: ((Int, Int) -> Void)?
    var onEditCell: ((Int, Int) -> Void)?

    private var monitor: Any?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeMonitor()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            guard let self else { return event }
            return self.handle(event) ? nil : event
        }
    }

    override func removeFromSuperview() {
        removeMonitor()
        super.removeFromSuperview()
    }

    private func removeMonitor() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard let window, event.window === window, !isEditing else { return false }
        // Let the cell text editor keep receiving clicks while active.
        if let field = CellEditorFocusBridge.field,
           let editor = field.currentEditor(),
           window.firstResponder === editor {
            return false
        }

        guard let scrollView = enclosingScrollView,
              let documentView = scrollView.documentView else { return false }

        let pointInDoc = documentView.convert(event.locationInWindow, from: nil)
        guard documentView.bounds.contains(pointInDoc) else { return false }

        // Row-number gutter: leave to SwiftUI (row selection / Shift+click).
        if pointInDoc.x < rowNumberWidth { return false }

        let dataWidth = rowNumberWidth + CGFloat(columnCount) * columnWidth
        guard pointInDoc.x < dataWidth else { return false }

        let rowIndex: Int
        if documentView.isFlipped {
            rowIndex = Int(floor(pointInDoc.y / rowHeight))
        } else {
            rowIndex = Int(floor((documentView.bounds.height - pointInDoc.y) / rowHeight))
        }
        guard rowIndex >= 0, rowIndex < rowCount else { return false }

        let columnIndex = Int(floor((pointInDoc.x - rowNumberWidth) / columnWidth))
        guard columnIndex >= 0, columnIndex < columnCount else { return false }

        if event.clickCount >= 2 {
            onEditCell?(rowIndex, columnIndex)
        } else {
            onSelectCell?(rowIndex, columnIndex)
        }
        return true
    }
}

// MARK: - Selection fill

private extension Color {
    static let selectionFill = Color(nsColor: .selectedContentBackgroundColor).opacity(0.35)
}
