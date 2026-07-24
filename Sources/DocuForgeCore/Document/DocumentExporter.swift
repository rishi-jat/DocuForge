import Foundation
import AppKit
import PDFKit
import CoreGraphics
import CoreText

/// Renders a `DocumentScene` to PDF (and other formats) from the object model —
/// never from glyph-cover patches.
public enum DocumentExporter {

    public static func exportPDF(_ scene: DocumentScene, to url: URL) throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("docuforge-export-\(UUID().uuidString).pdf")
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(url: temp as CFURL),
              let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw DocuForgeError.pdfOperationFailed("Could not create PDF context.")
        }

        for page in scene.pages {
            var box = CGRect(origin: .zero, size: page.size)
            ctx.beginPage(mediaBox: &box)

            // Background
            ctx.setFillColor(cgColor(page.background))
            ctx.fill(box)

            // Backdrop image
            if let data = page.backdropImageData, let img = NSImage(data: data),
               let cg = cgImage(img) {
                ctx.saveGState()
                // flip for top-left image into bottom-left PDF
                ctx.translateBy(x: 0, y: page.size.height)
                ctx.scaleBy(x: 1, y: -1)
                ctx.draw(cg, in: CGRect(origin: .zero, size: page.size))
                ctx.restoreGState()
            }

            for obj in page.sortedObjects {
                drawObject(obj, pageHeight: page.size.height, in: ctx)
            }

            ctx.endPage()
        }
        ctx.closePDF()

        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try FileManager.default.copyItem(at: temp, to: url)
        try? FileManager.default.removeItem(at: temp)
    }

    public static func exportPDFData(_ scene: DocumentScene) throws -> Data {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("docuforge-export-\(UUID().uuidString).pdf")
        try exportPDF(scene, to: url)
        let data = try Data(contentsOf: url)
        try? FileManager.default.removeItem(at: url)
        return data
    }

    // MARK: - Drawing

    private static func drawObject(_ obj: CanvasObject, pageHeight: CGFloat, in ctx: CGContext) {
        let pdfFrame = toPDF(obj.frame, pageHeight: pageHeight)
        ctx.saveGState()
        // Rotate around center
        let center = CGPoint(x: pdfFrame.midX, y: pdfFrame.midY)
        ctx.translateBy(x: center.x, y: center.y)
        ctx.rotate(by: -obj.rotation * .pi / 180) // PDF y-up; mirror rotation sign
        ctx.translateBy(x: -center.x, y: -center.y)

        switch obj.kind {
        case .text(let content):
            drawText(content, in: pdfFrame, ctx: ctx)
        case .image(let content):
            if let img = NSImage(data: content.imageData), let cg = cgImage(img) {
                ctx.draw(cg, in: pdfFrame)
            }
        case .shape(let content):
            drawShape(content, in: pdfFrame, ctx: ctx)
        case .table(let content):
            drawTable(content, in: pdfFrame, ctx: ctx)
        }
        ctx.restoreGState()
    }

    private static func drawText(_ content: CanvasObject.TextContent, in frame: CGRect, ctx: CGContext) {
        let font = ctFont(content.style)
        let color = cgColor(content.style.color)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color
        ]
        let attr = NSAttributedString(string: content.text, attributes: attrs)
        let framesetter = CTFramesetterCreateWithAttributedString(attr)
        // PDF y-up: flip text frame
        ctx.saveGState()
        ctx.translateBy(x: frame.minX, y: frame.maxY)
        ctx.scaleBy(x: 1, y: -1)
        let path = CGPath(rect: CGRect(x: 0, y: 0, width: frame.width, height: frame.height), transform: nil)
        let frameRef = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: attr.length), path, nil)
        CTFrameDraw(frameRef, ctx)
        ctx.restoreGState()
    }

    private static func drawShape(_ content: CanvasObject.ShapeContent, in frame: CGRect, ctx: CGContext) {
        ctx.setFillColor(cgColor(content.fill))
        ctx.setStrokeColor(cgColor(content.stroke))
        ctx.setLineWidth(content.strokeWidth)
        switch content.shape {
        case .rectangle:
            ctx.fill(frame)
            ctx.stroke(frame)
        case .ellipse:
            ctx.fillEllipse(in: frame)
            ctx.strokeEllipse(in: frame)
        case .line:
            ctx.move(to: CGPoint(x: frame.minX, y: frame.midY))
            ctx.addLine(to: CGPoint(x: frame.maxX, y: frame.midY))
            ctx.strokePath()
        }
    }

    private static func drawTable(_ content: CanvasObject.TableContent, in frame: CGRect, ctx: CGContext) {
        let rows = max(1, content.rows)
        let cols = max(1, content.columns)
        let cw = frame.width / CGFloat(cols)
        let rh = frame.height / CGFloat(rows)
        ctx.setStrokeColor(CGColor(gray: 0.4, alpha: 1))
        ctx.setLineWidth(0.5)
        for r in 0..<rows {
            for c in 0..<cols {
                let cell = CGRect(
                    x: frame.minX + CGFloat(c) * cw,
                    y: frame.minY + CGFloat(rows - 1 - r) * rh,
                    width: cw,
                    height: rh
                )
                ctx.stroke(cell)
                let text = (r < content.cells.count && c < content.cells[r].count)
                    ? content.cells[r][c].text : ""
                if !text.isEmpty {
                    drawText(
                        .init(text: text, style: content.style),
                        in: cell.insetBy(dx: 3, dy: 2),
                        ctx: ctx
                    )
                }
            }
        }
    }

    private static func toPDF(_ topLeft: CGRect, pageHeight: CGFloat) -> CGRect {
        CGRect(
            x: topLeft.origin.x,
            y: pageHeight - topLeft.origin.y - topLeft.height,
            width: topLeft.width,
            height: topLeft.height
        )
    }

    private static func ctFont(_ style: TextStyle) -> CTFont {
        var name = style.fontName
        if style.bold && style.italic { name = "Helvetica-BoldOblique" }
        else if style.bold { name = "Helvetica-Bold" }
        else if style.italic { name = "Helvetica-Oblique" }
        else if name == "Helvetica" || name.isEmpty { name = "Helvetica" }
        return CTFontCreateWithName(name as CFString, style.fontSize, nil)
    }

    private static func cgColor(_ c: CodableColor) -> CGColor {
        CGColor(red: c.r, green: c.g, blue: c.b, alpha: c.a)
    }

    private static func cgImage(_ image: NSImage) -> CGImage? {
        var rect = CGRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }
}
