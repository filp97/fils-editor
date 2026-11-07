//
//  TextFileEncoding.swift
//  fil's editor
//

import Foundation

/// How a text file was stored on disk: the character encoding plus whether it began with a
/// byte order mark. CSV documents keep it so saving writes the file back the way it was read
/// (Excel exports UTF-8 with BOM, UTF-16 "Unicode text", or Windows-1252).
nonisolated struct TextFileEncoding: Hashable, Sendable {
    var encoding: String.Encoding
    var hasByteOrderMark: Bool

    static let utf8 = TextFileEncoding(encoding: .utf8, hasByteOrderMark: false)

    private static let utf8BOM: [UInt8] = [0xEF, 0xBB, 0xBF]
    private static let utf16LEBOM: [UInt8] = [0xFF, 0xFE]
    private static let utf16BEBOM: [UInt8] = [0xFE, 0xFF]

    var label: String {
        let name: String
        switch encoding {
        case .utf8: name = "UTF-8"
        case .utf16LittleEndian, .utf16BigEndian, .utf16: name = "UTF-16"
        case .windowsCP1252: name = "Windows-1252"
        case .isoLatin1: name = "ISO Latin-1"
        default: name = String.localizedName(of: encoding)
        }
        return hasByteOrderMark ? "\(name) with BOM" : name
    }

    /// Decodes file bytes: BOM first, then UTF-8 → Windows-1252 → Latin-1 (Latin-1 never fails).
    static func decode(_ data: Data) -> (text: String, format: TextFileEncoding) {
        let bytes = [UInt8](data.prefix(3))
        if bytes.starts(with: utf8BOM),
           let text = String(data: data.dropFirst(3), encoding: .utf8) {
            return (text, TextFileEncoding(encoding: .utf8, hasByteOrderMark: true))
        }
        if bytes.starts(with: utf16LEBOM),
           let text = String(data: data.dropFirst(2), encoding: .utf16LittleEndian) {
            return (text, TextFileEncoding(encoding: .utf16LittleEndian, hasByteOrderMark: true))
        }
        if bytes.starts(with: utf16BEBOM),
           let text = String(data: data.dropFirst(2), encoding: .utf16BigEndian) {
            return (text, TextFileEncoding(encoding: .utf16BigEndian, hasByteOrderMark: true))
        }
        for encoding in [String.Encoding.utf8, .windowsCP1252, .isoLatin1] {
            if let text = String(data: data, encoding: encoding) {
                return (text, TextFileEncoding(encoding: encoding, hasByteOrderMark: false))
            }
        }
        return ("", .utf8)
    }

    /// Encodes `text` in this format. Falls back to UTF-8 when the text contains characters
    /// the original encoding cannot represent (e.g. an emoji typed into a Windows-1252 file).
    func encode(_ text: String) -> Data {
        guard let body = text.data(using: encoding, allowLossyConversion: false) else {
            return Data(text.utf8)
        }
        guard hasByteOrderMark else { return body }
        switch encoding {
        case .utf8: return Data(Self.utf8BOM) + body
        case .utf16LittleEndian: return Data(Self.utf16LEBOM) + body
        case .utf16BigEndian: return Data(Self.utf16BEBOM) + body
        default: return body
        }
    }
}
