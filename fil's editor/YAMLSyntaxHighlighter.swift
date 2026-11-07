//
//  YAMLSyntaxHighlighter.swift
//  fil's editor
//

import AppKit

/// Line-based YAML colouring over UTF-16 units (same palette as `JSONSyntaxHighlighter`).
/// It is a colouring heuristic, not a parser: validity comes from `YAMLTools.validate`.
/// Handles comments, document markers, sequence dashes, keys (plain or quoted), quoted and
/// plain scalars, numbers/literals, anchors/aliases, tags, flow collections and the body of
/// block scalars (`|` / `>`).
enum YAMLSyntaxHighlighter {
    private static let keyColor = NSColor.systemBlue
    private static let stringColor = NSColor.systemRed
    private static let numberColor = NSColor.systemOrange
    private static let literalColor = NSColor.systemPink
    private static let punctuationColor = NSColor.secondaryLabelColor
    private static let commentColor = NSColor.systemGray
    private static let anchorColor = NSColor.systemPurple
    private static let tagColor = NSColor.systemTeal

    private static let space: UInt16 = 32
    private static let tab: UInt16 = 9
    private static let newline: UInt16 = 10
    private static let carriageReturn: UInt16 = 13
    private static let hash: UInt16 = 35        // #
    private static let colon: UInt16 = 58       // :
    private static let dash: UInt16 = 45        // -
    private static let dot: UInt16 = 46         // .
    private static let doubleQuote: UInt16 = 34
    private static let singleQuote: UInt16 = 39
    private static let backslash: UInt16 = 92
    private static let ampersand: UInt16 = 38   // &
    private static let asterisk: UInt16 = 42    // *
    private static let bang: UInt16 = 33        // !
    private static let pipe: UInt16 = 124       // |
    private static let greater: UInt16 = 62     // >
    private static let comma: UInt16 = 44
    private static let openBracket: UInt16 = 91, closeBracket: UInt16 = 93
    private static let openBrace: UInt16 = 123, closeBrace: UInt16 = 125

    private static let literals: Set<String> = [
        "true", "True", "TRUE", "false", "False", "FALSE",
        "null", "Null", "NULL", "~",
        "yes", "Yes", "YES", "no", "No", "NO", "on", "On", "ON", "off", "Off", "OFF",
    ]
    private static let specialNumbers: Set<String> = [
        ".inf", ".Inf", ".INF", "+.inf", "+.Inf", "+.INF", "-.inf", "-.Inf", "-.INF",
        ".nan", ".NaN", ".NAN",
    ]

    static func highlight(_ textStorage: NSTextStorage, baseAttributes: [NSAttributedString.Key: Any]) {
        let units = Array(textStorage.string.utf16)
        guard units.count <= JSONSyntaxHighlighter.maximumLength else { return }

        textStorage.beginEditing()
        textStorage.addAttributes(baseAttributes, range: NSRange(location: 0, length: units.count))
        var scanner = Scanner(units: units) { start, end, color in
            guard end > start else { return }
            textStorage.addAttribute(.foregroundColor, value: color, range: NSRange(location: start, length: end - start))
        }
        scanner.run()
        textStorage.endEditing()
    }

    private struct Scanner {
        let units: [UInt16]
        let paint: (Int, Int, NSColor) -> Void
        /// Indentation of the line that opened a block scalar; deeper lines are its text.
        var blockScalarParentIndent: Int?

        init(units: [UInt16], paint: @escaping (Int, Int, NSColor) -> Void) {
            self.units = units
            self.paint = paint
        }

        mutating func run() {
            var lineStart = 0
            while lineStart < units.count {
                var lineEnd = lineStart
                while lineEnd < units.count, units[lineEnd] != newline { lineEnd += 1 }
                var contentEnd = lineEnd
                if contentEnd > lineStart, units[contentEnd - 1] == carriageReturn { contentEnd -= 1 }
                scanLine(from: lineStart, to: contentEnd)
                lineStart = lineEnd + 1
            }
        }

