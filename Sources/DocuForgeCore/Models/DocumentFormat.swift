import Foundation
import UniformTypeIdentifiers

/// Supported document and image formats for conversion and processing.
public enum DocumentFormat: String, CaseIterable, Sendable, Identifiable, Hashable {
    case pdf
    case png
    case jpeg
    case heic
    case tiff
    case gif
    case webp
    case bmp
    case docx
    case pptx
    case xlsx
    case rtf
    case html
    case txt
    case csv
    case pages
    case key
    case numbers
    case unknown

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .pdf: return "PDF"
        case .png: return "PNG"
        case .jpeg: return "JPEG"
        case .heic: return "HEIC"
        case .tiff: return "TIFF"
        case .gif: return "GIF"
        case .webp: return "WebP"
        case .bmp: return "BMP"
        case .docx: return "Word (DOCX)"
        case .pptx: return "PowerPoint (PPTX)"
        case .xlsx: return "Excel (XLSX)"
        case .rtf: return "Rich Text"
        case .html: return "HTML"
        case .txt: return "Plain Text"
        case .csv: return "CSV"
        case .pages: return "Pages"
        case .key: return "Keynote"
        case .numbers: return "Numbers"
        case .unknown: return "Unknown"
        }
    }

    public var pathExtension: String {
        switch self {
        case .jpeg: return "jpg"
        case .key: return "key"
        default: return rawValue
        }
    }

    public var utType: UTType {
        switch self {
        case .pdf: return .pdf
        case .png: return .png
        case .jpeg: return .jpeg
        case .heic: return .heic
        case .tiff: return .tiff
        case .gif: return .gif
        case .webp: return .webP
        case .bmp: return .bmp
        case .docx: return UTType(filenameExtension: "docx") ?? .data
        case .pptx: return UTType(filenameExtension: "pptx") ?? .data
        case .xlsx: return UTType(filenameExtension: "xlsx") ?? .data
        case .rtf: return .rtf
        case .html: return .html
        case .txt: return .plainText
        case .csv: return .commaSeparatedText
        case .pages: return UTType(filenameExtension: "pages") ?? .data
        case .key: return UTType(filenameExtension: "key") ?? .data
        case .numbers: return UTType(filenameExtension: "numbers") ?? .data
        case .unknown: return .data
        }
    }

    public var isImage: Bool {
        [.png, .jpeg, .heic, .tiff, .gif, .webp, .bmp].contains(self)
    }

    public var isPDF: Bool { self == .pdf }

    public var isOfficeOpenXML: Bool {
        [.docx, .pptx, .xlsx].contains(self)
    }

    public var isTextLike: Bool {
        [.txt, .rtf, .html, .csv].contains(self)
    }

    public var isIWork: Bool {
        [.pages, .key, .numbers].contains(self)
    }

    public static func detect(url: URL) -> DocumentFormat {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "pdf": return .pdf
        case "png": return .png
        case "jpg", "jpeg", "jpe": return .jpeg
        case "heic", "heif": return .heic
        case "tif", "tiff": return .tiff
        case "gif": return .gif
        case "webp": return .webp
        case "bmp": return .bmp
        case "docx": return .docx
        case "pptx": return .pptx
        case "xlsx": return .xlsx
        case "rtf": return .rtf
        case "html", "htm": return .html
        case "txt", "md", "text": return .txt
        case "csv": return .csv
        case "pages": return .pages
        case "key": return .key
        case "numbers": return .numbers
        default:
            if let type = UTType(filenameExtension: ext) {
                if type.conforms(to: .pdf) { return .pdf }
                if type.conforms(to: .image) {
                    if type.conforms(to: .png) { return .png }
                    if type.conforms(to: .jpeg) { return .jpeg }
                    if type.conforms(to: .heic) { return .heic }
                    if type.conforms(to: .tiff) { return .tiff }
                    if type.conforms(to: .gif) { return .gif }
                    return .png
                }
            }
            return .unknown
        }
    }
}
