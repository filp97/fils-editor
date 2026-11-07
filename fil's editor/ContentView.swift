//
//  ContentView.swift
//  fil's editor
//

import SwiftUI

struct ContentView: View {
    @ObservedObject var document: CSVDocument
    @Environment(\.undoManager) private var undoManager

    @State private var selectedRows = Set<CSVRow.ID>()
    @State private var selectedColumns = Set<Int>()
    @State private var selectedCell: CellAddress?
    @State private var editingCell: CellAddress?
    @State private var editingText = ""

    // Find & replace
    @State private var showFindBar = false
    @State private var findText = ""
    @State private var replaceText = ""
    @State private var caseSensitive = false
    @State private var filterMatchingRows = false
    @State private var lastReplaceCount: Int?
    @State private var searchMatches: [CellAddress] = []
    @State private var currentMatchIndex = 0
    @State private var searchScanGeneration = 0
    @State private var isSearching = false
    @State private var scrollToSelectionToken = 0
    @State private var deleteSelectionRequest = 0
    @State private var gridZoom: CGFloat = 1
    @FocusState private var findFieldFocused: Bool
    @FocusState private var replaceFieldFocused: Bool

    // Column rename
    @State private var renamingColumnIndex: Int?
    @State private var renameText = ""
    @State private var canUndo = false
    @State private var canRedo = false

