import Foundation
import AppKit
import PDFKit
import CoreGraphics

/// Builds a `DocumentScene` from files. PDF/DOCX become editable objects on a canvas —
/// not an OCR side-panel workflow.
public enum DocumentImporter {

    public static func open(url: URL) throws -> DocumentScene {
        let format = DocumentFormat.detect(url: url)
        switch format {
        case .pdf:
            return try importPDF(url: url)
        case .txt, .markdown, .rtf, .html:
            return try importPlainText(url: url, format: format)
        case .docx, .doc, .odt:
            return try importViaTextutil(url: url, title: url.deletingPathExtension().lastPathComponent)
        case .png, .jpeg, .tiff, .gif, .bmp, .heic, .webp:
            return try importImage(url: url)
        default:
            // Best effort: if PDFKit can open, treat as PDF
            if PDFDocument(url: url) != nil {
                return try importPDF(url: url)
            }
            throw DocuForgeError.invalidInput("Cannot open \(format.displayName) as a canvas document. Convert to PDF first.")
        }
    }

    // MARK: - PDF → scene (text frames + optional page backdrop for layout fidelity)

    public static func importPDF(url: URL) throws -> DocumentScene {
        guard let doc = PDFDocument(url: url) else {
            throw DocuForgeError.pdfOperationFailed("Could not open PDF \(url.lastPathComponent)")
        }
        if doc.isLocked {
            throw DocuForgeError.invalidInput("PDF is password-locked.")
        }

        var pages: [DocPage] = []
        for i in 0..<doc.pageCount {
            guard let pdfPage = doc.page(at: i) else { continue }
            let media = pdfPage.bounds(for: .mediaBox)
            let pageH = media.height
            let pageW = media.width

            var objects: [CanvasObject] = []
            var z = 0

            // Extract text runs as editable text frames (primary edit surface).
            let lines = extractTextLines(page: pdfPage, document: doc)
            for line in lines {
                // PDF coords are bottom-left → convert to top-left
                let topLeft = CGRect(
                    x: line.bounds.minX - media.minX,
                    y: pageH - (line.bounds.maxY - media.minY),
                    width: max(8, line.bounds.width),
                    height: max(8, line.bounds.height)
                )
                let style = TextStyle(
                    fontName: "Helvetica",
                    fontSize: estimateFontSize(height: line.bounds.height, text: line.text),
                    bold: line.bounds.height >= 16,
                    color: .black
                )
                z += 1
                objects.append(CanvasObject(
                    frame: topLeft.insetBy(dx: -1, dy: -1),
                    zIndex: z,
                    name: String(line.text.prefix(40)),
                    kind: .text(.init(text: line.text, style: style))
                ))
            }

            // Backdrop: full page render WITHOUT embedding as the only content —
            // used only when almost no text was found (scan/image PDF).
            var backdrop: Data? = nil
            if objects.filter(\.isText).count < 2 {
                if let img = renderPageImage(pdfPage, scale: 2.0),
                   let tiff = img.tiffRepresentation,
                   let rep = NSBitmapImageRep(data: tiff),
                   let png = rep.representation(using: .png, properties: [:]) {
                    backdrop = png
                    z += 1
                    objects.insert(CanvasObject(
                        frame: CGRect(x: 0, y: 0, width: pageW, height: pageH),
                        zIndex: 0,
                        locked: true,
                        name: "Page image",
                        kind: .image(.init(imageData: png))
                    ), at: 0)
                }
            }

            pages.append(DocPage(
                size: CGSize(width: pageW, height: pageH),
                background: .white,
                objects: objects,
                backdropImageData: backdrop
            ))
        }

        if pages.isEmpty {
            pages = [DocPage()]
        }

        return DocumentScene(
            title: url.deletingPathExtension().lastPathComponent,
            pages: pages
        )
    }

    // MARK: - Plain text / markdown

    public static func importPlainText(url: URL, format: DocumentFormat) throws -> DocumentScene {
        let raw: String
        if format == .rtf {
            if let attr = try? NSAttributedString(
                url: url,
                options: [.documentType: NSAttributedString.DocumentType.rtf],
                documentAttributes: nil
            ) {
                raw = attr.string
            } else {
                raw = try String(contentsOf: url, encoding: .utf8)
            }
        } else {
            raw = try String(contentsOf: url, encoding: .utf8)
        }
        return sceneFromPlainText(raw, title: url.deletingPathExtension().lastPathComponent)
    }

