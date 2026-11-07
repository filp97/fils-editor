//
//  fil_s_editorApp.swift
//  fil's editor
//

import SwiftUI

@main
struct fil_s_editorApp: App {
    var body: some Scene {
        DocumentGroup(newDocument: { CSVDocument() }) { configuration in
            ContentView(document: configuration.document)
        }
        .defaultSize(width: 900, height: 600)

        DocumentGroup(newDocument: { JSONDocument() }) { configuration in
            StructuredTextEditorView(document: configuration.document, language: .json)
        }
        .defaultSize(width: 800, height: 600)

        DocumentGroup(newDocument: { YAMLDocument() }) { configuration in
            StructuredTextEditorView(document: configuration.document, language: .yaml)
        }
        .defaultSize(width: 800, height: 600)
    }
}
