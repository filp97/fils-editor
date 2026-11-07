//
//  StructuredTextEditorView.swift
//  fil's editor
//

import AppKit
import SwiftUI

/// A document whose whole content is one editable string (JSON, YAML).
protocol PlainTextDocument: ReferenceFileDocument {
    var text: String { get set }
}

/// Text editor window shared by JSON and YAML documents: highlighted editor with line
/// numbers, live validation in the status bar, find/replace and zoom. `language` selects the
/// validator, the highlighter and whether Format/Minify appear (JSON only).
struct StructuredTextEditorView<Document: PlainTextDocument>: View {
    @ObservedObject var document: Document
    let language: StructuredTextLanguage
    @Environment(\.undoManager) private var undoManager
    @StateObject private var controller = JSONTextController()
    @State private var validation = TextValidationResult.pending

    private let indentUnit = "    "

    var body: some View {
        VStack(spacing: 0) {
            JSONTextEditor(
                text: document.text,
                language: language,
                controller: controller,
                undoManager: undoManager,
                onTextChange: { document.text = $0 }
            )
            Divider()
            statusBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .toolbar { toolbarContent }
        .task(id: document.text) {
            let text = document.text
            if validation != .pending {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
            }
            let language = language
            let result = await Task.detached { language.validate(text) }.value
            guard !Task.isCancelled else { return }
            validation = result
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if language.supportsReformat {
            ToolbarItemGroup {
            Button {
                reformat(minify: false)
            } label: {
                Label("Format", systemImage: "text.alignleft")
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])
            .help("Format the JSON with indentation (⇧⌘F)")

            Button {
                reformat(minify: true)
            } label: {
                Label("Minify", systemImage: "arrow.down.right.and.arrow.up.left")
            }
            .keyboardShortcut("f", modifiers: [.command, .shift, .option])
            .help("Remove spaces and line breaks from the JSON (⌥⇧⌘F)")
            }
        }

        ToolbarItemGroup {
            Button {
                controller.showFind(replace: false)
            } label: {
                Label("Find", systemImage: "magnifyingglass")
            }
            .keyboardShortcut("f", modifiers: .command)
            .help("Find in text (⌘F)")

            Button {
                controller.showFind(replace: true)
            } label: {
                Label("Replace", systemImage: "arrow.left.arrow.right")
            }
            .keyboardShortcut("f", modifiers: [.command, .option])
            .help("Find and replace (⌥⌘F)")
        }
    }

    private func reformat(minify: Bool) {
        let text = document.text
        let result = language.validate(text)
        validation = result
        guard result.isValid else {
            NSSound.beep()
            if case let .invalid(_, line?, column?) = result.status {
                controller.goTo(line: line, column: column)
            }
            return
        }
        let reformatted = JSONTools.reformat(text, indent: minify ? nil : indentUnit)
        guard reformatted != text else { return }
        controller.replaceAll(with: reformatted, actionName: minify ? "Minify JSON" : "Format JSON")
    }

    // MARK: - Status bar

    private var statusBar: some View {
        HStack(spacing: 16) {
            Text("^[\(validation.lineCount) line](inflect: true)")
            validationLabel
            Spacer()
            zoomControl
            Text("UTF-8")
                .foregroundStyle(.secondary)
            Text(language.name)
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(.bar)
    }

    private var zoomControl: some View {
        HStack(spacing: 4) {
            Button {
                controller.zoomOut()
            } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .help("Zoom out (⌘− or Ctrl −)")

            Button {
                controller.resetZoom()
            } label: {
                Text("\(controller.zoomPercent)%")
                    .monospacedDigit()
                    .frame(minWidth: 40)
            }
            .help("Reset zoom to 100% (⌘0 or Ctrl 0)")

            Button {
                controller.zoomIn()
            } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .help("Zoom in (⌘+ or Ctrl +)")
        }
        .buttonStyle(.borderless)
    }

    @ViewBuilder
    private var validationLabel: some View {
        switch validation.status {
        case .empty:
            Text("Empty document")
                .foregroundStyle(.secondary)
        case .valid:
            Label("Valid \(language.name)", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case let .invalid(message, line, column):
            Button {
                if let line, let column {
                    controller.goTo(line: line, column: column)
                }
            } label: {
                Label(errorDescription(message: message, line: line, column: column), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .buttonStyle(.plain)
            .help(line == nil ? message : "Go to error")
        }
    }

    private func errorDescription(message: String, line: Int?, column: Int?) -> String {
        guard let line, let column else { return "Invalid \(language.name): \(message)" }
        return "Error at line \(line), column \(column): \(message)"
    }
}