    public static func sceneFromPlainText(_ text: String, title: String) -> DocumentScene {
        let pageWidth: CGFloat = 612
        let pageHeight: CGFloat = 792
        let margin: CGFloat = 72
        let maxWidth = pageWidth - margin * 2
        let lines = text.components(separatedBy: .newlines)
        var y: CGFloat = margin
        var z = 0
        var pages: [DocPage] = []
        var current: [CanvasObject] = []

        func flushPage() {
            pages.append(DocPage(
                size: CGSize(width: pageWidth, height: pageHeight),
                objects: current
            ))
            current = []
            y = margin
        }

        for line in lines {
            let isHeading = line.hasPrefix("#") || (line.count < 60 && line == line.uppercased() && line.count > 2)
            let fontSize: CGFloat = isHeading ? 22 : 12
            let bold = isHeading
            let display = line.trimmingCharacters(in: CharacterSet(charactersIn: "# ").union(.whitespaces))
            let height = fontSize * 1.35
            if y + height > pageHeight - margin {
                flushPage()
            }
            z += 1
            let frame = CGRect(x: margin, y: y, width: maxWidth, height: height)
            current.append(CanvasObject(
                frame: frame,
                zIndex: z,
                name: String(display.prefix(40)),
                kind: .text(.init(
                    text: display.isEmpty ? " " : display,
                    style: TextStyle(fontSize: fontSize, bold: bold)
                ))
            ))
            y += height + 4
        }
        if !current.isEmpty || pages.isEmpty {
            flushPage()
        }
        return DocumentScene(title: title, pages: pages)
    }

    // MARK: - textutil office

    public static func importViaTextutil(url: URL, title: String) throws -> DocumentScene {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("docuforge-import-\(UUID().uuidString).txt")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
        p.arguments = ["-convert", "txt", "-output", tmp.path, url.path]
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0, let text = try? String(contentsOf: tmp, encoding: .utf8) else {
            throw DocuForgeError.conversionFailed("Could not read \(url.lastPathComponent) via textutil.")
        }
        try? FileManager.default.removeItem(at: tmp)
        return sceneFromPlainText(text, title: title)
    }

    public static func importImage(url: URL) throws -> DocumentScene {
        guard let img = NSImage(contentsOf: url),
              let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            throw DocuForgeError.conversionFailed("Could not load image.")
        }
        let w = max(200, img.size.width)
        let h = max(200, img.size.height)
        let pageW: CGFloat = 612
        let pageH: CGFloat = 792
        let scale = min(pageW / w, pageH / h, 1)
        let dw = w * scale
        let dh = h * scale
        let frame = CGRect(x: (pageW - dw) / 2, y: (pageH - dh) / 2, width: dw, height: dh)
        let obj = CanvasObject(
            frame: frame,
            zIndex: 1,
            name: url.lastPathComponent,
            kind: .image(.init(imageData: png))
        )
        return DocumentScene(
            title: url.deletingPathExtension().lastPathComponent,
            pages: [DocPage(objects: [obj])]
        )
    }

    public static func blankDocument(title: String = "Untitled") -> DocumentScene {
        DocumentScene(title: title, pages: [DocPage()])
    }

    // MARK: - PDF text extraction helpers

    private struct TextLine {
        var text: String
        var bounds: CGRect
    }

    private static func extractTextLines(page: PDFPage, document: PDFDocument) -> [TextLine] {
        guard let full = page.string, !full.isEmpty else { return [] }
        let ns = full as NSString
        var lines: [TextLine] = []
        var start = 0

        func flush(end: Int) {
            guard end > start else { return }
            let range = NSRange(location: start, length: end - start)
            let raw = ns.substring(with: range)
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            let trim = (raw as NSString).range(of: text)
            let absRange: NSRange
            if trim.location != NSNotFound {
                absRange = NSRange(location: start + trim.location, length: trim.length)
            } else {
                absRange = range
            }
            guard let bounds = boundsForRange(page: page, document: document, range: absRange) else { return }
            lines.append(TextLine(text: text, bounds: bounds))
        }

        for i in 0..<ns.length {
            let ch = ns.character(at: i)
            if ch == 10 || ch == 13 || ch == 0x0C {
                flush(end: i)
                start = i + 1
            }
        }
        flush(end: ns.length)
        return lines
    }

    private static func boundsForRange(page: PDFPage, document: PDFDocument, range: NSRange) -> CGRect? {
        let end = max(range.location, NSMaxRange(range) - 1)
        if let sel = document.selection(
            from: page, atCharacterIndex: range.location,
            to: page, atCharacterIndex: end
        ) {
            let b = sel.bounds(for: page)
            if !b.isNull, b.width > 0.5, b.height > 0.5 { return b }
        }
        var union = CGRect.null
        for i in range.location..<NSMaxRange(range) {
            let b = page.characterBounds(at: i)
            if !b.isNull { union = union.union(b) }
        }
        return union.isNull ? nil : union
    }

    private static func estimateFontSize(height: CGFloat, text: String) -> CGFloat {
        max(8, min(72, height * 0.88))
    }

    private static func renderPageImage(_ page: PDFPage, scale: CGFloat) -> NSImage? {
        let media = page.bounds(for: .mediaBox)
        let size = CGSize(width: media.width * scale, height: media.height * scale)
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
        return image
    }
}
