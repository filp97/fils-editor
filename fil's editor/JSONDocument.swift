//
//  JSONDocument.swift
//  fil's editor
//

import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers

final class JSONDocument: ReferenceFileDocument, PlainTextDocument {
    typealias Snapshot = String

    @Published var text: String

    nonisolated static var readableContentTypes: [UTType] {
        [.json]
    }

    nonisolated static var writableContentTypes: [UTType] {
        [.json]
    }

    init() {
        text = "{\n    \n}\n"
    }

    required nonisolated init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        // BOM is dropped and the file is saved as UTF-8 (the encoding JSON requires).
        text = TextFileEncoding.decode(data).text
    }

    func snapshot(contentType: UTType) throws -> String {
        text
    }

    nonisolated func fileWrapper(snapshot: String, configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(snapshot.utf8))
    }
}