        private mutating func scanLine(from lineStart: Int, to end: Int) {
            var i = skipSpaces(from: lineStart, to: end)
            let indent = i - lineStart
            let isBlank = i >= end

            if let parentIndent = blockScalarParentIndent {
                if isBlank { return }
                if indent > parentIndent {
                    paint(i, end, stringColor)
                    return
                }
                blockScalarParentIndent = nil
            }
            if isBlank { return }

            if units[i] == hash {
                paint(i, end, commentColor)
                return
            }

            // Document markers "---" / "..." at column 0.
            if indent == 0, i + 3 <= end,
               (units[i] == dash && units[i + 1] == dash && units[i + 2] == dash)
                || (units[i] == dot && units[i + 1] == dot && units[i + 2] == dot),
               i + 3 == end || isSpace(units[i + 3]) {
                paint(i, i + 3, punctuationColor)
                i = skipSpaces(from: i + 3, to: end)
                if i >= end { return }
            }

            // Sequence entries ("- ", possibly nested: "- - x").
            while i < end, units[i] == dash, i + 1 == end || isSpace(units[i + 1]) {
                paint(i, i + 1, punctuationColor)
                i = skipSpaces(from: i + 1, to: end)
            }
            guard i < end else { return }

            var parentIndent = indent
            if let colonIndex = keyColon(from: i, to: end) {
                paint(i, colonIndex, keyColor)
                paint(colonIndex, colonIndex + 1, punctuationColor)
                parentIndent = i - lineStart
                i = colonIndex + 1
            }
            scanValue(from: i, to: end, parentIndent: parentIndent)
        }

        /// Index of the ':' ending a block-mapping key that starts at `start`, if any.
        private func keyColon(from start: Int, to end: Int) -> Int? {
            let first = units[start]
            if first == openBracket || first == openBrace || first == hash { return nil }
            var j = start
            if first == doubleQuote || first == singleQuote {
                j = endOfQuoted(from: start, to: end)
                j = skipSpaces(from: j, to: end)
                guard j < end, units[j] == colon, j + 1 == end || isSpace(units[j + 1]) else { return nil }
                return j
            }
            while j < end {
                let unit = units[j]
                if unit == colon, j + 1 == end || isSpace(units[j + 1]) { return j }
                if unit == hash, j > start, isSpace(units[j - 1]) { return nil }
                j += 1
            }
            return nil
        }

        private mutating func scanValue(from start: Int, to end: Int, parentIndent: Int) {
            var i = skipSpaces(from: start, to: end)
            var flowDepth = 0
            while i < end {
                let unit = units[i]
                if isSpace(unit) {
                    i += 1
                    continue
                }
                switch unit {
                case hash where i == start || isSpace(units[i - 1]):
                    paint(i, end, commentColor)
                    return
                case doubleQuote, singleQuote:
                    let stringEnd = endOfQuoted(from: i, to: end)
                    let next = skipSpaces(from: stringEnd, to: end)
                    let isFlowKey = flowDepth > 0 && next < end && units[next] == colon
                    paint(i, stringEnd, isFlowKey ? keyColor : stringColor)
                    i = stringEnd
                case ampersand, asterisk:
                    let tokenEnd = endOfToken(from: i, to: end)
                    paint(i, tokenEnd, anchorColor)
                    i = tokenEnd
                case bang:
                    let tokenEnd = endOfToken(from: i, to: end)
                    paint(i, tokenEnd, tagColor)
                    i = tokenEnd
                case pipe where flowDepth == 0, greater where flowDepth == 0:
                    var indicatorEnd = i + 1
                    while indicatorEnd < end, isBlockIndicatorModifier(units[indicatorEnd]) { indicatorEnd += 1 }
                    paint(i, indicatorEnd, punctuationColor)
                    blockScalarParentIndent = parentIndent
                    i = indicatorEnd
                case openBracket, openBrace:
                    flowDepth += 1
                    paint(i, i + 1, punctuationColor)
                    i += 1
                case closeBracket, closeBrace:
                    flowDepth = max(0, flowDepth - 1)
                    paint(i, i + 1, punctuationColor)
                    i += 1
                case comma where flowDepth > 0:
                    paint(i, i + 1, punctuationColor)
                    i += 1
                case colon where flowDepth > 0:
                    paint(i, i + 1, punctuationColor)
                    i += 1
                default:
                    let scalarEnd = endOfPlainScalar(from: i, to: end, inFlow: flowDepth > 0)
                    var trimmedEnd = scalarEnd
                    while trimmedEnd > i, isSpace(units[trimmedEnd - 1]) { trimmedEnd -= 1 }
                    let next = skipSpaces(from: scalarEnd, to: end)
                    if flowDepth > 0, next < end, units[next] == colon {
                        paint(i, trimmedEnd, keyColor)
                    } else {
                        paint(i, trimmedEnd, color(forPlainScalar: String(decoding: units[i..<trimmedEnd], as: UTF16.self)))
                    }
                    i = max(scalarEnd, i + 1)
                }
            }
        }

