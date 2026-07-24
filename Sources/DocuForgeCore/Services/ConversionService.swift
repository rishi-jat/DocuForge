import Foundation
import AppKit
import PDFKit
import CoreText
import CoreGraphics

/// High-level format conversion orchestrating PDF, Image, and Office extractors.
public actor ConversionService {
    private let pdf = PDFService()
    private let images = ImageService()

    public init() {}

    public func convert(
        url: URL,
        to target: DocumentFormat,
        outputDirectory: URL
    ) async throws -> ProcessingResult {
        let source = DocumentFormat.detect(url: url)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        // Same format → copy
        if source == target {
            let out = outputDirectory.appendingPathComponent(url.lastPathComponent)
            if FileManager.default.fileExists(atPath: out.path) {
                try FileManager.default.removeItem(at: out)
            }
            try FileManager.default.copyItem(at: url, to: out)
            return ProcessingResult(
                outputURLs: [out],
                bytesIn: FileIO.fileSize(at: url),
                bytesOut: FileIO.fileSize(at: out),
                notes: ["Copied without conversion."]
            )
        }

        // Images → image
        if source.isImage && target.isImage {
            let out = outputDirectory.appendingPathComponent(
                url.deletingPathExtension().lastPathComponent + ".\(target.pathExtension)"
            )
            return try await images.convert(url: url, to: target, outputURL: out)
        }

        // Images → PDF
        if source.isImage && target == .pdf {
            let out = outputDirectory.appendingPathComponent(
                url.deletingPathExtension().lastPathComponent + ".pdf"
            )
            return try await pdf.imagesToPDF(urls: [url], outputURL: out)
        }

        // PDF → images
        if source == .pdf && target.isImage {
            return try await pdf.pdfToImages(url: url, format: target, outputDirectory: outputDirectory)
        }

        // PDF → text (via page string extraction + optional note)
        if source == .pdf && target == .txt {
            return try await pdfToPlainText(url: url, outputDirectory: outputDirectory)
        }

        // Text-like → PDF / TXT
        if source.isTextLike || source == .txt {
            return try convertTextLike(url: url, source: source, target: target, outputDirectory: outputDirectory)
        }

        // Office Open XML → text or PDF
        if source.isOfficeOpenXML {
            return try await convertOffice(url: url, source: source, target: target, outputDirectory: outputDirectory)
        }

        // iWork packages: try embedded PDF preview if present
        if source.isIWork {
            return try await convertIWork(url: url, source: source, target: target, outputDirectory: outputDirectory)
        }

        throw DocuForgeError.conversionFailed(
            "Cannot convert \(source.displayName) → \(target.displayName) offline. Supported paths: images↔images, images↔PDF, PDF→images/text, DOCX/PPTX/XLSX→text/PDF, RTF/HTML/TXT→PDF."
        )
    }

    // MARK: - Private paths

    private func pdfToPlainText(url: URL, outputDirectory: URL) async throws -> ProcessingResult {
        guard let doc = PDFDocument(url: url) else {
            throw DocuForgeError.pdfOperationFailed("Could not open PDF.")
        }
        var text = ""
        for i in 0..<doc.pageCount {
            if let page = doc.page(at: i), let s = page.string {
                text += s
                text += "\n\n"
            }
        }
        let out = outputDirectory.appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".txt")
        try text.write(to: out, atomically: true, encoding: .utf8)
        var notes: [String] = []
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            notes.append("No embedded text found. Use the OCR tool for scanned PDFs.")
        }
        return ProcessingResult(
            outputURLs: [out],
            bytesIn: FileIO.fileSize(at: url),
            bytesOut: FileIO.fileSize(at: out),
            notes: notes
        )
    }

    private func convertTextLike(
        url: URL,
        source: DocumentFormat,
        target: DocumentFormat,
        outputDirectory: URL
    ) throws -> ProcessingResult {
        let data = try Data(contentsOf: url)
        let text: String

        switch source {
        case .txt, .csv, .html:
            text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1)
                ?? ""
        case .rtf:
            if let attr = try? NSAttributedString(
                data: data,
                options: [.documentType: NSAttributedString.DocumentType.rtf],
                documentAttributes: nil
            ) {
                text = attr.string
            } else {
                text = String(data: data, encoding: .utf8) ?? ""
            }
        default:
            text = String(data: data, encoding: .utf8) ?? ""
        }

        switch target {
        case .txt:
            let out = outputDirectory.appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".txt")
            try text.write(to: out, atomically: true, encoding: .utf8)
            return ProcessingResult(outputURLs: [out], bytesIn: FileIO.fileSize(at: url), bytesOut: FileIO.fileSize(at: out))
        case .pdf:
            let out = outputDirectory.appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".pdf")
            // Use nonisolated call through PDFService actor — need async; use local helper
            return try textToPDFSync(text: text, outputURL: out, bytesIn: FileIO.fileSize(at: url))
        default:
            throw DocuForgeError.conversionFailed("Text sources convert to TXT or PDF only.")
        }
    }

    private func convertOffice(
        url: URL,
        source: DocumentFormat,
        target: DocumentFormat,
        outputDirectory: URL
    ) async throws -> ProcessingResult {
        let text = try OfficeOpenXML.extractText(from: url, format: source)
        let base = url.deletingPathExtension().lastPathComponent
        switch target {
        case .txt:
            let out = outputDirectory.appendingPathComponent(base + ".txt")
            try text.write(to: out, atomically: true, encoding: .utf8)
            return ProcessingResult(
                outputURLs: [out],
                bytesIn: FileIO.fileSize(at: url),
                bytesOut: FileIO.fileSize(at: out),
                notes: ["Extracted text from \(source.displayName). Layout and images are not preserved."]
            )
        case .pdf:
            let out = outputDirectory.appendingPathComponent(base + ".pdf")
            let result = try await pdf.textToPDF(text: text, title: base, outputURL: out)
            return ProcessingResult(
                outputURLs: result.outputURLs,
                bytesIn: FileIO.fileSize(at: url),
                bytesOut: result.bytesOut,
                notes: ["Converted \(source.displayName) text content to PDF. Complex layout is flattened to text."]
            )
        default:
            throw DocuForgeError.conversionFailed("Office documents convert to TXT or PDF offline.")
        }
    }

    private func convertIWork(
        url: URL,
        source: DocumentFormat,
        target: DocumentFormat,
        outputDirectory: URL
    ) async throws -> ProcessingResult {
        // iWork files are packages or single-file ZIP. Look for preview.pdf / QuickLook/Preview.pdf
        let data = try Data(contentsOf: url)
        // Try as directory package first
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            let candidates = [
                url.appendingPathComponent("QuickLook/Preview.pdf"),
                url.appendingPathComponent("preview.pdf")
            ]
            for c in candidates where FileManager.default.fileExists(atPath: c.path) {
                return try await convert(url: c, to: target, outputDirectory: outputDirectory)
            }
        }

        // Single-file iWork is a ZIP — try embedded QuickLook preview
        for key in ["QuickLook/Preview.pdf", "preview.pdf"] {
            if let pdfData = OfficeOpenXML.zipReadOptional(url: url, entry: key) {
                let temp = FileIO.temporaryURL(prefix: "iwork-preview", ext: "pdf")
                try pdfData.write(to: temp)
                defer { try? FileManager.default.removeItem(at: temp) }
                return try await convert(url: temp, to: target, outputDirectory: outputDirectory)
            }
        }
        _ = data // keep load for package size validation side-effect free

        throw DocuForgeError.conversionFailed(
            "Could not extract a preview from this \(source.displayName) file. Open it in \(source.displayName) and export to PDF for full fidelity."
        )
    }

    private func textToPDFSync(text: String, outputURL: URL, bytesIn: Int64) throws -> ProcessingResult {
        // Direct Core Graphics path to avoid actor re-entry from sync context
        let pageRect = CGRect(x: 0, y: 0, width: 612, height: 792)
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: nil, nil) else {
            throw DocuForgeError.conversionFailed("Could not create PDF context.")
        }
        var mediaBox = pageRect
        let margin: CGFloat = 54
        let font = NSFont.systemFont(ofSize: 12)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.black,
            .paragraphStyle: paragraph
        ]
        let attr = NSAttributedString(string: text, attributes: attrs)
        // Simple single-page for short text; multi-page via framesetter-like chunking
        let full = attr.string as NSString
        var location = 0
        while location < full.length {
            context.beginPage(mediaBox: &mediaBox)
            let textRect = CGRect(x: margin, y: margin, width: pageRect.width - margin * 2, height: pageRect.height - margin * 2)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            let remaining = full.substring(from: location)
            let chunk = NSAttributedString(string: remaining, attributes: attrs)
            let framesetter = CTFramesetterCreateWithAttributedString(chunk)
            let path = CGPath(rect: textRect, transform: nil)
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
            CTFrameDraw(frame, context)
            let visible = CTFrameGetVisibleStringRange(frame)
            location += max(visible.length, 1)
            NSGraphicsContext.restoreGraphicsState()
            context.endPage()
            if visible.length == 0 { break }
        }
        context.closePDF()
        try (data as Data).write(to: outputURL)
        return ProcessingResult(outputURLs: [outputURL], bytesIn: bytesIn, bytesOut: FileIO.fileSize(at: outputURL))
    }
}
