import Foundation
import PDFKit
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Offline PDF operations powered by PDFKit + Core Graphics.
public actor PDFService {
    public init() {}

    // MARK: - Introspection

    public func pageCount(at url: URL) throws -> Int {
        guard let doc = PDFDocument(url: url) else {
            throw DocuForgeError.pdfOperationFailed("Could not open PDF at \(url.lastPathComponent)")
        }
        return doc.pageCount
    }

    public func loadDocument(at url: URL) throws -> PDFDocument {
        guard let doc = PDFDocument(url: url) else {
            throw DocuForgeError.pdfOperationFailed("Could not open PDF at \(url.lastPathComponent)")
        }
        return doc
    }

    // MARK: - Merge

    public func merge(urls: [URL], outputURL: URL) throws -> ProcessingResult {
        guard urls.count >= 2 else {
            throw DocuForgeError.invalidInput("Add at least two PDFs to merge.")
        }
        let merged = PDFDocument()
        var bytesIn: Int64 = 0
        for url in urls {
            bytesIn += FileIO.fileSize(at: url)
            guard let doc = PDFDocument(url: url) else {
                throw DocuForgeError.pdfOperationFailed("Could not open \(url.lastPathComponent)")
            }
            for i in 0..<doc.pageCount {
                guard let page = doc.page(at: i) else { continue }
                merged.insert(page, at: merged.pageCount)
            }
        }
        guard merged.write(to: outputURL) else {
            throw DocuForgeError.pdfOperationFailed("Failed to write merged PDF.")
        }
        return ProcessingResult(
            outputURLs: [outputURL],
            bytesIn: bytesIn,
            bytesOut: FileIO.fileSize(at: outputURL)
        )
    }

    // MARK: - Split

    public func split(
        url: URL,
        mode: SplitMode,
        rangesText: String,
        everyN: Int,
        outputDirectory: URL
    ) throws -> ProcessingResult {
        let doc = try loadDocument(at: url)
        let count = doc.pageCount
        guard count > 0 else {
            throw DocuForgeError.invalidInput("PDF has no pages.")
        }

        var ranges: [PageRange] = []
        switch mode {
        case .everyPage:
            ranges = (1...count).map { PageRange(start: $0, end: $0) }
        case .ranges:
            ranges = try PageRangeParser.parse(rangesText, pageCount: count)
        case .everyN:
            let n = max(1, everyN)
            var start = 1
            while start <= count {
                let end = min(start + n - 1, count)
                ranges.append(PageRange(start: start, end: end))
                start = end + 1
            }
        }

        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        var outputs: [URL] = []
        let base = url.deletingPathExtension().lastPathComponent
        let bytesIn = FileIO.fileSize(at: url)

        for (idx, range) in ranges.enumerated() {
            let part = PDFDocument()
            for pageIndex in (range.start - 1)..<range.end {
                guard let page = doc.page(at: pageIndex) else { continue }
                part.insert(page, at: part.pageCount)
            }
            let name: String
            if range.start == range.end {
                name = "\(base)-p\(range.start).pdf"
            } else {
                name = "\(base)-p\(range.start)-\(range.end).pdf"
            }
            let out = outputDirectory.appendingPathComponent(name)
            // Avoid overwrite collisions
            let finalOut = uniqueURL(out, index: idx)
            guard part.write(to: finalOut) else {
                throw DocuForgeError.pdfOperationFailed("Failed to write \(finalOut.lastPathComponent)")
            }
            outputs.append(finalOut)
        }

        let bytesOut = outputs.reduce(Int64(0)) { $0 + FileIO.fileSize(at: $1) }
        return ProcessingResult(outputURLs: outputs, bytesIn: bytesIn, bytesOut: bytesOut)
    }

    // MARK: - Compress

    public func compress(url: URL, quality: CompressQuality, outputURL: URL) throws -> ProcessingResult {
        let doc = try loadDocument(at: url)
        let bytesIn = FileIO.fileSize(at: url)
        let compressed = PDFDocument()

        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            let scale = quality.scale
            let pixelSize = CGSize(
                width: max(1, bounds.width * scale * 1.5),
                height: max(1, bounds.height * scale * 1.5)
            )

            guard let image = render(page: page, pixelSize: pixelSize),
                  let jpegData = jpegData(from: image, quality: quality.jpegQuality),
                  let newPage = pageFromJPEG(data: jpegData, mediaBox: bounds) else {
                // Fallback: keep original page if re-encode fails
                compressed.insert(page, at: compressed.pageCount)
                continue
            }
            compressed.insert(newPage, at: compressed.pageCount)
        }

        guard compressed.write(to: outputURL) else {
            throw DocuForgeError.pdfOperationFailed("Failed to write compressed PDF.")
        }
        let bytesOut = FileIO.fileSize(at: outputURL)
        var notes: [String] = []
        if bytesOut >= bytesIn {
            notes.append("Output is not smaller than the original; the PDF may already be optimized or mostly vector.")
        }
        return ProcessingResult(outputURLs: [outputURL], bytesIn: bytesIn, bytesOut: bytesOut, notes: notes)
    }

    // MARK: - Password protect / unlock

    public func protect(url: URL, userPassword: String, ownerPassword: String?, outputURL: URL) throws -> ProcessingResult {
        let doc = try loadDocument(at: url)
        let owner = ownerPassword?.isEmpty == false ? ownerPassword! : userPassword
        guard !userPassword.isEmpty else {
            throw DocuForgeError.invalidInput("Enter a password.")
        }
        let options: [PDFDocumentWriteOption: Any] = [
            .userPasswordOption: userPassword,
            .ownerPasswordOption: owner
        ]
        guard doc.write(to: outputURL, withOptions: options) else {
            throw DocuForgeError.pdfOperationFailed("Failed to write password-protected PDF.")
        }
        return ProcessingResult(
            outputURLs: [outputURL],
            bytesIn: FileIO.fileSize(at: url),
            bytesOut: FileIO.fileSize(at: outputURL)
        )
    }

    public func unlock(url: URL, password: String, outputURL: URL) throws -> ProcessingResult {
        guard let doc = PDFDocument(url: url) else {
            throw DocuForgeError.pdfOperationFailed("Could not open PDF.")
        }
        if doc.isLocked {
            guard doc.unlock(withPassword: password) else {
                throw DocuForgeError.invalidInput("Incorrect password.")
            }
        }
        // PDFKit often re-saves encryption metadata if we write the same document.
        // Rebuild pages into a fresh document to produce a truly open PDF.
        let clean = PDFDocument()
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            clean.insert(page, at: clean.pageCount)
        }
        guard clean.pageCount > 0 else {
            throw DocuForgeError.pdfOperationFailed("No pages available after unlock.")
        }
        guard clean.write(to: outputURL) else {
            throw DocuForgeError.pdfOperationFailed("Failed to write unlocked PDF.")
        }
        return ProcessingResult(
            outputURLs: [outputURL],
            bytesIn: FileIO.fileSize(at: url),
            bytesOut: FileIO.fileSize(at: outputURL)
        )
    }

    // MARK: - Watermark

    public func watermark(url: URL, options: WatermarkOptions, outputURL: URL) throws -> ProcessingResult {
        let doc = try loadDocument(at: url)
        let outDoc = PDFDocument()

        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            let scale: CGFloat = 2.0
            let pixelSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)

            guard let baseImage = render(page: page, pixelSize: pixelSize) else {
                outDoc.insert(page, at: outDoc.pageCount)
                continue
            }

            let stamped = drawWatermark(on: baseImage, options: options)
            guard let jpeg = jpegData(from: stamped, quality: 0.92),
                  let newPage = pageFromJPEG(data: jpeg, mediaBox: bounds) else {
                outDoc.insert(page, at: outDoc.pageCount)
                continue
            }
            outDoc.insert(newPage, at: outDoc.pageCount)
        }

        guard outDoc.write(to: outputURL) else {
            throw DocuForgeError.pdfOperationFailed("Failed to write watermarked PDF.")
        }
        return ProcessingResult(
            outputURLs: [outputURL],
            bytesIn: FileIO.fileSize(at: url),
            bytesOut: FileIO.fileSize(at: outputURL)
        )
    }

    // MARK: - Page management

    public func reorderRotateDelete(
        url: URL,
        /// New order as 0-based source indices. Omit deleted pages.
        orderedIndices: [Int],
        /// Rotations in degrees (0, 90, 180, 270) keyed by original 0-based index.
        rotations: [Int: Int],
        outputURL: URL
    ) throws -> ProcessingResult {
        let doc = try loadDocument(at: url)
        let outDoc = PDFDocument()
        for srcIndex in orderedIndices {
            guard let page = doc.page(at: srcIndex) else { continue }
            if let deg = rotations[srcIndex], deg % 360 != 0 {
                // PDFKit rotation is clockwise in degrees
                page.rotation = (page.rotation + deg) % 360
            }
            outDoc.insert(page, at: outDoc.pageCount)
        }
        guard outDoc.write(to: outputURL) else {
            throw DocuForgeError.pdfOperationFailed("Failed to write modified PDF.")
        }
        return ProcessingResult(
            outputURLs: [outputURL],
            bytesIn: FileIO.fileSize(at: url),
            bytesOut: FileIO.fileSize(at: outputURL)
        )
    }

    public func extractPages(url: URL, indices: [Int], outputURL: URL) throws -> ProcessingResult {
        try reorderRotateDelete(url: url, orderedIndices: indices, rotations: [:], outputURL: outputURL)
    }

    // MARK: - PDF ↔ Images

    public func pdfToImages(url: URL, format: DocumentFormat, outputDirectory: URL) throws -> ProcessingResult {
        guard format.isImage else {
            throw DocuForgeError.invalidInput("Target must be an image format.")
        }
        let doc = try loadDocument(at: url)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let base = url.deletingPathExtension().lastPathComponent
        var outputs: [URL] = []
        let bytesIn = FileIO.fileSize(at: url)

        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            let pixelSize = CGSize(width: bounds.width * 2, height: bounds.height * 2)
            guard let image = render(page: page, pixelSize: pixelSize) else { continue }
            let out = outputDirectory.appendingPathComponent("\(base)-p\(i + 1).\(format.pathExtension)")
            try ImageServiceWrite.write(image: image, to: out, format: format)
            outputs.append(out)
        }
        let bytesOut = outputs.reduce(Int64(0)) { $0 + FileIO.fileSize(at: $1) }
        return ProcessingResult(outputURLs: outputs, bytesIn: bytesIn, bytesOut: bytesOut)
    }

    public func imagesToPDF(urls: [URL], outputURL: URL) throws -> ProcessingResult {
        guard !urls.isEmpty else {
            throw DocuForgeError.invalidInput("Add at least one image.")
        }
        let doc = PDFDocument()
        var bytesIn: Int64 = 0
        for url in urls {
            bytesIn += FileIO.fileSize(at: url)
            guard let image = NSImage(contentsOf: url) else {
                throw DocuForgeError.conversionFailed("Could not load image \(url.lastPathComponent)")
            }
            guard let page = PDFPage(image: image) else {
                throw DocuForgeError.conversionFailed("Could not create PDF page from \(url.lastPathComponent)")
            }
            doc.insert(page, at: doc.pageCount)
        }
        guard doc.write(to: outputURL) else {
            throw DocuForgeError.pdfOperationFailed("Failed to write PDF from images.")
        }
        return ProcessingResult(
            outputURLs: [outputURL],
            bytesIn: bytesIn,
            bytesOut: FileIO.fileSize(at: outputURL)
        )
    }

    public func textToPDF(text: String, title: String, outputURL: URL) throws -> ProcessingResult {
        let pageRect = CGRect(x: 0, y: 0, width: 612, height: 792) // US Letter
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: nil, nil) else {
            throw DocuForgeError.conversionFailed("Could not create PDF context.")
        }

        var mediaBox = pageRect
        context.beginPage(mediaBox: &mediaBox)

        let margin: CGFloat = 54
        let textRect = CGRect(
            x: margin,
            y: margin,
            width: pageRect.width - margin * 2,
            height: pageRect.height - margin * 2
        )

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.black,
            .paragraphStyle: paragraph
        ]
        let attr = NSAttributedString(string: text, attributes: attrs)

        // Use NSGraphicsContext bridge
        NSGraphicsContext.saveGraphicsState()
        let nsContext = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.current = nsContext
        attr.draw(with: textRect, options: [.usesLineFragmentOrigin, .usesFontLeading])
        NSGraphicsContext.restoreGraphicsState()

        context.endPage()
        context.closePDF()

        try (data as Data).write(to: outputURL)
        return ProcessingResult(outputURLs: [outputURL], bytesOut: FileIO.fileSize(at: outputURL))
    }

    // MARK: - Helpers

    private func render(page: PDFPage, pixelSize: CGSize) -> NSImage? {
        let image = NSImage(size: pixelSize)
        image.lockFocus()
        if let context = NSGraphicsContext.current?.cgContext {
            context.setFillColor(NSColor.white.cgColor)
            context.fill(CGRect(origin: .zero, size: pixelSize))
            context.saveGState()
            let bounds = page.bounds(for: .mediaBox)
            let sx = pixelSize.width / bounds.width
            let sy = pixelSize.height / bounds.height
            context.scaleBy(x: sx, y: sy)
            page.draw(with: .mediaBox, to: context)
            context.restoreGState()
        }
        image.unlockFocus()
        return image
    }

    private func jpegData(from image: NSImage, quality: CGFloat) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: quality])
    }

    private func pageFromJPEG(data: Data, mediaBox: CGRect) -> PDFPage? {
        guard let image = NSImage(data: data) else { return nil }
        return PDFPage(image: image)
    }

    private func drawWatermark(on image: NSImage, options: WatermarkOptions) -> NSImage {
        let size = image.size
        let out = NSImage(size: size)
        out.lockFocus()
        image.draw(in: CGRect(origin: .zero, size: size))

        let color = NSColor(
            calibratedRed: options.colorRed,
            green: options.colorGreen,
            blue: options.colorBlue,
            alpha: options.opacity
        )
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: options.fontSize),
            .foregroundColor: color
        ]
        let attr = NSAttributedString(string: options.text, attributes: attrs)
        let textSize = attr.size()

        var origin = CGPoint.zero
        switch options.position {
        case .center, .diagonal:
            origin = CGPoint(x: (size.width - textSize.width) / 2, y: (size.height - textSize.height) / 2)
        case .topLeft:
            origin = CGPoint(x: 40, y: size.height - textSize.height - 40)
        case .topRight:
            origin = CGPoint(x: size.width - textSize.width - 40, y: size.height - textSize.height - 40)
        case .bottomLeft:
            origin = CGPoint(x: 40, y: 40)
        case .bottomRight:
            origin = CGPoint(x: size.width - textSize.width - 40, y: 40)
        }

        if options.position == .diagonal, let ctx = NSGraphicsContext.current?.cgContext {
            ctx.saveGState()
            ctx.translateBy(x: size.width / 2, y: size.height / 2)
            ctx.rotate(by: -.pi / 4)
            attr.draw(at: CGPoint(x: -textSize.width / 2, y: -textSize.height / 2))
            ctx.restoreGState()
        } else {
            attr.draw(at: origin)
        }

        out.unlockFocus()
        return out
    }

    private func uniqueURL(_ url: URL, index: Int) -> URL {
        if !FileManager.default.fileExists(atPath: url.path) { return url }
        let parent = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        return parent.appendingPathComponent("\(base)-\(index).\(ext)")
    }
}

