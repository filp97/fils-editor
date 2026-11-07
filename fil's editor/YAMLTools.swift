//
//  YAMLTools.swift
//  fil's editor
//

import Foundation
import Yams

nonisolated enum YAMLTools {
    /// Parses every document in the stream (`---` separated) with Yams/libyaml. Composing
    /// nodes, rather than constructing Swift values, is enough to catch syntax errors,
    /// undefined aliases and duplicate keys.
    static func validate(_ text: String) -> TextValidationResult {
        let lines = TextValidationResult.lineCount(of: text)
        if text.allSatisfy(\.isWhitespace) {
            return TextValidationResult(status: .empty, lineCount: lines)
        }

        do {
            var documents = try Yams.compose_all(yaml: text)
            while documents.next() != nil {}
            if let error = documents.error { throw error }
        } catch let error as YamlError {
            return TextValidationResult(status: status(for: error, in: text), lineCount: lines)
        } catch {
            return TextValidationResult(
                status: .invalid(message: error.localizedDescription, line: nil, column: nil),
                lineCount: lines
            )
        }
        return TextValidationResult(status: .valid, lineCount: lines)
    }

    private static func status(for error: YamlError, in text: String) -> TextValidationResult.Status {
        switch error {
        case let .scanner(_, problem, mark, _),
             let .parser(_, problem, mark, _),
             let .composer(_, problem, mark, _):
            return invalid(localizedMessage(problem), mark: mark, in: text)
        case let .duplicatedKeysInMapping(duplicates, context):
            let keys = duplicates.joined(separator: ", ")
            return invalid("Duplicate key: \(keys)", mark: context.mark, in: text)
        case let .reader(problem, _, _, _):
            return .invalid(message: localizedMessage(problem), line: nil, column: nil)
        default:
            return .invalid(message: error.description, line: nil, column: nil)
        }
    }

    private static func invalid(_ message: String, mark: Mark, in text: String) -> TextValidationResult.Status {
        guard mark.line > 0 else { return .invalid(message: message, line: nil, column: nil) }
        let column = utf16Column(line: mark.line, scalarColumn: mark.column, in: text)
        return .invalid(message: message, line: mark.line, column: column)
    }

    /// libyaml counts columns in Unicode scalars; the editor counts UTF-16 units.
    static func utf16Column(line: Int, scalarColumn: Int, in text: String) -> Int {
        let scalars = text.unicodeScalars
        var index = scalars.startIndex
        var currentLine = 1
        while currentLine < line, index < scalars.endIndex {
            if scalars[index] == "\n" { currentLine += 1 }
            index = scalars.index(after: index)
        }
        var column = 1
        var utf16Column = 1
        while column < scalarColumn, index < scalars.endIndex, scalars[index] != "\n" {
            utf16Column += scalars[index].utf16.count
            column += 1
            index = scalars.index(after: index)
        }
        return utf16Column
    }

    /// Friendlier wording for the libyaml problems people actually hit; anything else stays as is.
    private static func localizedMessage(_ problem: String) -> String {
        let translations: [(String, String)] = [
            ("mapping values are not allowed", "Colon not allowed here: quote the value or check the indentation"),
            ("found character that cannot start any token", "Character not allowed here (tabs can't be used for indentation)"),
            ("found a tab character", "Tab in indentation: YAML indents with spaces only"),
            ("did not find expected key", "Expected key not found: check the indentation"),
            ("could not find expected ':'", "Missing ':' after the key"),
            ("did not find expected '-' indicator", "Missing '-' for the list item"),
            ("did not find expected node content", "Missing value"),
            ("did not find expected ',' or ']'", "Missing ',' or ']' in the list"),
            ("did not find expected ',' or '}'", "Missing ',' or '}' in the mapping"),
            ("did not find expected comment or line break", "Unexpected content after the value"),
            ("block sequence entries are not allowed", "List item '-' not allowed here: check the indentation"),
            ("found unexpected end of stream", "Unexpected end of file: a closing quote may be missing"),
            ("found undefined alias", "Undefined alias"),
            ("found unknown escape character", "Invalid escape sequence"),
            ("found unexpected document indicator", "Unexpected document marker '---'"),
            ("found incompatible YAML document", "Unsupported YAML version"),
            ("invalid leading UTF-8 octet", "Invalid UTF-8 text"),
            ("control characters are not allowed", "Control character not allowed"),
        ]
        for (raw, friendly) in translations where problem.hasPrefix(raw) {
            return friendly
        }
        return problem
    }
}