        private func color(forPlainScalar text: String) -> NSColor {
            if literals.contains(text) { return literalColor }
            if isNumber(text) { return numberColor }
            return stringColor
        }

        private func isNumber(_ text: String) -> Bool {
            if specialNumbers.contains(text) { return true }
            var body = Substring(text)
            if body.hasPrefix("+") || body.hasPrefix("-") { body = body.dropFirst() }
            if body.hasPrefix("0x") { return body.count > 2 && body.dropFirst(2).allSatisfy(\.isHexDigit) }
            if body.hasPrefix("0o") { return body.count > 2 && body.dropFirst(2).allSatisfy { ("0"..."7").contains($0) } }
            guard !body.isEmpty,
                  body.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == "." || $0 == "_" || $0 == "e" || $0 == "E" || $0 == "+" || $0 == "-") }),
                  body.contains(where: \.isNumber) else { return false }
            return Double(body.replacingOccurrences(of: "_", with: "")) != nil
        }

        /// End (exclusive) of a quoted scalar starting at `start`; stops at the end of the line
        /// when the closing quote is on a later line.
        private func endOfQuoted(from start: Int, to end: Int) -> Int {
            let quote = units[start]
            var j = start + 1
            while j < end {
                let unit = units[j]
                if quote == doubleQuote, unit == backslash {
                    j += 2
                    continue
                }
                if unit == quote {
                    if quote == singleQuote, j + 1 < end, units[j + 1] == singleQuote {
                        j += 2 // '' is an escaped quote
                        continue
                    }
                    return j + 1
                }
                j += 1
            }
            return min(j, end)
        }

        private func endOfToken(from start: Int, to end: Int) -> Int {
            var j = start + 1
            while j < end, !isSpace(units[j]), !isFlowIndicator(units[j]) { j += 1 }
            return j
        }

        private func endOfPlainScalar(from start: Int, to end: Int, inFlow: Bool) -> Int {
            var j = start
            while j < end {
                let unit = units[j]
                if unit == hash, j > start, isSpace(units[j - 1]) { return j }
                if inFlow {
                    if isFlowIndicator(unit) { return j }
                    if unit == colon, j + 1 == end || isSpace(units[j + 1]) || isFlowIndicator(units[j + 1]) { return j }
                }
                j += 1
            }
            return j
        }

        private func skipSpaces(from start: Int, to end: Int) -> Int {
            var j = start
            while j < end, isSpace(units[j]) { j += 1 }
            return j
        }

        private func isSpace(_ unit: UInt16) -> Bool { unit == space || unit == tab }

        private func isFlowIndicator(_ unit: UInt16) -> Bool {
            unit == comma || unit == openBracket || unit == closeBracket || unit == openBrace || unit == closeBrace
        }

        private func isBlockIndicatorModifier(_ unit: UInt16) -> Bool {
            unit == 43 || unit == dash || (49...57).contains(unit) // + - 1-9
        }
    }
}
