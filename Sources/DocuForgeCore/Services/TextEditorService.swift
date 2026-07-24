import Foundation
import AppKit

/// Load/edit/save text-like documents. Saves back to original format when possible.
public actor TextEditorService {
    private let textUtil = TextUtilService()

    public init() {}

    public struct TextDocument: Sendable {
        public var text: String
        public var format: DocumentFormat
        public var sourceURL: URL
        public var isRich: Bool
        public var limitationNote: String?

        public init(text: String, format: DocumentFormat, sourceURL: URL, isRich: Bool, limitationNote: String? = nil) {
            self.text = text
            self.format = format
            self.sourceURL = sourceURL
            self.isRich = isRich
            self.limitationNote = limitationNote
        }
    }

    public func open(url: URL) throws -> TextDocument {
        let format = DocumentFormat.detect(url: url)
        switch format {
        case .txt, .markdown, .csv:
            let text = try String(contentsOf: url, encoding: .utf8)
            return TextDocument(text: text, format: format, sourceURL: url, isRich: false)
        case .rtf:
            let data = try Data(contentsOf: url)
            let attr = try NSAttributedString(
                data: data,
                options: [.documentType: NSAttributedString.DocumentType.rtf],
                documentAttributes: nil
            )
            return TextDocument(text: attr.string, format: format, sourceURL: url, isRich: true)
        case .html:
            let data = try Data(contentsOf: url)
            if let attr = try? NSAttributedString(
                data: data,
                options: [
                    .documentType: NSAttributedString.DocumentType.html,
                    .characterEncoding: String.Encoding.utf8.rawValue
                ],
                documentAttributes: nil
            ) {
                return TextDocument(
                    text: attr.string,
                    format: format,
                    sourceURL: url,
                    isRich: true,
                    limitationNote: "HTML is edited as plain text; tags are not preserved on save unless you edit the raw source in TXT mode."
                )
            }
            let text = String(data: data, encoding: .utf8) ?? ""
            return TextDocument(text: text, format: format, sourceURL: url, isRich: false)
        case .doc, .docx, .odt:
            // Convert to plain text for editing via textutil
            let tmp = FileIO.temporaryURL(prefix: "edit-open", ext: "txt")
            // Sync textutil
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
            process.arguments = ["-convert", "txt", "-output", tmp.path, url.path]
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw DocuForgeError.conversionFailed("Could not open \(format.displayName) for editing.")
            }
            let text = try String(contentsOf: tmp, encoding: .utf8)
            try? FileManager.default.removeItem(at: tmp)
            return TextDocument(
                text: text,
                format: format,
                sourceURL: url,
                isRich: false,
                limitationNote: "\(format.displayName) is edited as plain text. Saving rewrites the file via textutil (complex layout/images are not preserved)."
            )
        default:
            throw DocuForgeError.unsupportedFormat(format)
        }
    }

    public func save(_ document: TextDocument, to url: URL? = nil) throws -> ProcessingResult {
        let target = url ?? document.sourceURL
        switch document.format {
        case .txt, .markdown, .csv:
            try document.text.write(to: target, atomically: true, encoding: .utf8)
            return ProcessingResult(
                outputURLs: [target],
                bytesOut: FileIO.fileSize(at: target),
                notes: ["Saved \(document.format.displayName)."]
            )
        case .rtf:
            let attr = NSAttributedString(string: document.text, attributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: NSColor.textColor
            ])
            let data = try attr.data(
                from: NSRange(location: 0, length: attr.length),
                documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
            )
            try data.write(to: target)
            return ProcessingResult(
                outputURLs: [target],
                bytesOut: FileIO.fileSize(at: target),
                notes: ["Saved RTF (plain-styled text)."]
            )
        case .html:
            let escaped = document.text
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
            let html = "<!DOCTYPE html><html><head><meta charset=\"utf-8\"></head><body><pre>\(escaped)</pre></body></html>"
            try html.write(to: target, atomically: true, encoding: .utf8)
            return ProcessingResult(
                outputURLs: [target],
                bytesOut: FileIO.fileSize(at: target),
                notes: ["Saved as simple HTML wrapper around plain text."]
            )
        case .doc, .docx, .odt:
            let tmp = FileIO.temporaryURL(prefix: "edit-save", ext: "txt")
            try document.text.write(to: tmp, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: tmp) }
            let fmt: String
            switch document.format {
            case .doc: fmt = "doc"
            case .docx: fmt = "docx"
            case .odt: fmt = "odt"
            default: fmt = "txt"
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
            process.arguments = ["-convert", fmt, "-output", target.path, tmp.path]
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw DocuForgeError.conversionFailed("textutil could not save \(document.format.displayName).")
            }
            return ProcessingResult(
                outputURLs: [target],
                bytesOut: FileIO.fileSize(at: target),
                notes: [
                    "Saved \(document.format.displayName) via textutil.",
                    "Complex layout and embedded objects from the original may not be preserved."
                ]
            )
        default:
            throw DocuForgeError.unsupportedFormat(document.format)
        }
    }

    public func isEditableTextFormat(_ format: DocumentFormat) -> Bool {
        [.txt, .markdown, .csv, .rtf, .html, .doc, .docx, .odt].contains(format)
    }
}