    var body: some View {
        VStack(spacing: 0) {
            if showFindBar {
                findBar
                Divider()
            }
            grid
            Divider()
            statusBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .toolbar { toolbarContent }
        .onAppear { updateUndoState() }
        .onChange(of: document.table) { _, _ in
            updateUndoState()
            refreshSearchMatches(focusFirst: false)
        }
        .onChange(of: findText) { refreshSearchMatches(focusFirst: false) }
        .onChange(of: caseSensitive) { refreshSearchMatches(focusFirst: false) }
        .alert("Rename Column", isPresented: renameAlertPresented) {
            TextField("Column name", text: $renameText)
            Button("Rename") {
                if let index = renamingColumnIndex {
                    document.renameColumn(at: index, name: renameText, undoManager: undoManager)
                }
                renamingColumnIndex = nil
            }
            Button("Cancel", role: .cancel) {
                renamingColumnIndex = nil
            }
        }
    }

    // MARK: - Grid

    private var displayedRows: [CSVRow] {
        guard filterMatchingRows, !findText.isEmpty else { return document.table.rows }
        let options: String.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
        return document.table.rows.filter { row in
            row.cells.contains { $0.range(of: findText, options: options) != nil }
        }
    }

    private var rowNumbers: [CSVRow.ID: Int] {
        Dictionary(uniqueKeysWithValues: document.table.rows.enumerated().map { ($1.id, $0 + 1) })
    }

    private var grid: some View {
        SpreadsheetGrid(
            document: document,
            rows: displayedRows,
            rowNumbers: rowNumbers,
            highlightText: showFindBar ? findText : "",
            caseSensitive: caseSensitive,
            selectedCell: $selectedCell,
            selectedRows: $selectedRows,
            selectedColumns: $selectedColumns,
            editingCell: $editingCell,
            editingText: $editingText,
            zoom: $gridZoom,
            scrollToSelectionToken: scrollToSelectionToken,
            deleteSelectionRequest: deleteSelectionRequest,
            keyboardCaptureSuppressed: findFieldFocused || replaceFieldFocused,
            onReleaseFindBarFocus: releaseFindBarFocus,
            undoManager: undoManager,
            contextMenuContent: { rowID, columnIndex in
                AnyView(cellContextMenu(rowID: rowID, columnIndex: columnIndex))
            }
        )
        .layoutPriority(1)
    }

    @ViewBuilder
    private func cellContextMenu(rowID: CSVRow.ID, columnIndex: Int) -> some View {
        Section("Row") {
            Button("Insert Row Above") {
                if let index = document.rowIndex(of: rowID),
                   let newRowID = document.insertRow(at: index, undoManager: undoManager) {
                    selectRow(newRowID)
                }
            }
            Button("Insert Row Below") {
                if let index = document.rowIndex(of: rowID),
                   let newRowID = document.insertRow(at: index + 1, undoManager: undoManager) {
                    selectRow(newRowID)
                }
            }
            Button("Duplicate Row") {
                if let newRowID = document.duplicateRow(id: rowID, undoManager: undoManager) {
                    selectRow(newRowID)
                }
            }
            Button("Delete Row", role: .destructive) {
                var ids = selectedRows.contains(rowID) ? selectedRows : [rowID]
                ids.insert(rowID)
                document.removeRows(ids: ids, undoManager: undoManager)
                selectedRows.subtract(ids)
            }
        }
        Section("Column") {
            Button("Rename Column…") {
                beginRenamingColumn(at: columnIndex)
            }
            Button("Insert Column Before") {
                document.insertColumn(at: columnIndex, undoManager: undoManager)
            }
            Button("Insert Column After") {
                document.insertColumn(at: columnIndex + 1, undoManager: undoManager)
            }
            Button("Sort Ascending") {
                document.sortRows(by: columnIndex, ascending: true, undoManager: undoManager)
            }
            Button("Sort Descending") {
                document.sortRows(by: columnIndex, ascending: false, undoManager: undoManager)
            }
            Button("Delete Column", role: .destructive) {
                document.removeColumn(at: columnIndex, undoManager: undoManager)
            }
            .disabled(document.table.columns.count <= 1)
        }
    }

    // MARK: - Find & replace bar

    private var findBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Find in document", text: $findText)
                .textFieldStyle(.roundedBorder)
                .focused($findFieldFocused)
                .frame(maxWidth: 260)
                .onSubmit { goToNextMatch() }

            Button {
                goToPreviousMatch()
            } label: {
                Image(systemName: "chevron.up")
            }
            .disabled(searchMatches.isEmpty)
            .help("Previous match (⇧⌘G)")

            Button {
                goToNextMatch()
            } label: {
                Image(systemName: "chevron.down")
            }
            .disabled(searchMatches.isEmpty)
            .help("Next match (⌘G)")

            if isSearching {
                ProgressView()
                    .controlSize(.small)
            } else if !findText.isEmpty {
                if searchMatches.isEmpty {
                    Text("No results")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(currentMatchIndex + 1) of \(searchMatches.count)")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            Divider()
                .frame(height: 20)

            TextField("Replace with", text: $replaceText)
                .textFieldStyle(.roundedBorder)
                .focused($replaceFieldFocused)
                .frame(maxWidth: 200)

            Button("Replace All") {
                lastReplaceCount = document.replaceAll(
                    find: findText,
                    with: replaceText,
                    caseSensitive: caseSensitive,
                    undoManager: undoManager
                )
                refreshSearchMatches(focusFirst: false)
            }
            .disabled(findText.isEmpty)

            Toggle("Aa", isOn: $caseSensitive)
                .toggleStyle(.button)
                .help("Match case")

            Toggle(isOn: $filterMatchingRows) {
                Image(systemName: "line.3.horizontal.decrease.circle")
            }
            .toggleStyle(.button)
            .help("Show only matching rows")

            if let count = lastReplaceCount {
                Text("^[\(count) cell](inflect: true) replaced")
                    .font(.callout)
                    .foregroundStyle(.green)
            }

            Spacer()

            Button {
                closeFindBar()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .onChange(of: findText) {
            lastReplaceCount = nil
        }
    }

    private func refreshSearchMatches(focusFirst: Bool) {
        guard !findText.isEmpty else {
            searchMatches = []
            currentMatchIndex = 0
            isSearching = false
            return
        }

        searchScanGeneration += 1
        let generation = searchScanGeneration
        let query = findText
        let caseSensitive = caseSensitive
        let rows = document.table.rows
        isSearching = true

        Task.detached(priority: .userInitiated) {
            let options: String.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
            var matches: [CellAddress] = []
            matches.reserveCapacity(256)
            for row in rows {
                for (columnIndex, cell) in row.cells.enumerated() {
                    if cell.range(of: query, options: options) != nil {
                        matches.append(CellAddress(rowID: row.id, columnIndex: columnIndex))
                    }
                }
            }

            let found = matches
            await MainActor.run {
                guard generation == searchScanGeneration else { return }
                searchMatches = found
                isSearching = false
                if found.isEmpty {
                    currentMatchIndex = 0
                } else {
                    currentMatchIndex = min(currentMatchIndex, found.count - 1)
                    if focusFirst {
                        focusMatch(at: 0)
                    }
                }
            }
        }
    }

    private func goToNextMatch() {
        guard !searchMatches.isEmpty else { return }
        let nextIndex = (currentMatchIndex + 1) % searchMatches.count
        focusMatch(at: nextIndex)
    }

    private func goToPreviousMatch() {
        guard !searchMatches.isEmpty else { return }
        let previousIndex = (currentMatchIndex - 1 + searchMatches.count) % searchMatches.count
        focusMatch(at: previousIndex)
    }

    private func focusMatch(at index: Int) {
        guard searchMatches.indices.contains(index) else { return }
        if filterMatchingRows {
            filterMatchingRows = false
        }
        editingCell = nil
        selectedRows.removeAll()
        currentMatchIndex = index
        let address = searchMatches[index]
        selectedCell = address
        scrollToSelectionToken += 1
        releaseFindBarFocus()
    }

    private func releaseFindBarFocus() {
        findFieldFocused = false
        replaceFieldFocused = false
    }

    private func openFindBar(focusField: Bool = true) {
        showFindBar = true
        if focusField {
            findFieldFocused = true
        }
        refreshSearchMatches(focusFirst: false)
    }

    private func closeFindBar() {
        showFindBar = false
        filterMatchingRows = false
        lastReplaceCount = nil
        searchMatches = []
        currentMatchIndex = 0
        isSearching = false
    }

    // MARK: - Status bar

    private var statusBar: some View {
        HStack(spacing: 16) {
            Text("^[\(document.table.rows.count) row](inflect: true)")
            Text("^[\(document.table.columns.count) column](inflect: true)")
            if !selectedRows.isEmpty {
                Text("\(selectedRows.count) selected")
                    .foregroundStyle(.tint)
            }
            if filterMatchingRows && !findText.isEmpty {
                Text("\(displayedRows.count) visible (filter on)")
                    .foregroundStyle(.orange)
            }
            if showFindBar && !findText.isEmpty && !searchMatches.isEmpty {
                Text("^[\(searchMatches.count) match](inflect: true)")
                    .foregroundStyle(.tint)
            }
            Spacer()
            zoomControl
            if document.isSpreadsheetSource {
                sheetPicker
                Text("XLSX")
                    .foregroundStyle(.secondary)
            } else {
                Text("Delimiter: \(delimiterLabel(document.table.delimiter))")
                    .foregroundStyle(.secondary)
                Text(document.table.fileEncoding.label)
                    .foregroundStyle(.secondary)
                Text(document.table.lineEnding.label)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(.bar)
    }

    @ViewBuilder
    private var sheetPicker: some View {
        if document.sheetNames.count > 1 {
            Picker("Sheet", selection: sheetSelection) {
                ForEach(Array(document.sheetNames.enumerated()), id: \.offset) { index, name in
                    Text(name).tag(index)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 180)
            .help("Switch sheet of the Excel workbook")
        } else if let only = document.sheetNames.first {
            Text(only)
                .foregroundStyle(.secondary)
                .help("Excel sheet")
        }
    }

    private var sheetSelection: Binding<Int> {
        Binding(
            get: { document.currentSheetIndex },
            set: { newIndex in
                selectedCell = nil
                selectedRows.removeAll()
                selectedColumns.removeAll()
                editingCell = nil
                document.selectSheet(at: newIndex, undoManager: undoManager)
            }
        )
    }

    private var zoomControl: some View {
        HStack(spacing: 4) {
            Button {
                gridZoom = GridZoom.zoomedOut(gridZoom)
            } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .help("Zoom out (⌘− or Ctrl −)")

            Button {
                gridZoom = 1
            } label: {
                Text("\(GridZoom.percent(gridZoom))%")
                    .monospacedDigit()
                    .frame(minWidth: 40)
            }
            .help("Reset zoom to 100% (⌘0 or Ctrl 0)")

            Button {
                gridZoom = GridZoom.zoomedIn(gridZoom)
            } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .help("Zoom in (⌘+ or Ctrl +)")
        }
        .buttonStyle(.borderless)
    }

    private func delimiterLabel(_ delimiter: Character) -> String {
        switch delimiter {
        case ",": "Comma"
        case ";": "Semicolon"
        case "\t": "Tab"
        case "|": "Pipe"
        default: String(delimiter)
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            Button {
                undoManager?.undo()
                updateUndoState()
            } label: {
                Label("Undo", systemImage: "arrow.uturn.backward")
            }
            .disabled(!canUndo)
            .help("Undo (⌘Z)")

            Button {
                undoManager?.redo()
                updateUndoState()
            } label: {
                Label("Redo", systemImage: "arrow.uturn.forward")
            }
            .disabled(!canRedo)
            .help("Redo (⇧⌘Z)")
        }

        ToolbarItemGroup {
            Button {
                appendRowAtEnd()
            } label: {
                Label {
                    Text("Add Row")
                } icon: {
                    AddRowToolbarIcon()
                }
            }
            .help("Add a row at the end of the document")

            Button {
                insertRowBelowCurrentPosition()
            } label: {
                Label {
                    Text("Insert Row Below")
                } icon: {
                    InsertRowBelowToolbarIcon()
                }
            }
            .disabled(!canInsertRowBelowCurrentPosition)
            .help("Insert a row between the current selection and the one below")

            Button {
                deleteSelectionRequest += 1
            } label: {
                Label {
                    Text("Delete Selection")
                } icon: {
                    DeleteSelectionToolbarIcon()
                }
            }
            .disabled(!hasSelection)
            .help("Delete the selection: clears the cell or removes the row")

            Button {
                document.appendColumn(undoManager: undoManager)
            } label: {
                Label {
                    Text("Add Column")
                } icon: {
                    AddColumnToolbarIcon()
                }
            }
            .help("Add a column at the end of the document")

            Menu {
                ForEach(Array(document.table.columns.enumerated()), id: \.element.id) { index, _ in
                    Button(document.table.displayName(ofColumn: index), role: .destructive) {
                        document.removeColumn(at: index, undoManager: undoManager)
                    }
                }
            } label: {
                Label {
                    Text("Delete Column")
                } icon: {
                    DeleteColumnToolbarIcon()
                }
            }
            .disabled(document.table.columns.count <= 1)
            .help("Delete a column from the document")

            columnsMenu

            optionsMenu

            Button {
                if showFindBar {
                    closeFindBar()
                } else {
                    openFindBar()
                }
            } label: {
                Label("Find", systemImage: "magnifyingglass")
            }
            .keyboardShortcut("f", modifiers: .command)
            .help("Find in document (⌘F)")

            Button {
                goToNextMatch()
            } label: {
                Label("Next", systemImage: "chevron.down")
            }
            .disabled(searchMatches.isEmpty)
            .keyboardShortcut("g", modifiers: .command)
            .help("Next match (⌘G)")

            Button {
                goToPreviousMatch()
            } label: {
                Label("Previous", systemImage: "chevron.up")
            }
            .disabled(searchMatches.isEmpty)
            .keyboardShortcut("g", modifiers: [.command, .shift])
            .help("Previous match (⇧⌘G)")
        }
    }

    private var columnsMenu: some View {
        Menu {
            ForEach(Array(document.table.columns.enumerated()), id: \.element.id) { index, _ in
                Menu(document.table.displayName(ofColumn: index)) {
                    Button("Rename…") { beginRenamingColumn(at: index) }
                    Divider()
                    Button("Insert Column Before") {
                        document.insertColumn(at: index, undoManager: undoManager)
                    }
                    Button("Insert Column After") {
                        document.insertColumn(at: index + 1, undoManager: undoManager)
                    }
                    Divider()
                    Button("Move Left") {
                        document.moveColumn(from: index, to: index - 1, undoManager: undoManager)
                    }
                    .disabled(index == 0)
                    Button("Move Right") {
                        document.moveColumn(from: index, to: index + 1, undoManager: undoManager)
                    }
                    .disabled(index == document.table.columns.count - 1)
                    Divider()
                    Button("Sort Ascending") {
                        document.sortRows(by: index, ascending: true, undoManager: undoManager)
                    }
                    Button("Sort Descending") {
                        document.sortRows(by: index, ascending: false, undoManager: undoManager)
                    }
                    Divider()
                    Button("Delete Column", role: .destructive) {
                        document.removeColumn(at: index, undoManager: undoManager)
                    }
                    .disabled(document.table.columns.count <= 1)
                }
            }
        } label: {
            Label("Columns", systemImage: "tablecells")
        }
        .help("Column operations")
    }

    private var optionsMenu: some View {
        Menu {
            Picker("Delimiter", selection: delimiterBinding) {
                Text("Comma (,)").tag(",")
                Text("Semicolon (;)").tag(";")
                Text("Tab (⇥)").tag("\t")
                Text("Pipe (|)").tag("|")
            }
            .pickerStyle(.inline)
            Divider()
            Picker("Line Ending", selection: lineEndingBinding) {
                ForEach(CSVLineEnding.allCases, id: \.self) { lineEnding in
                    Text(lineEnding.label).tag(lineEnding)
                }
            }
            .pickerStyle(.menu)
            Divider()
            Toggle("First Row as Header", isOn: headerRowBinding)
        } label: {
            Label("Options", systemImage: "gearshape")
        }
        .help("Delimiter and header")
    }

    private var lineEndingBinding: Binding<CSVLineEnding> {
        Binding(
            get: { document.table.lineEnding },
            set: { document.setLineEnding($0, undoManager: undoManager) }
        )
    }

    private var delimiterBinding: Binding<String> {
        Binding(
            get: { String(document.table.delimiter) },
            set: { newValue in
                if let delimiter = newValue.first {
                    document.setDelimiter(delimiter, undoManager: undoManager)
                }
            }
        )
    }

    private var headerRowBinding: Binding<Bool> {
        Binding(
            get: { document.table.hasHeaderRow },
            set: { document.setHasHeaderRow($0, undoManager: undoManager) }
        )
    }

    private var renameAlertPresented: Binding<Bool> {
        Binding(
            get: { renamingColumnIndex != nil },
            set: { if !$0 { renamingColumnIndex = nil } }
        )
    }

    // MARK: - Actions

    private func beginRenamingColumn(at index: Int) {
        guard document.table.columns.indices.contains(index) else { return }
        renameText = document.table.columns[index].name
        renamingColumnIndex = index
    }

    private func appendRowAtEnd() {
        if let newRowID = document.appendRow(undoManager: undoManager) {
            selectRow(newRowID)
            scrollToSelectionToken += 1
        }
    }

    private var currentSelectedRowIndex: Int? {
        if !selectedRows.isEmpty {
            // One pass over the rows: looking up each selected id separately is O(n²) after ⌘A.
            return document.table.rows.firstIndex { selectedRows.contains($0.id) }
        }
        if let cell = selectedCell {
            return document.rowIndex(of: cell.rowID)
        }
        return nil
    }

    private var canInsertRowBelowCurrentPosition: Bool {
        guard let index = currentSelectedRowIndex else { return false }
        return index < document.table.rows.count - 1
    }

    private func insertRowBelowCurrentPosition() {
        guard let index = currentSelectedRowIndex,
              index < document.table.rows.count - 1,
              let newRowID = document.insertRow(at: index + 1, undoManager: undoManager) else { return }
        selectRow(newRowID)
    }

    private var hasSelection: Bool {
        !selectedRows.isEmpty || !selectedColumns.isEmpty || selectedCell != nil
    }

    private func selectRow(_ rowID: CSVRow.ID) {
        editingCell = nil
        selectedCell = nil
        selectedRows = [rowID]
    }

    private func updateUndoState() {
        canUndo = undoManager?.canUndo ?? false
        canRedo = undoManager?.canRedo ?? false
    }
}

#Preview {
    ContentView(document: CSVDocument())
}
