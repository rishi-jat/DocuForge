import Foundation

/// Sidebar tools exposed by DocuForge.
public enum ToolKind: String, CaseIterable, Identifiable, Sendable, Hashable {
    case edit
    case convert
    case merge
    case split
    case compress
    case ocr
    case protect
    case watermark
    case pages
    case batch

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .edit: return "Edit"
        case .convert: return "Convert"
        case .merge: return "Merge PDF"
        case .split: return "Split PDF"
        case .compress: return "Compress"
        case .ocr: return "OCR"
        case .protect: return "Password"
        case .watermark: return "Watermark"
        case .pages: return "Pages"
        case .batch: return "Batch"
        }
    }

    public var subtitle: String {
        switch self {
        case .edit: return "WYSIWYG canvas editor"
        case .convert: return "Formats & images"
        case .merge: return "Combine documents"
        case .split: return "Extract ranges"
        case .compress: return "Reduce file size"
        case .ocr: return "Make text searchable"
        case .protect: return "Encrypt PDFs"
        case .watermark: return "Stamp documents"
        case .pages: return "Reorder & rotate"
        case .batch: return "Process many files"
        }
    }

    public var systemImage: String {
        switch self {
        case .edit: return "pencil.and.outline"
        case .convert: return "arrow.triangle.2.circlepath"
        case .merge: return "doc.on.doc"
        case .split: return "scissors"
        case .compress: return "archivebox"
        case .ocr: return "text.viewfinder"
        case .protect: return "lock.doc"
        case .watermark: return "drop.triangle"
        case .pages: return "rectangle.stack"
        case .batch: return "square.stack.3d.up"
        }
    }

    public var section: ToolSection {
        switch self {
        case .edit: return .edit
        case .convert, .ocr: return .transform
        case .merge, .split, .pages: return .structure
        case .compress, .protect, .watermark: return .secure
        case .batch: return .automation
        }
    }
}

public enum ToolSection: String, CaseIterable, Identifiable, Sendable {
    case edit
    case transform
    case structure
    case secure
    case automation

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .edit: return "Editor"
        case .transform: return "Transform"
        case .structure: return "Structure"
        case .secure: return "Secure & Polish"
        case .automation: return "Automation"
        }
    }
}
