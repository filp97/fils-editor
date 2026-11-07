//
//  ToolbarIcons.swift
//  fil's editor
//

import AppKit
import SwiftUI

enum ToolbarIcons {
    static let addRow = makeIcon(kind: .addRow)
    static let insertRowBelow = makeIcon(kind: .insertRowBelow)
    static let addColumn = makeIcon(kind: .addColumn)
    static let deleteColumn = makeIcon(kind: .deleteColumn)
    static let deleteSelection = makeIcon(kind: .deleteSelection)

    static var addRowImage: Image { Image(nsImage: addRow) }
    static var insertRowBelowImage: Image { Image(nsImage: insertRowBelow) }
    static var addColumnImage: Image { Image(nsImage: addColumn) }
    static var deleteColumnImage: Image { Image(nsImage: deleteColumn) }
    static var deleteSelectionImage: Image { Image(nsImage: deleteSelection) }

    private static let greyBorder = NSColor(srgbRed: 0.62, green: 0.64, blue: 0.66, alpha: 1)
    private static let blueBorder = NSColor(srgbRed: 0.30, green: 0.52, blue: 0.82, alpha: 1)
    private static let blueFill = NSColor(srgbRed: 0.30, green: 0.52, blue: 0.82, alpha: 0.20)
    private static let redBorder = NSColor(srgbRed: 0.84, green: 0.24, blue: 0.22, alpha: 1)
    private static let redFill = NSColor(srgbRed: 0.84, green: 0.24, blue: 0.22, alpha: 0.18)

    private enum IconKind { case addRow, insertRowBelow, addColumn, deleteColumn, deleteSelection }

    private enum GridStyle { case existing, highlight, remove }

    private static func makeIcon(kind: IconKind) -> NSImage {
        let pixelSize: CGFloat = 40
        let pointSize: CGFloat = 20

        let image = NSImage(size: NSSize(width: pointSize, height: pointSize), flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.saveGState()
            context.scaleBy(x: rect.width / pixelSize, y: rect.height / pixelSize)
            switch kind {
            case .addRow: drawAddRow()
            case .insertRowBelow: drawInsertRowBelow()
            case .addColumn: drawAddColumn()
            case .deleteColumn: drawDeleteColumn()
            case .deleteSelection: drawDeleteSelection()
            }
            context.restoreGState()
            return true
        }
        image.isTemplate = false
        return image
    }

    // MARK: - Row icons

    private static func drawAddRow() {
        let gridX: CGFloat = 4
        let gridW: CGFloat = 32
        let rowH: CGFloat = 12
        let gap: CGFloat = 2
        let bottomY: CGFloat = 4
        let topY = bottomY + rowH + gap

        drawGridRow(x: gridX, y: topY, width: gridW, height: rowH, columns: 3, style: .existing)
        drawGridRow(x: gridX, y: bottomY, width: gridW, height: rowH, columns: 3, style: .highlight)
    }

    private static func drawInsertRowBelow() {
        let gridX: CGFloat = 4
        let gridW: CGFloat = 32
        let rowH: CGFloat = 9
        let gap: CGFloat = 2
        let bottomY: CGFloat = 3
        let middleY = bottomY + rowH + gap
        let topY = middleY + rowH + gap

        drawGridRow(x: gridX, y: bottomY, width: gridW, height: rowH, columns: 3, style: .existing)
        drawGridRow(x: gridX, y: middleY, width: gridW, height: rowH, columns: 3, style: .highlight)
        drawGridRow(x: gridX, y: topY, width: gridW, height: rowH, columns: 3, style: .existing)
    }

    private static func drawDeleteSelection() {
        let bounds = CGRect(x: 4, y: 4, width: 32, height: 32)
        let inset: CGFloat = 2
        let x1 = bounds.minX + inset
        let x2 = bounds.maxX - inset
        let y1 = bounds.minY + inset
        let y2 = bounds.maxY - inset

        let path = NSBezierPath()
        path.lineWidth = 4.5
        path.lineCapStyle = .round
        path.move(to: CGPoint(x: x1, y: y1))
        path.line(to: CGPoint(x: x2, y: y2))
        path.move(to: CGPoint(x: x2, y: y1))
        path.line(to: CGPoint(x: x1, y: y2))

        redBorder.setStroke()
        path.stroke()
    }

