import Foundation
import CoreGraphics

/// A file queued for processing in the UI or batch pipeline.
public struct DocumentItem: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let url: URL
    public let format: DocumentFormat
    public let fileSize: Int64
    public let pageCount: Int?
    public let displayName: String

    public init(
        id: UUID = UUID(),
        url: URL,
        format: DocumentFormat? = nil,
        fileSize: Int64? = nil,
        pageCount: Int? = nil
    ) {
        self.id = id
        self.url = url
        self.format = format ?? DocumentFormat.detect(url: url)
        if let fileSize {
            self.fileSize = fileSize
        } else {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey])
            self.fileSize = Int64(values?.fileSize ?? 0)
        }
        self.pageCount = pageCount
        self.displayName = url.lastPathComponent
    }

    public var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }
}

public enum JobState: Sendable, Equatable {
    case idle
    case running(progress: Double, message: String)
    case succeeded(outputURLs: [URL])
    case failed(message: String)

    public var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}

public struct ProcessingResult: Sendable {
    public let outputURLs: [URL]
    public let bytesIn: Int64
    public let bytesOut: Int64
    public let notes: [String]

    public init(outputURLs: [URL], bytesIn: Int64 = 0, bytesOut: Int64 = 0, notes: [String] = []) {
        self.outputURLs = outputURLs
        self.bytesIn = bytesIn
        self.bytesOut = bytesOut
        self.notes = notes
    }
}

public enum DocuForgeError: Error, LocalizedError, Sendable {
    case invalidInput(String)
    case unsupportedFormat(DocumentFormat)
    case conversionFailed(String)
    case pdfOperationFailed(String)
    case ocrFailed(String)
    case ioError(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .invalidInput(let s): return s
        case .unsupportedFormat(let f): return "Unsupported format: \(f.displayName)"
        case .conversionFailed(let s): return "Conversion failed: \(s)"
        case .pdfOperationFailed(let s): return "PDF operation failed: \(s)"
        case .ocrFailed(let s): return "OCR failed: \(s)"
        case .ioError(let s): return s
        case .cancelled: return "Cancelled"
        }
    }
}

public enum CompressQuality: String, CaseIterable, Identifiable, Sendable {
    case high
    case medium
    case low

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .high: return "High quality"
        case .medium: return "Balanced"
        case .low: return "Smallest size"
        }
    }

    /// JPEG quality when re-encoding page images (0...1).
    public var jpegQuality: CGFloat {
        switch self {
        case .high: return 0.85
        case .medium: return 0.65
        case .low: return 0.40
        }
    }

    /// Scale factor applied to page render size.
    public var scale: CGFloat {
        switch self {
        case .high: return 1.0
        case .medium: return 0.85
        case .low: return 0.70
        }
    }
}

public enum SplitMode: String, CaseIterable, Identifiable, Sendable {
    case everyPage
    case ranges
    case everyN

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .everyPage: return "Every page"
        case .ranges: return "Custom ranges"
        case .everyN: return "Every N pages"
        }
    }
}

public struct PageRange: Sendable, Hashable, Identifiable {
    public var id: UUID
    /// 1-based inclusive start.
    public var start: Int
    /// 1-based inclusive end.
    public var end: Int

    public init(id: UUID = UUID(), start: Int, end: Int) {
        self.id = id
        self.start = start
        self.end = end
    }
}

public enum WatermarkPosition: String, CaseIterable, Identifiable, Sendable {
    case center
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight
    case diagonal

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .center: return "Center"
        case .topLeft: return "Top left"
        case .topRight: return "Top right"
        case .bottomLeft: return "Bottom left"
        case .bottomRight: return "Bottom right"
        case .diagonal: return "Diagonal"
        }
    }
}

public struct WatermarkOptions: Sendable {
    public var text: String
    public var opacity: Double
    public var fontSize: CGFloat
    public var position: WatermarkPosition
    public var colorRed: Double
    public var colorGreen: Double
    public var colorBlue: Double

    public init(
        text: String = "CONFIDENTIAL",
        opacity: Double = 0.25,
        fontSize: CGFloat = 48,
        position: WatermarkPosition = .diagonal,
        colorRed: Double = 0.6,
        colorGreen: Double = 0.6,
        colorBlue: Double = 0.6
    ) {
        self.text = text
        self.opacity = opacity
        self.fontSize = fontSize
        self.position = position
        self.colorRed = colorRed
        self.colorGreen = colorGreen
        self.colorBlue = colorBlue
    }
}

public enum BatchOperation: String, CaseIterable, Identifiable, Sendable {
    case compress
    case ocrToText
    case imagesToPDF
    case pdfToPNG
    case removePassword // not without password — we skip; placeholder
    case convertImagesToJPEG
    case extractArchive
    case markdownToPDF

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .compress: return "Compress PDFs"
        case .ocrToText: return "OCR → Text"
        case .imagesToPDF: return "Images → PDF"
        case .pdfToPNG: return "PDF → PNG"
        case .removePassword: return "Unlock (needs password)"
        case .convertImagesToJPEG: return "Images → JPEG"
        case .extractArchive: return "Extract archives"
        case .markdownToPDF: return "Markdown → PDF"
        }
    }
}