/// Shared image write helpers used by PDFService without creating an actor cycle.
enum ImageServiceWrite {
    static func write(image: NSImage, to url: URL, format: DocumentFormat, jpegQuality: CGFloat = 0.9) throws {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else {
            throw DocuForgeError.conversionFailed("Could not create bitmap for \(url.lastPathComponent)")
        }

        let data: Data?
        switch format {
        case .png:
            data = rep.representation(using: .png, properties: [:])
        case .jpeg:
            data = rep.representation(using: .jpeg, properties: [.compressionFactor: jpegQuality])
        case .gif:
            data = rep.representation(using: .gif, properties: [:])
        case .bmp:
            data = rep.representation(using: .bmp, properties: [:])
        case .tiff:
            data = rep.representation(using: .tiff, properties: [:])
        case .heic, .webp:
            // Use ImageIO for HEIC/WebP
            data = try imageIOEncode(rep: rep, format: format, jpegQuality: jpegQuality)
        default:
            throw DocuForgeError.unsupportedFormat(format)
        }

        guard let data else {
            throw DocuForgeError.conversionFailed("Failed to encode \(format.displayName)")
        }
        try data.write(to: url, options: .atomic)
    }

    private static func imageIOEncode(rep: NSBitmapImageRep, format: DocumentFormat, jpegQuality: CGFloat) throws -> Data {
        guard let cgImage = rep.cgImage else {
            throw DocuForgeError.conversionFailed("Missing CGImage")
        }
        let data = NSMutableData()
        let uti: CFString
        var props: [CFString: Any] = [:]
        switch format {
        case .heic:
            uti = UTType.heic.identifier as CFString
            props[kCGImageDestinationLossyCompressionQuality] = jpegQuality
        case .webp:
            uti = UTType.webP.identifier as CFString
            props[kCGImageDestinationLossyCompressionQuality] = jpegQuality
        case .jpeg:
            uti = UTType.jpeg.identifier as CFString
            props[kCGImageDestinationLossyCompressionQuality] = jpegQuality
        case .png:
            uti = UTType.png.identifier as CFString
        case .tiff:
            uti = UTType.tiff.identifier as CFString
        default:
            throw DocuForgeError.unsupportedFormat(format)
        }
        guard let dest = CGImageDestinationCreateWithData(data, uti, 1, nil) else {
            throw DocuForgeError.conversionFailed("ImageIO destination failed for \(format.displayName)")
        }
        CGImageDestinationAddImage(dest, cgImage, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw DocuForgeError.conversionFailed("ImageIO finalize failed for \(format.displayName)")
        }
        return data as Data
    }
}
