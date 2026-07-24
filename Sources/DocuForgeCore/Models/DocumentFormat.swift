import Foundation
import UniformTypeIdentifiers

/// Supported document, presentation, spreadsheet, image, ebook, and archive formats.
public enum DocumentFormat: String, CaseIterable, Sendable, Identifiable, Hashable {
    // Documents
    case pdf
    case doc
    case docx
    case odt
    case rtf
    case rtfd
    case txt
    case markdown
    case html
    case webarchive
    case pages
    // Presentations
    case ppt
    case pptx
    case odp
    case key
    // Spreadsheets
    case xls
    case xlsx
    case ods
    case csv
    case numbers
    // Ebook
    case epub
    // Images
    case png
    case jpeg
    case heic
    case tiff
    case gif
    case webp
    case bmp
    case svg
    case ico
    case psd
    case avif
    case jp2
    // Archives
    case zip
    case tar
    case gzip
    // Fallback
    case unknown

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .pdf: return "PDF"
        case .doc: return "Word 97–2004 (DOC)"
        case .docx: return "Word (DOCX)"
        case .odt: return "OpenDocument Text (ODT)"
        case .rtf: return "Rich Text (RTF)"
        case .rtfd: return "Rich Text Directory (RTFD)"
        case .txt: return "Plain Text"
        case .markdown: return "Markdown"
        case .html: return "HTML"
        case .webarchive: return "Web Archive"
        case .pages: return "Pages"
        case .ppt: return "PowerPoint 97–2003 (PPT)"
        case .pptx: return "PowerPoint (PPTX)"
        case .odp: return "OpenDocument Presentation (ODP)"
        case .key: return "Keynote"
        case .xls: return "Excel 97–2004 (XLS)"
        case .xlsx: return "Excel (XLSX)"
        case .ods: return "OpenDocument Spreadsheet (ODS)"
        case .csv: return "CSV"
        case .numbers: return "Numbers"
        case .epub: return "EPUB"
        case .png: return "PNG"
        case .jpeg: return "JPEG"
        case .heic: return "HEIC"
        case .tiff: return "TIFF"
        case .gif: return "GIF"
        case .webp: return "WebP"
        case .bmp: return "BMP"
        case .svg: return "SVG"
        case .ico: return "ICO"
        case .psd: return "Photoshop (PSD)"
        case .avif: return "AVIF"
        case .jp2: return "JPEG 2000"
        case .zip: return "ZIP"
        case .tar: return "TAR"
        case .gzip: return "GZIP"
        case .unknown: return "Unknown"
        }
    }

    public var pathExtension: String {
        switch self {
        case .jpeg: return "jpg"
        case .markdown: return "md"
        case .key: return "key"
        case .gzip: return "gz"
        case .jp2: return "jp2"
        default: return rawValue
        }
    }

    public var category: FormatCategory {
        switch self {
        case .pdf, .doc, .docx, .odt, .rtf, .rtfd, .txt, .markdown, .html, .webarchive, .pages:
            return .document
        case .ppt, .pptx, .odp, .key:
            return .presentation
        case .xls, .xlsx, .ods, .csv, .numbers:
            return .spreadsheet
        case .epub:
            return .ebook
        case .png, .jpeg, .heic, .tiff, .gif, .webp, .bmp, .svg, .ico, .psd, .avif, .jp2:
            return .image
        case .zip, .tar, .gzip:
            return .archive
        case .unknown:
            return .other
        }
    }

    public var utType: UTType {
        switch self {
        case .pdf: return .pdf
        case .doc: return UTType(filenameExtension: "doc") ?? .data
        case .docx: return UTType(filenameExtension: "docx") ?? .data
        case .odt: return UTType(filenameExtension: "odt") ?? .data
        case .rtf: return .rtf
        case .rtfd: return UTType(filenameExtension: "rtfd") ?? .package
        case .txt: return .plainText
        case .markdown: return UTType(filenameExtension: "md") ?? .plainText
        case .html: return .html
        case .webarchive: return UTType(filenameExtension: "webarchive") ?? .data
        case .pages: return UTType(filenameExtension: "pages") ?? .data
        case .ppt: return UTType(filenameExtension: "ppt") ?? .data
        case .pptx: return UTType(filenameExtension: "pptx") ?? .data
        case .odp: return UTType(filenameExtension: "odp") ?? .data
        case .key: return UTType(filenameExtension: "key") ?? .data
        case .xls: return UTType(filenameExtension: "xls") ?? .data
        case .xlsx: return UTType(filenameExtension: "xlsx") ?? .data
        case .ods: return UTType(filenameExtension: "ods") ?? .data
        case .csv: return .commaSeparatedText
        case .numbers: return UTType(filenameExtension: "numbers") ?? .data
        case .epub: return UTType(filenameExtension: "epub") ?? .data
        case .png: return .png
        case .jpeg: return .jpeg
        case .heic: return .heic
        case .tiff: return .tiff
        case .gif: return .gif
        case .webp: return .webP
        case .bmp: return .bmp
        case .svg: return .svg
        case .ico: return UTType(filenameExtension: "ico") ?? .image
        case .psd: return UTType(filenameExtension: "psd") ?? .image
        case .avif: return UTType(filenameExtension: "avif") ?? .image
        case .jp2: return UTType(filenameExtension: "jp2") ?? .image
        case .zip: return .zip
        case .tar: return UTType(filenameExtension: "tar") ?? .data
        case .gzip: return UTType(filenameExtension: "gz") ?? .data
        case .unknown: return .data
        }
    }

    public var isImage: Bool { category == .image }
    public var isPDF: Bool { self == .pdf }
    public var isArchive: Bool { category == .archive }
    public var isIWork: Bool { [.pages, .key, .numbers].contains(self) }

    public var isOfficeOpenXML: Bool {
        [.docx, .pptx, .xlsx].contains(self)
    }

    public var isOpenDocument: Bool {
        [.odt, .odp, .ods].contains(self)
    }

    public var isLegacyOffice: Bool {
        [.doc, .ppt, .xls].contains(self)
    }

    public var isTextLike: Bool {
        [.txt, .markdown, .rtf, .html, .csv, .webarchive].contains(self)
    }

    /// Formats that macOS `textutil` can convert among.
    public var isTextUtilFormat: Bool {
        [.txt, .rtf, .rtfd, .html, .doc, .docx, .odt, .webarchive].contains(self)
    }

    /// Sensible conversion targets shown in the Convert UI for this source.
    public var suggestedTargets: [DocumentFormat] {
        switch self {
        case .pages, .key, .numbers:
            // Prefer high-fidelity PDF (via iWork automation when available).
            return [.pdf, .png, .jpeg, .txt, .docx, .pptx, .xlsx]
        case .pdf:
            return [.png, .jpeg, .tiff, .txt, .html, .docx, .rtf, .pages]
        case .pptx, .ppt, .odp:
            return [.pdf, .key, .png, .jpeg, .txt]
        case .docx, .doc, .odt, .rtf:
            return [.pdf, .pages, .docx, .doc, .odt, .rtf, .txt, .html]
        case .xlsx, .xls, .ods, .csv:
            return [.pdf, .numbers, .csv, .xlsx, .txt, .html]
        default:
            break
        }
        switch category {
        case .image:
            return [.png, .jpeg, .heic, .tiff, .gif, .webp, .bmp, .pdf, .ico]
        case .document:
            return [.pdf, .pages, .txt, .html, .rtf, .docx, .odt, .doc]
        case .presentation:
            return [.pdf, .key, .pptx, .txt, .png, .jpeg]
        case .spreadsheet:
            return [.pdf, .numbers, .xlsx, .csv, .txt, .html]
        case .ebook:
            return [.pdf, .txt, .html, .epub]
        case .archive:
            return [.zip]
        case .other:
            return [.pdf, .txt]
        }
    }

    /// Common export targets for the Convert picker (ordered) — always includes iWork.
    public static var commonTargets: [DocumentFormat] {
        [
            .pdf,
            .pages, .key, .numbers,
            .docx, .doc, .odt, .rtf, .txt, .html, .markdown,
            .pptx, .ppt, .odp,
            .xlsx, .xls, .ods, .csv,
            .png, .jpeg, .heic, .tiff, .webp, .gif, .bmp, .ico, .jp2, .svg,
            .epub, .zip
        ]
    }

    /// All formats users can pick as conversion outputs, grouped for UI.
    public static var pickerTargetsByCategory: [(FormatCategory, [DocumentFormat])] {
        let all = commonTargets
        return FormatCategory.allCases.compactMap { cat in
            let items = all.filter { $0.category == cat }
            return items.isEmpty ? nil : (cat, items)
        }
    }

    public static func detect(url: URL) -> DocumentFormat {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "pdf": return .pdf
        case "doc": return .doc
        case "docx": return .docx
        case "odt": return .odt
        case "rtf": return .rtf
        case "rtfd": return .rtfd
        case "txt", "text", "log": return .txt
        case "md", "markdown", "mdown": return .markdown
        case "html", "htm": return .html
        case "webarchive": return .webarchive
        case "pages": return .pages
        case "ppt": return .ppt
        case "pptx": return .pptx
        case "odp": return .odp
        case "key": return .key
        case "xls": return .xls
        case "xlsx": return .xlsx
        case "ods": return .ods
        case "csv", "tsv": return .csv
        case "numbers": return .numbers
        case "epub": return .epub
        case "png": return .png
        case "jpg", "jpeg", "jpe": return .jpeg
        case "heic", "heif": return .heic
        case "tif", "tiff": return .tiff
        case "gif": return .gif
        case "webp": return .webp
        case "bmp", "dib": return .bmp
        case "svg", "svgz": return .svg
        case "ico": return .ico
        case "psd": return .psd
        case "avif": return .avif
        case "jp2", "j2k", "jpf", "jpx": return .jp2
        case "zip": return .zip
        case "tar": return .tar
        case "gz", "gzip", "tgz": return .gzip
        default:
            if let type = UTType(filenameExtension: ext) {
                if type.conforms(to: .pdf) { return .pdf }
                if type.conforms(to: .image) {
                    if type.conforms(to: .png) { return .png }
                    if type.conforms(to: .jpeg) { return .jpeg }
                    if type.conforms(to: .heic) { return .heic }
                    if type.conforms(to: .tiff) { return .tiff }
                    if type.conforms(to: .gif) { return .gif }
                    if type.conforms(to: .svg) { return .svg }
                    if type.conforms(to: .webP) { return .webp }
                    return .png
                }
                if type.conforms(to: .plainText) { return .txt }
                if type.conforms(to: .html) { return .html }
                if type.conforms(to: .rtf) { return .rtf }
                if type.conforms(to: .zip) { return .zip }
            }
            return .unknown
        }
    }
}

public enum FormatCategory: String, CaseIterable, Sendable, Identifiable {
    case document
    case presentation
    case spreadsheet
    case ebook
    case image
    case archive
    case other

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .document: return "Documents"
        case .presentation: return "Presentations"
        case .spreadsheet: return "Spreadsheets"
        case .ebook: return "Ebooks"
        case .image: return "Images"
        case .archive: return "Archives"
        case .other: return "Other"
        }
    }
}

/// How a conversion path is implemented.
public enum ConversionEngine: String, Sendable {
    case copy
    case pdfKit
    case imageIO
    case textUtil
    case visionOCR
    case officeOpenXML
    case openDocument
    case iWorkAutomation
    case iWorkPreview
    case quickLook
    case epub
    case archive
    case webKit
    case libreOffice
    case markdown
    case unsupported
}

public struct ConversionCapability: Sendable, Identifiable {
    public var id: String { "\(source.rawValue)->\(target.rawValue)" }
    public let source: DocumentFormat
    public let target: DocumentFormat
    public let engine: ConversionEngine
    public let fidelity: Fidelity
    public let notes: String

    public enum Fidelity: String, Sendable {
        case full
        case high
        case textOnly
        case preview
        case extract
        case none
    }
}
