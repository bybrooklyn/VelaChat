import Foundation
import ZIPFoundation

/// The shared OPC spine of the three OOXML emitters (plan §9.1): an
/// .xlsx/.docx/.pptx file is a zip container whose entries are XML "parts"
/// wired together by relationship graphs and declared in
/// `[Content_Types].xml`. Every format is "a content-types map + a rels
/// graph + N XML parts", so this type owns the container and each emitter
/// only contributes its own parts.
///
/// Pure and synchronous — bytes in, bytes out — so the whole layer is
/// unit-testable in VelaCore with no AppKit on the path.
public struct OOXMLPackage {
    private var entries: [(name: String, data: Data)] = []

    public init() {}

    /// Adds one part. Insertion order is preserved in the zip;
    /// `[Content_Types].xml` should be added first by convention.
    public mutating func addXML(_ path: String, _ xml: String) {
        add(path, data: Data(xml.utf8))
    }

    public mutating func add(_ path: String, data: Data) {
        entries.append((path, data))
    }

    public var partNames: [String] { entries.map(\.name) }

    /// Serializes to the finished document's bytes.
    public func makeData() throws -> Data {
        // In-memory archive: ZIPFoundation builds the local headers,
        // central directory, and EOCD record that Apple's Compression
        // framework deliberately does not.
        let archive = try Archive(data: Data(), accessMode: .create)
        for entry in entries {
            let payload = entry.data
            try archive.addEntry(
                with: entry.name,
                type: .file,
                uncompressedSize: Int64(payload.count),
                compressionMethod: .deflate
            ) { position, chunkSize in
                let start = payload.startIndex + Int(position)
                let end = min(start + chunkSize, payload.endIndex)
                return payload.subdata(in: start..<end)
            }
        }
        guard let data = archive.data else {
            throw CocoaError(.fileWriteUnknown)
        }
        return data
    }
}

/// Text sanitization shared by every emitter. A single control character
/// or stray `&` in model-produced content would otherwise corrupt a whole
/// document into Excel's repair-prompt territory — the exact failure mode
/// plan §9.1 names as the thing to avoid.
enum XMLText {
    /// Escapes the five XML specials and drops characters XML 1.0 cannot
    /// represent at all (C0 controls other than tab/newline/carriage
    /// return, plus the non-characters U+FFFE/U+FFFF).
    static func escaped(_ raw: String) -> String {
        var out = String()
        out.reserveCapacity(raw.count)
        for character in raw {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            case "\t", "\n", "\r": out.append(character)
            default:
                let scalars = character.unicodeScalars
                if scalars.count == 1, let scalar = scalars.first,
                   !isValidXMLScalar(scalar) { continue }
                out.append(character)
            }
        }
        return out
    }

    private static func isValidXMLScalar(_ scalar: Unicode.Scalar) -> Bool {
        if scalar == "\u{FFFE}" || scalar == "\u{FFFF}" { return false }
        if scalar.value < 0x20 { return false }  // \t \n \r handled above
        if scalar.value >= 0xD800 && scalar.value <= 0xDFFF { return false }
        return true
    }

    /// Strips characters spreadsheet/document apps forbid in *names*
    /// (sheet titles, shape names) rather than escaping them — there is
    /// no escape form for these.
    static func sanitizedName(_ raw: String, fallback: String) -> String {
        let forbidden = CharacterSet(charactersIn: "[]:*?/\\")
        var cleaned = raw.components(separatedBy: forbidden).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // A leading/trailing apostrophe is illegal too.
        if cleaned.hasPrefix("'") { cleaned.removeFirst() }
        if cleaned.hasSuffix("'") { cleaned.removeLast() }
        cleaned = String(cleaned.prefix(31)).trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? fallback : cleaned
    }
}
