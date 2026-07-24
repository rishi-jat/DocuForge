import Foundation
import PDFKit
import AppKit
import CoreGraphics

/// In-memory PDF editing session. Mutations apply to a working copy; call `save` to persist.
public actor PDFEditorService {
    public init() {}

    public struct SessionSnapshot: Sendable {
        public let pageCount: Int
        public let fileName: String
        public let isEncrypted: Bool
        public let pageLabels: [String]
        public let pageRotations: [Int]
    }

    // Working documents keyed by session id
    private var documents: [UUID: PDFDocument] = [:]
    private var sourceURLs: [UUID: URL] = [:]
    private var dirty: [UUID: Bool] = [:]

    public func open(url: URL) throws -> (id: UUID, snapshot: SessionSnapshot) {
        guard let doc = PDFDocument(url: url) else {
            throw DocuForgeError.pdfOperationFailed("Could not open \(url.lastPathComponent) for editing.")
        }
        if doc.isLocked {
            throw DocuForgeError.invalidInput("PDF is password-locked. Unlock it in the Password tool first.")
        }
        let id = UUID()
        documents[id] = doc
        sourceURLs[id] = url
        dirty[id] = false
        return (id, snapshot(id: id, doc: doc, url: url))
    }

    public func snapshot(id: UUID) throws -> SessionSnapshot {
        let doc = try document(id)
        let url = sourceURLs[id] ?? URL(fileURLWithPath: "document.pdf")
        return snapshot(id: id, doc: doc, url: url)
    }

    public func isDirty(id: UUID) -> Bool { dirty[id] ?? false }

    public func close(id: UUID) {
        documents[id] = nil
        sourceURLs[id] = nil
        dirty[id] = nil
    }

    // MARK: - Page ops

    public func rotatePage(id: UUID, pageIndex: Int, degrees: Int) throws {
        let doc = try document(id)
        guard let page = doc.page(at: pageIndex) else {
            throw DocuForgeError.invalidInput("Invalid page index \(pageIndex).")
        }
        page.rotation = (page.rotation + degrees) % 360
        if page.rotation < 0 { page.rotation += 360 }
        dirty[id] = true
    }

    public func deletePages(id: UUID, indices: [Int]) throws {
        let doc = try document(id)
        let sorted = indices.sorted(by: >)
        for i in sorted {
            guard i >= 0, i < doc.pageCount else { continue }
            doc.removePage(at: i)
        }
        guard doc.pageCount > 0 else {
            throw DocuForgeError.invalidInput("Cannot delete every page. Keep at least one.")
        }
        dirty[id] = true
    }

    public func movePage(id: UUID, from: Int, to: Int) throws {
        let doc = try document(id)
        guard from >= 0, from < doc.pageCount, to >= 0, to <= doc.pageCount, from != to else {
            throw DocuForgeError.invalidInput("Invalid page move.")
        }
        var indices = Array(0..<doc.pageCount)
        let item = indices.remove(at: from)
        let insertAt = min(to, indices.count)
        indices.insert(item, at: insertAt)
        try reorderPages(id: id, orderedIndices: indices)
    }

    public func reorderPages(id: UUID, orderedIndices: [Int]) throws {
        let doc = try document(id)
        let out = PDFDocument()
        for i in orderedIndices {
            guard let page = doc.page(at: i) else { continue }
            out.insert(page, at: out.pageCount)
        }
        guard out.pageCount > 0 else {
            throw DocuForgeError.invalidInput("Reorder produced an empty document.")
        }
        documents[id] = out
        dirty[id] = true
    }

    public func insertBlankPage(id: UUID, at index: Int, size: CGSize = CGSize(width: 612, height: 792)) throws {
        let doc = try document(id)
        let blank = blankPage(size: size)
        let at = min(max(0, index), doc.pageCount)
        doc.insert(blank, at: at)
        dirty[id] = true
    }

    public func insertImagePage(id: UUID, imageURL: URL, at index: Int) throws {
        let doc = try document(id)
        guard let image = NSImage(contentsOf: imageURL),
              let page = PDFPage(image: image) else {
            throw DocuForgeError.conversionFailed("Could not create page from \(imageURL.lastPathComponent)")
        }
        let at = min(max(0, index), doc.pageCount)
        doc.insert(page, at: at)
        dirty[id] = true
    }

    // MARK: - Annotations

    public enum AnnotationKind: String, Sendable, CaseIterable, Identifiable {
        case highlight
        case freeText
        case inkSignature
        case stamp
        case underline
        case strikethrough

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .highlight: return "Highlight"
            case .freeText: return "Text box"
            case .inkSignature: return "Signature"
            case .stamp: return "Stamp"
            case .underline: return "Underline"
            case .strikethrough: return "Strikethrough"
            }
        }
    }

    public func addHighlight(
        id: UUID,
        pageIndex: Int,
        rect: CGRect,
        color: (r: Double, g: Double, b: Double) = (1, 0.9, 0.2)
    ) throws {
        let page = try page(id: id, index: pageIndex)
        let ann = PDFAnnotation(bounds: rect, forType: .highlight, withProperties: nil)
        ann.color = NSColor(calibratedRed: color.r, green: color.g, blue: color.b, alpha: 0.45)
        page.addAnnotation(ann)
        dirty[id] = true
    }

    public func addFreeText(
        id: UUID,
        pageIndex: Int,
        rect: CGRect,
        text: String,
        fontSize: CGFloat = 14
    ) throws {
        let page = try page(id: id, index: pageIndex)
        let ann = PDFAnnotation(bounds: rect, forType: .freeText, withProperties: nil)
        ann.contents = text
        ann.font = NSFont.systemFont(ofSize: fontSize)
        ann.fontColor = .black
        ann.color = NSColor.white.withAlphaComponent(0.01)
        page.addAnnotation(ann)
        dirty[id] = true
    }

    public func addUnderline(id: UUID, pageIndex: Int, rect: CGRect) throws {
        let page = try page(id: id, index: pageIndex)
        let ann = PDFAnnotation(bounds: rect, forType: .underline, withProperties: nil)
        ann.color = .systemBlue
        page.addAnnotation(ann)
        dirty[id] = true
    }

    public func addStrikethrough(id: UUID, pageIndex: Int, rect: CGRect) throws {
        let page = try page(id: id, index: pageIndex)
        let ann = PDFAnnotation(bounds: rect, forType: .strikeOut, withProperties: nil)
        ann.color = .systemRed
        page.addAnnotation(ann)
        dirty[id] = true
    }

    /// Simple ink signature drawn inside `rect` (page coordinates).
    public func addSignature(
        id: UUID,
        pageIndex: Int,
        rect: CGRect,
        pathPoints: [CGPoint] = []
    ) throws {
        let page = try page(id: id, index: pageIndex)
        let ann = PDFAnnotation(bounds: rect, forType: .ink, withProperties: nil)
        ann.color = .black
        let bp = NSBezierPath()
        if pathPoints.count >= 2 {
            bp.move(to: pathPoints[0])
            for p in pathPoints.dropFirst() { bp.line(to: p) }
        } else {
            // Default signature flourish inside local bounds
            let local = CGRect(origin: .zero, size: rect.size)
            bp.move(to: CGPoint(x: 4, y: local.midY))
            bp.curve(
                to: CGPoint(x: local.maxX - 4, y: local.midY),
                controlPoint1: CGPoint(x: local.width * 0.3, y: local.maxY - 4),
                controlPoint2: CGPoint(x: local.width * 0.7, y: local.minY + 4)
            )
        }
        ann.add(bp)
        page.addAnnotation(ann)
        dirty[id] = true
    }

    public func addStamp(
        id: UUID,
        pageIndex: Int,
        rect: CGRect,
        text: String
    ) throws {
        let page = try page(id: id, index: pageIndex)
        let ann = PDFAnnotation(bounds: rect, forType: .stamp, withProperties: nil)
        ann.contents = text
        ann.color = NSColor.systemRed.withAlphaComponent(0.85)
        page.addAnnotation(ann)
        dirty[id] = true
    }

    public func addWatermarkText(
        id: UUID,
        text: String,
        opacity: Double = 0.25
    ) throws {
        let doc = try document(id)
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            let w = min(bounds.width * 0.7, 360)
            let h: CGFloat = 48
            let rect = CGRect(
                x: (bounds.width - w) / 2,
                y: (bounds.height - h) / 2,
                width: w,
                height: h
            )
            let ann = PDFAnnotation(bounds: rect, forType: .freeText, withProperties: nil)
            ann.contents = text
            ann.font = NSFont.boldSystemFont(ofSize: 28)
            ann.fontColor = NSColor.gray.withAlphaComponent(opacity)
            ann.color = .clear
            ann.alignment = .center
            page.addAnnotation(ann)
        }
        dirty[id] = true
    }

    public func clearAnnotations(id: UUID, pageIndex: Int) throws {
        let page = try page(id: id, index: pageIndex)
        for ann in page.annotations {
            page.removeAnnotation(ann)
        }
        dirty[id] = true
    }

    // MARK: - Crop

    /// Crop a page by setting its crop box (normalized 0...1 relative to media box).
    public func cropPage(
        id: UUID,
        pageIndex: Int,
        normalizedRect: CGRect
    ) throws {
        let page = try page(id: id, index: pageIndex)
        let media = page.bounds(for: .mediaBox)
        let nx = max(0, min(1, normalizedRect.origin.x))
        let ny = max(0, min(1, normalizedRect.origin.y))
        let nw = max(0.05, min(1 - nx, normalizedRect.size.width))
        let nh = max(0.05, min(1 - ny, normalizedRect.size.height))
        let crop = CGRect(
            x: media.minX + nx * media.width,
            y: media.minY + ny * media.height,
            width: nw * media.width,
            height: nh * media.height
        )
        page.setBounds(crop, for: .cropBox)
        dirty[id] = true
    }

    // MARK: - Save

    public func save(id: UUID, to url: URL? = nil) throws -> ProcessingResult {
        let doc = try document(id)
        let target = url ?? sourceURLs[id]
        guard let target else {
            throw DocuForgeError.ioError("No save location.")
        }
        // Write atomically via temp
        let temp = FileIO.temporaryURL(prefix: "edit-save", ext: "pdf")
        guard doc.write(to: temp) else {
            throw DocuForgeError.pdfOperationFailed("Failed to write edited PDF.")
        }
        if FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.removeItem(at: target)
        }
        try FileManager.default.copyItem(at: temp, to: target)
        try? FileManager.default.removeItem(at: temp)
        sourceURLs[id] = target
        dirty[id] = false
        // Reload from disk to normalize
        if let reloaded = PDFDocument(url: target) {
            documents[id] = reloaded
        }
        return ProcessingResult(
            outputURLs: [target],
            bytesOut: FileIO.fileSize(at: target),
            notes: ["Saved PDF with annotations and page edits."]
        )
    }

    public func saveAs(id: UUID, url: URL) throws -> ProcessingResult {
        try save(id: id, to: url)
    }

    /// Render a page preview thumbnail (for UI).
    public func pagePreview(id: UUID, pageIndex: Int, maxEdge: CGFloat = 240) throws -> Data {
        let page = try page(id: id, index: pageIndex)
        let bounds = page.bounds(for: .mediaBox)
        let scale = maxEdge / max(bounds.width, bounds.height)
        let size = CGSize(width: max(1, bounds.width * scale), height: max(1, bounds.height * scale))
        let image = NSImage(size: size)
        image.lockFocus()
        if let ctx = NSGraphicsContext.current?.cgContext {
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fill(CGRect(origin: .zero, size: size))
            ctx.saveGState()
            ctx.scaleBy(x: scale, y: scale)
            page.draw(with: .mediaBox, to: ctx)
            ctx.restoreGState()
        }
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            throw DocuForgeError.conversionFailed("Preview render failed.")
        }
        return png
    }

    public func pageBounds(id: UUID, pageIndex: Int) throws -> CGRect {
        try page(id: id, index: pageIndex).bounds(for: .mediaBox)
    }

    // MARK: - Helpers

    private func document(_ id: UUID) throws -> PDFDocument {
        guard let doc = documents[id] else {
            throw DocuForgeError.invalidInput("Editor session is not open.")
        }
        return doc
    }

    private func page(id: UUID, index: Int) throws -> PDFPage {
        let doc = try document(id)
        guard let page = doc.page(at: index) else {
            throw DocuForgeError.invalidInput("Invalid page index \(index).")
        }
        return page
    }

    private func snapshot(id: UUID, doc: PDFDocument, url: URL) -> SessionSnapshot {
        var labels: [String] = []
        var rotations: [Int] = []
        for i in 0..<doc.pageCount {
            labels.append("Page \(i + 1)")
            rotations.append(doc.page(at: i)?.rotation ?? 0)
        }
        return SessionSnapshot(
            pageCount: doc.pageCount,
            fileName: url.lastPathComponent,
            isEncrypted: doc.isEncrypted,
            pageLabels: labels,
            pageRotations: rotations
        )
    }

    private func blankPage(size: CGSize) -> PDFPage {
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSBezierPath.fill(NSRect(origin: .zero, size: size))
        image.unlockFocus()
        return PDFPage(image: image) ?? PDFPage()
    }
}

