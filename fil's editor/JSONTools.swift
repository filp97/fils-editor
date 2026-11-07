//
//  JSONTools.swift
//  fil's editor
//

import Foundation

nonisolated enum JSONTools {
    static func validate(_ text: String) -> TextValidationResult {
        let lines = TextValidationResult.lineCount(of: text)
        if text.allSatisfy(\.isWhitespace) {
            return TextValidationResult(status: .empty, lineCount: lines)
        }

        let data = Data(text.utf8)
        do {
            _ = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            let nsError = error as NSError
            let rawMessage = nsError.userInfo[NSDebugDescriptionErrorKey] as? String ?? nsError.localizedDescription
            var line: Int?
            var column: Int?

            if let index = nsError.userInfo["NSJSONSerializationErrorIndex"] as? Int, index <= data.count {
                // The index counts UTF-8 bytes; the editor (goTo) counts UTF-16 units. Convert so
                // the caret lands on the error even after accents or emoji.
                let utf16Offset = String(decoding: data.prefix(index), as: UTF8.self).utf16.count
                let position = lineAndColumn(atUTF16Offset: utf16Offset, in: text)
                line = position.line
                column = position.column
            } else if let regex = try? Regex("line (\\d+), column (\\d+)"),
                      let match = rawMessage.firstMatch(of: regex),
                      match.count == 3,
                      let lineText = match[1].substring,
                      let columnText = match[2].substring,
                      let parsedLine = Int(lineText),
                      let parsedColumn = Int(columnText) {
                // Foundation reports 0-based columns in its message.
                line = parsedLine
                column = parsedColumn + 1
            }

            return TextValidationResult(
                status: .invalid(message: localizedMessage(rawMessage), line: line, column: column),
                lineCount: lines
            )
        }

        // JSONSerialization tolerates trailing commas, which strict JSON forbids.
        if let offset = trailingCommaOffset(in: text) {
            let position = lineAndColumn(atUTF16Offset: offset, in: text)
            return TextValidationResult(
                status: .invalid(message: "Trailing comma not allowed", line: position.line, column: position.column),
                lineCount: lines
            )
        }

        return TextValidationResult(status: .valid, lineCount: lines)
    }

    private static func localizedMessage(_ message: String) -> String {
        var trimmed = message
        if let range = trimmed.range(of: " around line ") {
            trimmed = String(trimmed[..<range.lowerBound])
        }
        let translations: [(String, String)] = [
            ("Invalid value", "Invalid value"),
            ("Badly formed object", "Malformed object"),
            ("Badly formed array", "Malformed array"),
            ("No string key for value in object", "Keys must be strings in double quotes"),
            ("Garbage at end", "Unexpected content after the end of the JSON"),
            ("Unescaped control character", "Unescaped control character"),
            ("Number with leading zero", "Number with a leading zero"),
            ("Unexpected end of file", "Unexpected end of file"),
            ("Invalid escape sequence", "Invalid escape sequence"),
            ("Something looked like a 'true'", "Invalid value: did you mean true?"),
            ("Something looked like a 'false'", "Invalid value: did you mean false?"),
            ("Something looked like a 'null'", "Invalid value: did you mean null?"),
            ("Number wound up as NaN", "Number out of range"),
        ]
        for (raw, friendly) in translations where trimmed.hasPrefix(raw) {
            return friendly
        }
        return trimmed
    }

    private static func trailingCommaOffset(in text: String) -> Int? {
        let units = Array(text.utf16)
        var lastCommaOffset: Int?
        var i = 0
        while i < units.count {
            let unit = units[i]
            switch unit {
            case 34:
                lastCommaOffset = nil
                i += 1
                while i < units.count {
                    let stringUnit = units[i]
                    i += 1
                    if stringUnit == 92 { i += 1 } else if stringUnit == 34 { break }
                }
                continue
            case 44:
                lastCommaOffset = i
            case 125, 93:
                if let lastCommaOffset { return lastCommaOffset }
            default:
                if !isWhitespace(unit) { lastCommaOffset = nil }
            }
            i += 1
        }
        return nil
    }

    static func lineAndColumn(atUTF16Offset offset: Int, in text: String) -> (line: Int, column: Int) {
        var line = 1
        var column = 1
        for (index, unit) in text.utf16.enumerated() {
            if index == offset { break }
            if unit == 10 {
                line += 1
                column = 1
            } else {
                column += 1
            }
        }
        return (line, column)
    }

    /// Re-indents valid JSON without reordering keys or rewriting values.
    /// Pass `nil` as `indent` to minify.
    static func reformat(_ text: String, indent: String?) -> String {
        let input = Array(text.utf16)
        let indentUnits = indent.map { Array($0.utf16) }
        var output: [UInt16] = []
        output.reserveCapacity(input.count)
        var depth = 0

        func appendNewline() {
            guard let indentUnits else { return }
            output.append(10)
            for _ in 0..<depth {
                output.append(contentsOf: indentUnits)
            }
        }

        var i = 0
        let count = input.count
        while i < count {
            let unit = input[i]
            switch unit {
            case 34: // "
                output.append(unit)
                i += 1
                while i < count {
                    let stringUnit = input[i]
                    output.append(stringUnit)
                    i += 1
                    if stringUnit == 92, i < count { // backslash escape
                        output.append(input[i])
                        i += 1
                    } else if stringUnit == 34 {
                        break
                    }
                }
                continue
            case 123, 91: // { [
                output.append(unit)
                var next = i + 1
                while next < count, isWhitespace(input[next]) { next += 1 }
                if next < count, input[next] == 125 || input[next] == 93 {
                    output.append(input[next])
                    i = next + 1
                    continue
                }
                depth += 1
                appendNewline()
            case 125, 93: // } ]
                depth = max(0, depth - 1)
                appendNewline()
                output.append(unit)
            case 44: // ,
                output.append(unit)
                appendNewline()
            case 58: // :
                output.append(unit)
                if indentUnits != nil { output.append(32) }
            case 32, 9, 10, 13:
                break
            default:
                output.append(unit)
            }
            i += 1
        }

        if indentUnits != nil {
            output.append(10)
        }
        return String(decoding: output, as: UTF16.self)
    }

    static func isWhitespace(_ unit: UInt16) -> Bool {
        unit == 32 || unit == 9 || unit == 10 || unit == 13
    }
}
