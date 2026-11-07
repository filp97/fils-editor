//
//  YAMLDocument.swift
//  fil's editor
//

import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// `.yaml` / `.yml` files (both map to `public.yaml`). Edited as plain text in
/// `StructuredTextEditorView`; saved as UTF-8 without BOM.
final class YAMLDocument: ReferenceFileDocument, PlainTextDocument {
    typealias Snapshot = String

    @Published var text: String

    nonisolated static var readableContentTypes: [UTType] {
        [.yaml]
    }

    nonisolated static var writableContentTypes: [UTType] {
        [.yaml]
    }

    init() {
        text = ""
    }

    required nonisolated init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        text = TextFileEncoding.decode(data).text
    }

    func snapshot(contentType: UTType) throws -> String {
        text
    }

    nonisolated func fileWrapper(snapshot: String, configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(snapshot.utf8))
    }
}
