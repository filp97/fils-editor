//
//  StructuredTextLanguage.swift
//  fil's editor
//

import AppKit
import Foundation

/// Outcome of validating a text document (JSON or YAML). Line/column are 1-based and the
/// column counts UTF-16 units, the unit `JSONTextController.goTo(line:column:)` uses.
nonisolated struct TextValidationResult: Sendable, Equatable {
    enum Status: Sendable, Equatable {
        case empty
        case valid
        case invalid(message: String, line: Int?, column: Int?)
    }

    let status: Status
    let lineCount: Int

    static let pending = TextValidationResult(status: .empty, lineCount: 1)

    var isValid: Bool { status == .valid }

    static func lineCount(of text: String) -> Int {
        text.utf16.reduce(1) { $1 == 10 ? $0 + 1 : $0 }
    }
}

/// The languages edited by `StructuredTextEditorView`: what differs between them is the
/// validator, the syntax highlighter and whether "Format/Minify" is offered.
nonisolated enum StructuredTextLanguage: Sendable {
    case json
    case yaml

    var name: String {
        switch self {
        case .json: "JSON"
        case .yaml: "YAML"
        }
    }

    /// YAML is not reformatted: re-emitting it through a library drops comments and quoting.
    var supportsReformat: Bool { self == .json }

    func validate(_ text: String) -> TextValidationResult {
        switch self {
        case .json: JSONTools.validate(text)
        case .yaml: YAMLTools.validate(text)
        }
    }

    @MainActor
    func highlight(_ textStorage: NSTextStorage, baseAttributes: [NSAttributedString.Key: Any]) {
        switch self {
        case .json: JSONSyntaxHighlighter.highlight(textStorage, baseAttributes: baseAttributes)
        case .yaml: YAMLSyntaxHighlighter.highlight(textStorage, baseAttributes: baseAttributes)
        }
    }
}