    // MARK: - Column icons

    private static func drawAddColumn() {
        let gridY: CGFloat = 4
        let gridH: CGFloat = 32
        let colW: CGFloat = 12
        let gap: CGFloat = 2
        let rows = 3
        let leftX: CGFloat = 4
        let rightX = leftX + colW + gap

        drawGridColumn(x: leftX, y: gridY, width: colW, height: gridH, rows: rows, style: .existing)
        drawGridColumn(x: rightX, y: gridY, width: colW, height: gridH, rows: rows, style: .highlight)
    }

    /// Same layout as add-column: grey | highlighted — but red instead of blue.
    private static func drawDeleteColumn() {
        let gridY: CGFloat = 4
        let gridH: CGFloat = 32
        let colW: CGFloat = 12
        let gap: CGFloat = 2
        let rows = 3
        let leftX: CGFloat = 4
        let rightX = leftX + colW + gap

        drawGridColumn(x: leftX, y: gridY, width: colW, height: gridH, rows: rows, style: .existing)
        drawGridColumn(x: rightX, y: gridY, width: colW, height: gridH, rows: rows, style: .remove)
    }

    // MARK: - Drawing

    private static func drawGridRow(
        x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat,
        columns: Int, style: GridStyle
    ) {
        let rect = CGRect(x: x, y: y, width: width, height: height)
        fillAndStroke(rect: rect, style: style)

        let colW = width / CGFloat(columns)
        let border = borderColor(for: style)
        border.setStroke()
        for i in 1..<columns {
            let lineX = x + colW * CGFloat(i)
            let path = NSBezierPath()
            path.lineWidth = style == .existing ? 0.9 : 1.2
            path.move(to: CGPoint(x: lineX, y: y + 1))
            path.line(to: CGPoint(x: lineX, y: y + height - 1))
            path.stroke()
        }
    }

    private static func drawGridColumn(
        x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat,
        rows: Int, style: GridStyle
    ) {
        let rect = CGRect(x: x, y: y, width: width, height: height)
        fillAndStroke(rect: rect, style: style)

        let rowH = height / CGFloat(rows)
        let border = borderColor(for: style)
        border.setStroke()
        for i in 1..<rows {
            let lineY = y + rowH * CGFloat(i)
            let path = NSBezierPath()
            path.lineWidth = style == .existing ? 0.9 : 1.2
            path.move(to: CGPoint(x: x + 1, y: lineY))
            path.line(to: CGPoint(x: x + width - 1, y: lineY))
            path.stroke()
        }
    }

    private static func fillAndStroke(rect: CGRect, style: GridStyle) {
        if style != .existing {
            fillColor(for: style).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5).fill()
        }
        borderColor(for: style).setStroke()
        let outline = NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5)
        outline.lineWidth = style == .existing ? 1.1 : 1.4
        outline.stroke()
    }

    private static func fillColor(for style: GridStyle) -> NSColor {
        switch style {
        case .existing: greyBorder
        case .highlight: blueFill
        case .remove: redFill
        }
    }

    private static func borderColor(for style: GridStyle) -> NSColor {
        switch style {
        case .existing: greyBorder
        case .highlight: blueBorder
        case .remove: redBorder
        }
    }
}

struct AddRowToolbarIcon: View {
    var body: some View {
        ToolbarIcons.addRowImage
            .interpolation(.high)
            .antialiased(true)
            .frame(width: 20, height: 20)
    }
}

struct InsertRowBelowToolbarIcon: View {
    var body: some View {
        ToolbarIcons.insertRowBelowImage
            .interpolation(.high)
            .antialiased(true)
            .frame(width: 20, height: 20)
    }
}

struct AddColumnToolbarIcon: View {
    var body: some View {
        ToolbarIcons.addColumnImage
            .interpolation(.high)
            .antialiased(true)
            .frame(width: 20, height: 20)
    }
}

struct DeleteSelectionToolbarIcon: View {
    var body: some View {
        ToolbarIcons.deleteSelectionImage
            .interpolation(.high)
            .antialiased(true)
            .frame(width: 20, height: 20)
    }
}

struct DeleteColumnToolbarIcon: View {
    var body: some View {
        ToolbarIcons.deleteColumnImage
            .interpolation(.high)
            .antialiased(true)
            .frame(width: 20, height: 20)
    }
}
